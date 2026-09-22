import DabbiModel
import Foundation

/// What a predicate being typed can continue with (M2-02, ARCHITECTURE.md §6.5).
///
/// Half a predicate rarely parses, so nothing here goes through `NSPredicate`. The text up to the caret is
/// tokenised, the partial key path in front of the caret is resolved against the model, and what could come next
/// is offered: the entity's properties, the operators the type on the left allows, the `[cd]` options, the words
/// that join two comparisons. Nothing is evaluated and no store is touched.
public struct PredicateCompleter: Sendable {
    public let model: ModelDescription
    private let resolver: KeyPathResolver

    public init(model: ModelDescription) {
        self.model = model
        self.resolver = KeyPathResolver(model: model)
    }

    /// What can be typed at `caret` — a UTF-16 offset, which is what AppKit's text views count in.
    ///
    /// The result is empty rather than an error when the caret is somewhere nothing can be offered: inside a
    /// string, after a number, or behind a key path the model cannot resolve.
    public func completions(in text: String, at caret: Int, entity: String) -> PredicateCompletions {
        let units = Array(text.utf16)
        let caret = min(max(caret, 0), units.count)
        let stem = Self.stem(in: units, before: caret)
        let nothing = PredicateCompletions(range: stem.range, items: [])
        guard model.entity(named: entity) != nil else { return nothing }

        let tokens = Lexer.tokens(in: units, upTo: caret)
        // The token the caret sits at the end of is the one being typed; anything else is already written.
        let partial = tokens.last.flatMap { $0.end == caret && $0.kind.isPartial ? $0 : nil }
        let previous = partial == nil ? tokens.last : tokens.dropLast().last

        if let partial, partial.kind == .unterminatedString || partial.kind == .number { return nothing }

        var place: Place
        if let partial, partial.kind == .unterminatedOptions {
            place = .options
        } else {
            place = Self.place(after: previous)
            // A word being typed where a key path belongs refines which key path: `author.na` asks what an
            // Author's properties are, not what the fetched entity's are.
            if let partial, partial.kind == .path, case .keyPath(_, _, let quantifiers) = place {
                guard let path = Self.path(of: partial.text, stem: stem.text) else { return nothing }
                place = .keyPath(
                    prefix: path.prefix, collectionOperator: path.collectionOperator,
                    quantifiers: quantifiers && path.prefix.isEmpty && !path.collectionOperator)
            }
        }

        return PredicateCompletions(
            range: stem.range, items: Self.matching(items(for: place, in: entity), stem: stem.text))
    }

    // MARK: What belongs where

    /// Where the caret is, and so what can be written there.
    private enum Place {
        /// A key path, standing at `prefix` — empty for the fetched entity itself. `collectionOperator` is the
        /// caret right after an `@`, where only `count` and its siblings belong. `quantifiers` is a comparison
        /// that has not started yet, where `ANY` and `NOT` are still words that can be written.
        case keyPath(prefix: String, collectionOperator: Bool, quantifiers: Bool)
        /// After a key path, written here as the user wrote it.
        case comparisonOperator(String)
        case value
        case conjunction
        case options
    }

    private static func place(after token: Token?) -> Place {
        guard let token else { return .keyPath(prefix: "", collectionOperator: false, quantifiers: true) }
        switch token.kind {
        case .string, .number:
            return .conjunction
        case .options:
            return .value
        case .unterminatedString, .unterminatedOptions:
            return .value
        case .symbol:
            switch token.text {
            case "(", "&&", "||", "!":
                return .keyPath(prefix: "", collectionOperator: false, quantifiers: true)
            case ")", "}":
                return .conjunction
            default:
                // A comparison operator, a comma or a brace: a value comes next either way.
                return .value
            }
        case .path:
            let word = token.text.uppercased()
            if Keyword.logical.contains(word) {
                return .keyPath(prefix: "", collectionOperator: false, quantifiers: true)
            }
            if Keyword.quantifiers.contains(word) {
                return .keyPath(prefix: "", collectionOperator: false, quantifiers: false)
            }
            if Keyword.wordOperators.contains(word) { return .value }
            if Keyword.values.contains(word) { return .conjunction }
            return .comparisonOperator(token.text)
        }
    }

    private func items(for place: Place, in entity: String) -> [PredicateCompletionItem] {
        switch place {
        case .keyPath(let prefix, let collectionOperator, let quantifiers):
            return keyPathItems(
                prefix: prefix, collectionOperator: collectionOperator, quantifiers: quantifiers, in: entity)
        case .comparisonOperator(let keyPath):
            return operatorItems(after: keyPath, in: entity)
        case .value:
            return [
                PredicateCompletionItem("nil", kind: .value, detail: String(localized: "No value")),
                PredicateCompletionItem("TRUE", kind: .value),
                PredicateCompletionItem("FALSE", kind: .value),
            ]
        case .conjunction:
            return [
                PredicateCompletionItem("AND", kind: .keyword, detail: String(localized: "Both must hold")),
                PredicateCompletionItem("OR", kind: .keyword, detail: String(localized: "Either may hold")),
            ]
        case .options:
            // In this order the letters already typed pick themselves out: `[c` offers `[c]` before `[cd]`.
            return [
                PredicateCompletionItem("c]", kind: .option, detail: String(localized: "Ignore case")),
                PredicateCompletionItem("cd]", kind: .option, detail: String(localized: "Ignore case and accents")),
                PredicateCompletionItem("d]", kind: .option, detail: String(localized: "Ignore accents")),
                PredicateCompletionItem("n]", kind: .option, detail: String(localized: "Normalised comparison")),
            ]
        }
    }

    private func keyPathItems(
        prefix: String, collectionOperator: Bool, quantifiers: Bool, in entity: String
    ) -> [PredicateCompletionItem] {
        let root = ResolvedKeyPath(target: .object(entity: entity), isCollection: false)
        let resolved: ResolvedKeyPath
        if prefix.isEmpty {
            resolved = root
        } else if let step = try? resolver.resolve(prefix, from: root).get() {
            resolved = step
        } else {
            // Nothing sensible follows a key path the model does not have; the validator says why.
            return []
        }

        if collectionOperator {
            guard resolved.isCollection else { return [] }
            return CollectionOperator.allCases.map {
                PredicateCompletionItem(
                    String($0.rawValue.dropFirst()), kind: .collectionOperator, detail: Self.gloss($0))
            }
        }

        var items = properties(at: resolved)
        if resolved.isCollection {
            items += CollectionOperator.allCases.map {
                PredicateCompletionItem($0.rawValue, kind: .collectionOperator, detail: Self.gloss($0))
            }
        }
        if quantifiers {
            items += [
                PredicateCompletionItem("ANY", kind: .keyword, detail: String(localized: "One of many matches")),
                PredicateCompletionItem("ALL", kind: .keyword, detail: String(localized: "Every one of many matches")),
                PredicateCompletionItem("NONE", kind: .keyword, detail: String(localized: "Not one of many matches")),
                PredicateCompletionItem("NOT", kind: .keyword),
                PredicateCompletionItem("SELF", kind: .keyword, detail: String(localized: "The object itself")),
                PredicateCompletionItem("TRUEPREDICATE", kind: .keyword, detail: String(localized: "Every row")),
                PredicateCompletionItem("FALSEPREDICATE", kind: .keyword, detail: String(localized: "No row")),
            ]
        }
        return items
    }

    private func properties(at resolved: ResolvedKeyPath) -> [PredicateCompletionItem] {
        switch resolved.target {
        case .object(let name):
            return model.entity(named: name).map(properties(of:)) ?? []
        case .toOne(let relationship), .toMany(let relationship):
            return model.entity(named: relationship.destinationEntity).map(properties(of:)) ?? []
        case .attribute(let attribute, _):
            // A composite attribute's elements are addressable, and nothing else an attribute holds is (S3).
            return (attribute.compositeElements ?? []).map {
                PredicateCompletionItem($0.name, kind: .attribute, detail: $0.type.displayName)
            }
        case .collectionOperator, .fetchedProperty:
            return []
        }
    }

    private func properties(of entity: EntityDescription) -> [PredicateCompletionItem] {
        entity.attributes.map { PredicateCompletionItem($0.name, kind: .attribute, detail: $0.type.displayName) }
            + entity.relationships.map {
                PredicateCompletionItem(
                    $0.name, kind: .relationship,
                    detail: ($0.isToMany ? String(localized: "To-many → ") : String(localized: "To-one → "))
                        + $0.destinationEntity)
            }
    }

    private func operatorItems(after keyPath: String, in entity: String) -> [PredicateCompletionItem] {
        let resolved = try? resolver.resolve(keyPath, in: entity).get()
        return PredicateOperator.allCases
            .filter { Self.suits($0, resolved) }
            .map { PredicateCompletionItem($0.keyword, kind: .comparisonOperator, detail: Self.gloss($0)) }
    }

    /// Whether an operator says anything about the type on its left. A key path the model cannot resolve gets
    /// the whole list rather than none: the user is mid-word, not necessarily wrong.
    private static func suits(_ op: PredicateOperator, _ resolved: ResolvedKeyPath?) -> Bool {
        guard let resolved else { return true }
        switch op {
        case .equal, .notEqual, .inCollection:
            return true
        case .lessThan, .lessThanOrEqual, .greaterThan, .greaterThanOrEqual, .between:
            switch resolved.typeGroup {
            case .number, .boolean, .date, .string, .uuid, .unknown: return true
            default: return false
            }
        case .contains:
            // A string contains a substring; a to-many contains an object.
            switch resolved.typeGroup {
            case .string, .uri, .object, .unknown: return true
            default: return resolved.isCollection
            }
        case .beginsWith, .endsWith, .like, .matches:
            switch resolved.typeGroup {
            case .string, .uri, .unknown: return true
            default: return false
            }
        }
    }

    private static func gloss(_ op: PredicateOperator) -> String? {
        switch op {
        case .equal: String(localized: "Is equal to")
        case .notEqual: String(localized: "Is not equal to")
        case .lessThan: String(localized: "Is less than")
        case .lessThanOrEqual: String(localized: "Is at most")
        case .greaterThan: String(localized: "Is greater than")
        case .greaterThanOrEqual: String(localized: "Is at least")
        case .contains: String(localized: "Contains")
        case .beginsWith: String(localized: "Begins with")
        case .endsWith: String(localized: "Ends with")
        case .like: String(localized: "Matches a pattern with * and ?")
        case .matches: String(localized: "Matches a regular expression")
        case .between: String(localized: "Is between two values: { lower, upper }")
        case .inCollection: String(localized: "Is one of { … }")
        }
    }

    private static func gloss(_ op: CollectionOperator) -> String? {
        op.isSupportedBySQLiteStore
            ? String(localized: "How many")
            : String(localized: "Not supported by SQLite stores")
    }

    // MARK: Text

    /// The word in front of the caret — what a chosen item replaces. Dots are not part of it, so completing
    /// `author.na` replaces `na` and leaves the path it hangs from alone, which is also how AppKit's text views
    /// decide what a completion covers.
    private static func stem(in units: [UInt16], before caret: Int) -> (text: String, range: Range<Int>) {
        var start = caret
        while start > 0, Lexer.isWord(units[start - 1]) { start -= 1 }
        return (String(decoding: units[start..<caret], as: UTF16.self), start..<caret)
    }

    /// Splits the key path being typed into the part that is already written and whether an `@` was just typed.
    /// `nil` when the text in front of the stem is something else entirely — a `$variable`, say.
    private static func path(of partial: String, stem: String) -> (prefix: String, collectionOperator: Bool)? {
        var head = Substring(partial).dropLast(stem.count)
        if head.isEmpty { return ("", false) }
        if head.hasSuffix("@") {
            head = head.dropLast()
            if head.hasSuffix(".") { head = head.dropLast() }
            return (String(head), true)
        }
        guard head.hasSuffix(".") else { return nil }
        return (String(head.dropLast()), false)
    }

    private static func matching(
        _ items: [PredicateCompletionItem], stem: String
    ) -> [PredicateCompletionItem] {
        guard !stem.isEmpty else { return items }
        let lowercased = stem.lowercased()
        let matches = items.filter { $0.text.lowercased().hasPrefix(lowercased) }
        // What was typed in the case it is written in comes first: typing `n` offers `name` before `NONE`.
        return matches.filter { $0.text.hasPrefix(stem) } + matches.filter { !$0.text.hasPrefix(stem) }
    }
}

// MARK: - The result

public struct PredicateCompletions: Sendable, Hashable {
    /// What a chosen item replaces, as UTF-16 offsets into the text: the word in front of the caret, which is
    /// empty when the caret sits after a space.
    public var range: Range<Int>
    /// In the order to offer them: the likeliest first.
    public var items: [PredicateCompletionItem]

    public var isEmpty: Bool { items.isEmpty }

    public init(range: Range<Int>, items: [PredicateCompletionItem]) {
        self.range = range
        self.items = items
    }
}

public struct PredicateCompletionItem: Sendable, Hashable {
    public enum Kind: String, Sendable, Hashable, Codable, CaseIterable {
        case attribute, relationship, collectionOperator, comparisonOperator, keyword, option, value
    }

    /// The text that replaces ``PredicateCompletions/range``.
    public var text: String
    public var kind: Kind
    /// What it is, in a few words: an attribute's type, a relationship's destination, what an operator does.
    public var detail: String?

    public init(_ text: String, kind: Kind, detail: String? = nil) {
        self.text = text
        self.kind = kind
        self.detail = detail
    }
}

// MARK: - Tokens

private struct Token {
    enum Kind {
        /// An identifier, a keyword or a whole key path: `name`, `AND`, `author.books.@count`.
        case path
        case number
        case string
        case unterminatedString
        /// `[cd]` after an operator.
        case options
        case unterminatedOptions
        case symbol

        /// Whether a token of this kind can be one the user is still typing.
        var isPartial: Bool {
            switch self {
            case .path, .number, .unterminatedString, .unterminatedOptions: true
            case .string, .options, .symbol: false
            }
        }
    }

    var kind: Kind
    var text: String
    /// The UTF-16 offset one past the token's last character.
    var end: Int
}

/// Enough of the predicate language to tell where the caret is. It is deliberately forgiving: it is reading text
/// that is half-written by definition, and a token it gets slightly wrong costs a completion, not a fetch.
private enum Lexer {
    static func tokens(in units: [UInt16], upTo end: Int) -> [Token] {
        var tokens: [Token] = []
        var index = 0
        while index < end {
            let character = units[index]
            if isSpace(character) {
                index += 1
                continue
            }
            let start = index

            if character == quote || character == apostrophe {
                index += 1
                var isClosed = false
                while index < end {
                    if units[index] == backslash {
                        index = min(index + 2, end)
                        continue
                    }
                    let isQuote = units[index] == character
                    index += 1
                    if isQuote {
                        isClosed = true
                        break
                    }
                }
                tokens.append(token(isClosed ? .string : .unterminatedString, units, start..<index))
            } else if isDigit(character) {
                while index < end, isDigit(units[index]) || units[index] == dot { index += 1 }
                tokens.append(token(.number, units, start..<index))
            } else if isPathStart(character) {
                while index < end, isPathCharacter(units[index]) { index += 1 }
                tokens.append(token(.path, units, start..<index))
            } else if character == openBracket {
                while index < end, units[index] != closeBracket { index += 1 }
                let isClosed = index < end
                if isClosed { index += 1 }
                tokens.append(token(isClosed ? .options : .unterminatedOptions, units, start..<index))
            } else {
                index += 1
                if index < end, isSecondSymbolCharacter(units[index]), isFirstSymbolCharacter(character) {
                    index += 1
                }
                tokens.append(token(.symbol, units, start..<index))
            }
        }
        return tokens
    }

    private static func token(_ kind: Token.Kind, _ units: [UInt16], _ range: Range<Int>) -> Token {
        Token(kind: kind, text: String(decoding: units[range], as: UTF16.self), end: range.upperBound)
    }

    // Only ASCII is classified; anything above it belongs to whatever token it is found in, which keeps a name
    // written in another script — or an emoji in a string — from splitting a token in two.
    static func isSpace(_ c: UInt16) -> Bool { c == 32 || c == 9 || c == 10 || c == 13 }
    static func isDigit(_ c: UInt16) -> Bool { c >= 48 && c <= 57 }
    static func isLetter(_ c: UInt16) -> Bool {
        (c >= 65 && c <= 90) || (c >= 97 && c <= 122) || c > 127
    }
    static func isWord(_ c: UInt16) -> Bool { isLetter(c) || isDigit(c) || c == underscore }
    static func isPathStart(_ c: UInt16) -> Bool {
        isLetter(c) || c == underscore || c == dollar || c == at || c == hash
    }
    static func isPathCharacter(_ c: UInt16) -> Bool { isWord(c) || c == dot || c == at || c == dollar }
    private static func isFirstSymbolCharacter(_ c: UInt16) -> Bool {
        c == less || c == greater || c == equals || c == bang || c == ampersand || c == pipe
    }
    private static func isSecondSymbolCharacter(_ c: UInt16) -> Bool {
        c == equals || c == less || c == greater || c == ampersand || c == pipe
    }

    private static let quote = UInt16(34)
    private static let apostrophe = UInt16(39)
    private static let backslash = UInt16(92)
    private static let openBracket = UInt16(91)
    private static let closeBracket = UInt16(93)
    private static let dot = UInt16(46)
    private static let underscore = UInt16(95)
    private static let dollar = UInt16(36)
    private static let at = UInt16(64)
    private static let hash = UInt16(35)
    private static let less = UInt16(60)
    private static let greater = UInt16(62)
    private static let equals = UInt16(61)
    private static let bang = UInt16(33)
    private static let ampersand = UInt16(38)
    private static let pipe = UInt16(124)
}

private enum Keyword {
    static let logical: Set<String> = ["AND", "OR", "NOT"]
    static let quantifiers: Set<String> = ["ANY", "ALL", "NONE", "SOME"]
    static let wordOperators: Set<String> = [
        "CONTAINS", "BEGINSWITH", "ENDSWITH", "LIKE", "MATCHES", "IN", "BETWEEN",
    ]
    static let values: Set<String> = [
        "NIL", "NULL", "TRUE", "FALSE", "YES", "NO", "TRUEPREDICATE", "FALSEPREDICATE",
    ]
}
