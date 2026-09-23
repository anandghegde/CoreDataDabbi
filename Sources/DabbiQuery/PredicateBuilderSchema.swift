import DabbiModel
import Foundation

// The visual builder's half of the predicate core (M2-03, PRD-1, PRD-2). The builder in the app is an
// `NSPredicateEditor` whose row templates are generated from what is here: which key paths an entity offers,
// what each can be compared with and how, and how one row reads and writes a comparison of the AST. None of it
// needs AppKit, so all of it is tested here; the templates only draw it.

/// What kind of value a builder row edits. It decides the row's operators and its value editor.
public enum BuilderValueKind: String, Sendable, Hashable, Codable, CaseIterable {
    case string, integer, decimal, boolean, date, uuid, uri
    /// A to-one relationship, binary data, a transformable: the builder can ask whether there is one, and nothing
    /// else, because there is no value to type.
    case presence

    init?(_ type: AttributeType) {
        switch type {
        case .integer16, .integer32, .integer64: self = .integer
        case .decimal, .double, .float: self = .decimal
        case .string: self = .string
        case .boolean: self = .boolean
        case .date: self = .date
        case .uuid: self = .uuid
        case .uri: self = .uri
        case .binaryData, .transformable, .objectID: self = .presence
        // A composite has no value of its own — its elements are the rows — and an undefined attribute is a
        // transient one, which a fetch cannot see.
        case .composite, .undefined: return nil
        }
    }

    /// The comparisons a row of this kind offers, in menu order. Nil checks are separate: see
    /// ``BuilderField/operators``.
    public var comparisons: [PredicateOperator] {
        switch self {
        case .string:
            [.equal, .notEqual, .contains, .beginsWith, .endsWith, .like, .matches, .inCollection]
        case .integer, .decimal:
            [
                .equal, .notEqual, .lessThan, .lessThanOrEqual, .greaterThan, .greaterThanOrEqual, .between,
                .inCollection,
            ]
        case .date:
            [.equal, .notEqual, .lessThan, .lessThanOrEqual, .greaterThan, .greaterThanOrEqual, .between]
        case .uuid:
            [.equal, .notEqual, .inCollection]
        case .boolean, .uri:
            [.equal, .notEqual]
        case .presence:
            []
        }
    }

    /// Whether `[c]` and `[d]` can be switched on — string comparisons only, since that is the only kind they
    /// change anything for.
    public var acceptsStringOptions: Bool { self == .string }

    /// Whether a row's value is typed into a text field, and so can also be a `$VARIABLE` for a fetch-request
    /// template. A date has a date picker and a Boolean a pop-up; neither can hold a variable.
    public var isTyped: Bool {
        switch self {
        case .string, .integer, .decimal, .uuid, .uri: true
        case .boolean, .date, .presence: false
        }
    }

    /// Whether `literal` can be shown in this kind's editor and written back unchanged.
    public func accepts(_ literal: PredicateLiteral) -> Bool {
        switch (self, literal) {
        case (.string, .string), (.date, .date), (.uuid, .uuid), (.uri, .url), (.boolean, .bool): true
        case (.integer, .int), (.decimal, .int), (.decimal, .double), (.decimal, .decimal): true
        // `flag == 1` is how many people write a Boolean; the store compares the same column either way.
        case (.boolean, .int(let value)): value == 0 || value == 1
        case (.integer, .double(let value)): value.rounded() == value && abs(value) < 9e15
        default: false
        }
    }
}

/// `ANY`, `ALL` or `NONE` in front of a comparison through a to-many relationship.
public enum BuilderQuantifier: String, Sendable, Hashable, Codable, CaseIterable {
    case any, all
    /// `NONE`, which parses as `NOT (ANY …)`. Not `none`, which an optional quantifier would read as `nil`.
    case notAny
}

/// What a row's operator pop-up can say: a comparison, or whether there is a value at all.
public enum BuilderOperator: Sendable, Hashable, Codable {
    case compare(PredicateOperator)
    case isNil
    case isNotNil

    /// How many values the row edits: none for a nil check, two for `BETWEEN`, a list for `IN`.
    public var arity: BuilderArity {
        switch self {
        case .isNil, .isNotNil: .none
        case .compare(.between): .pair
        case .compare(.inCollection): .list
        case .compare: .single
        }
    }
}

public enum BuilderArity: String, Sendable, Hashable, Codable, CaseIterable {
    case none, single, pair, list
}

extension PredicateOptions {
    /// The option sets the builder offers, in menu order. `[n]` is not among them: it is an optimisation for
    /// already-normalised text, not a question anybody asks, and a predicate using it stays in the text field.
    public static let builderChoices: [PredicateOptions] = [
        [], [.caseInsensitive], [.diacriticInsensitive], [.caseInsensitive, .diacriticInsensitive],
    ]
}

/// One key path the builder offers, and what can be asked about it.
public struct BuilderField: Sendable, Hashable, Identifiable {
    public var keyPath: String
    public var kind: BuilderValueKind
    /// Reached through a to-many relationship, so a row must say `ANY`, `ALL` or `NONE`: the SQLite store
    /// refuses a bare to-many key path.
    public var isQuantified: Bool
    /// Whether "is nil" and "is not nil" are offered. Not for `@count`, which is never nil, nor through a to-many,
    /// where it asks something nobody means.
    public var offersNilChecks: Bool

    public var id: String { keyPath }

    /// The key path's parts, for a title: `author.name` → `["author", "name"]`.
    public var components: [String] { keyPath.split(separator: ".").map(String.init) }

    /// Every operator the row's pop-up offers, comparisons first.
    public var operators: [BuilderOperator] {
        kind.comparisons.map(BuilderOperator.compare) + (offersNilChecks ? [.isNil, .isNotNil] : [])
    }

    public var quantifiers: [BuilderQuantifier] { isQuantified ? BuilderQuantifier.allCases : [] }
}

/// The key paths the builder offers for one entity, generated from the model.
public struct BuilderSchema: Sendable, Hashable {
    public let entity: String
    /// In menu order: the entity's own attributes, then what is reached through each relationship.
    public private(set) var fields: [BuilderField]
    private let model: ModelDescription

    /// - Parameters:
    ///   - relationshipDepth: how many relationships a generated key path may pass through. A predicate that
    ///     goes deeper still gets its rows: ``including(_:)`` adds any key path it names.
    ///   - fieldLimit: where a very wide model stops being listed, so a pop-up stays a pop-up.
    public init(model: ModelDescription, entity: String, relationshipDepth: Int = 2, fieldLimit: Int = 400) {
        self.model = model
        self.entity = entity
        fields = []
        guard let description = model.entity(named: entity) else { return }
        var keyPaths: [String] = []
        Self.walk(
            description, model: model, prefix: "", depth: relationshipDepth, cameBack: nil, throughToMany: false,
            into: &keyPaths, limit: fieldLimit)
        let resolver = KeyPathResolver(model: model)
        fields = keyPaths.compactMap { Self.field(for: $0, entity: entity, resolver: resolver) }
    }

    public func field(for keyPath: String) -> BuilderField? {
        fields.first { $0.keyPath == keyPath }
    }

    /// The same schema with every key path `ast` compares added, when the model knows it and the builder has a
    /// row for it — a path deeper than the generated ones, say. Opening a predicate in the builder must not
    /// depend on how far the menus happened to reach.
    public func including(_ ast: PredicateAST) -> BuilderSchema {
        let resolver = KeyPathResolver(model: model)
        var copy = self
        for comparison in ast.comparisons {
            guard let keyPath = comparison.left.plainKeyPath, field(for: keyPath) == nil,
                !copy.fields.contains(where: { $0.keyPath == keyPath }),
                let field = Self.field(for: keyPath, entity: entity, resolver: resolver)
            else { continue }
            copy.fields.append(field)
        }
        return copy
    }

    /// Lists key paths depth first. A relationship is not followed back the way the walk came, since
    /// `books.author.books` only leads to where it started, and a second to-many is not entered: one quantifier
    /// per row is what a row can say.
    private static func walk(
        _ entity: EntityDescription, model: ModelDescription, prefix: String, depth: Int, cameBack: String?,
        throughToMany: Bool, into keyPaths: inout [String], limit: Int
    ) {
        func add(_ keyPath: String) {
            if keyPaths.count < limit { keyPaths.append(keyPath) }
        }
        for attribute in entity.attributes where !attribute.isTransient {
            addAttribute(attribute, prefix: prefix, add: add)
        }
        for relationship in entity.relationships where relationship.name != cameBack {
            guard keyPaths.count < limit else { return }
            let path = prefix + relationship.name
            if relationship.isToMany {
                guard !throughToMany else { continue }
                add(path + ".@count")
            } else if !throughToMany {
                add(path)
            }
            guard depth > 0, let destination = model.entity(named: relationship.destinationEntity) else { continue }
            walk(
                destination, model: model, prefix: path + ".", depth: depth - 1, cameBack: relationship.inverseName,
                throughToMany: throughToMany || relationship.isToMany, into: &keyPaths, limit: limit)
        }
    }

    /// A composite attribute is not a row; its elements are, however deeply they nest.
    private static func addAttribute(_ attribute: AttributeDescription, prefix: String, add: (String) -> Void) {
        guard let elements = attribute.compositeElements else {
            add(prefix + attribute.name)
            return
        }
        for element in elements {
            addAttribute(element, prefix: prefix + attribute.name + ".", add: add)
        }
    }

    /// What the builder can do with `keyPath`, by resolving it the way validation does, so the builder never
    /// offers a path validation would then refuse.
    static func field(for keyPath: String, entity: String, resolver: KeyPathResolver) -> BuilderField? {
        guard case .success(let resolved) = resolver.resolve(keyPath, in: entity) else { return nil }
        switch resolved.target {
        case .attribute(let attribute, _):
            guard !attribute.isTransient, let kind = BuilderValueKind(attribute.type) else { return nil }
            return BuilderField(
                keyPath: keyPath, kind: kind, isQuantified: resolved.isCollection,
                offersNilChecks: !resolved.isCollection)
        case .toOne:
            // Through a to-many, "is there one" would need a quantifier and a nil check both; nobody asks that.
            guard !resolved.isCollection else { return nil }
            return BuilderField(keyPath: keyPath, kind: .presence, isQuantified: false, offersNilChecks: true)
        case .collectionOperator(.count, _) where !resolved.isCollection:
            return BuilderField(keyPath: keyPath, kind: .integer, isQuantified: false, offersNilChecks: false)
        case .object, .toMany, .collectionOperator, .fetchedProperty:
            return nil
        }
    }
}

// MARK: - Rows

/// A value in a row: something typed, or a `$VARIABLE` a fetch-request template fills in.
public enum BuilderValue: Sendable, Hashable, Codable {
    case literal(PredicateLiteral)
    case variable(String)

    var expression: PredicateExpression {
        switch self {
        case .literal(let literal): .constant(literal)
        case .variable(let name): .variable(name)
        }
    }
}

/// One row of the builder: `keyPath quantifier operator[options] values`.
public struct BuilderRow: Sendable, Hashable {
    public var keyPath: String
    /// `nil` for a field that is not reached through a to-many.
    public var quantifier: BuilderQuantifier?
    public var op: BuilderOperator
    public var options: PredicateOptions
    /// As many as ``BuilderOperator/arity`` says: none, one, two, or a list.
    public var values: [BuilderValue]

    public init(
        keyPath: String, quantifier: BuilderQuantifier? = nil, op: BuilderOperator, options: PredicateOptions = [],
        values: [BuilderValue] = []
    ) {
        self.keyPath = keyPath
        self.quantifier = quantifier
        self.op = op
        self.options = options
        self.values = values
    }

    /// Reads a row out of `ast`: a comparison, or `NOT (ANY …)`, which is how `NONE` parses. `nil` when `ast` is
    /// not one row, or when `field` has no editor for what it says — the caller then keeps it as text.
    public init?(_ ast: PredicateAST, field: BuilderField) {
        var negated = false
        var node = ast
        if case .not(let inner) = ast {
            negated = true
            node = inner
        }
        guard case .comparison(let comparison) = node, comparison.left.plainKeyPath == field.keyPath else {
            return nil
        }

        switch (comparison.modifier, field.isQuantified, negated) {
        case (.direct, false, false): quantifier = nil
        case (.any, true, false): quantifier = .any
        case (.all, true, false): quantifier = .all
        case (.any, true, true): quantifier = .notAny
        default: return nil
        }
        keyPath = field.keyPath
        options = comparison.options
        guard options.isEmpty || (field.kind.acceptsStringOptions && PredicateOptions.builderChoices.contains(options))
        else { return nil }

        if case .constant(.null) = comparison.right, field.offersNilChecks {
            switch comparison.op {
            case .equal: op = .isNil
            case .notEqual: op = .isNotNil
            default: return nil
            }
            guard options.isEmpty else { return nil }
            values = []
            return
        }

        guard field.kind.comparisons.contains(comparison.op) else { return nil }
        op = .compare(comparison.op)
        guard let values = Self.values(of: comparison.right, arity: op.arity, kind: field.kind) else { return nil }
        self.values = values
    }

    private static func values(
        of right: PredicateExpression, arity: BuilderArity, kind: BuilderValueKind
    )
        -> [BuilderValue]?
    {
        let values: [BuilderValue]
        switch right {
        case .constant(.array(let literals)) where arity == .pair || arity == .list:
            values = literals.map(BuilderValue.literal)
        case .aggregate(let elements) where arity == .pair || arity == .list:
            var collected: [BuilderValue] = []
            for element in elements {
                switch element {
                case .constant(let literal): collected.append(.literal(literal))
                case .variable(let name): collected.append(.variable(name))
                default: return nil
                }
            }
            values = collected
        case .constant(let literal) where arity == .single:
            values = [.literal(literal)]
        // `IN $TAGS` — the whole list is the variable.
        case .variable(let name) where arity == .single || arity == .list:
            values = [.variable(name)]
        default:
            return nil
        }
        if arity == .pair, values.count != 2 { return nil }
        for value in values {
            switch value {
            case .literal(let literal): guard kind.accepts(literal) else { return nil }
            case .variable: guard kind.isTyped else { return nil }
            }
        }
        return values
    }

    /// The predicate the row stands for. `NONE` is written `NOT (ANY …)`, which is what it parses as.
    public var predicate: PredicateAST {
        let modifier: PredicateModifier =
            switch quantifier {
            case nil: .direct
            case .any, .notAny: .any
            case .all: .all
            }
        let right: PredicateExpression
        let comparisonOperator: PredicateOperator
        switch op {
        case .isNil, .isNotNil:
            right = .constant(.null)
            comparisonOperator = op == .isNil ? .equal : .notEqual
        case .compare(let compared):
            comparisonOperator = compared
            if op.arity == .list, values.count == 1, case .variable(let name) = values[0] {
                right = .variable(name)
            } else if op.arity == .pair || op.arity == .list {
                right = .aggregate(values.map(\.expression))
            } else {
                right = values.first?.expression ?? .constant(.null)
            }
        }
        let comparison = PredicateAST.comparison(
            PredicateComparison(
                left: .keyPath(keyPath), op: comparisonOperator, right: right, modifier: modifier,
                options: op.arity == .none ? [] : options))
        return quantifier == .notAny ? .not(comparison) : comparison
    }
}

// MARK: - The editor's shape

/// What the builder shows for a predicate: its rows, or why it keeps the predicate as text.
public enum BuilderPresentation: Sendable, Hashable {
    /// The predicate in the one shape the editor accepts: a group at the root (so an empty filter is an empty
    /// "All" group rather than no editor), a None group as `NOT (OR …)`, and a `NONE` row as `NOT (ANY …)`.
    /// Anything else makes `NSPredicateEditor` raise, so nothing else is ever handed to it.
    case rows(PredicateAST)
    /// The builder shows one read-only row and the text field stays authoritative.
    case custom([BuilderObstacle])
}

extension BuilderSchema {
    /// How the builder shows `ast`. Checks every comparison against a row as well as the tree's shape, so what
    /// comes back as `.rows` reads back out of the editor as the same predicate.
    public func presentation(of ast: PredicateAST) -> BuilderPresentation {
        let normalised = ast.normalisedForBuilder()
        let obstacles = normalised.builderObstacles
        guard obstacles.isEmpty else { return .custom(obstacles) }
        let schema = including(normalised)
        var rowObstacles: [BuilderObstacle] = []
        let shaped = schema.shape(normalised, obstacles: &rowObstacles)
        guard rowObstacles.isEmpty else { return .custom(rowObstacles) }
        switch shaped {
        case .and, .or: return .rows(shaped)
        case .not(.or): return .rows(shaped)
        default: return .rows(.and([shaped]))
        }
    }

    /// The row `ast` is, when it is one this schema can show.
    public func row(for ast: PredicateAST) -> BuilderRow? {
        guard let keyPath = Self.rowKeyPath(of: ast), let field = field(for: keyPath) else { return nil }
        return BuilderRow(ast, field: field)
    }

    private static func rowKeyPath(of ast: PredicateAST) -> String? {
        switch ast {
        case .comparison(let comparison), .not(.comparison(let comparison)): comparison.left.plainKeyPath
        default: nil
        }
    }

    private func shape(_ ast: PredicateAST, obstacles: inout [BuilderObstacle]) -> PredicateAST {
        switch ast {
        case .all:
            // The empty group. At the root it is "no filter"; nested, it is a group with no rows, which the
            // editor draws and reads back as TRUEPREDICATE.
            return .and([])
        case .and(let subs):
            return .and(subs.map { shape($0, obstacles: &obstacles) })
        case .or(let subs):
            return .or(subs.map { shape($0, obstacles: &obstacles) })
        case .not(let inner):
            // A `NONE` row stays a row; any other negation is a None group, which the editor writes NOT (OR …).
            if row(for: ast) != nil { return ast }
            if case .or(let subs) = inner { return .not(.or(subs.map { shape($0, obstacles: &obstacles) })) }
            return .not(.or([shape(inner, obstacles: &obstacles)]))
        case .comparison(let comparison):
            if row(for: ast) == nil {
                obstacles.append(rowObstacle(for: comparison))
            }
            return ast
        case .none, .custom:
            // `builderObstacles` has already turned these away.
            return ast
        }
    }

    private func rowObstacle(for comparison: PredicateComparison) -> BuilderObstacle {
        let text = (try? PredicateAST.comparison(comparison).formatString()) ?? String(describing: comparison)
        guard let keyPath = comparison.left.plainKeyPath, let field = field(for: keyPath) else {
            return BuilderObstacle(reason: .keyPathNotOffered, text: text)
        }
        if field.isQuantified, comparison.modifier == .direct {
            return BuilderObstacle(reason: .needsQuantifier, text: text)
        }
        return BuilderObstacle(reason: .noEditorForRow, text: text)
    }
}

// MARK: - Typed values

extension BuilderValueKind {
    /// The value typed into a row's field, or `nil` when it is not one of these. `$NAME` is a substitution
    /// variable; an empty number field is 0, the way an empty `NSPredicateEditor` number field has always read.
    public func value(from text: String) -> BuilderValue? {
        let trimmed = text.trimmingCharacters(in: .whitespaces)
        if isTyped, let name = Self.variableName(trimmed) { return .variable(name) }
        switch self {
        case .string:
            // Text is taken as typed: leading spaces can be what a user is looking for.
            return .literal(.string(text))
        case .integer, .decimal:
            if trimmed.isEmpty { return .literal(.int(0)) }
            if let integer = Int64(trimmed) { return .literal(.int(integer)) }
            if let double = Double(trimmed), double.isFinite { return .literal(.double(double)) }
            return nil
        case .uuid:
            return UUID(uuidString: trimmed).map { .literal(.uuid($0)) }
        case .uri:
            guard let url = URL(string: trimmed), url.scheme != nil else { return nil }
            return .literal(.url(url))
        case .boolean, .date, .presence:
            return nil
        }
    }

    /// How a value is shown in a row's field. `value(from:)` reads it back as the same value.
    public func text(for value: BuilderValue) -> String {
        switch value {
        case .variable(let name): "$" + name
        case .literal(let literal): Self.text(for: literal)
        }
    }

    /// A list for `IN`: values separated by commas. A string containing a comma, a quote or spaces at either end
    /// is written in double quotes, with `\"` and `\\` inside them.
    public func values(fromList text: String) -> [BuilderValue]? {
        guard let items = Self.splitList(text) else { return nil }
        var values: [BuilderValue] = []
        for (item, quoted) in items {
            if quoted {
                guard self == .string else { return nil }
                values.append(.literal(.string(item)))
            } else {
                guard let value = value(from: item) else { return nil }
                values.append(value)
            }
        }
        return values
    }

    public func listText(for values: [BuilderValue]) -> String {
        values.map { value in
            let text = text(for: value)
            guard self == .string, case .literal = value, Self.needsQuotes(text) else { return text }
            let escaped = text.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
            return "\"" + escaped + "\""
        }.joined(separator: ", ")
    }

    private static func text(for literal: PredicateLiteral) -> String {
        switch literal {
        case .null: ""
        case .bool(let value): value ? "true" : "false"
        case .int(let value): String(value)
        case .double(let value): value.rounded() == value && abs(value) < 1e15 ? String(Int64(value)) : String(value)
        case .decimal(let value): NSDecimalNumber(decimal: value).stringValue
        case .string(let value): value
        case .date(let value): ISO8601DateFormatter().string(from: value)
        case .uuid(let value): value.uuidString
        case .url(let value): value.absoluteString
        case .data(let value): value.base64EncodedString()
        case .objectRef(let ref): ref.uri.absoluteString
        case .array(let elements): elements.map(text(for:)).joined(separator: ", ")
        }
    }

    private static func variableName(_ text: String) -> String? {
        guard text.hasPrefix("$") else { return nil }
        let name = text.dropFirst()
        guard let first = name.first, first.isLetter || first == "_",
            name.allSatisfy({ $0.isLetter || $0.isNumber || $0 == "_" })
        else { return nil }
        return String(name)
    }

    private static func needsQuotes(_ text: String) -> Bool {
        text.isEmpty || text.contains(",") || text.contains("\"") || text.hasPrefix(" ") || text.hasSuffix(" ")
            || text.hasPrefix("$")
    }

    /// Splits on commas outside double quotes. `nil` for an unterminated quote or text after a closing one.
    private static func splitList(_ text: String) -> [(String, quoted: Bool)]? {
        guard !text.trimmingCharacters(in: .whitespaces).isEmpty else { return [] }
        var items: [(String, quoted: Bool)] = []
        var characters = text[...]
        while true {
            characters = characters.drop(while: { $0 == " " })
            if characters.first == "\"" {
                characters = characters.dropFirst()
                var item = ""
                var closed = false
                while let character = characters.popFirst() {
                    if character == "\\", let escaped = characters.popFirst() {
                        item.append(escaped)
                    } else if character == "\"" {
                        closed = true
                        break
                    } else {
                        item.append(character)
                    }
                }
                guard closed else { return nil }
                characters = characters.drop(while: { $0 == " " })
                items.append((item, true))
                guard let next = characters.popFirst() else { return items }
                guard next == "," else { return nil }
            } else {
                let end = characters.firstIndex(of: ",") ?? characters.endIndex
                items.append((characters[..<end].trimmingCharacters(in: .whitespaces), false))
                guard end < characters.endIndex else { return items }
                characters = characters[characters.index(after: end)...]
            }
        }
    }
}
