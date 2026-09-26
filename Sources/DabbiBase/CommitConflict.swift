import Foundation

/// An object with staged edits whose row somebody else changed or deleted since it was first edited here
/// (EDT-10, ARCHITECTURE.md §6.4): the commit is refused until it is settled, one way or the other, per object.
public struct CommitConflict: Sendable, Hashable, Codable, Identifiable {
    public enum Kind: String, Sendable, Hashable, Codable {
        /// The row was saved again by somebody else: some of its values are not what they were.
        case changed
        /// The row is gone from the store. The staged edits of it can only be let go.
        case deleted
    }

    /// Which side of a conflict the commit takes.
    public enum Choice: String, Sendable, Hashable, Codable {
        /// The staged edits go ahead: what was staged is written over what the other side saved. Properties
        /// staged here win; the rest are the store's as it is now.
        case mine
        /// The staged edits of the object are let go, and the store's values stand. A staged delete is taken
        /// back.
        case theirs
    }

    /// One property, as it was when the object was first edited here (`original`), as staged (`mine`) and as
    /// it is in the store now (`theirs`). `nil` where there is no such value: nothing staged for the property,
    /// the object deleted here, or the row gone from the store.
    public struct Field: Sendable, Hashable, Codable {
        public let property: String
        public let original: Value
        public let mine: Value?
        public let theirs: Value?

        public init(property: String, original: Value, mine: Value?, theirs: Value?) {
            self.property = property
            self.original = original
            self.mine = mine
            self.theirs = theirs
        }

        /// Both sides changed the property, to different values: the one a choice really decides.
        public var isClash: Bool {
            guard let mine, let theirs else { return false }
            return mine != original && theirs != original && mine != theirs
        }
    }

    public let object: PendingObjectID
    public let kind: Kind
    /// What is staged for the object: an update, or a delete.
    public let staged: PendingChange.Kind
    /// The object's display attribute, as it was.
    public let label: String?
    /// The properties either side changed, by name. Row values: for the screen, never for a log.
    public let fields: [Field]

    public var id: PendingObjectID { object }

    public init(object: PendingObjectID, kind: Kind, staged: PendingChange.Kind, label: String?, fields: [Field]) {
        self.object = object
        self.kind = kind
        self.staged = staged
        self.label = label
        self.fields = fields
    }

    /// The choices that mean something for this conflict: a row that is gone takes only `.theirs`.
    public var choices: [Choice] { kind == .deleted ? [.theirs] : [.mine, .theirs] }
}
