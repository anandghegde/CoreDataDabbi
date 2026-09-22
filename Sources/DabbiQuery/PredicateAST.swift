import DabbiBase
import Foundation

/// A predicate as a value: the one source of truth the text field, the visual builder and the saved-predicate
/// file all hold (ARCHITECTURE.md §6.5).
///
/// Text becomes an AST by parsing through ``PredicateGuard`` and walking the `NSPredicate`; the builder edits an
/// AST directly; execution turns an AST back into an `NSPredicate`. Everything the parser can produce has a case
/// here, so a round trip is lossless for shape — ``PredicateAST/custom(_:)`` exists only for predicate classes a
/// future OS might add.
public indirect enum PredicateAST: Sendable, Hashable, Codable {
    /// `TRUEPREDICATE`.
    case all
    /// `FALSEPREDICATE`.
    case none
    case and([PredicateAST])
    case or([PredicateAST])
    case not(PredicateAST)
    case comparison(PredicateComparison)
    /// A predicate with no structural case here, kept as the format string that produced it.
    case custom(String)
}

/// One comparison row: `modifier left operator[options] right`.
public struct PredicateComparison: Sendable, Hashable, Codable {
    public var left: PredicateExpression
    public var op: PredicateOperator
    public var right: PredicateExpression
    /// `ANY` / `ALL` in front of the comparison. `NONE` parses as `NOT (ANY …)`, so it is not a case here.
    public var modifier: PredicateModifier
    public var options: PredicateOptions

    public init(
        left: PredicateExpression,
        op: PredicateOperator,
        right: PredicateExpression,
        modifier: PredicateModifier = .direct,
        options: PredicateOptions = []
    ) {
        self.left = left
        self.op = op
        self.right = right
        self.modifier = modifier
        self.options = options
    }

    /// The same comparison with its sides swapped — `30 < age` as `age > 30`. Used by the builder, which always
    /// puts the key path on the left.
    ///
    /// `nil` when the operator has no reverse: `"Swift" BEGINSWITH name` asks something quite different from
    /// `name BEGINSWITH "Swift"`, so such a comparison is left as it is and reported as unshowable instead.
    public var reversed: PredicateComparison? {
        guard let reversedOperator = op.reversed else { return nil }
        var copy = self
        (copy.left, copy.right) = (right, left)
        copy.op = reversedOperator
        return copy
    }
}

/// The side of a comparison, or an argument of one.
public indirect enum PredicateExpression: Sendable, Hashable, Codable {
    /// `SELF` — the object being evaluated.
    case object
    /// A key path, possibly through relationships and composite elements, possibly ending in `@count`.
    case keyPath(String)
    case constant(PredicateLiteral)
    /// `$NAME`: a substitution variable of a fetch-request template, or a `SUBQUERY` binding.
    case variable(String)
    /// `{ 1, 2, 3 }` — the collection form of `IN` and `BETWEEN`.
    case aggregate([PredicateExpression])
    /// A built-in function such as `lowercase:` or `count:`. Custom selectors never get this far:
    /// ``PredicateGuard`` refuses them while parsing.
    case function(name: String, arguments: [PredicateExpression])
    /// `SUBQUERY(collection, $variable, predicate)`.
    case subquery(collection: PredicateExpression, variable: String, predicate: PredicateAST)
    /// A key path read off another expression: `$item.price`, `SUBQUERY(…).@count`.
    case keyPathOn(PredicateExpression, keyPath: String)
    /// An expression with no structural case here, kept as the text that produced it.
    case custom(String)
}

/// A constant in a predicate. Narrower than ``Value``, which describes a *row*: a predicate never compares
/// against a blob summary or a to-many count.
public indirect enum PredicateLiteral: Sendable, Hashable, Codable {
    case null
    case bool(Bool)
    case int(Int64)
    case double(Double)
    case decimal(Decimal)
    case string(String)
    case date(Date)
    case uuid(UUID)
    case url(URL)
    case data(Data)
    /// `SELF == <x-coredata://…>`: a managed object named by its URI.
    case objectRef(ObjectRef)
    /// A constant collection, as `IN %@` produces. Written text uses ``PredicateExpression/aggregate(_:)``.
    case array([PredicateLiteral])
}

public enum PredicateModifier: String, Sendable, Hashable, Codable, CaseIterable {
    case direct, any, all

    /// How the modifier is written in front of a comparison.
    public var keyword: String? {
        switch self {
        case .direct: nil
        case .any: "ANY"
        case .all: "ALL"
        }
    }
}

public enum PredicateOperator: String, Sendable, Hashable, Codable, CaseIterable {
    case lessThan, lessThanOrEqual, greaterThan, greaterThanOrEqual, equal, notEqual
    case matches, like, beginsWith, endsWith, contains, between
    /// `IN`.
    case inCollection

    /// How the operator is written.
    public var keyword: String {
        switch self {
        case .lessThan: "<"
        case .lessThanOrEqual: "<="
        case .greaterThan: ">"
        case .greaterThanOrEqual: ">="
        case .equal: "=="
        case .notEqual: "!="
        case .matches: "MATCHES"
        case .like: "LIKE"
        case .beginsWith: "BEGINSWITH"
        case .endsWith: "ENDSWITH"
        case .contains: "CONTAINS"
        case .between: "BETWEEN"
        case .inCollection: "IN"
        }
    }

    /// The operator that means the same thing with the sides swapped. `nil` for the string and collection
    /// operators, which are not symmetric and have no swapped form: `a CONTAINS b` is not `b CONTAINS a`.
    public var reversed: PredicateOperator? {
        switch self {
        case .lessThan: .greaterThan
        case .lessThanOrEqual: .greaterThanOrEqual
        case .greaterThan: .lessThan
        case .greaterThanOrEqual: .lessThanOrEqual
        case .equal: .equal
        case .notEqual: .notEqual
        case .matches, .like, .beginsWith, .endsWith, .contains, .between, .inCollection: nil
        }
    }

    /// Operators whose right side is a collection rather than a single value.
    public var wantsCollection: Bool { self == .inCollection || self == .between }

    /// Operators for which `[c]`, `[d]` and `[n]` mean anything.
    public var acceptsStringOptions: Bool {
        switch self {
        case .matches, .like, .beginsWith, .endsWith, .contains, .equal, .notEqual, .inCollection: true
        default: false
        }
    }
}

/// `[c]`, `[d]` and `[n]` after a string operator.
public struct PredicateOptions: OptionSet, Sendable, Hashable, Codable {
    public let rawValue: UInt
    public init(rawValue: UInt) { self.rawValue = rawValue }

    public static let caseInsensitive = PredicateOptions(rawValue: 1 << 0)
    public static let diacriticInsensitive = PredicateOptions(rawValue: 1 << 1)
    public static let normalized = PredicateOptions(rawValue: 1 << 2)

    /// The bracketed suffix as it is written: `[cd]`, or empty when there is nothing to write.
    public var suffix: String {
        var letters = ""
        if contains(.caseInsensitive) { letters += "c" }
        if contains(.diacriticInsensitive) { letters += "d" }
        if contains(.normalized) { letters += "n" }
        return letters.isEmpty ? "" : "[\(letters)]"
    }
}

extension PredicateAST {
    /// The comparisons in the tree, in the order they are written. The builder counts rows with this.
    public var comparisons: [PredicateComparison] {
        switch self {
        case .all, .none, .custom: []
        case .and(let subs), .or(let subs): subs.flatMap(\.comparisons)
        case .not(let sub): sub.comparisons
        case .comparison(let comparison): [comparison]
        }
    }

    /// `and` and `or` of a single subpredicate collapse to it, and nested `and`s inside an `and` flatten.
    /// The parser produces both shapes; the builder is easier to drive from the flattened one.
    public var simplified: PredicateAST {
        switch self {
        case .and(let subs): Self.flatten(subs.map(\.simplified), isAnd: true)
        case .or(let subs): Self.flatten(subs.map(\.simplified), isAnd: false)
        case .not(let sub): .not(sub.simplified)
        case .all, .none, .comparison, .custom: self
        }
    }

    private static func flatten(_ subs: [PredicateAST], isAnd: Bool) -> PredicateAST {
        let lifted = subs.flatMap { sub -> [PredicateAST] in
            switch (sub, isAnd) {
            case (.and(let inner), true), (.or(let inner), false): inner
            default: [sub]
            }
        }
        if lifted.count == 1 { return lifted[0] }
        // An empty AND is TRUEPREDICATE and an empty OR is FALSEPREDICATE, which is how Cocoa evaluates them.
        if lifted.isEmpty { return isAnd ? .all : .none }
        return isAnd ? .and(lifted) : .or(lifted)
    }
}
