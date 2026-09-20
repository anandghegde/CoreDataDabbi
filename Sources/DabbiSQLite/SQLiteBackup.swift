import DabbiBase
import Foundation
import SQLite3

/// A consistent copy of a live database through SQLite's online backup API.
///
/// The source is only ever read. Pages are copied in steps, so a busy writer is never blocked for long, and the
/// result is a transactionally consistent database even while the inspected app keeps saving.
public enum SQLiteBackup {
    public struct Progress: Sendable, Hashable {
        public let remainingPages: Int
        public let totalPages: Int
    }

    /// Copies the `main` database of `source` into a new file at `destination`.
    ///
    /// The copy is switched to a rollback journal, so it is one self-contained file. A copy of a WAL database would
    /// otherwise say "WAL" in its header and have no `-shm`, and neither SQLite nor Core Data opens that read-only.
    /// Core Data puts a store back into WAL mode by itself the next time it opens it read-write.
    ///
    /// - Parameters:
    ///   - destination: Must not exist yet. Nothing is ever overwritten.
    ///   - pagesPerStep: Pages copied per step; between steps the source's lock is released.
    ///   - maxBusyRetries: How many times a busy or locked source is retried (25 ms apart) before giving up.
    public static func copy(
        from source: SQLiteConnection,
        to destination: URL,
        pagesPerStep: Int32 = 2048,
        maxBusyRetries: Int = 400,
        progress: ((Progress) -> Void)? = nil
    ) throws {
        guard !FileManager.default.fileExists(atPath: destination.path) else {
            throw DabbiError(
                .sqlite,
                "A file already exists at the backup destination.",
                arguments: ["path": destination.path]
            )
        }
        let target = try SQLiteConnection.writable(at: destination)
        defer { target.close() }

        var succeeded = false
        defer {
            if !succeeded {
                target.close()
                for suffix in ["", "-wal", "-shm", "-journal"] {
                    try? FileManager.default.removeItem(atPath: destination.path + suffix)
                }
            }
        }

        guard let backup = sqlite3_backup_init(target.handle, "main", source.handle, "main") else {
            throw target.currentError(sqlite3_errcode(target.handle))
        }

        var busyRetries = 0
        var code: Int32
        repeat {
            if Task.isCancelled {
                sqlite3_backup_finish(backup)
                throw DabbiError(.cancelled, "The backup was cancelled.")
            }
            code = sqlite3_backup_step(backup, pagesPerStep)
            progress?(
                Progress(
                    remainingPages: Int(sqlite3_backup_remaining(backup)),
                    totalPages: Int(sqlite3_backup_pagecount(backup))
                ))
            if code == SQLITE_BUSY || code == SQLITE_LOCKED {
                busyRetries += 1
                if busyRetries > maxBusyRetries { break }
                sqlite3_sleep(25)
            }
        } while code == SQLITE_OK || code == SQLITE_BUSY || code == SQLITE_LOCKED

        let finishCode = sqlite3_backup_finish(backup)
        guard code == SQLITE_DONE, finishCode == SQLITE_OK else {
            throw target.currentError(code == SQLITE_DONE ? finishCode : code)
        }
        try target.execute("PRAGMA journal_mode = DELETE")
        succeeded = true
    }
}
