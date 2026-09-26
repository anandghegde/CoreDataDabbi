import DabbiBase
import DabbiModel
import DabbiSQLite
import Foundation

@testable import DabbiStore

/// What "not corrupted" means for a store the fuzzer or the soak has written to (PRD §10 Reliability), checked
/// from outside the session that wrote it.
///
/// - SQLite: `integrity_check` says `ok`.
/// - Core Data's bookkeeping: every row's `Z_ENT` is an entity that lives in its table, and no primary key is past
///   the `Z_MAX` its table's entities have handed out — else the next insert collides.
/// - References: no to-one column or join-table row names a row that is not there, where Core Data keeps them.
/// - Core Data: the store opens afresh, every object of every entity materialises, and the counts are the ones
///   the writer last committed.
enum StoreSoundness {
    /// The store's rows as SQLite sees them: per table, how many and the sum of their `Z_OPT`. Any write that
    /// reaches the file changes one of them, so equal fingerprints around a refused commit mean nothing leaked.
    struct Fingerprint: Hashable, CustomStringConvertible {
        var tables: [String: [Int64]]

        var description: String {
            tables.sorted { $0.key < $1.key }.map { "\($0.key): \($0.value)" }.joined(separator: ", ")
        }
    }

    static func fingerprint(of store: URL, schema: SchemaMap) throws -> Fingerprint {
        let connection = try SQLiteConnection(readOnly: store)
        defer { connection.close() }
        var tables: [String: [Int64]] = [:]
        for table in Set(schema.entities.values.filter(\.verified).map(\.table)) {
            let quoted = SQLiteConnection.quoteIdentifier(table)
            let row = try connection.query("SELECT count(*), total(Z_OPT) FROM \(quoted)").first
            tables[table] = [row?[0].int64 ?? -1, Int64(row?[1].double ?? -1)]
        }
        for table in try connection.tableNames() where table.hasPrefix("Z_") && table.first(where: \.isNumber) != nil {
            // Many-to-many join tables: `Z_<n><REL>`.
            let rows = try connection.scalar("SELECT count(*) FROM \(SQLiteConnection.quoteIdentifier(table))")
            tables[table] = [rows?.int64 ?? -1]
        }
        return Fingerprint(tables: tables)
    }

    /// Everything SQLite and Core Data's own tables say about the file. Problems, described without row data.
    static func fileProblems(of store: URL, model: ModelDescription, schema: SchemaMap) throws -> [String] {
        let connection = try SQLiteConnection(readOnly: store)
        defer { connection.close() }
        var problems: [String] = []

        let integrity = try connection.query("PRAGMA integrity_check", maxRows: 5).compactMap { $0[0].string }
        if integrity != ["ok"] { problems.append("integrity_check: \(integrity.joined(separator: "; "))") }

        var maxima: [Int: Int64] = [:]
        for row in try connection.query("SELECT Z_ENT, Z_MAX FROM Z_PRIMARYKEY") {
            if let entity = row[0].int64, let max = row[1].int64 { maxima[Int(entity)] = max }
        }
        let byTable = Dictionary(grouping: schema.entities.values.filter(\.verified), by: \.table)
        for (table, entities) in byTable {
            let quoted = SQLiteConnection.quoteIdentifier(table)
            let numbers = entities.compactMap(\.entityNumber)
            let known = numbers.map(String.init).joined(separator: ",")
            let strays = try connection.scalar("SELECT count(*) FROM \(quoted) WHERE Z_ENT NOT IN (\(known))")
            if let strays = strays?.int64, strays > 0 { problems.append("\(table): \(strays) rows of no entity") }
            let highest = try connection.scalar("SELECT max(Z_PK) FROM \(quoted)")?.int64 ?? 0
            let handedOut = numbers.compactMap { maxima[$0] }.max() ?? 0
            if highest > handedOut { problems.append("\(table): Z_PK \(highest) is past Z_MAX \(handedOut)") }
        }

        for entity in model.entities {
            guard let map = schema.entities[entity.name], map.verified else { continue }
            for relationship in entity.relationships where relationship.declaredIn == entity.name {
                // Only what Core Data keeps: through a relationship with no inverse, or one whose inverse has No
                // Action, a delete leaves the reference behind by design — the delete preview says so (EDT-2),
                // and Core Data reads it as nothing.
                guard
                    let inverse = relationship.inverseName.flatMap({
                        model.entity(named: relationship.destinationEntity)?.relationship(named: $0)
                    }), inverse.deleteRule != .noAction
                else { continue }
                guard let storage = map.relationships[relationship.name], storage.verified,
                    let destination = schema.entities[relationship.destinationEntity], destination.verified
                else { continue }
                let target = SQLiteConnection.quoteIdentifier(destination.table)
                let column = SQLiteConnection.quoteIdentifier(storage.column)
                let sql: String
                switch storage.storage {
                case .foreignKey:
                    sql = """
                        SELECT count(*) FROM \(SQLiteConnection.quoteIdentifier(storage.table)) \
                        WHERE \(column) IS NOT NULL AND \(column) NOT IN (SELECT Z_PK FROM \(target))
                        """
                case .joinTable:
                    sql = """
                        SELECT count(*) FROM \(SQLiteConnection.quoteIdentifier(storage.table)) \
                        WHERE \(column) NOT IN (SELECT Z_PK FROM \(target))
                        """
                case .inverseForeignKey, .unknown:
                    continue
                }
                if let dangling = try connection.scalar(sql)?.int64, dangling > 0 {
                    problems.append("\(entity.name).\(relationship.name): \(dangling) references to no row")
                }
            }
        }
        return problems
    }

    /// Opens the store afresh, read-only, and materialises every object. The own count of each entity.
    static func reopen(_ store: URL, modelURL: URL?) async throws -> [String: Int] {
        let session = try await StoreSession.open(storeURL: store, modelURL: modelURL)
        defer { Task { await session.close() } }
        var counts: [String: Int] = [:]
        for entity in session.info.model.entities {
            let refs = try await session.references(FetchSpec(entity: entity.name, includeSubentities: false))
            let objects = try await session.objects(refs)
            if objects.count != refs.count {
                throw StoreSoundnessError("\(entity.name): \(refs.count - objects.count) objects did not materialise")
            }
            counts[entity.name] = refs.count
        }
        return counts
    }

    /// The own count of each entity, as `session` has it: what it last committed, when nothing is staged.
    static func counts(in session: StoreSession) async throws -> [String: Int] {
        Dictionary(uniqueKeysWithValues: try await session.entityCounts().map { ($0.entity, $0.own) })
    }
}

struct StoreSoundnessError: Error, CustomStringConvertible {
    let description: String
    init(_ description: String) { self.description = description }
}

/// SplitMix64: small, fast, and the same sequence for the same seed on every machine — a failing seed is a
/// reproduction.
struct SeededGenerator: RandomNumberGenerator {
    private var state: UInt64

    init(seed: UInt64) { state = seed }

    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
}
