import Foundation

/// One change made to one attribute of many objects at once (EDT-4): *Batch Update*, *Find and Replace* and
/// *Nullify Attributes*. Staged like any other edit, as one step of the undo stack.
public enum BatchOperation: Sendable, Hashable, Codable {
    /// Sets every object's value to this one — any scalar type, read as the attribute's type.
    case set(Value)
    /// Replaces text in a string attribute.
    case replace(FindReplace)
    /// Empties the attribute.
    case nullify
}

/// What *Find and Replace* looks for and puts in its place.
public struct FindReplace: Sendable, Hashable, Codable {
    /// The text to find, or with `isRegularExpression` an ICU regular expression.
    public var find: String
    /// What each match becomes. A regular expression's replacement may refer to its groups as `$1`, `$2`….
    public var replacement: String
    public var isRegularExpression: Bool
    public var ignoresCase: Bool

    public init(find: String, replacement: String, isRegularExpression: Bool = false, ignoresCase: Bool = false) {
        self.find = find
        self.replacement = replacement
        self.isRegularExpression = isRegularExpression
        self.ignoresCase = ignoresCase
    }
}

/// Which objects a batch edit changes: the rows selected, or all the rows the grid's fetch matches.
public enum BatchTarget: Sendable {
    case objects([PendingObjectID])
    /// Every object the fetch matches, its limit included, those only inserted too.
    case fetch(FetchSpec)
}

/// What a batch edit would do, worked out without staging anything (EDT-4).
public struct BatchPreview: Sendable, Hashable {
    /// One object's value before and after.
    public struct Sample: Sendable, Hashable {
        public let object: PendingObjectID
        /// The object's display name, if its entity has one.
        public let label: String?
        public let before: Value
        public let after: Value

        public init(object: PendingObjectID, label: String?, before: Value, after: Value) {
            self.object = object
            self.label = label
            self.before = before
            self.after = after
        }
    }

    /// How many objects the edit was asked to change.
    public let matched: Int
    /// How many of them it would change: an object already holding the new value is left as it is.
    public let changing: Int
    /// The first few objects it would change.
    public let samples: [Sample]

    public init(matched: Int, changing: Int, samples: [Sample]) {
        self.matched = matched
        self.changing = changing
        self.samples = samples
    }
}
