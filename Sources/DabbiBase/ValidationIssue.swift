import Foundation

/// One rule of the model that a staged object breaks, in words (EDT-2).
///
/// Core Data validates what it saves, and refuses the whole save for one value out of line. An editable session
/// asks the same questions after every staged edit, so a broken rule shows beside its field as soon as it is
/// broken rather than when the commit is refused.
///
/// `message` is English, as a `DabbiError`'s is. A front end that localises renders `rule`, `limit` and `count`
/// itself.
///
/// Privacy: an issue names the object, the property and the model's rule — never the value that breaks it.
public struct ValidationIssue: Sendable, Hashable, Codable {
    public enum Rule: String, Sendable, Hashable, Codable {
        /// A property that is not optional has no value, or a to-one no object.
        case required
        case tooShort, tooLong
        case belowMinimum, aboveMaximum
        case tooEarly, tooLate
        case invalidDate
        case patternMismatch
        case invalidURI
        case tooFewObjects, tooManyObjects
        /// The object is deleted while a relationship whose delete rule is Deny still leads to objects.
        case deleteDenied
        /// Another object has the same values for a uniqueness constraint.
        case notUnique
        /// A rule the model states in a shape of its own — the app's predicate, verbatim in `limit`.
        case other
    }

    public let object: PendingObjectID
    /// The property that breaks the rule; `nil` when the rule is about the object as a whole.
    public let property: String?
    public let rule: Rule
    /// What the model allows, as the model says it: a length, a number, a date, a pattern, a count of objects.
    /// `nil` when the rule has no figure, or the model does not say.
    public let limit: String?
    /// How many objects the relationship leads to, when that is what is wrong — a Deny rule's objects.
    public let count: Int?
    /// The rule, as a sentence about the property: “Must be at least 1 character long.”
    public let message: String

    public init(
        object: PendingObjectID, property: String?, rule: Rule, limit: String? = nil, count: Int? = nil,
        message: String
    ) {
        self.object = object
        self.property = property
        self.rule = rule
        self.limit = limit
        self.count = count
        self.message = message
    }
}

extension ValidationIssue: CustomStringConvertible {
    /// “Sample#3 · name: Must be at least 1 character long.” — how a refused commit lists it.
    public var description: String {
        property.map { "\(object) · \($0): \(message)" } ?? "\(object): \(message)"
    }
}

/// What deleting some objects would do, by the model's delete rules, worked out before anything is staged
/// (EDT-2).
///
/// A delete in Core Data is seldom only the objects asked for: Cascade takes others along, Nullify unlinks the
/// objects that stay, Deny refuses the commit while anything is left behind, and No Action — or a relationship
/// that has no inverse — leaves objects pointing at rows that are gone. This says which, before the user agrees.
///
/// It is the model's rules applied to what is staged now; staging the delete and validating it is what decides.
public struct DeletePreview: Sendable, Hashable, Codable {
    /// The objects of one entity a rule reaches.
    public struct Group: Sendable, Hashable, Codable {
        public let entity: String
        public let count: Int
        /// The first few, in object-ID order, for a front end to name.
        public let sample: [PendingObjectID]

        public init(entity: String, count: Int, sample: [PendingObjectID]) {
            self.entity = entity
            self.count = count
            self.sample = sample
        }
    }

    /// How many objects were asked for — those not already staged for deletion.
    public let requested: Int
    /// Objects Cascade rules would delete along with them, by entity.
    public let cascaded: [Group]
    /// Objects that stay and lose their link to a deleted one (Nullify), by entity.
    public let nullified: [Group]
    /// Objects that stay and keep pointing at a deleted one: the rule is No Action, or the relationship they
    /// point through has no inverse for Core Data to follow. By entity.
    public let dangling: [Group]
    /// What the commit would refuse: Deny rules with objects still behind them, and rules of the objects that
    /// stay which unlinking them would break — a required to-one emptied, a to-many left below its minimum.
    public let issues: [ValidationIssue]

    public init(
        requested: Int, cascaded: [Group] = [], nullified: [Group] = [], dangling: [Group] = [],
        issues: [ValidationIssue] = []
    ) {
        self.requested = requested
        self.cascaded = cascaded
        self.nullified = nullified
        self.dangling = dangling
        self.issues = issues
    }

    /// Whether the delete removes what was asked for and breaks nothing: nothing to ask the user about.
    /// Nullify alone is what anybody expects a delete to do.
    public var isPlain: Bool { cascaded.isEmpty && dangling.isEmpty && issues.isEmpty }

    public var cascadedCount: Int { cascaded.reduce(0) { $0 + $1.count } }
}
