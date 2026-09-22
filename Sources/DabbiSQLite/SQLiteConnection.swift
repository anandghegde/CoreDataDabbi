import CDabbiSQLite
import DabbiBase
import Foundation
import SQLite3

/// A hardened, read-only connection to a SQLite database.
///
/// Not `Sendable`: confine a connection to one actor (see `SQLiteReader`).
///
/// **Short read transactions only.** A reader that keeps a transaction open pins the WAL and stops the inspected
/// app's checkpoints from completing. Nothing here holds a transaction between calls, and `readTransaction` takes
/// a synchronous body so a transaction can never span an `await`.
public final class SQLiteConnection {
    public struct Options: Sendable, Hashable {
        /// How long a statement waits on a lock held by the inspected app before giving up.
        public var busyTimeoutMilliseconds: Int32 = 250
        public var authorizer: SQLiteAuthorizerPolicy = .readOnly
        /// Upper bound for the length of one SQL statement, in bytes.
        public var maxSQLLength: Int32 = 1_000_000
        /// Upper bound for a single string or blob value, in bytes.
        public var maxValueLength: Int32 = 512 * 1024 * 1024
        /// VM instructions between two checks of the deadline and of task cancellation.
        public var progressGranularity: Int32 = 2_000

        public init() {}
    }

    public let url: URL
    /// Interrupts a running statement from any thread.
    public let interruptHandle: SQLiteInterruptHandle

    let handle: OpaquePointer
    private let progress = ProgressState()
    private var isClosed = false

    /// Opens `url` read-only and applies the hardening described in ARCHITECTURE.md §6.2.
    ///
    /// The header is sniffed first, so an encrypted or non-SQLite file fails with `.notSQLite` and an explanation
    /// rather than with SQLite's terse "file is not a database".
    public convenience init(readOnly url: URL, options: Options = .init()) throws {
        _ = try SQLiteHeader.read(from: url)
        try Self.requireReadableInPlace(url)
        try self.init(url: url, flags: SQLITE_OPEN_READONLY | SQLITE_OPEN_FULLMUTEX, options: options)

        try execute("PRAGMA query_only = 1")
        _ = dabbi_sqlite3_distrust_schema(handle)
        _ = dabbi_sqlite3_enable_defensive(handle)
        SQLiteAuthorizer.install(on: handle, policy: options.authorizer)

        // sqlite3_open_v2 is lazy; touch the schema so problems with the file surface here, as our errors.
        do {
            _ = try scalar("SELECT count(*) FROM sqlite_master")
        } catch let error as DabbiError {
            close()
            throw Self.explainOpenFailure(error, url: url)
        }
    }

    /// Opens (creating if needed) a database we own, read-write. Used for backup destinations.
    static func writable(at url: URL) throws -> SQLiteConnection {
        var options = Options()
        options.authorizer = .unrestricted
        return try SQLiteConnection(
            url: url,
            flags: SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_FULLMUTEX,
            options: options
        )
    }

    private init(url: URL, flags: Int32, options: Options) throws {
        var db: OpaquePointer?
        let code = sqlite3_open_v2(url.path, &db, flags, nil)
        guard code == SQLITE_OK, let db else {
            let message = db.map { String(cString: sqlite3_errmsg($0)) } ?? "out of memory"
            sqlite3_close_v2(db)
            throw Self.explainOpenFailure(Self.error(code: code, message: message), url: url)
        }
        self.url = url
        self.handle = db
        self.interruptHandle = SQLiteInterruptHandle(db)

        sqlite3_busy_timeout(db, options.busyTimeoutMilliseconds)
        sqlite3_limit(db, SQLITE_LIMIT_SQL_LENGTH, options.maxSQLLength)
        sqlite3_limit(db, SQLITE_LIMIT_LENGTH, options.maxValueLength)
        sqlite3_limit(db, SQLITE_LIMIT_ATTACHED, 0)
        sqlite3_progress_handler(
            db, options.progressGranularity, progressCallback, Unmanaged.passUnretained(progress).toOpaque())
    }

    deinit {
        close()
    }

    /// Closes the connection. Statements that are still alive finish finalising on their own.
    public func close() {
        guard !isClosed else { return }
        isClosed = true
        interruptHandle.invalidate()
        sqlite3_progress_handler(handle, 0, nil, nil)
        sqlite3_close_v2(handle)
    }

    // MARK: Statements

    public func prepare(_ sql: String) throws -> SQLiteStatement {
        try ensureOpen()
        var statement: OpaquePointer?
        let code = sqlite3_prepare_v2(handle, sql, -1, &statement, nil)
        guard code == SQLITE_OK, let statement else {
            sqlite3_finalize(statement)
            throw currentError(code)
        }
        return SQLiteStatement(handle: statement, connection: self)
    }

    /// Runs a statement for its side effect on connection state (pragmas, `BEGIN`, `COMMIT`).
    public func execute(_ sql: String) throws {
        let statement = try prepare(sql)
        while try statement.step() {}
    }

    /// Runs a query and materialises the result. `maxRows` bounds the memory a caller is willing to spend.
    public func query(_ sql: String, _ bindings: [SQLiteValue] = [], maxRows: Int? = nil) throws -> [SQLiteRow] {
        let statement = try prepare(sql)
        try statement.bind(bindings)
        let columns = statement.columnNames
        var rows: [SQLiteRow] = []
        while try statement.step() {
            if let maxRows, rows.count >= maxRows { break }
            rows.append(SQLiteRow(columns: columns, values: statement.values()))
        }
        return rows
    }

    /// The first column of the first row, or `nil` when the query returns no row.
    public func scalar(_ sql: String, _ bindings: [SQLiteValue] = []) throws -> SQLiteValue? {
        let statement = try prepare(sql)
        try statement.bind(bindings)
        return try statement.step() ? statement.value(at: 0) : nil
    }

    /// Runs `body` inside one read transaction, so several queries see the same snapshot of the database.
    ///
    /// `body` is synchronous on purpose: the transaction is over when this call returns.
    public func readTransaction<T>(_ body: () throws -> T) throws -> T {
        try execute("BEGIN")
        do {
            let result = try body()
            try execute("COMMIT")
            return result
        } catch {
            try? execute("ROLLBACK")
            throw error
        }
    }

    /// Runs `body` with a deadline. A statement still running at the deadline fails with `.timeout`.
    public func withTimeout<T>(_ seconds: TimeInterval, _ body: () throws -> T) throws -> T {
        let previous = progress.deadline
        progress.deadline = Date().addingTimeInterval(seconds)
        defer { progress.deadline = previous }
        return try body()
    }

    // MARK: Conveniences

    /// `PRAGMA data_version`: changes only when *another* connection commits. The tracker's cheap no-op filter.
    public func dataVersion() throws -> Int64 {
        try scalar("PRAGMA data_version")?.int64 ?? 0
    }

    public func tableNames() throws -> [String] {
        try query("SELECT name FROM sqlite_master WHERE type = 'table' ORDER BY name").compactMap { $0[0].string }
    }

    public func tableExists(_ name: String) throws -> Bool {
        try scalar("SELECT 1 FROM sqlite_master WHERE type = 'table' AND name = ?", [.text(name)]) != nil
    }

    /// Column names of `table` in declaration order. `table` is quoted, so any name is safe to pass.
    public func columnNames(ofTable table: String) throws -> [String] {
        try query("PRAGMA table_info(\(Self.quoteIdentifier(table)))").compactMap { $0["name"]?.string }
    }

    /// Quotes an identifier for interpolation into SQL.
    public static func quoteIdentifier(_ identifier: String) -> String {
        "\"" + identifier.replacingOccurrences(of: "\"", with: "\"\"") + "\""
    }

    // MARK: Errors

    private func ensureOpen() throws {
        guard !isClosed else { throw DabbiError(.sqlite, "The database connection is closed.") }
    }

    func currentError(_ code: Int32) -> DabbiError {
        if code == SQLITE_INTERRUPT {
            if progress.timedOut {
                progress.timedOut = false
                return DabbiError(.timeout, "The query took too long and was stopped.")
            }
            return DabbiError(.cancelled, "The query was cancelled.")
        }
        return Self.error(code: code, message: String(cString: sqlite3_errmsg(handle)))
    }

    static func error(code: Int32, message: String) -> DabbiError {
        let primary = code & 0xFF
        if primary == SQLITE_AUTH {
            return DabbiError(
                .sqliteDenied,
                "This statement is not allowed on a read-only connection.",
                arguments: ["sqliteCode": String(code)],
                diagnosis: ["SQLite said: \(message)."],
                recovery: ["Only SELECT statements and read-only pragmas can be run."]
            )
        }
        return DabbiError(
            .sqlite,
            "SQLite reported an error: \(message).",
            arguments: ["sqliteCode": String(code), "sqliteMessage": message]
        )
    }

    /// Refuses a database with a write-ahead log and no `-shm` before SQLite sees it.
    ///
    /// Verified against the system SQLite (3.4x) and against Core Data with `NSReadOnlyPersistentStoreOption`:
    /// whoever reads a WAL database needs its `-shm`, and a *read-only* connection that finds none creates one —
    /// 32 KB next to the store, left behind when it closes. In a folder that cannot be written to the same open
    /// fails with `SQLITE_CANTOPEN`. CoreDataDabbi does not write next to the user's stores, so both cases end
    /// the same way: `.readOnlyLocation`, which the locator answers with a working copy (§6.2).
    ///
    /// SQLite decides by the log's existence alone, whatever its size and whatever the header says
    /// (`pagerOpenWalIfPresent`); so does this. An app that is just starting can create the `-shm` between this
    /// check and the open — then it is the app's file, and nothing of ours.
    public static func requireReadableInPlace(_ url: URL) throws {
        let files = FileManager.default
        guard files.fileExists(atPath: url.path + "-wal"), !files.fileExists(atPath: url.path + "-shm") else { return }
        throw cannotBeReadInPlace(url, underlying: nil)
    }

    private static func cannotBeReadInPlace(_ url: URL, underlying: DabbiError?) -> DabbiError {
        let hasSharedMemory = FileManager.default.fileExists(atPath: url.path + "-shm")
        return DabbiError(
            .readOnlyLocation,
            "The database cannot be opened in place.",
            arguments: ["path": url.path],
            diagnosis: [
                hasSharedMemory
                    ? "The store uses write-ahead logging and its -shm file could not be opened."
                    : "The store uses write-ahead logging and its -shm file is missing. Nothing can read it "
                        + "without writing next to it, and CoreDataDabbi does not write next to your stores.",
                "Folder: \(url.deletingLastPathComponent().path)",
            ],
            recovery: [
                hasSharedMemory
                    ? "Check the permissions of \(url.lastPathComponent)-shm, or open a copy of the store."
                    : "If the store was copied from somewhere, copy its -wal and -shm files along with it.",
                "Otherwise open it once with the app that owns it; that recreates the missing files.",
            ],
            underlying: underlying
        )
    }

    private static func explainOpenFailure(_ error: DabbiError, url: URL) -> DabbiError {
        guard error.code == .sqlite, let code = error.arguments["sqliteCode"].flatMap(Int32.init) else { return error }
        switch code & 0xFF {
        case SQLITE_NOTADB:
            return DabbiError(
                .notSQLite,
                "This file is not a SQLite database, or it is encrypted.",
                arguments: ["path": url.path],
                diagnosis: ["SQLite could not read \(url.lastPathComponent) as a database."],
                underlying: error
            )
        case SQLITE_CANTOPEN, SQLITE_READONLY:
            guard FileManager.default.fileExists(atPath: url.path) else { return error }
            return cannotBeReadInPlace(url, underlying: error)
        default:
            return error
        }
    }
}

// MARK: - Interrupt and progress

/// Lets any thread interrupt the statement a connection is running — used by task-cancellation handlers.
public final class SQLiteInterruptHandle: @unchecked Sendable {
    private let lock = NSLock()
    private var db: OpaquePointer?

    init(_ db: OpaquePointer) {
        self.db = db
    }

    /// Makes the running statement, if any, fail with `.cancelled`. Does nothing once the connection is closed.
    public func interrupt() {
        lock.withLock {
            if let db { sqlite3_interrupt(db) }
        }
    }

    func invalidate() {
        lock.withLock { db = nil }
    }
}

/// State read by the progress callback, which runs on the thread that is stepping a statement.
private final class ProgressState {
    var deadline: Date?
    var timedOut = false
}

private let progressCallback: @convention(c) (UnsafeMutableRawPointer?) -> Int32 = { context in
    if Task.isCancelled { return 1 }
    guard let context else { return 0 }
    let state = Unmanaged<ProgressState>.fromOpaque(context).takeUnretainedValue()
    if let deadline = state.deadline, Date() >= deadline {
        state.timedOut = true
        return 1
    }
    return 0
}
