import DabbiBase
import Foundation

/// What the tracker remembers about rows, so that a change can be shown as *before → after* (ARCHITECTURE.md §6.6).
///
/// Two different things, kept together because they are learnt together:
///
/// - **Values.** A bounded number of whole-object readings. They come from three places: priming at the start of
///   tracking, materialising an earlier change, and the front end handing over what the user is already looking at
///   (`ChangeTracker.remember(_:)`) — the grid has those rows anyway, so a store too large to prime still shows
///   before-values for the part of it on screen.
/// - **Membership.** Which rows satisfied the watched view's predicate, which is the only way to tell *entered*
///   from *left* (TRK-7): a predicate answers "does it match now", never "did it match before".
///
/// Neither is ever guessed. A row with no reading gives a `nil` before rather than an empty one, and a row whose
/// membership is unknown gives no transition rather than a plausible one.
struct PriorValues {
    /// How many rows' values to hold. Whole-object readings are the expensive thing the tracker keeps — a key
    /// costs 20 bytes, a row of values costs kilobytes — so the cache is capped and the oldest arrivals go first.
    var limit: Int

    private var snapshots: [ObjectRef: ObjectSnapshot] = [:]
    /// Refs in the order they were first remembered, oldest first. Entries whose row has since been dropped stay
    /// until they are walked past, which costs nothing and keeps remembering O(1).
    private var arrivals: [ObjectRef] = []
    private var members: Set<ObjectRef> = []
    private var nonMembers: Set<ObjectRef> = []

    /// Whether `members` holds every row of the view. Set when priming read the whole view; false when the view
    /// was too large to prime, and then a row that is in neither set is *unknown*, not a non-member.
    var membershipIsComplete = false

    init(limit: Int = 100_000) {
        self.limit = max(0, limit)
    }

    // MARK: Values

    /// How many rows' values are held.
    var count: Int { snapshots.count }

    /// How many rows the view's membership is known for.
    var membershipCount: Int { members.count + nonMembers.count }

    func snapshot(of ref: ObjectRef) -> ObjectSnapshot? { snapshots[ref] }

    mutating func remember(_ snapshot: ObjectSnapshot) {
        let ref = snapshot.row.ref
        guard limit > 0 else { return }
        if snapshots.updateValue(snapshot, forKey: ref) == nil {
            arrivals.append(ref)
            evictIfNeeded()
        }
    }

    /// Remembers a whole page the front end has just shown. This is the cheap half of *prior values*: the rows are
    /// already fetched, and remembering them costs one dictionary insert each.
    mutating func remember(_ page: RowPage) {
        for row in page.rows {
            remember(ObjectSnapshot(row: row, columns: page.columns, generation: page.generation))
        }
    }

    mutating func forget(_ ref: ObjectRef) {
        snapshots[ref] = nil
        members.remove(ref)
        nonMembers.remove(ref)
    }

    mutating func removeAll() {
        snapshots.removeAll(keepingCapacity: true)
        arrivals.removeAll(keepingCapacity: true)
        members.removeAll(keepingCapacity: true)
        nonMembers.removeAll(keepingCapacity: true)
        membershipIsComplete = false
    }

    private mutating func evictIfNeeded() {
        guard snapshots.count > limit else { return }
        var index = 0
        while snapshots.count > limit, index < arrivals.count {
            let ref = arrivals[index]
            index += 1
            // Nothing to evict for a ref that was already forgotten; its place in the queue is simply skipped.
            guard snapshots[ref] != nil else { continue }
            snapshots[ref] = nil
        }
        arrivals.removeFirst(index)
    }

    // MARK: Membership (TRK-7)

    /// Whether the row satisfied the view's predicate when it was last seen; `nil` when nobody knows.
    func matched(_ ref: ObjectRef) -> Bool? {
        if members.contains(ref) { return true }
        if nonMembers.contains(ref) { return false }
        // A complete priming read the whole view, so a row it did not name is a row outside it.
        return membershipIsComplete ? false : nil
    }

    mutating func note(_ ref: ObjectRef, matches: Bool?) {
        switch matches {
        case true:
            members.insert(ref)
            nonMembers.remove(ref)
        case false:
            nonMembers.insert(ref)
            members.remove(ref)
        case nil:
            members.remove(ref)
            nonMembers.remove(ref)
        }
    }

    mutating func noteMembers(_ refs: [ObjectRef], isComplete: Bool) {
        members.formUnion(refs)
        nonMembers.subtract(refs)
        membershipIsComplete = isComplete
    }
}
