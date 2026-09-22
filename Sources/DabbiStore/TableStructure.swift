import DabbiBase
import DabbiSQLite
import Foundation

/// How one entity is actually stored (BRW-8, "Structure tab").
///
/// `SchemaMap` says which table and columns an entity's properties are expected to live in; this is what SQLite
/// says it has. It is read straight out of `sqlite_master` and `PRAGMA table_info`, so it is a fact about the
/// file rather than a guess by convention — and it is how a guess gets checked when the two disagree.
///
/// It is for reading only. Nothing in the app builds a query out of it.
public struct TableStructure: Sendable, Hashable, Codable {
    public struct Column: Sendable, Hashable, Codable {
        public var name: String
        /// The declared type, as SQLite records it: `INTEGER`, `VARCHAR`, `BLOB`, or empty when undeclared.
        public var declaredType: String
        public var isNotNull: Bool
        public var defaultValue: String?
        /// Its position in the primary key, counting from 1; `nil` when it is not part of one.
        public var primaryKeyPosition: Int?

        public init(
            name: String, declaredType: String, isNotNull: Bool, defaultValue: String?, primaryKeyPosition: Int?
        ) {
            self.name = name
            self.declaredType = declaredType
            self.isNotNull = isNotNull
            self.defaultValue = defaultValue
            self.primaryKeyPosition = primaryKeyPosition
        }
    }

    public struct Index: Sendable, Hashable, Codable {
        public var name: String
        public var isUnique: Bool
        /// The columns it covers, in order. Empty for an index over an expression.
        public var columns: [String]
        /// The `CREATE INDEX` statement, or `nil` for the ones SQLite makes itself for a `UNIQUE` constraint.
        public var definition: String?

        public init(name: String, isUnique: Bool, columns: [String], definition: String?) {
            self.name = name
            self.isUnique = isUnique
            self.columns = columns
            self.definition = definition
        }
    }

    public var entity: String
    public var table: String
    /// The `CREATE TABLE` statement as SQLite stores it, whitespace and all.
    public var definition: String?
    public var columns: [Column]
    public var indexes: [Index]
    /// The join tables of this entity's many-to-many relationships, keyed by relationship name. A row of one of
    /// them belongs to no entity, so it has nowhere else to be shown.
    public var joinTables: [String: TableStructure]

    public init(
        entity: String, table: String, definition: String?, columns: [Column], indexes: [Index],
        joinTables: [String: TableStructure] = [:]
    ) {
        self.entity = entity
        self.table = table
        self.definition = definition
        self.columns = columns
        self.indexes = indexes
        self.joinTables = joinTables
    }

    /// Everything above as one SQL script, for the Copy button and for anyone who would rather read SQL.
    public var script: String {
        var parts: [String] = []
        if let definition { parts.append(definition.trimmingCharacters(in: .whitespacesAndNewlines) + ";") }
        parts += indexes.compactMap { $0.definition?.trimmingCharacters(in: .whitespacesAndNewlines) }.map { $0 + ";" }
        for name in joinTables.keys.sorted() {
            guard let join = joinTables[name] else { continue }
            parts.append("-- \(entity).\(name)")
            parts.append(join.script)
        }
        return parts.joined(separator: "\n")
    }

    // MARK: Reading

    /// Reads the structure of `table` out of an open connection.
    ///
    /// The names go into the SQL as bound values wherever SQLite allows it. `PRAGMA` takes no bindings, so the
    /// table name is quoted instead — and it never comes from the user: it comes from `SchemaMap`, which builds
    /// it out of the model and checks it against `sqlite_master` first.
    static func read(table: String, entity: String, connection: SQLiteConnection) throws -> TableStructure {
        let definition = try connection.scalar(
            "SELECT sql FROM sqlite_master WHERE type = 'table' AND name = ?", [.text(table)])?.string

        let quoted = "\"" + table.replacingOccurrences(of: "\"", with: "\"\"") + "\""
        let columns = try connection.query("PRAGMA table_info(\(quoted))").map { row in
            Column(
                name: row[1].string ?? "",
                declaredType: row[2].string ?? "",
                isNotNull: (row[3].int64 ?? 0) != 0,
                defaultValue: row[4].string,
                primaryKeyPosition: row[5].int64.flatMap { $0 > 0 ? Int($0) : nil })
        }

        // `origin` is "c" for an index someone wrote, "u"/"pk" for the ones SQLite adds for constraints; both
        // are worth showing, because both are what a query will or will not be able to use.
        let indexes = try connection.query("PRAGMA index_list(\(quoted))").compactMap { row -> Index? in
            guard let name = row[1].string else { return nil }
            let quotedIndex = "\"" + name.replacingOccurrences(of: "\"", with: "\"\"") + "\""
            let columns = try connection.query("PRAGMA index_info(\(quotedIndex))").compactMap { $0[2].string }
            let definition = try connection.scalar(
                "SELECT sql FROM sqlite_master WHERE type = 'index' AND name = ?", [.text(name)])?.string
            return Index(name: name, isUnique: (row[2].int64 ?? 0) != 0, columns: columns, definition: definition)
        }

        return TableStructure(
            entity: entity, table: table, definition: definition, columns: columns, indexes: indexes)
    }
}
