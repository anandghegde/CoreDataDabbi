import DabbiBase
import Foundation

/// Which properties two readings of the same row differ in — the *changed fields* TRK-2 shows strongly.
///
/// By property **name**, never by position. The two sides need not be laid out the same way: the before may have
/// come from a grid page whose columns are the union of an entity and its sub-entities, or from a page that was
/// fetched lazily with three columns of twenty, while the after is read by the row's own entity's layout. Comparing
/// `values[i]` to `values[i]` across those two would report changes that did not happen.
///
/// A property only one side carries is not a change: it is a difference in what was read, which is why the
/// comparison is over the intersection and `comparedKeys` says how wide it was.
public enum FieldDiff {
    /// The properties whose values differ, and the properties that could be compared at all.
    public struct Result: Sendable, Hashable {
        public var changed: Set<String>
        /// The properties both sides carried. `changed` is a subset of it.
        public var compared: Set<String>

        public init(changed: Set<String>, compared: Set<String>) {
            self.changed = changed
            self.compared = compared
        }

        /// Nothing could be compared: the two readings have no property in common.
        public var isEmpty: Bool { compared.isEmpty }
    }

    /// Compares two whole-object readings.
    ///
    /// Blobs are compared by their summary — length, sniffed type, external flag — because a page never carries
    /// the bytes. Bytes that changed without changing any of those read as unchanged here; the row is still
    /// reported as changed, since its save counter moved, only the field is not marked.
    public static func compare(_ before: ObjectSnapshot, _ after: ObjectSnapshot) -> Result {
        compare(before.row, in: before.columns, to: after.row, in: after.columns)
    }

    public static func compare(
        _ before: RowSnapshot, in beforeColumns: ColumnSet, to after: RowSnapshot, in afterColumns: ColumnSet
    ) -> Result {
        var changed: Set<String> = []
        var compared: Set<String> = []
        // Indexed once: the after side is walked for every property, and a linear `index(of:)` per property is
        // quadratic on a wide entity.
        var positions: [String: Int] = [:]
        positions.reserveCapacity(afterColumns.properties.count)
        for (index, name) in afterColumns.properties.enumerated() where positions[name] == nil {
            positions[name] = index
        }

        for (index, name) in beforeColumns.properties.enumerated() {
            guard index < before.values.count, let other = positions[name], other < after.values.count else {
                continue
            }
            compared.insert(name)
            if before.values[index] != after.values[other] { changed.insert(name) }
        }
        return Result(changed: changed, compared: compared)
    }
}
