import DabbiBase
import Foundation

/// One object read on the tracker's behalf: its values now, and whether it belongs to the view being watched.
///
/// The tracker asks for many of these at once (`StoreSession.objects(_:matching:)`), diffs each against what it
/// held before, and turns the pair into a `ChangeEvent` (ARCHITECTURE.md §6.6).
public struct MaterialisedObject: Sendable, Hashable, Codable {
    /// Every stored property of the object, by its own entity's layout.
    public let snapshot: ObjectSnapshot
    /// Whether the object satisfies the predicate of the tracked view; `nil` when there was no predicate, or when
    /// the object's entity cannot answer it. Unknown is not "no": a view never reports a transition it guessed.
    public let matchesPredicate: Bool?

    public init(snapshot: ObjectSnapshot, matchesPredicate: Bool? = nil) {
        self.snapshot = snapshot
        self.matchesPredicate = matchesPredicate
    }

    public var ref: ObjectRef { snapshot.row.ref }
}
