import DabbiBase
import DabbiModel
import Foundation

/// The quick filter above the grid (PRD-6, ARCHITECTURE.md §6.5): a term looked for in every string attribute
/// of an entity, as an `OR` of `CONTAINS[cd]`.
///
/// It is a search, not a predicate the user wrote: it narrows whatever the grid is already showing — the
/// entity's filter, a saved predicate, a template's run — rather than replacing it, and it is never saved.
public struct QuickFilter: Sendable, Hashable {
    public let entity: String
    /// The key paths searched: the entity's own string attributes, inherited ones included, and the string
    /// elements of its composites. Transient attributes are left out, since a fetch cannot see them; so is
    /// everything through a relationship, since a term found in a related row would bring back rows that do not
    /// show it.
    public let keyPaths: [String]

    /// `nil` when the model has no such entity.
    public init?(model: ModelDescription, entity: String) {
        guard let description = model.entity(named: entity) else { return nil }
        self.entity = entity
        var keyPaths: [String] = []
        for attribute in description.attributes where !attribute.isTransient {
            Self.addStrings(of: attribute, prefix: "", to: &keyPaths)
        }
        self.keyPaths = keyPaths
    }

    /// Whether there is anything to search: an entity of numbers and dates has no text to find a term in.
    public var isSearchable: Bool { !keyPaths.isEmpty }

    /// The predicate that finds `term`. `nil` for a term that is empty once trimmed, which filters nothing;
    /// `FALSEPREDICATE` for an entity with no string attributes, in which no term is ever found.
    public func predicate(for term: String) -> PredicateAST? {
        let term = term.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !term.isEmpty else { return nil }
        let comparisons = keyPaths.map { keyPath in
            PredicateAST.comparison(
                PredicateComparison(
                    left: .keyPath(keyPath), op: .contains, right: .constant(.string(term)),
                    options: [.caseInsensitive, .diacriticInsensitive]))
        }
        switch comparisons.count {
        case 0: return PredicateAST.none
        case 1: return comparisons[0]
        default: return .or(comparisons)
        }
    }

    /// What to fetch: `filter` narrowed by the rows that contain `term`. Either may be absent.
    ///
    /// The filter's text is kept as the user wrote it, in parentheses, rather than reformatted through the AST:
    /// it has already been validated, and it is what the predicate bar shows.
    public func narrowing(_ filter: PredicateSource?, by term: String) -> PredicateSource? {
        guard let quick = predicate(for: term), let format = try? quick.formatString() else { return filter }
        guard let filter else { return PredicateSource(format: format) }
        return PredicateSource(format: "(\(filter.format)) AND (\(format))")
    }

    /// A composite's elements are searched one by one, however deeply they nest.
    private static func addStrings(of attribute: AttributeDescription, prefix: String, to keyPaths: inout [String]) {
        if let elements = attribute.compositeElements {
            for element in elements {
                addStrings(of: element, prefix: prefix + attribute.name + ".", to: &keyPaths)
            }
        } else if attribute.type == .string {
            keyPaths.append(prefix + attribute.name)
        }
    }
}
