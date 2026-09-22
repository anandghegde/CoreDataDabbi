import Foundation

/// What to fetch: the value-type equivalent of an `NSFetchRequest`.
public struct FetchSpec: Sendable, Hashable, Codable {
    public var entity: String
    /// `true` shows rows of every descendant entity too (BRW-6).
    public var includeSubentities: Bool
    public var predicate: PredicateSource?
    /// Empty means object-ID order, which needs no sort and is instant on any store size (BRW-11).
    public var sort: [SortKey]
    public var limit: Int?

    public init(
        entity: String,
        includeSubentities: Bool = true,
        predicate: PredicateSource? = nil,
        sort: [SortKey] = [],
        limit: Int? = nil
    ) {
        self.entity = entity
        self.includeSubentities = includeSubentities
        self.predicate = predicate
        self.sort = sort
        self.limit = limit
    }
}

/// A predicate as the user wrote it.
///
/// Text stays the stored form everywhere — in a `FetchSpec`, in a saved predicate, in a project file — because
/// it is readable, diffable and survives a version of the app whose AST has moved on. `DabbiQuery` turns it into
/// a `PredicateAST` (`PredicateSource.ast()`) for the builder and the validator, and back again.
public struct PredicateSource: Sendable, Hashable, Codable {
    /// An `NSPredicate` format string with no substitution arguments, e.g. `age > 30 AND name BEGINSWITH[cd] "a"`.
    public var format: String

    public init(format: String) {
        self.format = format
    }
}

public struct SortKey: Sendable, Hashable, Codable {
    public var keyPath: String
    public var ascending: Bool

    public init(keyPath: String, ascending: Bool = true) {
        self.keyPath = keyPath
        self.ascending = ascending
    }
}
