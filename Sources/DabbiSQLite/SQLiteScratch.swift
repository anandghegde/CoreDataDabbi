import DabbiBase
import Foundation

/// A database **we own**, for holding what is too big to keep in memory.
///
/// The tracker's version log spills its older rows into one of these (ARCHITECTURE.md §6.6), and it is the shape
/// any later "too much to remember" — a long tracking session, a large import report — should take. It is not a
/// store being inspected: it is created empty, written only by us, and deleted with `destroy()`.
///
/// Durability is deliberately off. The file dies with the session that made it, so a journal and an `fsync` per
/// transaction would buy nothing and cost every spill.
public final class SQLiteScratch {
    /// The file. Its directory is ours too when `temporary(name:)` made it.
    public let url: URL
    /// The read-write connection. Pragmas and writes are allowed on it, which is why it is only ever pointed at a
    /// file we created.
    public let connection: SQLiteConnection

    private let ownedDirectory: URL?
    private var isDestroyed = false

    /// Creates an empty database in a new directory under the system temporary directory.
    public static func temporary(name: String) throws -> SQLiteScratch {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("coredatadabbi-\(name)-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return try SQLiteScratch(at: directory.appendingPathComponent("\(name).sqlite"), ownedDirectory: directory)
    }

    /// Opens (creating if needed) a database at `url`, which must be a file nobody else is using.
    public convenience init(at url: URL) throws {
        try self.init(at: url, ownedDirectory: nil)
    }

    private init(at url: URL, ownedDirectory: URL?) throws {
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        self.url = url
        self.ownedDirectory = ownedDirectory
        connection = try SQLiteConnection.writable(at: url)
        do {
            // Nothing here outlives the process, so there is no reason to pay for a journal or for fsync.
            try connection.execute("PRAGMA journal_mode = MEMORY")
            try connection.execute("PRAGMA synchronous = OFF")
            try connection.execute("PRAGMA temp_store = MEMORY")
        } catch {
            connection.close()
            throw error
        }
    }

    deinit {
        // A temporary scratch is nobody else's file, so the last reference taking it with it is the right
        // behaviour: `destroy()` is only the eager form, for a caller that wants the bytes gone at a known
        // moment. A scratch at a URL the caller chose is left where it is; only the connection closes.
        if ownedDirectory == nil {
            connection.close()
        } else {
            destroy()
        }
    }

    /// Runs `body` inside one write transaction. Synchronous on purpose: the transaction is over when this returns.
    public func transaction<T>(_ body: () throws -> T) throws -> T {
        try connection.execute("BEGIN IMMEDIATE")
        do {
            let result = try body()
            try connection.execute("COMMIT")
            return result
        } catch {
            try? connection.execute("ROLLBACK")
            throw error
        }
    }

    /// Closes the connection and deletes the file — and the directory, when this made it.
    public func destroy() {
        guard !isDestroyed else { return }
        isDestroyed = true
        connection.close()
        if let ownedDirectory {
            try? FileManager.default.removeItem(at: ownedDirectory)
        } else {
            for suffix in ["", "-wal", "-shm", "-journal"] {
                try? FileManager.default.removeItem(atPath: url.path + suffix)
            }
        }
    }
}
