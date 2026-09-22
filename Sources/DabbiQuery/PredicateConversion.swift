import CoreData
import DabbiBase
import DabbiStore
import Foundation

// Text ⇄ AST ⇄ `NSPredicate`. Text only ever becomes a predicate through `PredicateGuard`, so nothing that could
// run arbitrary code reaches an AST; and because an AST can also arrive from a project file somebody edited by
// hand, the predicate built from one is checked again before it is handed back (ARCHITECTURE.md §6.5).

extension PredicateAST {
    /// Parses predicate text the user typed.
    ///
    /// - Throws: ``DabbiError`` with `.invalidPredicate` for a syntax error, `.unsafePredicate` for a construct
    ///   that could run arbitrary code.
    public static func parse(_ text: String) throws -> PredicateAST {
        try PredicateAST(PredicateGuard.parse(PredicateSource(format: text)))
    }

    public static func parse(_ source: PredicateSource) throws -> PredicateAST {
        try PredicateAST(PredicateGuard.parse(source))
    }

    /// Walks a parsed `NSPredicate` into the AST. Total: anything without a case becomes `.custom`.
    public init(_ predicate: NSPredicate) {
        switch predicate {
        case let compound as NSCompoundPredicate:
            let subs = compound.subpredicates.compactMap { ($0 as? NSPredicate).map(PredicateAST.init) }
            switch compound.compoundPredicateType {
            case .and: self = .and(subs)
            case .or: self = .or(subs)
            case .not: self = subs.count == 1 ? .not(subs[0]) : .and(subs.map { .not($0) })
            @unknown default: self = .custom(compound.predicateFormat)
            }
        case let comparison as NSComparisonPredicate:
            guard let op = PredicateOperator(comparison.predicateOperatorType) else {
                self = .custom(comparison.predicateFormat)
                return
            }
            self = .comparison(
                PredicateComparison(
                    left: PredicateExpression(comparison.leftExpression),
                    op: op,
                    right: PredicateExpression(comparison.rightExpression),
                    modifier: PredicateModifier(comparison.comparisonPredicateModifier),
                    options: PredicateOptions(comparison.options)
                ))
        default:
            switch NSStringFromClass(type(of: predicate)) {
            case "NSTruePredicate": self = .all
            case "NSFalsePredicate": self = .none
            default: self = .custom(predicate.predicateFormat)
            }
        }
    }

    /// Builds the `NSPredicate` to execute.
    ///
    /// - Throws: ``DabbiError`` when a `.custom` node does not parse, or when the result uses a construct the
    ///   safety check refuses.
    public func makePredicate() throws -> NSPredicate {
        let predicate = try buildPredicate()
        try PredicateGuard.check(predicate)
        return predicate
    }

    /// The predicate written as text — always a string that parses back to an equal AST.
    public func formatString() throws -> String {
        try makePredicate().predicateFormat
    }

    /// The form a `FetchSpec` and a saved predicate store: text stays authoritative on disk, so a project file
    /// written by this version stays readable by a version whose AST has moved on.
    public func source() throws -> PredicateSource {
        try PredicateSource(format: formatString())
    }

    private func buildPredicate() throws -> NSPredicate {
        switch self {
        case .all: NSPredicate(value: true)
        case .none: NSPredicate(value: false)
        case .and(let subs):
            NSCompoundPredicate(andPredicateWithSubpredicates: try subs.map { try $0.buildPredicate() })
        case .or(let subs):
            NSCompoundPredicate(orPredicateWithSubpredicates: try subs.map { try $0.buildPredicate() })
        case .not(let sub):
            NSCompoundPredicate(notPredicateWithSubpredicate: try sub.buildPredicate())
        case .comparison(let comparison):
            NSComparisonPredicate(
                leftExpression: try comparison.left.makeExpression(),
                rightExpression: try comparison.right.makeExpression(),
                modifier: comparison.modifier.cocoa,
                type: comparison.op.cocoa,
                options: comparison.options.cocoa
            )
        case .custom(let format):
            try PredicateGuard.parse(PredicateSource(format: format))
        }
    }
}

extension PredicateSource {
    public func ast() throws -> PredicateAST { try PredicateAST.parse(self) }
}

// MARK: - Expressions

extension PredicateExpression {
    /// `$r.age` and `SUBQUERY(…).@count` reach the parser as `valueForKeyPath:` sent to the variable or the
    /// subquery, with a key-path *specifier* as the argument. `NSExpression.ExpressionType` has no case for that
    /// specifier, so it is recognised by its raw value.
    static let keyPathSpecifierExpressionType: UInt = 10

    public init(_ expression: NSExpression) {
        switch expression.expressionType {
        case .evaluatedObject:
            self = .object
        case .keyPath:
            self = .keyPath(expression.keyPath)
        case .constantValue:
            self = .constant(PredicateLiteral(expression.constantValue))
        case .variable:
            self = .variable(expression.variable)
        case .aggregate:
            let elements = (expression.collection as? [Any])?.compactMap { $0 as? NSExpression }
            guard let elements else {
                self = .custom(expression.description)
                return
            }
            self = .aggregate(elements.map(PredicateExpression.init))
        case .subquery:
            guard let collection = expression.collection as? NSExpression else {
                self = .custom(expression.description)
                return
            }
            self = .subquery(
                collection: PredicateExpression(collection),
                variable: expression.variable,
                predicate: PredicateAST(expression.predicate))
        case .function:
            let arguments = expression.arguments ?? []
            if expression.function == "valueForKeyPath:", arguments.count == 1,
                let keyPath = Self.keyPathText(arguments[0])
            {
                self = .keyPathOn(PredicateExpression(expression.operand), keyPath: keyPath)
            } else {
                self = .function(name: expression.function, arguments: arguments.map(PredicateExpression.init))
            }
        default:
            if expression.expressionType.rawValue == Self.keyPathSpecifierExpressionType,
                let keyPath = Self.keyPathText(expression)
            {
                self = .keyPath(keyPath)
            } else {
                self = .custom(expression.description)
            }
        }
    }

    private static func keyPathText(_ expression: NSExpression) -> String? {
        if expression.expressionType == .keyPath { return expression.keyPath }
        guard expression.expressionType.rawValue == keyPathSpecifierExpressionType else { return nil }
        // A key-path specifier prints as the key path itself, which is what the `@count` in `$r.@count` is.
        return expression.description
    }

    func makeExpression() throws -> NSExpression {
        switch self {
        case .object:
            NSExpression.expressionForEvaluatedObject()
        case .keyPath(let keyPath):
            NSExpression(forKeyPath: keyPath)
        case .constant(let literal):
            NSExpression(forConstantValue: literal.objectValue)
        case .variable(let name):
            NSExpression(forVariable: name)
        case .aggregate(let elements):
            NSExpression(forAggregate: try elements.map { try $0.makeExpression() })
        case .function(let name, let arguments):
            NSExpression(forFunction: name, arguments: try arguments.map { try $0.makeExpression() })
        case .subquery(let collection, let variable, let predicate):
            NSExpression(
                forSubquery: try collection.makeExpression(),
                usingIteratorVariable: variable,
                predicate: try predicate.makePredicate())
        case .keyPathOn(let operand, let keyPath):
            NSExpression(
                forFunction: try operand.makeExpression(),
                selectorName: "valueForKeyPath:",
                arguments: [NSExpression(forKeyPath: keyPath)])
        case .custom(let text):
            // An expression's text, unlike a predicate's, has no guarded parser of its own.
            try objcGuarded("The expression “\(text)” could not be parsed.", code: .invalidPredicate) {
                NSExpression(format: text)
            }
        }
    }

    /// The key path this expression reads, when it is a plain one. `nil` for anything else — a constant, a
    /// function call, a key path on a variable.
    public var plainKeyPath: String? {
        if case .keyPath(let keyPath) = self { return keyPath }
        return nil
    }
}

// MARK: - Literals

extension PredicateLiteral {
    /// Maps a parsed constant. Anything unrecognised becomes its `description` as a string, which is what the
    /// format string would have shown anyway.
    init(_ value: Any?) {
        switch value {
        case nil, is NSNull:
            self = .null
        case let decimal as NSDecimalNumber:
            self = .decimal(decimal.decimalValue)
        case let number as NSNumber:
            self = Self.fromNumber(number)
        case let string as String:
            self = .string(string)
        case let date as Date:
            self = .date(date)
        case let uuid as UUID:
            self = .uuid(uuid)
        case let url as URL:
            self = .url(url)
        case let data as Data:
            self = .data(data)
        case let objectID as NSManagedObjectID:
            self =
                ObjectRef(uri: objectID.uriRepresentation()).map(PredicateLiteral.objectRef)
                ?? .string(objectID.uriRepresentation().absoluteString)
        case let array as [Any]:
            self = .array(array.map(PredicateLiteral.init))
        case let set as Set<AnyHashable>:
            self = .array(set.map(PredicateLiteral.init))
        case let value?:
            self = .string(String(describing: value))
        }
    }

    private static func fromNumber(_ number: NSNumber) -> PredicateLiteral {
        if CFGetTypeID(number as CFTypeRef) == CFBooleanGetTypeID() { return .bool(number.boolValue) }
        switch String(cString: number.objCType) {
        case "f", "d": return .double(number.doubleValue)
        default: return .int(number.int64Value)
        }
    }

    /// The object an `NSExpression` constant holds.
    var objectValue: Any? {
        switch self {
        case .null: nil
        case .bool(let value): NSNumber(value: value)
        case .int(let value): NSNumber(value: value)
        case .double(let value): NSNumber(value: value)
        case .decimal(let value): NSDecimalNumber(decimal: value)
        case .string(let value): value
        case .date(let value): value
        case .uuid(let value): value
        case .url(let value): value
        case .data(let value): value
        case .objectRef(let ref): ref.uri
        case .array(let elements): elements.map(\.objectValue)
        }
    }

    /// What kind of attribute this constant can be compared against, when that is knowable. `nil` for `null` and
    /// for collections, which say nothing about the other side's type.
    public var attributeType: AttributeTypeGroup? {
        switch self {
        case .null, .array: nil
        case .bool: .boolean
        case .int, .double, .decimal: .number
        case .string: .string
        case .date: .date
        case .uuid: .uuid
        case .url: .uri
        case .data: .binary
        case .objectRef: .object
        }
    }
}

/// Attribute types grouped by what they can be compared with. Integer 16/32/64, Double, Float and Decimal all
/// compare with a number, so a predicate does not need to tell them apart.
public enum AttributeTypeGroup: String, Sendable, Hashable, Codable, CaseIterable {
    case number, string, boolean, date, uuid, uri, binary, object, transformable, composite, unknown
}

// MARK: - Cocoa enum bridging

extension PredicateOperator {
    init?(_ type: NSComparisonPredicate.Operator) {
        switch type {
        case .lessThan: self = .lessThan
        case .lessThanOrEqualTo: self = .lessThanOrEqual
        case .greaterThan: self = .greaterThan
        case .greaterThanOrEqualTo: self = .greaterThanOrEqual
        case .equalTo: self = .equal
        case .notEqualTo: self = .notEqual
        case .matches: self = .matches
        case .like: self = .like
        case .beginsWith: self = .beginsWith
        case .endsWith: self = .endsWith
        case .in: self = .inCollection
        case .contains: self = .contains
        case .between: self = .between
        // `customSelector` never reaches here: `PredicateGuard` refuses it while parsing.
        case .customSelector: return nil
        @unknown default: return nil
        }
    }

    var cocoa: NSComparisonPredicate.Operator {
        switch self {
        case .lessThan: .lessThan
        case .lessThanOrEqual: .lessThanOrEqualTo
        case .greaterThan: .greaterThan
        case .greaterThanOrEqual: .greaterThanOrEqualTo
        case .equal: .equalTo
        case .notEqual: .notEqualTo
        case .matches: .matches
        case .like: .like
        case .beginsWith: .beginsWith
        case .endsWith: .endsWith
        case .contains: .contains
        case .between: .between
        case .inCollection: .in
        }
    }
}

extension PredicateModifier {
    init(_ modifier: NSComparisonPredicate.Modifier) {
        switch modifier {
        case .any: self = .any
        case .all: self = .all
        default: self = .direct
        }
    }

    var cocoa: NSComparisonPredicate.Modifier {
        switch self {
        case .direct: .direct
        case .any: .any
        case .all: .all
        }
    }
}

extension PredicateOptions {
    init(_ options: NSComparisonPredicate.Options) {
        var result: PredicateOptions = []
        if options.contains(.caseInsensitive) { result.insert(.caseInsensitive) }
        if options.contains(.diacriticInsensitive) { result.insert(.diacriticInsensitive) }
        if options.contains(.normalized) { result.insert(.normalized) }
        self = result
    }

    var cocoa: NSComparisonPredicate.Options {
        var result: NSComparisonPredicate.Options = []
        if contains(.caseInsensitive) { result.insert(.caseInsensitive) }
        if contains(.diacriticInsensitive) { result.insert(.diacriticInsensitive) }
        if contains(.normalized) { result.insert(.normalized) }
        return result
    }
}
