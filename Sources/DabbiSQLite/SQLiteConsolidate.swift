import DabbiBase
import Foundation
import SQLite3

extension SQLiteConnection {
    /// Makes a database file **we own** self-contained: replays its write-ahead log into it and switches it to a
    /// rollback journal, after which it opens read-only anywhere (ARCHITECTURE.md §6.2).
    ///
    /// This is the one place a database is opened read-write outside a backup, and it is only ever pointed at a
    /// working copy. Core Data puts a store back into WAL mode by itself the next time it opens it read-write.
    public static func consolidate(ownedCopyAt url: URL) throws {
        _ = try SQLiteHeader.read(from: url)
        let connection = try SQLiteConnection.writable(at: url)
        let mode: String?
        do {
            defer { connection.close() }
            // Opening replays the log; the checkpoint moves it into the main file, and leaving WAL mode deletes it.
            _ = try connection.query("PRAGMA wal_checkpoint(TRUNCATE)")
            mode = try connection.scalar("PRAGMA journal_mode = DELETE")?.string
        }
        guard mode?.lowercased() == "delete" else {
            throw DabbiError(
                .sqlite, "The working copy could not be made self-contained.",
                arguments: ["path": url.path], diagnosis: ["Its journal mode stayed “\(mode ?? "unknown")”."])
        }
        // The system's SQLite leaves the -shm behind when the last connection closes. Without a log it means
        // nothing, and with one around the next read-only open would be refused (`requireReadableInPlace`).
        for suffix in ["-shm", "-wal"] { try? FileManager.default.removeItem(atPath: url.path + suffix) }
    }
}
