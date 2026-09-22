import DabbiBase
import DabbiModel
import DabbiSQLite
import Foundation

/// Persistent history read straight out of the tables Core Data keeps it in (ARCHITECTURE.md §6.6, Appendix A).
///
/// The fallback behind `CoreDataHistoryReader`, and quarantined private knowledge exactly like `SchemaMap`:
/// every rule below was observed and is checked against the file before it is used, and anything that does not
/// check out is left unknown rather than guessed (ADR-17).
///
/// The layout, as observed:
///
/// - `ATRANSACTION` — one row per save. `Z_PK` is the transaction number Core Data's own token counts in.
///   `ZTIMESTAMP` is seconds since the Core Data reference date. Author, bundle identifier, context name and
///   process name are *interned*: the `Z…TS` integer columns hold `ATRANSACTIONSTRING.Z_PK`, and the `VARCHAR`
///   columns of the same names sit empty beside them.
/// - `ACHANGE` — one row per row a transaction touched. `ZCHANGETYPE` is 0 inserted, 1 updated, 2 deleted;
///   `ZENTITY` is the row's `Z_ENT` and `ZENTITYPK` its `Z_PK`; `ZTRANSACTIONID` points back to the transaction.
/// - `ACHANGE.ZCOLUMNS` — which properties an update wrote, as a bitmap read most-significant-bit first: bit 0 is
///   `0x80` of the first byte. Bit *i* is the *i*-th of the entity's non-transient properties **sorted by name**,
///   attributes and relationships in one list together — not attributes and then relationships, and not the order
///   the columns sit in the row's table, both of which the Notes fixture rules out. `NULL` on an insert or a
///   delete, where there is nothing to narrow down.
/// - `ACHANGE.ZTOMBSTONE<n>` — columns added to the table, one per preserving attribute, indexed the same way:
///   the *n*-th name of the entity's attributes that set `preservesValueInHistoryOnDeletion`, sorted by name.
///
/// Where this reader is weaker than the Core Data one: a save whose property bitmap is wider than the model
/// knows about, or an entity number `Z_PRIMARYKEY` does not name, leaves `updatedProperties` `nil` rather than
/// a partial answer.
public actor RawHistoryReader: HistoryReader {
    /// The tables this reader needs. `ATRANSACTIONSTRING` is optional — without it authors are read from the
    /// `VARCHAR` columns, which in practice are empty, and so come back unknown.
    static let transactionTable = "ATRANSACTION"
    static let changeTable = "ACHANGE"
    static let stringTable = "ATRANSACTIONSTRING"

    public nonisolated let source = HistorySource.rawTables
    public nonisolated let url: URL

    private let entityNames: [Int64: String]
    private let layouts: [String: Layout]

    private var reader: SQLiteReader?
    private var shape: Shape?

    /// - Parameters:
    ///   - url: the store. The reader opens its own read-only connection, separate from the scanner's and from
    ///     any `StoreSession`, and holds no transaction between calls.
    ///   - model: what entity and property names mean.
    ///   - schema: where the entity numbers come from (`Z_PRIMARYKEY`, already read and verified).
    public init(url: URL, model: ModelDescription, schema: SchemaMap) {
        self.url = url
        var names: [Int64: String] = [:]
        var layouts: [String: Layout] = [:]
        for entity in model.entities {
            if let number = schema.entities[entity.name]?.entityNumber {
                names[Int64(number)] = entity.name
            }
            layouts[entity.name] = Layout(entity)
        }
        self.entityNames = names
        self.layouts = layouts
    }

    public func currentToken() async throws -> HistoryToken? {
        let reader = try openedReader()
        _ = try await ensureShape(reader)
        let number = try await reader.read { connection in
            try connection.scalar("SELECT MAX(Z_PK) FROM \(Self.transactionTable)")?.int64
        }
        // No rows is not no history: the tables are there, nothing has been saved into them yet.
        return HistoryToken(transactionNumber: number ?? 0)
    }

    public func transactions(after token: HistoryToken?, limit: Int?) async throws -> [HistoryTransaction] {
        if let limit, limit <= 0 { return [] }
        let reader = try openedReader()
        let shape = try await ensureShape(reader)
        let floor = token?.transactionNumber ?? 0
        let (entityNames, layouts) = (self.entityNames, self.layouts)

        return try await reader.read { connection -> [HistoryTransaction] in
            // One transaction over both tables: a save landing between the two queries would otherwise show up
            // as changes belonging to no transaction.
            try connection.readTransaction { () -> [HistoryTransaction] in
                var transactions = try Self.readTransactions(after: floor, shape: shape, connection: connection)
                if let limit, transactions.count > limit {
                    transactions.removeFirst(transactions.count - limit)
                }
                guard let first = transactions.first, let last = transactions.last else { return [] }
                let changes = try Self.readChanges(
                    from: first.number, to: last.number, shape: shape, entityNames: entityNames,
                    layouts: layouts, connection: connection)
                return transactions.map {
                    var transaction = $0
                    transaction.changes = changes[$0.number] ?? []
                    return transaction
                }
            }
        }
    }

    public func close() {
        let reader = self.reader
        self.reader = nil
        shape = nil
        Task { await reader?.close() }
    }

    // MARK: The connection

    private func openedReader() throws -> SQLiteReader {
        if let reader { return reader }
        let reader = try SQLiteReader(url: url)
        self.reader = reader
        return reader
    }

    private func ensureShape(_ reader: SQLiteReader) async throws -> Shape {
        if let shape { return shape }
        let shape = try await reader.read { try Shape(connection: $0) }
        guard shape.isUsable else {
            throw DabbiError(
                .historyUnavailable, "This store has no persistent history tables.",
                arguments: ["path": url.path],
                diagnosis: ["\(Self.transactionTable) or \(Self.changeTable) is not in the database."],
                recovery: ["Changes are still detected by scanning, and still reported."])
        }
        self.shape = shape
        return shape
    }

    // MARK: Reading — called inside one read transaction

    private static func readTransactions(
        after floor: Int64, shape: Shape, connection: SQLiteConnection
    ) throws -> [HistoryTransaction] {
        var select = ["t.Z_PK"]
        var joins: [String] = []
        select.append(shape.has(.transaction, "ZTIMESTAMP") ? "t.ZTIMESTAMP" : "NULL")
        for (index, field) in Shape.internedFields.enumerated() {
            // Interned first, because that is where the value actually is; the VARCHAR twin is the documented
            // shape and is empty on every store looked at.
            if shape.hasStrings, shape.has(.transaction, field.key) {
                let alias = "s\(index)"
                joins.append("LEFT JOIN \(stringTable) \(alias) ON \(alias).Z_PK = t.\(field.key)")
                select.append("\(alias).ZNAME")
            } else if shape.has(.transaction, field.text) {
                select.append("t.\(field.text)")
            } else {
                select.append("NULL")
            }
        }
        let sql = """
            SELECT \(select.joined(separator: ", ")) FROM \(transactionTable) t \
            \(joins.joined(separator: " ")) WHERE t.Z_PK > ? ORDER BY t.Z_PK
            """
        return try connection.query(sql, [.integer(floor)]).map { row in
            HistoryTransaction(
                number: row[0].int64 ?? 0,
                timestamp: row[1].double.map { Date(timeIntervalSinceReferenceDate: $0) },
                author: row[2].string.flatMap(nonEmpty),
                contextName: row[4].string.flatMap(nonEmpty),
                bundleID: row[3].string.flatMap(nonEmpty),
                processID: row[5].string.flatMap(nonEmpty))
        }
    }

    private static func readChanges(
        from first: Int64,
        to last: Int64,
        shape: Shape,
        entityNames: [Int64: String],
        layouts: [String: Layout],
        connection: SQLiteConnection
    ) throws -> [Int64: [HistoryChange]] {
        let columns =
            ["ZTRANSACTIONID", "ZCHANGETYPE", "ZENTITY", "ZENTITYPK", "ZCOLUMNS"] + shape.tombstoneColumns
        let sql = """
            SELECT \(columns.joined(separator: ", ")) FROM \(changeTable) \
            WHERE ZTRANSACTIONID BETWEEN ? AND ? ORDER BY ZTRANSACTIONID, Z_PK
            """
        var result: [Int64: [HistoryChange]] = [:]
        for row in try connection.query(sql, [.integer(first), .integer(last)]) {
            guard let transaction = row[0].int64, let pk = row[3].int64,
                let number = row[2].int64, let entity = entityNames[number],
                let kind = kind(row[1])
            else { continue }
            let layout = layouts[entity]
            var updated: Set<String>?
            if kind == .updated, let bitmap = row[4].data, let layout {
                updated = layout.properties(in: bitmap)
            }
            var tombstone: [String: Value] = [:]
            if kind == .deleted, let layout {
                for (index, attribute) in layout.tombstones.enumerated() where index + 5 < row.values.count {
                    let raw = row[index + 5]
                    guard !raw.isNull else { continue }
                    tombstone[attribute.name] = value(raw, of: attribute)
                }
            }
            result[transaction, default: []].append(
                HistoryChange(
                    entity: entity, pk: pk, kind: kind, updatedProperties: updated, tombstone: tombstone))
        }
        return result
    }

    private static func nonEmpty(_ string: String) -> String? { string.isEmpty ? nil : string }

    /// `ACHANGE.ZCHANGETYPE`. A fourth value is one this reader has never seen and will not guess at: the row is
    /// dropped, and the scan — which found the row anyway — remains the answer (ADR-17).
    private static func kind(_ raw: SQLiteValue) -> HistoryChange.Kind? {
        switch raw.int64 {
        case 0: .inserted
        case 1: .updated
        case 2: .deleted
        default: nil
        }
    }

    // MARK: One entity's private ordering

    /// The two orderings `ACHANGE` indexes an entity's properties by. Worked out from the model alone, then
    /// checked against the width of what the file actually holds.
    struct Layout: Sendable {
        /// `ZCOLUMNS` bit order.
        let properties: [String]
        /// `ZTOMBSTONE<n>` column order.
        let tombstones: [AttributeDescription]

        init(_ entity: EntityDescription) {
            let attributes = entity.attributes.filter { !$0.isTransient }
            // Inherited properties are in `attributes` and `relationships` already, which is what makes two
            // entities sharing one table have two different orders — as they must, since a bit means a name.
            properties =
                (attributes.map(\.name) + entity.relationships.filter { !$0.isTransient }.map(\.name)).sorted()
            tombstones = attributes.filter(\.preservesValueInHistoryOnDeletion).sorted { $0.name < $1.name }
        }

        /// The names the bitmap's set bits stand for.
        ///
        /// `nil` when the file claims a property this model does not have — a model that no longer matches the
        /// store. A partial answer would read as *these fields and no others*, which would be a lie.
        func properties(in bitmap: Data) -> Set<String>? {
            var names: Set<String> = []
            for (byte, bits) in bitmap.enumerated() {
                guard bits != 0 else { continue }
                for offset in 0..<8 where bits & (0x80 >> UInt8(offset)) != 0 {
                    let index = byte * 8 + offset
                    guard index < properties.count else { return nil }
                    names.insert(properties[index])
                }
            }
            return names
        }
    }

    // MARK: What this file actually has

    /// The columns the two tables carry here, read once per connection. Core Data has added columns to these
    /// tables across releases, and `ZTOMBSTONE<n>` depends on the model, so nothing is assumed.
    struct Shape: Sendable {
        enum Table { case transaction, change }

        /// `(interned key column, VARCHAR twin)` in the order `HistoryTransaction` takes them:
        /// author, bundle identifier, context name, process name.
        static let internedFields: [(key: String, text: String)] = [
            ("ZAUTHORTS", "ZAUTHOR"), ("ZBUNDLEIDTS", "ZBUNDLEID"),
            ("ZCONTEXTNAMETS", "ZCONTEXTNAME"), ("ZPROCESSIDTS", "ZPROCESSID"),
        ]

        let transactionColumns: Set<String>
        let changeColumns: Set<String>
        let hasStrings: Bool
        /// `ZTOMBSTONE0`, `ZTOMBSTONE1`, … as far as the table goes, in index order.
        let tombstoneColumns: [String]

        init(connection: SQLiteConnection) throws {
            transactionColumns = Set(try connection.columnNames(ofTable: transactionTable))
            changeColumns = Set(try connection.columnNames(ofTable: changeTable))
            hasStrings = try connection.tableExists(stringTable)
            var tombstones: [String] = []
            while changeColumns.contains("ZTOMBSTONE\(tombstones.count)") {
                tombstones.append("ZTOMBSTONE\(tombstones.count)")
            }
            tombstoneColumns = tombstones
        }

        var isUsable: Bool {
            transactionColumns.contains("Z_PK") && changeColumns.contains("ZTRANSACTIONID")
                && changeColumns.contains("ZENTITY") && changeColumns.contains("ZENTITYPK")
                && changeColumns.contains("ZCHANGETYPE")
        }

        func has(_ table: Table, _ column: String) -> Bool {
            switch table {
            case .transaction: transactionColumns.contains(column)
            case .change: changeColumns.contains(column)
            }
        }
    }

    // MARK: Tombstone values

    /// One stored value as the attribute's type reads it.
    ///
    /// The raw twin of `ValueConverter.value(_:of:)`: that one converts what Core Data hands back, this one
    /// converts what SQLite holds, and the two have to agree so that a tombstone reads the same however it was
    /// read. A value whose storage does not match its declared type is reported as unknown, not coerced.
    static func value(_ raw: SQLiteValue, of attribute: AttributeDescription) -> Value {
        switch attribute.type {
        case .integer16, .integer32, .integer64:
            return raw.int64.map(Value.int) ?? .null
        case .double, .float:
            return raw.double.map(Value.double) ?? .null
        case .decimal:
            return raw.double.map { .decimal(Decimal($0)) } ?? raw.int64.map { .decimal(Decimal($0)) } ?? .null
        case .boolean:
            return raw.int64.map { .bool($0 != 0) } ?? .null
        case .string:
            return raw.string.map(Value.string) ?? .null
        case .date:
            // Core Data's own epoch, 2001-01-01, exactly as the row columns store it.
            return raw.double.map { .date(Date(timeIntervalSinceReferenceDate: $0)) } ?? .null
        case .uuid:
            if let data = raw.data, data.count == 16 {
                return .uuid(UUID(uuid: data.withUnsafeBytes { $0.load(as: uuid_t.self) }))
            }
            return raw.string.flatMap(UUID.init(uuidString:)).map(Value.uuid) ?? .null
        case .uri:
            return raw.string.flatMap(URL.init(string:)).map(Value.url) ?? .null
        case .objectID:
            return raw.string.flatMap(URL.init(string:)).map(Value.url) ?? .null
        case .binaryData, .transformable:
            guard let data = raw.data else { return .null }
            return .blob(
                BlobSummary(
                    byteCount: data.count,
                    sniffedType: MagicSniffer.sniff(data.prefix(MagicSniffer.prefixLength)),
                    isExternal: attribute.allowsExternalBinaryDataStorage))
        case .composite, .undefined:
            // A composite is several columns; a tombstone is one. Nothing honest to say.
            return .null
        }
    }
}
