import DabbiSQLite
import Foundation

/// The identity of every row of one table, as of one read (ARCHITECTURE.md §6.6).
///
/// Three parallel arrays rather than an array of structs: they are contiguous, they cost no padding, and the
/// merge walk touches `pks` alone for most of its comparisons. A million rows cost 8 + 4 + 8 = 20 bytes each,
/// so a table the size of the `large` fixture is about 20 MB — the price of telling an update from a no-op
/// without keeping any row *values* at all.
///
/// Sorted by `Z_PK`, which costs nothing to ask for: `Z_PK` is the table's `INTEGER PRIMARY KEY`, so
/// `ORDER BY Z_PK` is the order SQLite walks the table in anyway.
struct TableSnapshot: Sendable, Hashable {
    /// Ascending, and unique.
    private(set) var pks: [Int64] = []
    /// `Z_ENT` per row, in `pks` order. Zero when the table has no such column.
    private(set) var ents: [Int32] = []
    /// `Z_OPT` per row, in `pks` order — Core Data's save counter: 1 after the insert, one more per saved
    /// update (Appendix A). Zero throughout when the table has no such column.
    private(set) var opts: [Int64] = []

    var count: Int { pks.count }

    /// What holding this costs, counting what the arrays have *reserved* rather than what they hold: an array
    /// that grew by doubling is paying for the whole buffer.
    var bytes: Int {
        pks.capacity * MemoryLayout<Int64>.stride
            + ents.capacity * MemoryLayout<Int32>.stride
            + opts.capacity * MemoryLayout<Int64>.stride
    }

    init() {}

    init(pks: [Int64], ents: [Int32], opts: [Int64]) {
        self.pks = pks
        self.ents = ents
        self.opts = opts
    }

    /// The index of `pk`, by binary search over the ascending keys; `nil` when the snapshot has no such row.
    func index(ofPK pk: Int64) -> Int? {
        var low = 0
        var high = pks.count - 1
        while low <= high {
            let middle = low + (high - low) / 2
            if pks[middle] == pk { return middle }
            if pks[middle] < pk { low = middle + 1 } else { high = middle - 1 }
        }
        return nil
    }

    /// Reads the whole table. Must be called inside the scan's one read transaction.
    static func read(
        table: String,
        hasEntityColumn: Bool,
        hasOptimisticLockColumn: Bool,
        capacityHint: Int,
        connection: SQLiteConnection
    ) throws -> TableSnapshot {
        // A missing column is selected as the constant 0 rather than branching the stepping loop: the shape of
        // the result is then the same whatever the table turned out to carry.
        let sql = """
            SELECT Z_PK, \(hasEntityColumn ? "Z_ENT" : "0"), \(hasOptimisticLockColumn ? "Z_OPT" : "0") \
            FROM \(SQLiteConnection.quoteIdentifier(table)) ORDER BY Z_PK
            """
        let statement = try connection.prepare(sql)
        var snapshot = TableSnapshot()
        snapshot.pks.reserveCapacity(capacityHint)
        snapshot.ents.reserveCapacity(capacityHint)
        snapshot.opts.reserveCapacity(capacityHint)
        while try statement.step() {
            snapshot.pks.append(statement.int64(at: 0))
            snapshot.ents.append(Int32(truncatingIfNeeded: statement.int64(at: 1)))
            snapshot.opts.append(statement.int64(at: 2))
        }
        return snapshot
    }

    /// Walks two snapshots of the same table in one pass and says what happened between them.
    ///
    /// Both are sorted by primary key, so this is the merge half of a merge sort: a key only in the old one was
    /// deleted, a key only in the new one was inserted, and a key in both whose `Z_OPT` moved was saved over.
    /// Indices are into the snapshot each case belongs to — the deleted row's entity is only knowable from the
    /// old snapshot, which is why deletes carry an index into *it*.
    ///
    /// A key in both whose `Z_ENT` differs cannot happen — a row does not change entity — but if the caller
    /// forgot to reset after a store was replaced it can *look* like it has. That is reported as a delete and an
    /// insert, which is what it is.
    static func walk(
        from old: TableSnapshot,
        to new: TableSnapshot,
        deleted: (Int) -> Void,
        inserted: (Int) -> Void,
        updated: (Int) -> Void
    ) {
        var oldIndex = 0
        var newIndex = 0
        while oldIndex < old.count, newIndex < new.count {
            let oldKey = old.pks[oldIndex]
            let newKey = new.pks[newIndex]
            if oldKey < newKey {
                deleted(oldIndex)
                oldIndex += 1
            } else if oldKey > newKey {
                inserted(newIndex)
                newIndex += 1
            } else {
                if old.ents[oldIndex] != new.ents[newIndex] {
                    deleted(oldIndex)
                    inserted(newIndex)
                } else if old.opts[oldIndex] != new.opts[newIndex] {
                    updated(newIndex)
                }
                oldIndex += 1
                newIndex += 1
            }
        }
        while oldIndex < old.count {
            deleted(oldIndex)
            oldIndex += 1
        }
        while newIndex < new.count {
            inserted(newIndex)
            newIndex += 1
        }
    }
}

/// Every link in one join table, as of one read.
///
/// Sorted by the pair, so the same merge walk works. The order column rides along: for an ordered many-to-many
/// a reorder changes nothing but `Z_FOK_…`, and a tracker that only compared pairs would say nothing happened.
struct JoinSnapshot: Sendable, Hashable {
    private(set) var sources: [Int64] = []
    private(set) var destinations: [Int64] = []
    /// `Z_FOK_…` per link. Zero throughout when the relationship is not ordered.
    private(set) var orders: [Int64] = []

    var count: Int { sources.count }

    var bytes: Int {
        (sources.capacity + destinations.capacity + orders.capacity) * MemoryLayout<Int64>.stride
    }

    init() {}

    init(sources: [Int64], destinations: [Int64], orders: [Int64]) {
        self.sources = sources
        self.destinations = destinations
        self.orders = orders
    }

    /// Reads the whole join table. Must be called inside the scan's one read transaction.
    static func read(
        table: String,
        sourceColumn: String,
        destinationColumn: String,
        orderColumn: String?,
        capacityHint: Int,
        connection: SQLiteConnection
    ) throws -> JoinSnapshot {
        let quote = SQLiteConnection.quoteIdentifier
        let order = orderColumn.map(quote) ?? "0"
        let sql = """
            SELECT \(quote(sourceColumn)), \(quote(destinationColumn)), \(order) FROM \(quote(table)) \
            ORDER BY \(quote(sourceColumn)), \(quote(destinationColumn))
            """
        let statement = try connection.prepare(sql)
        var snapshot = JoinSnapshot()
        snapshot.sources.reserveCapacity(capacityHint)
        snapshot.destinations.reserveCapacity(capacityHint)
        snapshot.orders.reserveCapacity(capacityHint)
        while try statement.step() {
            snapshot.sources.append(statement.int64(at: 0))
            snapshot.destinations.append(statement.int64(at: 1))
            snapshot.orders.append(statement.int64(at: 2))
        }
        return snapshot
    }

    static func walk(
        from old: JoinSnapshot,
        to new: JoinSnapshot,
        removed: (Int) -> Void,
        added: (Int) -> Void,
        reordered: (Int) -> Void
    ) {
        var oldIndex = 0
        var newIndex = 0
        while oldIndex < old.count, newIndex < new.count {
            let oldPair = (old.sources[oldIndex], old.destinations[oldIndex])
            let newPair = (new.sources[newIndex], new.destinations[newIndex])
            if oldPair < newPair {
                removed(oldIndex)
                oldIndex += 1
            } else if oldPair > newPair {
                added(newIndex)
                newIndex += 1
            } else {
                if old.orders[oldIndex] != new.orders[newIndex] { reordered(newIndex) }
                oldIndex += 1
                newIndex += 1
            }
        }
        while oldIndex < old.count {
            removed(oldIndex)
            oldIndex += 1
        }
        while newIndex < new.count {
            added(newIndex)
            newIndex += 1
        }
    }
}
