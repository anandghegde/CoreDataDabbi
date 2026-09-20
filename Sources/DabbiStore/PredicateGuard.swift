import DabbiBase
import Foundation

/// Turns predicate text a user typed into an `NSPredicate` that is safe to hand to Core Data.
///
/// Two things can go wrong with user text. Parsing raises an Objective-C exception on a syntax error, so it runs
/// inside the exception bridge. And the predicate language can call arbitrary selectors on arbitrary objects —
/// `FUNCTION(obj, 'selector:', …)`, `CAST(name, 'Class')` — which a tool that opens other people's files must
/// not evaluate; those are refused before the predicate gets anywhere near a fetch.
public enum PredicateGuard {
    public static func parse(_ source: PredicateSource) throws -> NSPredicate {
        let format = source.format.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !format.isEmpty else {
            throw DabbiError(
                .invalidPredicate, "The predicate is empty.", recovery: ["Leave the predicate out to fetch every row."])
        }
        let predicate: NSPredicate
        do {
            // An explicit, empty argument array: a stray `%@` then raises instead of reading the stack.
            predicate = try objcGuarded("The predicate could not be parsed.", code: .invalidPredicate) {
                NSPredicate(format: format, argumentArray: [])
            }
        } catch var error as DabbiError {
            error.recovery = [
                "Check quotes and parentheses, and that every comparison has a left and a right side.",
                "Example: age > 30 AND name BEGINSWITH[cd] \"a\"",
            ]
            throw error
        }
        try check(predicate)
        return predicate
    }

    /// Built-in functions the predicate language offers by name. Anything else is a custom selector.
    static let allowedFunctions: Set<String> = [
        "sum:", "count:", "min:", "max:", "average:", "median:", "mode:", "stddev:",
        "add:to:", "from:subtract:", "multiply:by:", "divide:by:", "modulus:by:",
        "sqrt:", "log:", "ln:", "raise:toPower:", "exp:", "floor:", "ceiling:", "abs:", "trunc:",
        "uppercase:", "lowercase:", "length:", "now", "random", "randomn:",
        "bitwiseAnd:with:", "bitwiseOr:with:", "bitwiseXor:with:", "leftshift:by:", "rightshift:by:",
        "onesComplement:", "noindex:", "distinct:", "objectFrom:withIndex:", "castObject:toType:",
    ]

    /// `CAST(x, 'Class')` turns a string into a class to send messages to; casts to value types are harmless.
    /// `NSKeyPathSpecifierExpression`, which `NSExpression.ExpressionType` has no case for.
    private static let keyPathSpecifierExpressionType: UInt = 10

    static let allowedCastTypes: Set<String> = ["NSDate", "NSNumber", "NSDecimalNumber", "NSString"]

    static func check(_ predicate: NSPredicate) throws {
        switch predicate {
        case let compound as NSCompoundPredicate:
            for case let sub as NSPredicate in compound.subpredicates { try check(sub) }
        case let comparison as NSComparisonPredicate:
            guard comparison.predicateOperatorType != .customSelector else {
                throw unsafe("a custom comparison selector")
            }
            try check(comparison.leftExpression)
            try check(comparison.rightExpression)
        default:
            // TRUEPREDICATE / FALSEPREDICATE are plain NSPredicate instances. Block predicates cannot come from
            // text, but nothing else is known to be safe either.
            let name = NSStringFromClass(type(of: predicate))
            guard name == "NSTruePredicate" || name == "NSFalsePredicate" else {
                throw unsafe("a predicate of type \(name)")
            }
        }
    }

    static func check(_ expression: NSExpression) throws {
        switch expression.expressionType {
        case .constantValue, .evaluatedObject, .variable, .keyPath, .anyKey:
            return
        case .function:
            let function = expression.function
            // `$r.age` and `SUBQUERY(…).@count` are not key-path expressions to the parser: they come out as
            // `valueForKeyPath:` sent to the variable or the subquery, with a key-path specifier as the argument.
            // That is a key path like any other — as long as it has exactly this shape.
            if function == "valueForKeyPath:" {
                let arguments = expression.arguments ?? []
                guard [.variable, .subquery].contains(expression.operand.expressionType), arguments.count == 1,
                    arguments[0].expressionType == .keyPath
                        || arguments[0].expressionType.rawValue == keyPathSpecifierExpressionType
                else { throw unsafe("a key-path call on a custom target") }
                return try check(expression.operand)
            }
            guard allowedFunctions.contains(function) else { throw unsafe("the custom function “\(function)”") }
            // Built-ins are sent to a utility *class*; `FUNCTION(target, …)` names its own target instead.
            let operand = expression.operand
            guard operand.expressionType == .constantValue, operand.constantValue is AnyClass else {
                throw unsafe("a function call on a custom target")
            }
            let arguments = expression.arguments ?? []
            if function == "castObject:toType:" {
                guard arguments.count == 2, arguments[1].expressionType == .constantValue,
                    let type = arguments[1].constantValue as? String, allowedCastTypes.contains(type)
                else { throw unsafe("a cast to an arbitrary class") }
            }
            for argument in arguments { try check(argument) }
        case .unionSet, .intersectSet, .minusSet:
            try check(expression.left)
            try check(expression.right)
        case .subquery:
            if let collection = expression.collection as? NSExpression { try check(collection) }
            try check(expression.predicate)
        case .aggregate:
            for case let element as NSExpression in (expression.collection as? [Any]) ?? [] { try check(element) }
        case .conditional:
            try check(expression.predicate)
            try check(expression.true)
            try check(expression.false)
        case .block:
            throw unsafe("a block expression")
        @unknown default:
            throw unsafe("an unknown kind of expression")
        }
    }

    private static func unsafe(_ what: String) -> DabbiError {
        DabbiError(
            .unsafePredicate,
            "The predicate uses \(what), which could run arbitrary code and is not allowed.",
            recovery: ["Use comparisons, key paths and the built-in functions (count, sum, min, max, lowercase, …)."]
        )
    }
}
