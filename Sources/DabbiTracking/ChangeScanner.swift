import DabbiBase
import DabbiModel
import DabbiSQLite
import Foundation

/// Says which rows changed between two moments, by reading primary keys and nothing else (ARCHITECTURE.md §6.6).
///
/// This is the *scan* strategy, the one that always works. It keeps, per table, the `Z_PK` / `Z_ENT` / `Z_OPT` of
/// every row and diffs two of those by a merge walk: a key that went away was deleted, a key that appeared was
/// inserted, a key whose save counter moved was saved over. No row *values* are held, so watching a million-row
/// store costs about 20 MB and no I/O beyond one sequential pass per tracked table.
///
/// Two properties it is built to keep:
///
/// - **One transaction.** Every tracked table and join table is read inside a single read transaction, so a
///   commit that touched three entities is seen whole. Scanning table by table across separate reads would show
///   the halves of one save as two changes, in an order that depends on nothing but timing.
/// - **Honesty about what it cannot see.** A table with no `Z_OPT`, a table the schema map could not confirm, a
///   many-to-many whose join table is not where convention says — each becomes a `ScanLimitation` rather than a
///   silently short answer. `RawChangeSet.isReducedFidelity` is what the UI labels a session with.
///
/// The scanner is the second stage of the tracker chain: `StoreWatcher` says *something* committed, this says
/// *which rows*, and the stage above turns primary keys into objects, values and a version log.
public actor ChangeScanner {
    public struct Options: Sendable, Hashable {
        /// Bounds the one transaction a scan runs in. A store so large that a sequential pass over its keys
        /// takes longer than this is one the tracker should hear about, not one it should hang on.
        public var timeout: TimeInterval = 15

        public init() {}
    }

    public nonisolated let url: URL
    public nonisolated let options: Options

    private let model: ModelDescription
    private let schema: SchemaMap
    private let scope: TrackingScope
    private let log = DabbiLog.logger(.tracking)

    private var reader: SQLiteReader?
    private var plan: ScanPlan?
    private var tables: [String: TableSnapshot] = [:]
    private var joins: [String: JoinSnapshot] = [:]
    private var primed = false

    /// - Parameters:
    ///   - url: the store. The scanner opens its own read-only connection, separate from the watcher's gate and
    ///     from any `StoreSession`, and holds no transaction between scans.
    ///   - model: the model the store was opened with — what entity names mean.
    ///   - schema: the mapping from that model to this file's tables, already verified against it.
    public init(
        url: URL,
        model: ModelDescription,
        schema: SchemaMap,
        scope: TrackingScope = .allEntities,
        options: Options = .init()
    ) {
        self.url = url
        self.model = model
        self.schema = schema
        self.scope = scope
        self.options = options
    }

    /// Whether a baseline has been read. Until it has, there is nothing to diff against.
    public var isPrimed: Bool { primed }

    /// How many rows the scanner is currently remembering the identity of.
    public var heldRows: Int {
        tables.values.reduce(0) { $0 + $1.count } + joins.values.reduce(0) { $0 + $1.count }
    }

    /// What remembering them costs in memory. This is the figure §6.6 budgets for — about 20 bytes a row, the
    /// three keys and nothing else — and the one a UI would show before offering to track a very large store.
    public var heldBytes: Int {
        tables.values.reduce(0) { $0 + $1.bytes } + joins.values.reduce(0) { $0 + $1.bytes }
    }

    /// What the scan cannot do for this store and scope, worked out once from the model, the schema map and the
    /// database's own columns. Empty until the first scan, which is when the plan is made.
    public var limitations: [ScanLimitation] { plan?.limitations ?? [] }

    /// Reads the store as it is now and remembers it, reporting nothing. The rows already in a store are not
    /// news; this is what `scan()` diffs against.
    ///
    /// Doing this before the app is asked to make a change is what keeps the first real scan cheap and exact.
    @discardableResult
    public func prime() async throws -> RawChangeSet {
        guard !primed else { return RawChangeSet() }
        return try await scan()
    }

    /// One scan: read every tracked table in one transaction, diff it against the last one, and say what moved.
    ///
    /// The first call establishes the baseline and returns a set with `isBaseline` true and no changes in it.
    public func scan() async throws -> RawChangeSet {
        let start = ContinuousClock.now
        let reader = try openedReader()
        let plan = try await resolvedPlan(reader)
        let snapshots = try await Self.read(
            plan: plan, capacityHints: capacityHints(), reader: reader, options: options)

        var result: RawChangeSet
        if primed {
            result = diff(plan: plan, against: snapshots)
        } else {
            result = RawChangeSet(isBaseline: true)
            primed = true
        }
        tables = snapshots.tables
        joins = snapshots.joins
        // Read back from the plan rather than from the local copy: diffing can add a limitation of its own, for
        // an entity number that only turns up when a row carries it.
        result.limitations = limitations
        result.scannedRows = snapshots.rowCount
        result.duration = start.duration(to: ContinuousClock.now)
        return result
    }

    /// The own entity of each row, for keys the last scan read.
    ///
    /// A `LinkChange` comes out of a join table, which knows only what the relationship *declares*; when that
    /// entity has sub-entities the row on either end may be one of them. The scan read `Z_ENT` beside every key,
    /// so this is the one place that can say which — without a fetch, and without asking Core Data. A key the
    /// scan has not seen, or a table with no `Z_ENT`, comes back unchanged.
    public func resolved(_ rows: [RowID]) -> [RowID] {
        rows.map(resolved)
    }

    public func resolved(_ row: RowID) -> RowID {
        guard let plan,
            let table = schema.entities[row.entity]?.table,
            let planned = plan.tables.first(where: { $0.table == table }),
            // Without Z_ENT the table holds one entity, which is the one the relationship already named.
            planned.hasEntityColumn,
            let index = tables[table]?.index(ofPK: row.pk),
            let ents = tables[table]?.ents,
            let name = planned.entities[ents[index]]
        else { return row }
        return RowID(entity: name, pk: row.pk)
    }

    /// Forgets the baseline and lets go of the connection.
    ///
    /// This is what a `.storeReplaced` commit calls for: every primary key held here is about a file that is no
    /// longer there, and the connection is onto its bytes (Appendix D). The next scan primes again.
    public func reset() async {
        await reader?.close()
        reader = nil
        plan = nil
        tables = [:]
        joins = [:]
        primed = false
    }

    /// Finished with the store. The scanner can be used again; the next scan reopens and primes.
    public func close() async {
        await reset()
    }

    // MARK: Reading

    private func openedReader() throws -> SQLiteReader {
        if let reader { return reader }
        let opened = try SQLiteReader(url: url)
        reader = opened
        return opened
    }

    /// The plan is made once per connection: which tables to read, which columns they actually have, and which
    /// `Z_ENT` numbers mean which entity. Nothing in it can change while the file does not.
    private func resolvedPlan(_ reader: SQLiteReader) async throws -> ScanPlan {
        if let plan { return plan }
        let model = model
        let schema = schema
        let scope = scope
        let built = try await reader.read { connection in
            try connection.readTransaction {
                try ScanPlan.build(model: model, schema: schema, scope: scope, connection: connection)
            }
        }
        plan = built
        if !built.limitations.isEmpty {
            log.notice(
                "Tracking this store is reduced-fidelity: \(built.limitationSummary, privacy: .public)")
        }
        return built
    }

    private func capacityHints() -> [String: Int] {
        var hints: [String: Int] = [:]
        for (table, snapshot) in tables { hints[table] = snapshot.count }
        for (table, snapshot) in joins { hints[table] = snapshot.count }
        return hints
    }

    /// Everything the plan asks for, read in one transaction so the picture is consistent across entities.
    ///
    /// `nonisolated static` on purpose: the body runs on the connection's actor and must not reach into this
    /// one's state, so it is handed the plan and given nothing else.
    private static func read(
        plan: ScanPlan, capacityHints: [String: Int], reader: SQLiteReader, options: Options
    ) async throws -> Snapshots {
        try await reader.read { connection in
            try connection.withTimeout(options.timeout) {
                try connection.readTransaction {
                    var snapshots = Snapshots()
                    for table in plan.tables {
                        let snapshot = try TableSnapshot.read(
                            table: table.table,
                            hasEntityColumn: table.hasEntityColumn,
                            hasOptimisticLockColumn: table.hasOptimisticLockColumn,
                            capacityHint: capacityHints[table.table] ?? 0,
                            connection: connection)
                        snapshots.rowCount += snapshot.count
                        snapshots.tables[table.table] = snapshot
                    }
                    for join in plan.joins {
                        let snapshot = try JoinSnapshot.read(
                            table: join.table,
                            sourceColumn: join.sourceColumn,
                            destinationColumn: join.destinationColumn,
                            orderColumn: join.orderColumn,
                            capacityHint: capacityHints[join.table] ?? 0,
                            connection: connection)
                        snapshots.rowCount += snapshot.count
                        snapshots.joins[join.table] = snapshot
                    }
                    return snapshots
                }
            }
        }
    }

    // MARK: Diffing

    private func diff(plan: ScanPlan, against snapshots: Snapshots) -> RawChangeSet {
        var result = RawChangeSet()
        var unmapped: Set<String> = []

        for table in plan.tables {
            guard let new = snapshots.tables[table.table] else { continue }
            let changes = Self.changes(in: table, from: tables[table.table] ?? TableSnapshot(), to: new)
            result.inserted += changes.inserted
            result.updated += changes.updated
            result.deleted += changes.deleted
            if changes.sawUnmappedEntity { unmapped.insert(table.table) }
        }
        for join in plan.joins {
            guard let new = snapshots.joins[join.table] else { continue }
            result.links += Self.changes(in: join, from: joins[join.table] ?? JoinSnapshot(), to: new)
        }

        // Stable order, so two runs over the same pair of states produce the same log. Within a table the walk
        // already yields ascending primary keys; sorting is what interleaves the tables.
        result.inserted.sort()
        result.updated.sort()
        result.deleted.sort()
        result.links.sort {
            ($0.relationship, $0.source, $0.destination) < ($1.relationship, $1.source, $1.destination)
        }

        if !unmapped.isEmpty {
            // Found while diffing rather than while planning: a number only shows up when a row carries it.
            self.plan?.limitations += unmapped.sorted().map {
                ScanLimitation(reason: .unmappedEntityNumber, subject: $0)
            }
        }
        return result
    }

    private static func changes(
        in table: ScanPlan.Table, from old: TableSnapshot, to new: TableSnapshot
    ) -> (inserted: [RowID], updated: [RowID], deleted: [RowID], sawUnmappedEntity: Bool) {
        var inserted: [RowID] = []
        var updated: [RowID] = []
        var deleted: [RowID] = []
        var sawUnmapped = false

        /// The entity of a row, or `nil` when it is not one this scan reports. A number the model does not know
        /// is worth saying out loud; a number it knows but nobody asked to track is simply out of scope.
        func entity(forNumber number: Int32, in table: ScanPlan.Table) -> String? {
            guard table.hasEntityColumn else { return table.soleEntity }
            if let name = table.entities[number] { return name }
            if !table.knownNumbers.contains(number) { sawUnmapped = true }
            return nil
        }

        TableSnapshot.walk(
            from: old, to: new,
            deleted: { index in
                guard let name = entity(forNumber: old.ents[index], in: table) else { return }
                deleted.append(RowID(entity: name, pk: old.pks[index]))
            },
            inserted: { index in
                guard let name = entity(forNumber: new.ents[index], in: table) else { return }
                inserted.append(RowID(entity: name, pk: new.pks[index]))
            },
            updated: { index in
                guard let name = entity(forNumber: new.ents[index], in: table) else { return }
                updated.append(RowID(entity: name, pk: new.pks[index]))
            })

        return (inserted, updated, deleted, sawUnmapped)
    }

    private static func changes(in join: ScanPlan.Join, from old: JoinSnapshot, to new: JoinSnapshot) -> [LinkChange] {
        var links: [LinkChange] = []

        func link(_ kind: LinkChange.Kind, _ snapshot: JoinSnapshot, _ index: Int) -> LinkChange {
            LinkChange(
                kind: kind,
                relationship: join.relationship,
                source: RowID(entity: join.sourceEntity, pk: snapshot.sources[index]),
                destination: RowID(entity: join.destinationEntity, pk: snapshot.destinations[index]),
                order: join.orderColumn == nil ? nil : snapshot.orders[index])
        }

        JoinSnapshot.walk(
            from: old, to: new,
            removed: { links.append(link(.removed, old, $0)) },
            added: { links.append(link(.added, new, $0)) },
            reordered: { links.append(link(.reordered, new, $0)) })

        return links
    }
}

/// Table and join-table snapshots from one read.
private struct Snapshots: Sendable {
    var tables: [String: TableSnapshot] = [:]
    var joins: [String: JoinSnapshot] = [:]
    var rowCount = 0
}
