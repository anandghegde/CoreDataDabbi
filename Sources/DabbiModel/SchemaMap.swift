import DabbiBase
import DabbiSQLite
import Foundation

/// The quarantine for private knowledge about how Core Data names things in SQLite.
///
/// Every name in here is a *guess by convention* that was then checked against `sqlite_master` and
/// `PRAGMA table_info`. A mapping with `verified == false` is never used for anything but display; features that
/// need one degrade with an explanation instead (see `FormatProbe`).
///
/// Conventions, as observed (ARCHITECTURE.md Appendix A and the format canary tests):
///
/// - An entity's rows live in `Z<ROOT>`, the table of the top of its inheritance chain, told apart by `Z_ENT`.
///   Entity numbers come from `Z_PRIMARYKEY`.
/// - Attribute `name` → column `ZNAME`. Composite attributes are flattened to their leaf elements' names.
/// - To-one `boss` → `ZBOSS`, plus `Z<n>_BOSS` holding the destination's entity number when the destination
///   entity has sub-entities.
/// - A to-many whose inverse is to-one is that inverse's column on the destination's table; when ordered, the
///   position is in `Z_FOK_<INVERSE>` next to it.
/// - Many-to-many → join table `Z_<n><REL>` with one column per direction, `Z_<m><REL>`, where the number is the
///   entity number of the rows the column points to; when ordered, the position is in `Z_FOK_<m><REL>`.
public struct SchemaMap: Sendable, Hashable, Codable {
    public struct EntityMap: Sendable, Hashable, Codable {
        public var entity: String
        public var table: String
        /// `Z_ENT` of the entity's rows. `nil` when `Z_PRIMARYKEY` does not list the entity.
        public var entityNumber: Int?
        /// The table exists and the entity has a number.
        public var verified: Bool
        /// Keyed by attribute name; composite leaves by dotted path, e.g. `address.location.latitude`.
        /// Transient attributes have no column and are absent.
        public var attributes: [String: ColumnMap]
        /// Keyed by relationship name. Transient relationships are absent.
        public var relationships: [String: RelationshipMap]
    }

    public struct ColumnMap: Sendable, Hashable, Codable {
        public var column: String
        public var verified: Bool
    }

    public struct RelationshipMap: Sendable, Hashable, Codable {
        public enum Storage: String, Sendable, Hashable, Codable {
            /// `column` on the source's table holds the destination's primary key.
            case foreignKey
            /// `column` on the destination's table holds the source's primary key.
            case inverseForeignKey
            /// `table` is a join table; `sourceColumn` and `column` hold the two primary keys.
            case joinTable
            /// A shape whose storage is not known (for example a to-many without an inverse).
            case unknown
        }

        public var storage: Storage
        public var table: String
        public var column: String
        public var sourceColumn: String?
        /// Holds the destination's entity number; only present when the destination has sub-entities.
        public var entityColumn: String?
        /// Holds the position within an ordered relationship.
        public var orderColumn: String?
        public var verified: Bool
    }

    public var entities: [String: EntityMap]

    /// Every table and column the map names was found in the database.
    public var isVerified: Bool {
        entities.values.allSatisfy { entity in
            entity.verified
                && entity.attributes.values.allSatisfy(\.verified)
                && entity.relationships.values.allSatisfy(\.verified)
        }
    }

    /// What could not be verified, as `Entity`, `Entity.property` — for diagnostics.
    public var unverified: [String] {
        entities.values.flatMap { entity -> [String] in
            (entity.verified ? [] : [entity.entity])
                + entity.attributes.filter { !$0.value.verified }.map { "\(entity.entity).\($0.key)" }
                + entity.relationships.filter { !$0.value.verified }.map { "\(entity.entity).\($0.key)" }
        }.sorted()
    }

    // MARK: Building

    public static func build(model: ModelDescription, connection: SQLiteConnection) throws -> SchemaMap {
        try connection.readTransaction {
            var schema = Schema(connection: connection)
            let numbers = try schema.entityNumbers()
            var entities: [String: EntityMap] = [:]
            for entity in model.entities {
                entities[entity.name] = try map(entity, in: model, numbers: numbers, schema: &schema)
            }
            return SchemaMap(entities: entities)
        }
    }

    private static func table(of entity: String, in model: ModelDescription) -> String {
        "Z" + (model.rootEntity(of: entity)?.name ?? entity).uppercased()
    }

    private static func map(
        _ entity: EntityDescription,
        in model: ModelDescription,
        numbers: [String: Int],
        schema: inout Schema
    ) throws -> EntityMap {
        let table = table(of: entity.name, in: model)
        let columns = try schema.columns(of: table)

        var attributes: [String: ColumnMap] = [:]
        for attribute in entity.attributes where !attribute.isTransient {
            for (path, leaf) in leaves(of: attribute, prefix: "") {
                let column = "Z" + leaf.uppercased()
                attributes[path] = ColumnMap(column: column, verified: columns.contains(column))
            }
        }

        var relationships: [String: RelationshipMap] = [:]
        for relationship in entity.relationships where !relationship.isTransient {
            relationships[relationship.name] = try map(
                relationship, sourceTable: table, in: model, numbers: numbers, schema: &schema)
        }

        return EntityMap(
            entity: entity.name,
            table: table,
            entityNumber: numbers[entity.name],
            verified: !columns.isEmpty && numbers[entity.name] != nil,
            attributes: attributes,
            relationships: relationships
        )
    }

    /// `(dotted path, leaf name)` of every stored value of an attribute: itself, or a composite's leaves.
    private static func leaves(of attribute: AttributeDescription, prefix: String) -> [(String, String)] {
        let path = prefix + attribute.name
        guard let elements = attribute.compositeElements else { return [(path, attribute.name)] }
        return elements.flatMap { leaves(of: $0, prefix: path + ".") }
    }

    private static func map(
        _ relationship: RelationshipDescription,
        sourceTable: String,
        in model: ModelDescription,
        numbers: [String: Int],
        schema: inout Schema
    ) throws -> RelationshipMap {
        let name = relationship.name.uppercased()
        let destinationTable = table(of: relationship.destinationEntity, in: model)
        let inverse = relationship.inverseName.flatMap {
            model.entity(named: relationship.destinationEntity)?.relationship(named: $0)
        }

        if !relationship.isToMany {
            let columns = try schema.columns(of: sourceTable)
            let column = "Z" + name
            let entityColumn = columns.first { $0.wholeMatch(of: /Z\d+_(.+)/)?.output.1 == name[...] }
            return RelationshipMap(
                storage: .foreignKey, table: sourceTable, column: column, entityColumn: entityColumn,
                verified: columns.contains(column))
        }

        guard let inverse else {
            return RelationshipMap(storage: .unknown, table: "", column: "", verified: false)
        }

        if !inverse.isToMany {
            let columns = try schema.columns(of: destinationTable)
            let column = "Z" + inverse.name.uppercased()
            let orderColumn = relationship.isOrdered ? "Z_FOK_" + inverse.name.uppercased() : nil
            return RelationshipMap(
                storage: .inverseForeignKey, table: destinationTable, column: column, orderColumn: orderColumn,
                verified: columns.contains(column) && orderColumn.map(columns.contains) ?? true)
        }

        // Many-to-many. Column numbers are the entity numbers of the rows a column points to: the relationship's
        // destination entity for its own column, the inverse's destination (= this side) for the other.
        guard let destinationNumber = numbers[relationship.destinationEntity],
            let sourceNumber = numbers[inverse.destinationEntity]
        else {
            return RelationshipMap(storage: .joinTable, table: "", column: "", verified: false)
        }
        let inverseName = inverse.name.uppercased()
        let column = "Z_\(destinationNumber)\(name)"
        let sourceColumn = "Z_\(sourceNumber)\(inverseName)"
        let orderColumn = relationship.isOrdered ? "Z_FOK_\(destinationNumber)\(name)" : nil
        // The table is named after one of the two directions.
        let candidates = ["Z_\(sourceNumber)\(name)", "Z_\(destinationNumber)\(inverseName)"]
        for candidate in candidates {
            let columns = try schema.columns(of: candidate)
            guard columns.contains(column), columns.contains(sourceColumn) else { continue }
            return RelationshipMap(
                storage: .joinTable, table: candidate, column: column, sourceColumn: sourceColumn,
                orderColumn: orderColumn, verified: orderColumn.map(columns.contains) ?? true)
        }
        return RelationshipMap(
            storage: .joinTable, table: candidates[0], column: column, sourceColumn: sourceColumn,
            orderColumn: orderColumn, verified: false)
    }
}

/// Table and column lookups against the live database, cached for the duration of one map build.
private struct Schema {
    let connection: SQLiteConnection
    private var columnCache: [String: Set<String>] = [:]

    init(connection: SQLiteConnection) {
        self.connection = connection
    }

    /// Column names of `table`; empty when the table does not exist.
    mutating func columns(of table: String) throws -> Set<String> {
        if let cached = columnCache[table] { return cached }
        let columns = Set(try connection.columnNames(ofTable: table))
        columnCache[table] = columns
        return columns
    }

    /// Entity name → `Z_ENT`, from `Z_PRIMARYKEY`. Empty when the table is missing.
    func entityNumbers() throws -> [String: Int] {
        guard try connection.tableExists("Z_PRIMARYKEY") else { return [:] }
        var numbers: [String: Int] = [:]
        for row in try connection.query("SELECT Z_ENT, Z_NAME FROM Z_PRIMARYKEY") {
            if let number = row[0].int64, let name = row[1].string { numbers[name] = Int(number) }
        }
        return numbers
    }
}
