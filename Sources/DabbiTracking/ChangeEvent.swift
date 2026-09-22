import DabbiBase
import Foundation

/// Which side of a watched view's predicate an object crossed to (TRK-7).
public enum PredicateTransition: String, Sendable, Hashable, Codable {
    /// It did not satisfy the view's predicate before and does now: the row arrives, marked ↘.
    case entered
    /// It did and no longer does: the row leaves, marked ↗.
    case left
}

/// One thing that happened to one object, with the values on both sides of it (ARCHITECTURE.md §6.6).
///
/// This is the third stage of the tracker chain: `StoreWatcher` says *something* committed, `ChangeScanner` says
/// *which rows*, and this says *what about them* — what they were, what they are, which fields differ, which
/// links moved, and whether they came into or went out of the view being watched.
///
/// What is not known is said, not guessed. A row nobody had read before it changed has no `before` and a `nil`
/// `changedKeys`: the UI shows *changed — prior value unknown* rather than an empty before-column, which would
/// read as "it used to be blank".
public struct ChangeEvent: Sendable, Hashable, Codable {
    public enum Kind: String, Sendable, Hashable, Codable {
        case inserted
        case updated
        case deleted
    }

    public var object: ObjectRef
    public var kind: Kind
    /// The object as the tracker last saw it: primed at the start of tracking, read while materialising an
    /// earlier change, or handed over by the front end with `ChangeTracker.remember(_:)`.
    ///
    /// `nil` for an insert — there was nothing before — and for a change to a row no values were held for.
    ///
    /// One case is not something anybody saw: a row deleted before it was ever read, on a store whose model
    /// preserves values in history. Then this is the tombstone, `beforeIsTombstone` says so, and its `columns`
    /// hold only the preserved attributes — which is the whole of what is left of that row.
    public var before: ObjectSnapshot?
    /// The object as it is now. `nil` for a delete, and for a row that was gone again by the time the tracker
    /// came to read it.
    public var after: ObjectSnapshot?
    /// The properties whose values differ between the two sides, compared by name over the properties both sides
    /// carry. Only meaningful for `.updated`.
    ///
    /// A to-many is part of the reading as a count, so a join-table link that moved shows up here as that count
    /// changing, beside the `links` that say which. Empty means nothing in the reading differs at all — a blob
    /// whose length and sniffed type did not change, or a row written over with the same values. `nil` means
    /// unknown, which is not the same as nothing: there was no before.
    public var changedKeys: Set<String>?
    /// To-many links this object gained, lost or moved in the same commit (TRK-9). Only join-table
    /// relationships produce these; a to-many held as a foreign key is an ordinary update of the other row.
    public var links: [LinkChange]
    /// How the object crossed the watched view's predicate (TRK-7). `nil` when the view has no predicate, when
    /// the object was on the same side both times, or when which side it was on before is not known.
    public var transition: PredicateTransition?
    /// Who saved this change and when they saved it, when the store records persistent history (TRK-10).
    ///
    /// `nil` on a store that records none — most of them — and on a row the history read did not account for,
    /// which the batch reports as a `historyIncomplete` limitation rather than passing over.
    public var history: HistoryInfo?
    /// Whether `before` is the tombstone history kept rather than a reading anybody took.
    public var beforeIsTombstone: Bool
    /// When the tracker noticed.
    ///
    /// Not when the app saved: nothing outside persistent history records that (Appendix A). When the store does
    /// record it, `history?.timestamp` is the save time and this stays what it says — the moment the tracker
    /// found out, which is what the latency figures are measured against.
    public var at: Date

    public init(
        object: ObjectRef,
        kind: Kind,
        before: ObjectSnapshot? = nil,
        after: ObjectSnapshot? = nil,
        changedKeys: Set<String>? = nil,
        links: [LinkChange] = [],
        transition: PredicateTransition? = nil,
        history: HistoryInfo? = nil,
        beforeIsTombstone: Bool = false,
        at: Date = Date()
    ) {
        self.object = object
        self.kind = kind
        self.before = before
        self.after = after
        self.changedKeys = changedKeys
        self.links = links
        self.transition = transition
        self.history = history
        self.beforeIsTombstone = beforeIsTombstone
        self.at = at
    }

    /// Whether `property` is one of the fields to show strongly (TRK-2). Unknown prior values make no field
    /// strong: that the whole row changed is already said by the event itself.
    public func isChanged(_ property: String) -> Bool { changedKeys?.contains(property) ?? false }

    /// What the property read before the change, when that is known. A tombstone answers for the few attributes
    /// the model preserves and `nil` for the rest, which is exactly what is known about a deleted row.
    public func priorValue(of property: String) -> Value? { before?[property] }

    /// What it reads now.
    public func currentValue(of property: String) -> Value? { after?[property] }

    /// The changed properties in the order the row carries them, so a version row can be read column by column.
    public var changedProperties: [String] {
        guard let changedKeys else { return [] }
        let layout = after?.columns.properties ?? before?.columns.properties ?? []
        let ordered = layout.filter(changedKeys.contains)
        // A key that is in neither layout cannot happen, but sorting the remainder beats dropping it.
        return ordered + changedKeys.subtracting(ordered).sorted()
    }

    /// The row changed and the reading does not say how: nobody knows what it was, or nothing in it differs. The
    /// tracking UI labels these rather than showing an empty diff.
    public var isOpaque: Bool {
        kind == .updated && (changedKeys?.isEmpty ?? true)
    }
}

/// Everything one commit did, as one delivery to the front end (ARCHITECTURE.md §6.6).
///
/// One batch per commit, normally. `coalescedCommits` says when it stands for more than one — a burst the watcher
/// debounced, or the commits that arrived while tracking was paused — because a tracker that silently merges
/// commits is one whose version log cannot be trusted to be complete.
public struct ChangeBatch: Sendable, Hashable, Codable {
    /// When the batch was delivered.
    public var at: Date
    /// What the watcher saw. `.storeReplaced` batches carry no events: every key and prior value held was about
    /// a file that is no longer there, so the tracker starts again and says so.
    public var kind: StoreCommit.Kind
    public var events: [ChangeEvent]
    /// What the scan could not do exactly, for this store and scope. Empty means the batch is complete.
    public var limitations: [ScanLimitation]
    /// How many commits this batch stands for: 1 normally, more after a debounced burst or a pause.
    public var coalescedCommits: Int
    /// The scan's share of the latency budget: reading keys and diffing them.
    public var scanDuration: Duration
    /// Materialising's share: the Core Data fetches, the field diffs and the predicate evaluation.
    public var materialiseDuration: Duration
    /// Noticed → delivered, including the watcher's debounce. The figure §6.6 budgets 500 ms for.
    public var latency: Duration

    public init(
        at: Date = Date(),
        kind: StoreCommit.Kind = .commit,
        events: [ChangeEvent] = [],
        limitations: [ScanLimitation] = [],
        coalescedCommits: Int = 1,
        scanDuration: Duration = .zero,
        materialiseDuration: Duration = .zero,
        latency: Duration = .zero
    ) {
        self.at = at
        self.kind = kind
        self.events = events
        self.limitations = limitations
        self.coalescedCommits = coalescedCommits
        self.scanDuration = scanDuration
        self.materialiseDuration = materialiseDuration
        self.latency = latency
    }

    public var isEmpty: Bool { events.isEmpty }

    public var count: Int { events.count }

    /// Something was not tracked exactly. The UI says so rather than implying the log is complete.
    public var isReducedFidelity: Bool { !limitations.isEmpty }

    public func events(of kind: ChangeEvent.Kind) -> [ChangeEvent] { events.filter { $0.kind == kind } }

    /// Who saved what is in this batch, each named once, in the order they first appear (TRK-10).
    ///
    /// Derived rather than stored: the events carry the attribution, and a second copy of it on the batch would
    /// be one more thing that can disagree. Empty on a store that records no history. Never a row value, so this
    /// may be shown in a header or logged (§10).
    public var authors: [String] {
        var seen: Set<String> = []
        return events.compactMap { $0.history?.attribution }.filter { seen.insert($0).inserted }
    }

    /// The span of save times this batch covers, when history recorded them — as against `at`, which is when the
    /// tracker delivered it.
    public var savedAt: ClosedRange<Date>? {
        let times = events.compactMap { $0.history?.timestamp }.sorted()
        guard let first = times.first, let last = times.last else { return nil }
        return first...last
    }
}
