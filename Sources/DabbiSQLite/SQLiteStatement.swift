import DabbiBase
import Foundation
import SQLite3

private let SQLITE_TRANSIENT = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

/// A prepared statement. Finalised when it is released; keeps its connection alive until then.
public final class SQLiteStatement {
    private let handle: OpaquePointer
    private let connection: SQLiteConnection

    init(handle: OpaquePointer, connection: SQLiteConnection) {
        self.handle = handle
        self.connection = connection
    }

    deinit {
        sqlite3_finalize(handle)
    }

    // MARK: Binding

    /// Binds positional parameters, first parameter first. Clears earlier bindings and resets the statement.
    public func bind(_ values: [SQLiteValue]) throws {
        sqlite3_reset(handle)
        sqlite3_clear_bindings(handle)
        let expected = Int(sqlite3_bind_parameter_count(handle))
        guard values.count == expected else {
            throw DabbiError(.sqlite, "The statement takes \(expected) parameter(s) but \(values.count) were given.")
        }
        for (offset, value) in values.enumerated() {
            let index = Int32(offset + 1)
            let code: Int32
            switch value {
            case .null: code = sqlite3_bind_null(handle, index)
            case .integer(let value): code = sqlite3_bind_int64(handle, index, value)
            case .real(let value): code = sqlite3_bind_double(handle, index, value)
            case .text(let value): code = sqlite3_bind_text(handle, index, value, -1, SQLITE_TRANSIENT)
            case .blob(let value):
                code = value.withUnsafeBytes { bytes in
                    sqlite3_bind_blob64(handle, index, bytes.baseAddress, UInt64(bytes.count), SQLITE_TRANSIENT)
                }
            }
            guard code == SQLITE_OK else { throw connection.currentError(code) }
        }
    }

    // MARK: Stepping

    /// Advances to the next row. Returns `false` when the statement is done.
    public func step() throws -> Bool {
        let code = sqlite3_step(handle)
        switch code {
        case SQLITE_ROW: return true
        case SQLITE_DONE: return false
        default:
            let error = connection.currentError(code)
            sqlite3_reset(handle)
            throw error
        }
    }

    public func reset() {
        sqlite3_reset(handle)
    }

    // MARK: Columns

    public var columnCount: Int { Int(sqlite3_column_count(handle)) }

    public var columnNames: [String] {
        (0..<Int32(columnCount)).map { sqlite3_column_name(handle, $0).map { String(cString: $0) } ?? "" }
    }

    public func isNull(at index: Int) -> Bool {
        sqlite3_column_type(handle, Int32(index)) == SQLITE_NULL
    }

    public func int64(at index: Int) -> Int64 {
        sqlite3_column_int64(handle, Int32(index))
    }

    public func double(at index: Int) -> Double {
        sqlite3_column_double(handle, Int32(index))
    }

    public func text(at index: Int) -> String? {
        sqlite3_column_text(handle, Int32(index)).map { String(cString: $0) }
    }

    public func blob(at index: Int) -> Data? {
        guard let bytes = sqlite3_column_blob(handle, Int32(index)) else {
            return isNull(at: index) ? nil : Data()
        }
        return Data(bytes: bytes, count: Int(sqlite3_column_bytes(handle, Int32(index))))
    }

    public func value(at index: Int) -> SQLiteValue {
        switch sqlite3_column_type(handle, Int32(index)) {
        case SQLITE_INTEGER: return .integer(int64(at: index))
        case SQLITE_FLOAT: return .real(double(at: index))
        case SQLITE_TEXT: return .text(text(at: index) ?? "")
        case SQLITE_BLOB: return .blob(blob(at: index) ?? Data())
        default: return .null
        }
    }

    public func values() -> [SQLiteValue] {
        (0..<columnCount).map(value(at:))
    }
}
