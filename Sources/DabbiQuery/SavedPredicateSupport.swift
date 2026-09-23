import DabbiBase
import DabbiModel
import Foundation

// What the engine can say about a saved predicate (PRD-3, PRD-5). The saved predicate itself is a project file
// (`DabbiProject`); these take its parts, so that neither module has to know the other.

/// Whether a saved predicate still fits the model the store is open with (PRD-5).
///
/// A project outlives a model: an attribute is renamed, an entity goes. The predicate is not refused or
/// rewritten over it — it keeps its place in the list with a badge naming what is gone, and the user decides.
public struct SavedPredicateCheck: Sendable, Hashable {
    /// Key paths the model has no property for, from the predicate and then from the sort, each once.
    public var missingKeyPaths: [String]
    /// Everything that stops it from being run, in words: the missing entity, the predicate's errors, the sort
    /// keys that no longer resolve.
    public var problems: [String]
    /// The entity itself is gone. There is nothing to show it on, so it cannot even be opened.
    public var isMissingEntity: Bool

    public var isUsable: Bool { problems.isEmpty }

    public static let fine = SavedPredicateCheck(missingKeyPaths: [], problems: [], isMissingEntity: false)
}

extension PredicateValidator {
    /// Checks a saved predicate's entity, text and sort against the model.
    public func check(entity: String, predicate: PredicateSource?, sort: [SortKey]) -> SavedPredicateCheck {
        guard model.entity(named: entity) != nil else {
            return SavedPredicateCheck(
                missingKeyPaths: [], problems: ["There is no entity named “\(entity)” in the model."],
                isMissingEntity: true)
        }
        var check = SavedPredicateCheck.fine
        if let predicate {
            let validation = validate(predicate.format, entity: entity)
            check.missingKeyPaths = validation.missingKeyPaths
            check.problems = validation.errors.map(\.message)
        }
        let resolver = KeyPathResolver(model: model)
        for key in sort {
            guard case .failure(let failure) = resolver.resolve(key.keyPath, in: entity) else { continue }
            if !check.missingKeyPaths.contains(key.keyPath) { check.missingKeyPaths.append(key.keyPath) }
            check.problems.append("Sorted by “\(key.keyPath)”: \(failure.message)")
        }
        return check
    }
}

public enum SavedPredicateNaming {
    /// Longer than this, and a name stops being something to read in a sidebar.
    public static let maximumLength = 40

    /// The name a new saved predicate is given before the user names it: its first condition as written —
    /// `age > 30`, `ANY tags.name == "work"` — or the entity's name when it has no condition (PRD-3).
    public static func defaultName(for predicate: PredicateSource?, entity: String) -> String {
        guard let predicate, let ast = try? PredicateAST.parse(predicate),
            let first = firstCondition(of: ast), let text = try? first.formatString()
        else { return entity }
        guard text.count > maximumLength else { return text }
        return String(text.prefix(maximumLength - 1)).trimmingCharacters(in: .whitespaces) + "…"
    }

    /// Descends through `AND` and `OR` only. A `NOT` is part of the condition it negates, and a name that left
    /// it out would say the opposite of the predicate.
    private static func firstCondition(of ast: PredicateAST) -> PredicateAST? {
        switch ast {
        case .and(let parts), .or(let parts): parts.lazy.compactMap(firstCondition).first
        case .all: nil
        case .none, .not, .comparison, .custom: ast
        }
    }
}

extension BuilderSchema {
    /// The field a new predicate starts on: the entity's own `name` or `title` when it has one, as that is
    /// what people filter by first (PRD-3). Then an attribute that ends in either, such as `fullName`.
    public var preferredField: BuilderField? {
        let own = fields.filter { $0.kind == .string && !$0.keyPath.contains(".") }
        let exact = ["name", "title"].lazy.compactMap { word in
            own.first { $0.keyPath.lowercased() == word }
        }.first
        return exact ?? own.first { $0.keyPath.hasSuffix("Name") || $0.keyPath.hasSuffix("Title") }
    }

    /// The one row a new predicate opens with: `name CONTAINS[cd] ""`, for the value to be typed into.
    public var starterPredicate: PredicateAST? {
        guard let field = preferredField else { return nil }
        return .and([
            .comparison(
                PredicateComparison(
                    left: .keyPath(field.keyPath), op: .contains, right: .constant(.string("")),
                    options: [.caseInsensitive, .diacriticInsensitive]))
        ])
    }
}
