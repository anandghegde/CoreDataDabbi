import Foundation

/// How far through a store's persistent history a reader has got (ARCHITECTURE.md §6.6, TRK-10).
///
/// Core Data hands out an `NSPersistentHistoryToken`, an opaque object whose only documented use is being given
/// back to a later fetch. The raw reader has no such thing and does not need one: what it is really asking is
/// *which transactions are newer than the last one I accounted for*, and `ATRANSACTION.Z_PK` answers that.
///
/// So a token carries both — the transaction number always, the archived object when Core Data was the one
/// reading — and either reader can take the other's token and carry on from it. That matters at the one moment
/// the strategy can change: a store that starts out readable through the public API and stops being so.
public struct HistoryToken: Sendable, Hashable, Codable, Comparable, CustomStringConvertible {
    /// `ATRANSACTION.Z_PK` of the last transaction this token stands for. Transaction numbers rise and are never
    /// reused, so a plain comparison is a valid "newer than".
    public var transactionNumber: Int64
    /// The archived `NSPersistentHistoryToken`, when the public API produced this token. Opaque here on purpose:
    /// nothing outside `DabbiStore` unarchives it, and a token that cannot be unarchived is not fatal — the
    /// transaction number still says where to carry on from.
    public var opaque: Data?

    public init(transactionNumber: Int64, opaque: Data? = nil) {
        self.transactionNumber = transactionNumber
        self.opaque = opaque
    }

    /// Before the first transaction: everything the store still holds is newer than this.
    public static let beginning = HistoryToken(transactionNumber: 0)

    public static func < (lhs: HistoryToken, rhs: HistoryToken) -> Bool {
        lhs.transactionNumber < rhs.transactionNumber
    }

    /// Identity, not row data, so this may be logged (§10).
    public var description: String { "txn \(transactionNumber)" }
}

/// One transaction of a store's persistent history: one save, by one author, as Core Data recorded it.
///
/// The timestamp is the one thing here the scan cannot get at any price — it is when the *app* saved, where
/// `ChangeEvent.at` is only when the tracker noticed (Appendix A).
public struct HistoryTransaction: Sendable, Hashable, Codable {
    /// `ATRANSACTION.Z_PK`, and what `HistoryToken.transactionNumber` holds.
    public var number: Int64
    /// The token that stands for *this* transaction having been accounted for.
    public var token: HistoryToken
    /// When the app saved. `nil` when the row carries no timestamp.
    public var timestamp: Date?
    /// `NSManagedObjectContext.transactionAuthor` — the app's own word for who made the change: `app`, `sync`,
    /// a share name. The one field that makes a log of somebody else's store readable.
    public var author: String?
    /// `NSManagedObjectContext.name`.
    public var contextName: String?
    /// The bundle identifier of the process that saved.
    public var bundleID: String?
    /// The name of the process that saved.
    public var processID: String?
    /// The rows this transaction touched. Empty when the transaction's changes were not asked for.
    public var changes: [HistoryChange]

    public init(
        number: Int64,
        token: HistoryToken? = nil,
        timestamp: Date? = nil,
        author: String? = nil,
        contextName: String? = nil,
        bundleID: String? = nil,
        processID: String? = nil,
        changes: [HistoryChange] = []
    ) {
        self.number = number
        self.token = token ?? HistoryToken(transactionNumber: number)
        self.timestamp = timestamp
        self.author = author
        self.contextName = contextName
        self.bundleID = bundleID
        self.processID = processID
        self.changes = changes
    }

    /// What this transaction says about one row, when it says anything.
    public func change(ofEntity entity: String, pk: Int64) -> HistoryChange? {
        changes.first { $0.entity == entity && $0.pk == pk }
    }
}

/// One row's share of a transaction.
///
/// Deliberately a key and not an `ObjectRef`: history names a row by entity number and primary key, exactly as
/// the scan does, and minting an identity is the store session's job (`StoreSession.reference(entity:pk:)`).
public struct HistoryChange: Sendable, Hashable, Codable {
    public enum Kind: String, Sendable, Hashable, Codable {
        case inserted
        case updated
        case deleted
    }

    /// The row's own entity, resolved from `ACHANGE.ZENTITY` through `Z_PRIMARYKEY` — for a sub-entity row the
    /// sub-entity, not the root whose table it shares.
    public var entity: String
    public var pk: Int64
    public var kind: Kind
    /// The properties this save touched, by name.
    ///
    /// `nil` means the reader could not say which — not that none were touched (ADR-17). This is the field that
    /// makes TRK-10 worth having: a row nobody had read before it changed has no before-values to diff, but
    /// history still knows *which fields* the save wrote, so they can be shown as changed without claiming what
    /// they used to be.
    public var updatedProperties: Set<String>?
    /// Values a deleted row kept, for attributes the model marks `preservesValueInHistoryOnDeletion`.
    ///
    /// The only prior values the store itself offers for a row that is already gone. Empty when the model
    /// preserves nothing, or when the reader cannot map them.
    public var tombstone: [String: Value]

    public init(
        entity: String,
        pk: Int64,
        kind: Kind,
        updatedProperties: Set<String>? = nil,
        tombstone: [String: Value] = [:]
    ) {
        self.entity = entity
        self.pk = pk
        self.kind = kind
        self.updatedProperties = updatedProperties
        self.tombstone = tombstone
    }
}

/// What persistent history adds to a change the tracker found by other means (TRK-10).
///
/// Enrichment, not evidence: the scan decides *that* a row changed, and this says who changed it and when they
/// saved. A change with no `history` is a change history had nothing to say about — which is ordinary for a store
/// that does not track it, and worth noticing on one that does.
public struct HistoryInfo: Sendable, Hashable, Codable {
    /// The transaction that most recently touched this row within the batch.
    public var transactionNumber: Int64
    public var author: String?
    public var contextName: String?
    public var bundleID: String?
    public var processID: String?
    /// When the app saved, as against when the tracker noticed (`ChangeEvent.at`).
    public var timestamp: Date?
    /// How many transactions in this batch touched the row. More than one means a burst was debounced, or
    /// tracking was paused across several saves — the same thing `ChangeBatch.coalescedCommits` says for the
    /// batch as a whole, said for this row.
    public var transactionCount: Int

    public init(
        transactionNumber: Int64,
        author: String? = nil,
        contextName: String? = nil,
        bundleID: String? = nil,
        processID: String? = nil,
        timestamp: Date? = nil,
        transactionCount: Int = 1
    ) {
        self.transactionNumber = transactionNumber
        self.author = author
        self.contextName = contextName
        self.bundleID = bundleID
        self.processID = processID
        self.timestamp = timestamp
        self.transactionCount = transactionCount
    }

    /// Everything but the transaction itself, taken from a transaction.
    public init(_ transaction: HistoryTransaction, transactionCount: Int = 1) {
        self.init(
            transactionNumber: transaction.number,
            author: transaction.author,
            contextName: transaction.contextName,
            bundleID: transaction.bundleID,
            processID: transaction.processID,
            timestamp: transaction.timestamp,
            transactionCount: transactionCount)
    }

    /// The author, or the process, or the transaction number: the shortest thing that names the save. Never a row
    /// value, so this may be logged (§10).
    public var attribution: String {
        author ?? contextName ?? processID ?? bundleID ?? "transaction \(transactionNumber)"
    }
}
