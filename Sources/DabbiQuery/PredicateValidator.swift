import DabbiBase
import DabbiModel
import Foundation

/// Checks a predicate against the model before it is executed.
///
/// Core Data answers a bad key path with an Objective-C exception in the middle of a fetch. The validator finds
/// the same problems first and reports them as diagnostics the text field can underline and a saved predicate
/// can carry as a badge (PRD-5, ARCHITECTURE.md §6.5). It never evaluates anything.
public struct PredicateValidator: Sendable {
    public let model: ModelDescription
    private let resolver: KeyPathResolver

    public init(model: ModelDescription) {
        self.model = model
        self.resolver = KeyPathResolver(model: model)
    }

    /// Validates `ast` as a predicate fetched on `entity`.
    public func validate(_ ast: PredicateAST, entity: String) -> PredicateValidation {
        var run = Run(resolver: resolver)
        guard model.entity(named: entity) != nil else {
            run.error("There is no entity named “\(entity)” in the model.")
            return run.result
        }
        run.visit(ast, in: Scope(entity: entity))
        return run.result
    }

    /// Validates predicate text, parsing it first. A syntax error comes back as a diagnostic too, so a text
    /// field has one path for every kind of problem.
    public func validate(_ text: String, entity: String) -> PredicateValidation {
        do {
            return validate(try PredicateAST.parse(text), entity: entity)
        } catch let error as DabbiError {
            var run = Run(resolver: resolver)
            run.diagnostics.append(
                PredicateDiagnostic(severity: .error, message: error.message, suggestions: error.recovery))
            return run.result
        } catch {
            var run = Run(resolver: resolver)
            run.error(error.localizedDescription)
            return run.result
        }
    }
}

public struct PredicateValidation: Sendable, Hashable, Codable {
    public var diagnostics: [PredicateDiagnostic]
    /// Key paths in the predicate that the model has no property for (PRD-5), in the order they are written.
    public var missingKeyPaths: [String]
    /// `$NAME` variables the predicate expects a value for, sorted. A `SUBQUERY` iterator is not one of them.
    public var substitutionVariables: [String]

    public var errors: [PredicateDiagnostic] { diagnostics.filter { $0.severity == .error } }
    public var warnings: [PredicateDiagnostic] { diagnostics.filter { $0.severity == .warning } }
    /// Whether the predicate can be run. Warnings do not stop it.
    public var isValid: Bool { errors.isEmpty }
}

public struct PredicateDiagnostic: Sendable, Hashable, Codable {
    public enum Severity: String, Sendable, Hashable, Codable { case error, warning }

    public var severity: Severity
    public var message: String
    /// The key path the diagnostic is about, when it is about one.
    public var keyPath: String?
    /// What to try instead — "did you mean" names, or a sentence of advice.
    public var suggestions: [String]

    public init(severity: Severity, message: String, keyPath: String? = nil, suggestions: [String] = []) {
        self.severity = severity
        self.message = message
        self.keyPath = keyPath
        self.suggestions = suggestions
    }
}

// MARK: - The walk

/// What key paths mean at one point in the tree: the entity a bare key path starts from, and the `SUBQUERY`
/// iterators in scope.
private struct Scope {
    var entity: String
    var variables: [String: ResolvedKeyPath] = [:]

    var here: ResolvedKeyPath { ResolvedKeyPath(target: .object(entity: entity), isCollection: false) }
}

private struct Run {
    let resolver: KeyPathResolver
    var diagnostics: [PredicateDiagnostic] = []
    var missingKeyPaths: [String] = []
    var variables: Set<String> = []

    var result: PredicateValidation {
        PredicateValidation(
            diagnostics: diagnostics, missingKeyPaths: missingKeyPaths, substitutionVariables: variables.sorted())
    }

    mutating func error(_ message: String, keyPath: String? = nil, suggestions: [String] = []) {
        diagnostics.append(
            PredicateDiagnostic(severity: .error, message: message, keyPath: keyPath, suggestions: suggestions))
    }

    mutating func warn(_ message: String, keyPath: String? = nil, suggestions: [String] = []) {
        diagnostics.append(
            PredicateDiagnostic(severity: .warning, message: message, keyPath: keyPath, suggestions: suggestions))
    }

    mutating func visit(_ ast: PredicateAST, in scope: Scope) {
        switch ast {
        case .all, .none:
            return
        case .and(let subs), .or(let subs):
            for sub in subs { visit(sub, in: scope) }
        case .not(let sub):
            visit(sub, in: scope)
        case .custom(let format):
            warn(
                "This part of the predicate has no visual form and could not be checked against the model.",
                suggestions: ["It runs as written: \(format)"])
        case .comparison(let comparison):
            visit(comparison, in: scope)
        }
    }

    mutating func visit(_ comparison: PredicateComparison, in scope: Scope) {
        let left = visit(comparison.left, in: scope)
        let right = visit(comparison.right, in: scope)
        checkQuantifier(comparison, left: left)
        checkOperand(comparison, left: left, right: right)
        checkOptions(comparison, left: left)
    }

    /// `ANY` / `ALL` belong in front of a to-many key path and nowhere else.
    private mutating func checkQuantifier(_ comparison: PredicateComparison, left: ResolvedKeyPath?) {
        guard let left, let keyPath = comparison.left.plainKeyPath else { return }
        switch (comparison.modifier, left.isCollection) {
        case (.direct, true):
            // The SQLite store refuses a bare to-many key path; it cannot know which of the many to compare.
            error(
                "“\(keyPath)” names many values, so the comparison needs ANY or ALL in front of it.",
                keyPath: keyPath,
                suggestions: ["ANY \(keyPath) \(comparison.op.keyword) …", "ALL \(keyPath) \(comparison.op.keyword) …"])
        case (.any, false), (.all, false):
            let quantifier = comparison.modifier.keyword ?? "the quantifier"
            warn("“\(keyPath)” names a single value, so \(quantifier) does nothing here.", keyPath: keyPath)
        default:
            return
        }
    }

    /// The right side against the left: a collection for `IN` and `BETWEEN`, and a constant of a kind the left
    /// side can be compared with.
    private mutating func checkOperand(
        _ comparison: PredicateComparison, left: ResolvedKeyPath?, right: ResolvedKeyPath?
    ) {
        if comparison.op.wantsCollection {
            switch comparison.right {
            case .aggregate(let elements):
                if comparison.op == .between, elements.count != 2 {
                    error("BETWEEN needs exactly two values, and this one has \(elements.count).")
                }
            case .constant(.array(let elements)):
                if comparison.op == .between, elements.count != 2 {
                    error("BETWEEN needs exactly two values, and this one has \(elements.count).")
                }
            case .constant(let literal) where literal.attributeType != nil:
                error(
                    "\(comparison.op.keyword) compares against a list of values, not a single one.",
                    suggestions: ["Write the values in braces: \(comparison.op.keyword) { … }"])
            case .variable, .keyPath, .keyPathOn, .subquery, .function, .constant, .object, .custom:
                return
            }
            return
        }
        if case .fetchedProperty(let name, _) = left?.target {
            error(
                "“\(name)” is a fetched property, which a predicate cannot compare against.",
                keyPath: comparison.left.plainKeyPath)
        }
        guard let left, case .constant(let literal) = comparison.right, let constantType = literal.attributeType
        else { return }
        let target = left.typeGroup
        if target == .transformable {
            warn(
                "Transformable values are stored as an archive, so the database cannot compare them.",
                keyPath: comparison.left.plainKeyPath,
                suggestions: ["Filter on a plain attribute instead, or use the quick filter on the loaded rows."])
        } else if !target.accepts(constantType) {
            warn(
                "“\(comparison.left.plainKeyPath ?? "the left side")” holds \(target.article), and it is being "
                    + "compared with \(constantType.article).",
                keyPath: comparison.left.plainKeyPath)
        }
        _ = right
    }

    /// `[c]`, `[d]` and `[n]` only mean something to the string operators.
    private mutating func checkOptions(_ comparison: PredicateComparison, left: ResolvedKeyPath?) {
        guard !comparison.options.isEmpty, !comparison.op.acceptsStringOptions else { return }
        warn(
            "\(comparison.options.suffix) has no effect on \(comparison.op.keyword).",
            keyPath: comparison.left.plainKeyPath)
    }

    /// Resolves the key paths inside an expression and returns where it ends, when that is knowable.
    @discardableResult
    mutating func visit(_ expression: PredicateExpression, in scope: Scope) -> ResolvedKeyPath? {
        switch expression {
        case .object:
            return scope.here
        case .constant:
            return nil
        case .keyPath(let keyPath):
            return resolve(keyPath, from: scope.here, written: keyPath)
        case .variable(let name):
            if let bound = scope.variables[name] { return bound }
            variables.insert(name)
            return nil
        case .aggregate(let elements):
            for element in elements { visit(element, in: scope) }
            return nil
        case .function(_, let arguments):
            for argument in arguments { visit(argument, in: scope) }
            return nil
        case .keyPathOn(let operand, let keyPath):
            guard let base = visit(operand, in: scope) else { return nil }
            let written = operand.plainKeyPath.map { "\($0).\(keyPath)" } ?? keyPath
            return resolve(keyPath, from: base, written: written)
        case .subquery(let collection, let variable, let predicate):
            let base = visit(collection, in: scope)
            var inner = scope
            // The iterator stands for one element of the collection, so it is not itself a collection.
            if let entity = base?.entityName {
                inner.variables[variable] = ResolvedKeyPath(target: .object(entity: entity), isCollection: false)
            }
            visit(predicate, in: inner)
            return nil
        case .custom(let text):
            warn("The expression “\(text)” could not be checked against the model.")
            return nil
        }
    }

    /// Resolves one key path relative to `base`, recording a diagnostic when it does not resolve.
    /// `written` is the path as the user wrote it, which is what a diagnostic should point at.
    private mutating func resolve(
        _ keyPath: String, from base: ResolvedKeyPath, written: String
    )
        -> ResolvedKeyPath?
    {
        guard base.entityName != nil else { return nil }
        switch resolver.resolve(keyPath, from: base) {
        case .success(let target):
            if case .collectionOperator(let op, _) = target.target, !op.isSupportedBySQLiteStore {
                warn(
                    "Core Data's SQLite store can only use \(CollectionOperator.count.rawValue) in a fetch, "
                        + "not \(op.rawValue).",
                    keyPath: written)
            }
            return target
        case .failure(let failure):
            missingKeyPaths.append(written)
            error(failure.message, keyPath: written, suggestions: failure.suggestions)
            return nil
        }
    }
}

extension AttributeTypeGroup {
    /// "a number", "a string" — for diagnostics.
    var article: String {
        switch self {
        case .number: "a number"
        case .string: "text"
        case .boolean: "a true/false value"
        case .date: "a date"
        case .uuid: "a UUID"
        case .uri: "a URI"
        case .binary: "binary data"
        case .object: "an object reference"
        case .transformable: "a transformable value"
        case .composite: "a composite value"
        case .unknown: "a value of an unknown type"
        }
    }
}
