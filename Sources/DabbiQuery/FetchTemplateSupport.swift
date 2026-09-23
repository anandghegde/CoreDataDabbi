import DabbiBase
import DabbiModel
import Foundation

// Running a model's fetch-request templates (M2-05, BRW-1). A template is an entity, a predicate that may hold
// `$VARIABLE`s, a sort and a limit. Running one means asking for the variables, putting the values into the
// predicate, and showing the entity through the result — which is then a predicate like any other, so the grid,
// the predicate bar and tracking take it without knowing where it came from.
//
// The values go into the AST rather than through `NSManagedObjectModel.fetchRequestFromTemplate(withName:
// substitutionVariables:)`: what comes out has to be text anyway, for the predicate bar to show and for the grid
// to fetch with, and a model read from a store's cache may not carry its templates at all (PRJ-3).

/// One `$NAME` a template's predicate expects a value for.
public struct FetchTemplateVariable: Sendable, Hashable, Identifiable {
    public var name: String
    /// The key path it is compared with, when a comparison says: `dateValue > $SINCE` is `dateValue`.
    public var keyPath: String?
    /// What kind of value it takes. Text when nothing says otherwise — a variable compared with a function, or
    /// with a to-one relationship, which has no value that can be typed.
    public var kind: BuilderValueKind
    /// `IN $NAMES` takes a list, `BETWEEN $RANGE` a pair; everything else one value.
    public var arity: BuilderArity

    public var id: String { name }

    public init(name: String, keyPath: String? = nil, kind: BuilderValueKind = .string, arity: BuilderArity = .single) {
        self.name = name
        self.keyPath = keyPath
        self.kind = kind
        self.arity = arity
    }

    /// The value typed for this variable, or `nil` when the text is not one: a list is comma-separated, a pair is
    /// a list of exactly two (an empty list is not a value: `IN {}` is no row at all), a date is ISO 8601, a Boolean is `true`/`false` or `yes`/`no`.
    ///
    /// Text is taken as typed, `$` and all: in a prompt for a value, `$FOO` is what is being looked for, not
    /// another variable.
    public func value(from text: String) -> PredicateLiteral? {
        switch arity {
        case .none:
            return nil
        case .single:
            return Self.literal(from: text, kind: kind)
        case .pair, .list:
            guard let items = kind.values(fromList: text) else { return nil }
            var literals: [PredicateLiteral] = []
            for item in items {
                switch item {
                case .literal(let literal): literals.append(literal)
                // `values(fromList:)` reads `$X` as a variable; here it is only text.
                case .variable(let name):
                    guard let literal = Self.literal(from: "$" + name, kind: kind) else { return nil }
                    literals.append(literal)
                }
            }
            if arity == .pair ? literals.count != 2 : literals.isEmpty { return nil }
            return .array(literals)
        }
    }

    /// Whether `literal` is something this variable can take: the prompt's date picker and check box hand
    /// literals over directly, and are held to the same rule as text.
    public func accepts(_ literal: PredicateLiteral) -> Bool {
        switch (arity, literal) {
        case (.single, .array), (.none, _): false
        case (.single, let single): kind.accepts(single)
        case (.pair, .array(let items)): items.count == 2 && items.allSatisfy(kind.accepts)
        case (.list, .array(let items)): !items.isEmpty && items.allSatisfy(kind.accepts)
        case (.pair, _), (.list, _): false
        }
    }

    private static func literal(from text: String, kind: BuilderValueKind) -> PredicateLiteral? {
        let trimmed = text.trimmingCharacters(in: .whitespaces)
        switch kind {
        case .string, .presence:
            return .string(text)
        case .boolean:
            switch trimmed.lowercased() {
            case "true", "yes", "1": return .bool(true)
            case "false", "no", "0": return .bool(false)
            default: return nil
            }
        case .date:
            let formatter = ISO8601DateFormatter()
            if let date = formatter.date(from: trimmed) { return .date(date) }
            formatter.formatOptions = [.withFullDate]
            return formatter.date(from: trimmed).map(PredicateLiteral.date)
        case .integer, .decimal, .uuid, .uri:
            // A leading `$` makes the builder's reader see a variable; a number or an ID never starts with one.
            guard !trimmed.hasPrefix("$"), case .literal(let literal)? = kind.value(from: text) else { return nil }
            return literal
        }
    }
}

/// A fetch-request template, read against the model: what it shows, what it asks for, and whether it can run.
public struct FetchTemplatePlan: Sendable, Hashable {
    public var template: FetchRequestTemplate
    /// The variables in the order the predicate first mentions them, which is the order the prompt asks.
    public var variables: [FetchTemplateVariable]
    /// Why it cannot be run, in words. Empty when it can.
    public var problems: [String]

    public var name: String { template.name }
    /// The entity it fetches, when it names one the model has.
    public var entity: String? { problems.isEmpty ? template.entity : nil }
    public var isRunnable: Bool { problems.isEmpty }
    public var sort: [SortKey] { template.sort }
    /// `nil` for no limit — Core Data's `0`.
    public var limit: Int? { template.fetchLimit > 0 ? template.fetchLimit : nil }

    private let ast: PredicateAST?

    public init(template: FetchRequestTemplate, model: ModelDescription) {
        self.template = template
        var problems: [String] = []
        var ast: PredicateAST?
        if let entity = template.entity, model.entity(named: entity) != nil {
            if let format = template.predicateFormat {
                do {
                    ast = try PredicateAST.parse(format)
                } catch {
                    problems.append((error as? DabbiError)?.message ?? "The predicate could not be read.")
                }
            }
        } else if let entity = template.entity {
            problems.append("There is no entity named “\(entity)” in the model.")
        } else {
            problems.append("The fetch request does not say which entity it fetches.")
        }
        self.ast = ast
        self.problems = problems
        var collector = VariableCollector(resolver: KeyPathResolver(model: model), entity: template.entity ?? "")
        if let ast { collector.visit(ast, bound: []) }
        self.variables = collector.found
    }

    /// The predicate with every variable given its value, as text: what the grid is filtered by.
    ///
    /// `nil` when the template has no predicate, which is every row.
    ///
    /// - Throws: ``DabbiError`` with `.invalidPredicate` when a variable has no value, or a value it cannot take.
    public func predicate(with values: [String: PredicateLiteral]) throws -> PredicateSource? {
        guard isRunnable else { throw DabbiError(.invalidPredicate, problems.joined(separator: " ")) }
        guard let ast else { return nil }
        for variable in variables {
            guard let value = values[variable.name] else {
                throw DabbiError(.invalidPredicate, "“$\(variable.name)” needs a value.")
            }
            guard variable.accepts(value) else {
                throw DabbiError(.invalidPredicate, "“$\(variable.name)” cannot take that value.")
            }
        }
        return try ast.substituting(values, bound: []).source()
    }
}

// MARK: - Finding the variables

/// Walks a predicate for the variables it expects, and what each is compared with. A `SUBQUERY`'s iterator is
/// bound inside it, and is not one of them.
private struct VariableCollector {
    let resolver: KeyPathResolver
    let entity: String
    var found: [FetchTemplateVariable] = []

    mutating func visit(_ ast: PredicateAST, bound: Set<String>) {
        switch ast {
        case .all, .none, .custom: break
        case .and(let subs), .or(let subs): for sub in subs { visit(sub, bound: bound) }
        case .not(let sub): visit(sub, bound: bound)
        case .comparison(let comparison): visit(comparison, bound: bound)
        }
    }

    private mutating func visit(_ comparison: PredicateComparison, bound: Set<String>) {
        // The key path goes on the left, as the builder puts it, so that one reading covers `$MIN < age` too.
        let oriented =
            comparison.right.plainKeyPath != nil && comparison.left.plainKeyPath == nil
            ? (comparison.reversed ?? comparison) : comparison
        let field = oriented.left.plainKeyPath.flatMap { keyPath in
            bound.isEmpty ? BuilderSchema.field(for: keyPath, entity: entity, resolver: resolver) : nil
        }
        let kind = field.map(\.kind).flatMap { $0 == .presence ? nil : $0 }

        switch oriented.right {
        case .variable(let name) where !bound.contains(name):
            let arity: BuilderArity =
                switch oriented.op {
                case .inCollection: .list
                case .between: .pair
                default: .single
                }
            add(FetchTemplateVariable(name: name, keyPath: field?.keyPath, kind: kind ?? .string, arity: arity))
        case .aggregate(let elements):
            for case .variable(let name) in elements where !bound.contains(name) {
                add(FetchTemplateVariable(name: name, keyPath: field?.keyPath, kind: kind ?? .string))
            }
        default:
            visit(oriented.right, bound: bound)
        }
        visit(oriented.left, bound: bound)
    }

    /// Variables anywhere else in an expression say nothing about their type, and are asked for as text.
    private mutating func visit(_ expression: PredicateExpression, bound: Set<String>) {
        switch expression {
        case .object, .keyPath, .constant, .custom: break
        case .variable(let name):
            if !bound.contains(name) { add(FetchTemplateVariable(name: name)) }
        case .aggregate(let elements):
            for element in elements { visit(element, bound: bound) }
        case .function(_, let arguments):
            for argument in arguments { visit(argument, bound: bound) }
        case .subquery(let collection, let variable, let predicate):
            visit(collection, bound: bound)
            visit(predicate, bound: bound.union([variable]))
        case .keyPathOn(let operand, _):
            visit(operand, bound: bound)
        }
    }

    /// The first mention decides. A later one with a type fills in a first one that had none.
    private mutating func add(_ variable: FetchTemplateVariable) {
        guard let index = found.firstIndex(where: { $0.name == variable.name }) else {
            found.append(variable)
            return
        }
        if found[index].keyPath == nil, variable.keyPath != nil { found[index] = variable }
    }
}

// MARK: - Substitution

extension PredicateAST {
    fileprivate func substituting(_ values: [String: PredicateLiteral], bound: Set<String>) -> PredicateAST {
        switch self {
        case .all, .none, .custom: self
        case .and(let subs): .and(subs.map { $0.substituting(values, bound: bound) })
        case .or(let subs): .or(subs.map { $0.substituting(values, bound: bound) })
        case .not(let sub): .not(sub.substituting(values, bound: bound))
        case .comparison(let comparison): .comparison(comparison.substituting(values, bound: bound))
        }
    }
}

extension PredicateComparison {
    fileprivate func substituting(_ values: [String: PredicateLiteral], bound: Set<String>) -> PredicateComparison {
        var copy = self
        copy.left = left.substituting(values, bound: bound)
        copy.right = right.substituting(values, bound: bound)
        return copy
    }
}

extension PredicateExpression {
    fileprivate func substituting(_ values: [String: PredicateLiteral], bound: Set<String>) -> PredicateExpression {
        switch self {
        case .object, .keyPath, .constant, .custom:
            self
        case .variable(let name):
            bound.contains(name) ? self : values[name].map(PredicateExpression.constant) ?? self
        case .aggregate(let elements):
            .aggregate(elements.map { $0.substituting(values, bound: bound) })
        case .function(let name, let arguments):
            .function(name: name, arguments: arguments.map { $0.substituting(values, bound: bound) })
        case .subquery(let collection, let variable, let predicate):
            .subquery(
                collection: collection.substituting(values, bound: bound), variable: variable,
                predicate: predicate.substituting(values, bound: bound.union([variable])))
        case .keyPathOn(let operand, let keyPath):
            .keyPathOn(operand.substituting(values, bound: bound), keyPath: keyPath)
        }
    }
}
