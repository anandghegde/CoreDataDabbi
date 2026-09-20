import Foundation

/// A value in one of SQLite's five storage classes.
public enum SQLiteValue: Sendable, Hashable {
    case null
    case integer(Int64)
    case real(Double)
    case text(String)
    case blob(Data)

    public var int64: Int64? {
        if case .integer(let value) = self { return value }
        return nil
    }

    public var double: Double? {
        switch self {
        case .real(let value): return value
        case .integer(let value): return Double(value)
        default: return nil
        }
    }

    public var string: String? {
        if case .text(let value) = self { return value }
        return nil
    }

    public var data: Data? {
        if case .blob(let value) = self { return value }
        return nil
    }

    public var isNull: Bool { self == .null }
}

// Deliberately not `ExpressibleByNilLiteral`: with it, `connection.scalar(…) != nil` compares against `.null`
// instead of asking whether there was a row.
extension SQLiteValue: ExpressibleByIntegerLiteral, ExpressibleByStringLiteral {
    public init(integerLiteral value: Int64) { self = .integer(value) }
    public init(stringLiteral value: String) { self = .text(value) }
}

/// One fully materialised result row.
public struct SQLiteRow: Sendable, Hashable {
    public let columns: [String]
    public let values: [SQLiteValue]

    public init(columns: [String], values: [SQLiteValue]) {
        self.columns = columns
        self.values = values
    }

    public subscript(index: Int) -> SQLiteValue { values[index] }

    /// The value of the first column with this name (case-insensitive, like SQLite), or `nil` when there is none.
    public subscript(column: String) -> SQLiteValue? {
        columns.firstIndex { $0.caseInsensitiveCompare(column) == .orderedSame }.map { values[$0] }
    }
}
