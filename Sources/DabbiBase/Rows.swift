import Foundation

/// The ordered list of properties a page of rows carries. `RowSnapshot.values` follows this order.
public struct ColumnSet: Sendable, Hashable, Codable {
    /// Property names (attributes and relationships) of the fetched entity or its sub-entities.
    public var properties: [String]

    public init(_ properties: [String]) {
        self.properties = properties
    }

    public func index(of property: String) -> Int? { properties.firstIndex(of: property) }
}

/// One managed object's values at the moment it was read.
public struct RowSnapshot: Sendable, Hashable, Codable {
    public let ref: ObjectRef
    /// Values in `ColumnSet` order. A property the row's entity does not have is `.null`.
    public let values: [Value]

    public init(ref: ObjectRef, values: [Value]) {
        self.ref = ref
        self.values = values
    }
}

/// A window of rows from a pager.
public struct RowPage: Sendable, Hashable, Codable {
    /// Positions within the pager's ID list. May be shorter than the requested range at the end of the list.
    public let range: Range<Int>
    /// Rows in pager order. A row deleted since the pager was opened is absent, so `rows.count` can be less
    /// than `range.count`; `missing` says which.
    public let rows: [RowSnapshot]
    /// The columns the rows carry: the pager's, or the subset the page was asked for.
    public let columns: ColumnSet
    /// The session generation the page belongs to. Pages from an older generation must be dropped.
    public let generation: Int
    /// Positions in `range`, ascending, whose objects no longer exist. Almost always empty.
    public let missing: [Int]

    public init(range: Range<Int>, rows: [RowSnapshot], columns: ColumnSet, generation: Int, missing: [Int] = []) {
        self.range = range
        self.rows = rows
        self.columns = columns
        self.generation = generation
        self.missing = missing
    }

    /// The row at `position` of the pager's list; `nil` outside `range` and for a deleted row.
    public func row(at position: Int) -> RowSnapshot? {
        guard range.contains(position) else { return nil }
        var index = position - range.lowerBound
        for gap in missing {
            if gap == position { return nil }
            if gap > position { break }
            index -= 1
        }
        return rows.indices.contains(index) ? rows[index] : nil
    }

    /// One element per position of `range`; `nil` where the row is gone.
    public var rowsByPosition: [RowSnapshot?] {
        guard !missing.isEmpty else { return rows }
        var remaining = rows[...]
        let gaps = Set(missing)
        return range.map { gaps.contains($0) ? nil : remaining.popFirst() }
    }
}

/// All values of a single object, for the inspector and `get_object`.
public struct ObjectSnapshot: Sendable, Hashable, Codable {
    public let row: RowSnapshot
    public let columns: ColumnSet
    public let generation: Int

    public init(row: RowSnapshot, columns: ColumnSet, generation: Int) {
        self.row = row
        self.columns = columns
        self.generation = generation
    }

    public subscript(property: String) -> Value? {
        columns.index(of: property).map { row.values[$0] }
    }
}
