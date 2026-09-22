import Foundation

// Whether the visual builder can show a predicate (ARCHITECTURE.md §6.5, §7.1). `NSPredicateEditor` draws rows
// of "key path · operator · value"; anything else — a function call, a subquery, two key paths compared with
// each other — has no row. When one of those appears, the builder shows a single read-only "custom expression"
// row and the text field stays authoritative, so the user's predicate is never silently rewritten.

extension PredicateAST {
    /// Whether the visual builder can show this predicate with no loss.
    public var isBuilderRepresentable: Bool { builderObstacles.isEmpty }

    /// Why the builder cannot show it, in the order the parts are written. Empty when it can.
    public var builderObstacles: [BuilderObstacle] {
        normalisedForBuilder().collectObstacles()
    }

    /// The form the builder edits: nesting flattened, and comparisons written with the key path on the left,
    /// because a builder row always starts with one. `3 < age` becomes `age > 3`.
    public func normalisedForBuilder() -> PredicateAST {
        switch simplified {
        case .and(let subs): .and(subs.map { $0.normalisedForBuilder() })
        case .or(let subs): .or(subs.map { $0.normalisedForBuilder() })
        case .not(let sub): .not(sub.normalisedForBuilder())
        case .comparison(let comparison):
            .comparison(Self.keyPathFirst(comparison))
        case .all, .none, .custom: simplified
        }
    }

    /// Puts the key path on the left where the operator allows the swap, and leaves the comparison alone where
    /// it does not — a builder that cannot show a row must say so, not change what the row asks.
    private static func keyPathFirst(_ comparison: PredicateComparison) -> PredicateComparison {
        guard !comparison.left.isBuilderLeftSide, comparison.right.isBuilderLeftSide,
            let reversed = comparison.reversed
        else { return comparison }
        return reversed
    }

    private func collectObstacles() -> [BuilderObstacle] {
        switch self {
        case .all:
            // No rows: the builder shows an empty editor, which means "every row".
            return []
        case .none:
            return [BuilderObstacle(reason: .noRowForm, text: "FALSEPREDICATE")]
        case .and(let subs), .or(let subs):
            return subs.flatMap { $0.collectObstacles() }
        case .not(let sub):
            return sub.collectObstacles()
        case .custom(let format):
            return [BuilderObstacle(reason: .unparsedText, text: format)]
        case .comparison(let comparison):
            var obstacles: [BuilderObstacle] = []
            if !comparison.left.isBuilderLeftSide {
                obstacles.append(BuilderObstacle(reason: .leftSideIsNotAKeyPath, text: comparison.left.text))
            }
            if !comparison.right.isBuilderRightSide {
                obstacles.append(BuilderObstacle(reason: .rightSideIsNotAValue, text: comparison.right.text))
            }
            return obstacles
        }
    }
}

public struct BuilderObstacle: Sendable, Hashable, Codable {
    public enum Reason: String, Sendable, Hashable, Codable {
        /// A row starts with a key path; this comparison does not have one on either side.
        case leftSideIsNotAKeyPath
        /// A row ends in a typed value editor; this one compares against something computed.
        case rightSideIsNotAValue
        /// A predicate with no row form at all.
        case noRowForm
        /// Text the parser kept verbatim.
        case unparsedText
    }

    public var reason: Reason
    /// The part of the predicate this is about, as it is written.
    public var text: String

    public var message: String {
        switch reason {
        case .leftSideIsNotAKeyPath:
            "“\(text)” is not a key path, so the builder has no row for it."
        case .rightSideIsNotAValue:
            "“\(text)” is computed rather than a fixed value, so the builder has no editor for it."
        case .noRowForm:
            "“\(text)” has no row in the builder."
        case .unparsedText:
            "“\(text)” is kept as text."
        }
    }
}

extension PredicateExpression {
    /// Whether this can be a builder row's left side: a plain key path, or `SELF`.
    var isBuilderLeftSide: Bool {
        switch self {
        case .keyPath, .object: true
        default: false
        }
    }

    /// Whether this can be a builder row's right side: a value the user types, a list of them, or a `$VARIABLE`
    /// a fetch-request template fills in.
    var isBuilderRightSide: Bool {
        switch self {
        case .constant, .variable: true
        case .aggregate(let elements): elements.allSatisfy { if case .constant = $0 { true } else { false } }
        case .keyPath, .object, .function, .subquery, .keyPathOn, .custom: false
        }
    }

    /// How the expression is written, for a diagnostic. Falls back to a description when it will not build.
    var text: String {
        (try? makeExpression().description) ?? String(describing: self)
    }
}
