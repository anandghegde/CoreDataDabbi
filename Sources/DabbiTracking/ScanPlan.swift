import DabbiModel
import DabbiSQLite
import Foundation

/// What a scan reads, worked out once: which tables, which of their columns are really there, and which `Z_ENT`
/// number means which entity (ARCHITECTURE.md §6.6).
///
/// Built from three things that must agree — the model, the `SchemaMap` that maps it to this file's tables, and
/// the file's own `PRAGMA table_info`. Where they do not agree the plan records a `ScanLimitation` and carries
/// on with what it can do; nothing here throws for a store that is merely unusual.
struct ScanPlan: Sendable {
    /// One entity table. Sub-entities share it, so a table is planned once however many entities it holds.
    struct Table: Sendable {
        var table: String
        var hasEntityColumn: Bool
        var hasOptimisticLockColumn: Bool
        /// `Z_ENT` → entity name, for the entities in scope. A row whose number is not here is not reported.
        var entities: [Int32: String]
        /// Every `Z_ENT` the model and `Z_PRIMARYKEY` agree on, in scope or not. A number outside this set
        /// belongs to no entity the model describes, which is worth saying; a number inside it but outside
        /// `entities` is simply not being tracked.
        var knownNumbers: Set<Int32>
        /// The entity every row belongs to when the table has no `Z_ENT` at all. Only set when exactly one
        /// concrete entity lives in the table, because otherwise its rows cannot be told apart.
        var soleEntity: String?
    }

    /// One many-to-many join table. The two directions share it, so it is planned once, under whichever
    /// relationship name sorted first.
    struct Join: Sendable {
        var table: String
        var relationship: String
        var sourceEntity: String
        var destinationEntity: String
        var sourceColumn: String
        var destinationColumn: String
        /// `Z_FOK_…`, when the relationship is ordered and the column is there.
        var orderColumn: String?
    }

    var tables: [Table] = []
    var joins: [Join] = []
    var limitations: [ScanLimitation] = []

    /// For the log line: `ZNOTE: noOptimisticLockColumn`, comma-separated. Table, entity and property names
    /// only — never a row value (§10).
    var limitationSummary: String {
        limitations.map { "\($0.subject): \($0.reason.rawValue)" }.joined(separator: ", ")
    }

    // MARK: Building

    static func build(
        model: ModelDescription, schema: SchemaMap, scope: TrackingScope, connection: SQLiteConnection
    ) throws -> ScanPlan {
        var plan = ScanPlan()
        let tracked = scope.resolved(in: model)
        let knownNumbers = Set(schema.entities.values.compactMap { $0.entityNumber.map(Int32.init) })

        // Entities first, grouped by the table they share. Order is the tables' own, so a scan reads them in
        // the same order every time and the one transaction is as short as it can be.
        var numbersByTable: [String: [Int32: String]] = [:]
        var entitiesByTable: [String: [String]] = [:]
        for entity in tracked {
            guard let map = schema.entities[entity], map.verified, let number = map.entityNumber else {
                plan.limitations.append(ScanLimitation(reason: .unverifiedTable, subject: entity))
                continue
            }
            numbersByTable[map.table, default: [:]][Int32(number)] = entity
            entitiesByTable[map.table, default: []].append(entity)
        }

        for table in numbersByTable.keys.sorted() {
            let columns = Set(try connection.columnNames(ofTable: table))
            guard !columns.isEmpty else {
                plan.limitations.append(ScanLimitation(reason: .missingTable, subject: table))
                continue
            }
            let hasEntityColumn = columns.contains("Z_ENT")
            let hasOptimisticLockColumn = columns.contains("Z_OPT")
            if !hasOptimisticLockColumn {
                plan.limitations.append(
                    ScanLimitation(reason: .noOptimisticLockColumn, subject: table))
            }

            var soleEntity: String?
            if !hasEntityColumn {
                // Without `Z_ENT` the rows can only be attributed when there is nothing to attribute them
                // between — and that means every concrete entity of the hierarchy, not only the tracked ones.
                let occupants = Self.concreteEntities(ofTable: table, model: model, schema: schema)
                guard occupants.count == 1, let only = occupants.first, entitiesByTable[table] == [only] else {
                    plan.limitations.append(ScanLimitation(reason: .noEntityColumn, subject: table))
                    continue
                }
                soleEntity = only
            }

            plan.tables.append(
                Table(
                    table: table,
                    hasEntityColumn: hasEntityColumn,
                    hasOptimisticLockColumn: hasOptimisticLockColumn,
                    entities: numbersByTable[table] ?? [:],
                    knownNumbers: knownNumbers,
                    soleEntity: soleEntity))
        }

        plan.joins = Self.joins(model: model, schema: schema, tracked: tracked, limitations: &plan.limitations)
        return plan
    }

    /// Every concrete entity whose rows live in `table`, tracked or not.
    private static func concreteEntities(
        ofTable table: String, model: ModelDescription, schema: SchemaMap
    ) -> [String] {
        model.entities
            .filter { !$0.isAbstract && schema.entities[$0.name]?.table == table }
            .map(\.name)
    }

    /// The join tables of the tracked entities' many-to-many relationships, one entry per table.
    ///
    /// A to-many stored as a foreign key on the destination — the ordinary one-to-many — is not here: gaining or
    /// losing such a link *is* an update of the destination row, and the row diff reports it already. What needs
    /// its own diff is the storage the row diff cannot see: a separate table with no `Z_PK` of its own.
    private static func joins(
        model: ModelDescription, schema: SchemaMap, tracked: [String], limitations: inout [ScanLimitation]
    ) -> [Join] {
        var joins: [Join] = []
        var seen: Set<String> = []

        for entity in tracked {
            guard let entityMap = schema.entities[entity], let description = model.entity(named: entity) else {
                continue
            }
            for name in entityMap.relationships.keys.sorted() {
                guard let relationship = description.relationship(named: name), relationship.isToMany,
                    let map = entityMap.relationships[name]
                else { continue }
                switch map.storage {
                case .foreignKey, .inverseForeignKey:
                    continue
                case .unknown:
                    // A to-many with no inverse: convention does not say where its links are kept, so they are
                    // not scanned. The rows at either end are still watched.
                    limitations.append(
                        ScanLimitation(reason: .unverifiedJoinTable, subject: "\(entity).\(name)"))
                case .joinTable:
                    guard map.verified, !map.table.isEmpty, let sourceColumn = map.sourceColumn else {
                        limitations.append(
                            ScanLimitation(reason: .unverifiedJoinTable, subject: "\(entity).\(name)"))
                        continue
                    }
                    guard seen.insert(map.table).inserted else { continue }
                    joins.append(
                        Join(
                            table: map.table,
                            relationship: name,
                            sourceEntity: entity,
                            destinationEntity: relationship.destinationEntity,
                            sourceColumn: sourceColumn,
                            destinationColumn: map.column,
                            orderColumn: map.orderColumn))
                }
            }
        }
        return joins
    }
}
