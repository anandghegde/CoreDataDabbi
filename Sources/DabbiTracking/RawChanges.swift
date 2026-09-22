import Foundation

/// One row, as the scan knows it: an entity and a primary key, and nothing that had to be fetched.
///
/// Not an `ObjectRef`: a scan reads `Z_PK`, `Z_ENT` and `Z_OPT` and never opens Core Data, so it has no object
/// URI to give. Materialising (ARCHITECTURE.md §6.6) turns these into `ObjectRef`s by fetching them.
public struct RowID: Sendable, Hashable, Codable, Comparable, CustomStringConvertible {
    /// The row's *own* entity, resolved from `Z_ENT` — for a sub-entity row the sub-entity, not the root whose
    /// table it shares.
    public let entity: String
    public let pk: Int64

    public init(entity: String, pk: Int64) {
        self.entity = entity
        self.pk = pk
    }

    public static func < (lhs: RowID, rhs: RowID) -> Bool { (lhs.entity, lhs.pk) < (rhs.entity, rhs.pk) }

    /// Identity is not row data, so this may be logged (§10).
    public var description: String { "\(entity)#\(pk)" }
}

/// A to-many link that appeared, went away or moved (TRK-9).
///
/// Only *join tables* produce these. A to-many whose inverse is a to-one is stored as a foreign key on the
/// destination row, so gaining or losing such a link is an ordinary update of that row and the row diff already
/// reports it.
public struct LinkChange: Sendable, Hashable, Codable {
    public enum Kind: String, Sendable, Hashable, Codable {
        case added
        case removed
        /// An ordered relationship kept the link but moved it.
        case reordered
    }

    public var kind: Kind
    /// The relationship as the model names it, on `source`'s side. A join table is shared by the two directions
    /// and is scanned once, so every link in it is reported under the same name — the one that sorted first.
    public var relationship: String
    /// The entity is the relationship's declared source; when that entity has sub-entities, the row may be one
    /// of them. The join table does not say which, and the scan does not fetch to find out.
    public var source: RowID
    public var destination: RowID
    /// The position after the change, for an ordered relationship; `nil` when the relationship is not ordered.
    public var order: Int64?

    public init(kind: Kind, relationship: String, source: RowID, destination: RowID, order: Int64? = nil) {
        self.kind = kind
        self.relationship = relationship
        self.source = source
        self.destination = destination
        self.order = order
    }
}

/// Something the scan could not do, and why — the vocabulary behind *reduced-fidelity tracking* (§6.6).
///
/// A limitation is never an error: the scan reports what it could and says what it could not, and the stage
/// above decides whether to fall back to a capped refetch or simply to label what the user is looking at.
public struct ScanLimitation: Sendable, Hashable, Codable {
    public enum Reason: String, Sendable, Hashable, Codable {
        /// The schema map could not confirm the entity's table, so the entity is not scanned at all.
        case unverifiedTable
        /// The table the schema map names is not in the database.
        case missingTable
        /// The table has no `Z_OPT`, so a row that was saved over cannot be told from one nobody touched.
        /// Inserts and deletes are still exact.
        case noOptimisticLockColumn
        /// The table has no `Z_ENT` and holds more than one concrete entity, so its rows cannot be attributed.
        case noEntityColumn
        /// Rows carry a `Z_ENT` that `Z_PRIMARYKEY` does not name — a model that no longer matches the store.
        /// They are read but not reported.
        case unmappedEntityNumber
        /// A tracked many-to-many's join table could not be confirmed, so its links are not scanned.
        case unverifiedJoinTable
        /// The store records persistent history and it could not be read, so changes arrive without an author
        /// or a save time. Which rows changed is unaffected — the scan is what answers that (TRK-10).
        case historyUnavailable
        /// History was read and does not account for every row the scan found changed. Ordinary on a store
        /// whose writer saves with tracking switched off for some of its work; the changes are still reported,
        /// without an author.
        case historyIncomplete
    }

    public var reason: Reason
    /// A table name, an entity name or `Entity.relationship` — never a row value (§10).
    public var subject: String

    public init(reason: Reason, subject: String) {
        self.reason = reason
        self.subject = subject
    }
}

/// What one scan found: primary keys, with no values attached yet (§6.6).
public struct RawChangeSet: Sendable, Hashable, Codable {
    public var inserted: [RowID]
    public var updated: [RowID]
    public var deleted: [RowID]
    public var links: [LinkChange]
    /// What the scan could not do. Empty means every reported change is exact and nothing was missed.
    public var limitations: [ScanLimitation]
    /// True for the scan that established the baseline. A store's existing contents are not news, so its rows
    /// are counted in `scannedRows` and reported nowhere else.
    public var isBaseline: Bool
    /// How many rows the scan walked, across every tracked table and join table.
    public var scannedRows: Int
    /// How long the read and the diff took together — the scan's share of the latency budget.
    public var duration: Duration

    public init(
        inserted: [RowID] = [],
        updated: [RowID] = [],
        deleted: [RowID] = [],
        links: [LinkChange] = [],
        limitations: [ScanLimitation] = [],
        isBaseline: Bool = false,
        scannedRows: Int = 0,
        duration: Duration = .zero
    ) {
        self.inserted = inserted
        self.updated = updated
        self.deleted = deleted
        self.links = links
        self.limitations = limitations
        self.isBaseline = isBaseline
        self.scannedRows = scannedRows
        self.duration = duration
    }

    public var isEmpty: Bool {
        inserted.isEmpty && updated.isEmpty && deleted.isEmpty && links.isEmpty
    }

    public var count: Int { inserted.count + updated.count + deleted.count + links.count }

    /// Something was not scanned exactly. The tracking UI says so rather than implying the log is complete.
    public var isReducedFidelity: Bool { !limitations.isEmpty }

    /// Every changed row, whatever happened to it.
    public var allRows: [RowID] { inserted + updated + deleted }
}
