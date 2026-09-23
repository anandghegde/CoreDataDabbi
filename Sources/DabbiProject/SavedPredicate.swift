import DabbiBase
import Foundation

/// A predicate kept in the project under a name, with the grid it is looked at through (PRD-3, BRW-3).
///
/// One file per predicate in the package's `predicates/` folder (ARCHITECTURE.md §6.9), so two people adding
/// one each to a project in a repository do not both edit the same file. The predicate is kept as text, as
/// everywhere else (`PredicateSource`): an AST beside it would be a second answer that could disagree.
public struct SavedPredicate: Sendable, Hashable, Identifiable {
    public var id: UUID
    public var name: String
    /// The entity it filters. Its sub-entities' rows come along, as they do when the entity is picked.
    public var entity: String
    /// `nil` = every row: a saved view of the entity with its own columns and sort, and nothing left out.
    public var predicate: PredicateSource?
    public var columns: [ColumnLayout]
    public var sort: [SortKey]

    public init(
        id: UUID = UUID(), name: String, entity: String, predicate: PredicateSource?,
        columns: [ColumnLayout] = [], sort: [SortKey] = []
    ) {
        self.id = id
        self.name = name
        self.entity = entity
        self.predicate = predicate
        self.columns = columns
        self.sort = sort
    }

    /// The grid's layout while this predicate is shown: its own columns and sort, and itself as the filter.
    ///
    /// Setting it takes those three back. The display attribute is not among them — how an object of an
    /// entity is labelled is the entity's, wherever it is shown — so it is not kept here and reads as `nil`.
    public var layout: EntityLayout {
        get { EntityLayout(columns: columns, sort: sort, filter: predicate) }
        set {
            columns = newValue.columns
            sort = newValue.sort
            predicate = newValue.filter
        }
    }

    /// `base` if no predicate in `existing` is called that, else `base 2`, `base 3`… — the Finder's way.
    public static func uniqueName(_ base: String, among existing: some Sequence<String>) -> String {
        let taken = Set(existing.map { $0.lowercased() })
        guard taken.contains(base.lowercased()) else { return base }
        var number = 2
        while taken.contains("\(base) \(number)".lowercased()) { number += 1 }
        return "\(base) \(number)"
    }
}

extension SavedPredicate: Codable {
    private enum CodingKeys: String, CodingKey { case id, name, entity, predicate, columns, sort }

    public init(from decoder: any Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        id = try values.decode(UUID.self, forKey: .id)
        name = try values.decode(String.self, forKey: .name)
        entity = try values.decode(String.self, forKey: .entity)
        predicate = try values.decodeIfPresent(PredicateSource.self, forKey: .predicate)
        columns = try values.decodeIfPresent([ColumnLayout].self, forKey: .columns) ?? []
        sort = try values.decodeIfPresent([SortKey].self, forKey: .sort) ?? []
    }
}
