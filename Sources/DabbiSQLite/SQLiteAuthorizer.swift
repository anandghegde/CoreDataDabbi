import Foundation
import SQLite3

/// What a connection's compile-time authorizer lets through.
///
/// The authorizer is defence in depth on top of `SQLITE_OPEN_READONLY` and `PRAGMA query_only`
/// (ARCHITECTURE.md §6.2): even a statement that could not write anyway is refused when it is not a read.
public enum SQLiteAuthorizerPolicy: Sendable, Hashable {
    /// `SELECT`, column reads, functions, recursive CTEs, read transactions and an allow-list of read-only pragmas.
    /// `ATTACH`, every write, every write pragma and everything else is denied.
    case readOnly
    /// No authorizer. Only for connections to files we own (for example a backup destination).
    case unrestricted
}

enum SQLiteAuthorizer {
    /// Pragmas that only inspect the schema or check the file. They may take an argument (`table_info(ZPERSON)`).
    static let introspectionPragmas: Set<String> = [
        "table_info", "table_xinfo", "table_list", "index_list", "index_info", "index_xinfo",
        "foreign_key_list", "foreign_key_check", "integrity_check", "quick_check",
        "database_list", "collation_list", "function_list", "pragma_list", "compile_options",
    ]

    /// Pragmas that read a setting when given no argument. With an argument they would write, so that is denied.
    static let readablePragmas: Set<String> = [
        "data_version", "schema_version", "user_version", "application_id", "page_count", "page_size",
        "freelist_count", "journal_mode", "encoding", "auto_vacuum", "query_only", "busy_timeout",
        "cache_size", "max_page_count",
    ]

    static let deniedFunctions: Set<String> = ["load_extension"]

    static func install(on db: OpaquePointer, policy: SQLiteAuthorizerPolicy) {
        switch policy {
        case .unrestricted:
            sqlite3_set_authorizer(db, nil, nil)
        case .readOnly:
            sqlite3_set_authorizer(db, readOnlyCallback, nil)
        }
    }

    static func decide(action: Int32, first: String?, second: String?) -> Int32 {
        switch action {
        case SQLITE_SELECT, SQLITE_READ, SQLITE_RECURSIVE, SQLITE_TRANSACTION:
            return SQLITE_OK
        case SQLITE_FUNCTION:
            // For SQLITE_FUNCTION the *second* string is the function name.
            guard let name = second?.lowercased() else { return SQLITE_DENY }
            return deniedFunctions.contains(name) ? SQLITE_DENY : SQLITE_OK
        case SQLITE_PRAGMA:
            guard let name = first?.lowercased() else { return SQLITE_DENY }
            if introspectionPragmas.contains(name) { return SQLITE_OK }
            if readablePragmas.contains(name), second == nil { return SQLITE_OK }
            return SQLITE_DENY
        default:
            return SQLITE_DENY
        }
    }
}

private let readOnlyCallback:
    @convention(c) (
        UnsafeMutableRawPointer?, Int32, UnsafePointer<CChar>?, UnsafePointer<CChar>?, UnsafePointer<CChar>?,
        UnsafePointer<CChar>?
    ) -> Int32 = { _, action, first, second, _, _ in
        SQLiteAuthorizer.decide(
            action: action,
            first: first.map { String(cString: $0) },
            second: second.map { String(cString: $0) }
        )
    }
