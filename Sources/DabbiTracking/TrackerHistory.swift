import DabbiBase
import Foundation

extension ChangeTracker.Options {
    /// What the tracker does with the store's persistent history (TRK-10).
    public struct History: Sendable, Hashable {
        /// Off makes the tracker behave exactly as it did before history existed. On — the default — costs one
        /// probe when tracking starts and nothing at all on a store that records no history.
        public var isEnabled = true
        /// Which reader to try first; the other is tried after it (`HistoryReaders.open(for:preferring:)`).
        public var preferring: HistorySource = .coreData
        /// Transactions read per batch. A cap, not a target: a batch that hits it says so as a limitation rather
        /// than quietly dropping the oldest saves it did not read.
        public var maxTransactions = 2_000

        public init() {}
    }
}

/// A batch's persistent history, folded row by row (ARCHITECTURE.md §6.6, TRK-10).
///
/// Folded rather than kept as a list because the scan reports the *net* change to a row over the whole batch, so
/// the enrichment has to be about the whole batch too. Two rules do the folding, and both follow from that:
///
/// - **Attribution comes from the last transaction that touched the row** — the save that left it as the scan
///   found it. `transactionCount` then says how many saves are standing behind that one name.
/// - **Property names are the union** of every transaction's, because between them they are what the batch wrote.
///   One transaction that will not say which fields it wrote makes the union unknown rather than partial: a
///   half-answer would read as *these fields and no others*, which is the claim this engine never makes (ADR-17).
struct HistoryDigest: Sendable {
    /// One row's share of the batch.
    struct Row: Sendable {
        var info: HistoryInfo
        /// Every property the batch's saves wrote to this row. `nil` when any of them would not say.
        var updatedProperties: Set<String>?
        /// The values a delete preserved, from the transaction that deleted the row.
        var tombstone: [String: Value]
    }

    private(set) var rows: [RowID: Row] = [:]
    /// How many transactions went into this digest.
    private(set) var transactionCount = 0
    /// The digest stands for fewer transactions than the batch covers: the read hit `maxTransactions`.
    private(set) var isTruncated = false

    init() {}

    init(_ transactions: [HistoryTransaction], isTruncated: Bool = false) {
        self.isTruncated = isTruncated
        transactionCount = transactions.count
        // Oldest first, so the last write of each field of `info` is the newest transaction's.
        for transaction in transactions {
            let info = HistoryInfo(transaction)
            for change in transaction.changes {
                let id = RowID(entity: change.entity, pk: change.pk)
                let existing = rows[id]
                // A row met before keeps what it knew, *including that it did not know* — written out rather
                // than folded into `?? []`, which would quietly turn unknown back into known-empty.
                var known: Set<String>? = []
                if let existing { known = existing.updatedProperties }
                var row = Row(info: info, updatedProperties: known, tombstone: [:])
                row.info.transactionCount = (existing?.info.transactionCount ?? 0) + 1
                if change.kind == .updated {
                    if let named = change.updatedProperties, let known = row.updatedProperties {
                        row.updatedProperties = known.union(named)
                    } else {
                        row.updatedProperties = nil
                    }
                }
                // A row deleted and re-created within one batch keeps the newest tombstone, which is the one the
                // scan's net answer — deleted — is about.
                row.tombstone = change.tombstone.isEmpty ? (existing?.tombstone ?? [:]) : change.tombstone
                rows[id] = row
            }
        }
    }

    subscript(id: RowID) -> Row? { rows[id] }

    var isEmpty: Bool { rows.isEmpty }

    /// What this digest cannot account for, as limitations.
    ///
    /// One per entity, so a batch of ten thousand unaccounted rows cannot produce ten thousand lines, and because
    /// an entity name is the most that may be said about a change anyway (§10).
    ///
    /// Unaccounted is ordinary, not broken: a store carries history tables and its writer can still save with
    /// tracking switched off for a piece of work, or save into it from a process that sets no author. Those saves
    /// reach the file and never reach `ATRANSACTION`. The scan reports them all the same — that is why the scan,
    /// and not history, is what says which rows changed — and this is the line that admits they arrived nameless.
    func limitations(accountingFor rows: [RowID]) -> [ScanLimitation] {
        var unaccounted: Set<String> = []
        for row in rows where self.rows[row] == nil { unaccounted.insert(row.entity) }
        var result: [ScanLimitation] = []
        if isTruncated {
            result.append(ScanLimitation(reason: .historyIncomplete, subject: "ATRANSACTION"))
        }
        result += unaccounted.sorted().map { ScanLimitation(reason: .historyIncomplete, subject: $0) }
        return result
    }
}

extension HistoryDigest.Row {
    /// The tombstone as a reading, for a row that was deleted before anybody read it.
    ///
    /// Its `ColumnSet` holds only the attributes the model marks `preservesValueInHistoryOnDeletion`, in name
    /// order — which is not a partial reading of the row but the whole of what is left of it. `ChangeEvent`
    /// marks it with `beforeIsTombstone` so nothing mistakes it for something somebody saw, and its generation is
    /// 0 because it belongs to no session's reading.
    func tombstoneSnapshot(for ref: ObjectRef) -> ObjectSnapshot? {
        guard !tombstone.isEmpty else { return nil }
        let names = tombstone.keys.sorted()
        return ObjectSnapshot(
            row: RowSnapshot(ref: ref, values: names.map { tombstone[$0] ?? .null }),
            columns: ColumnSet(names),
            generation: 0)
    }
}
