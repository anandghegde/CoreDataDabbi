import DabbiBase
import DabbiModel
import DabbiSQLite
import Foundation

/// Takes consistent copies of a store and checks them (§7.3, EDT-9, ARCHITECTURE.md §6.9).
///
/// The store is only ever read: the database through SQLite's online backup from a read-only connection, so the
/// app can keep saving throughout, and the support folder (external binary data) file by file. A copy is built in
/// a hidden folder of the library, verified there, and only then renamed into place — a snapshot that can be
/// listed is one that held up.
public enum Snapshotter {
    private static let log = DabbiLog.logger(.snapshots)

    /// Copies the store at `store` into `library`.
    ///
    /// - Parameters:
    ///   - name: Shown in lists. Backups are named by the caller too; the library never names anything.
    public static func take(
        of store: URL, into library: SnapshotLibrary, kind: SnapshotManifest.Kind, name: String, note: String = ""
    ) async throws -> SnapshotManifest {
        let id = UUID()
        let staging = library.stagingFolder(for: id)
        let files = FileManager.default
        do {
            try files.createDirectory(at: staging, withIntermediateDirectories: true)
            let manifest = try await copyAndVerify(
                store, into: staging, id: id, kind: kind, name: name, note: note)
            try manifest.write(to: staging)
            try files.moveItem(at: staging, to: library.folder(for: id))
            log.notice(
                "Took a \(kind.rawValue, privacy: .public) of \(manifest.tables.count) tables, \(manifest.totalBytes) bytes."
            )
            return try SnapshotManifest.read(from: library.folder(for: id))
        } catch {
            try? files.removeItem(at: staging)
            throw explain(error, store: store)
        }
    }

    /// Checks a snapshot that was taken earlier: the database is intact, holds the rows its manifest says, and
    /// every external file the manifest counted is there. Run before a snapshot is put back (M3-03).
    public static func verify(_ manifest: SnapshotManifest, in library: SnapshotLibrary) throws {
        let folder = library.folder(for: manifest.id)
        let database = folder.appendingPathComponent(manifest.storeFileName)
        let copied = try Copy.read(database)
        guard copied.tables == manifest.tables else {
            throw unverified(database, "Its row counts are not the ones recorded when it was taken.")
        }
        let (count, _) = try externalFiles(in: StoreFiles.supportFolder(of: database))
        guard count == manifest.externalFileCount else {
            throw unverified(database, "Files of its external data are missing.")
        }
    }

    // MARK: Taking

    private static func copyAndVerify(
        _ store: URL, into staging: URL, id: UUID, kind: SnapshotManifest.Kind, name: String, note: String
    ) async throws -> SnapshotManifest {
        let createdAt = Date()
        let database = staging.appendingPathComponent(store.lastPathComponent)
        let support = StoreFiles.supportFolder(of: store)
        let copiedSupport = StoreFiles.supportFolder(of: database)

        // External data is written by Core Data as new files and never changed in place, so copying the folder
        // on both sides of the database copy leaves every file the copied rows name: one the app removed in
        // between was taken by the first pass, one it added by the second. What else comes along is unreferenced
        // and harmless.
        try mergeTree(from: support, into: copiedSupport)
        let reader = try SQLiteReader(url: store)
        let comparison: [SnapshotManifest.TableCount]?
        do {
            comparison = try await reader.read { connection in
                let before = try connection.dataVersion()
                try SQLiteBackup.copy(from: connection, to: database)
                // `data_version` moves only when another connection commits. Unchanged from before the copy to
                // inside the transaction that counts, the store's counts are the copy's; changed, they need not be.
                return try connection.readTransaction {
                    try connection.dataVersion() == before ? try Copy.tableCounts(connection) : nil
                }
            }
        } catch {
            await reader.close()
            throw error
        }
        await reader.close()
        try mergeTree(from: support, into: copiedSupport)

        let copied = try Copy.read(database)
        if let comparison, comparison != copied.tables {
            throw unverified(database, "Its row counts differ from the store’s.")
        }
        let (externalCount, externalBytes) = try externalFiles(in: copiedSupport)
        let metadata = try StoreMetadata.read(from: database)
        return SnapshotManifest(
            id: id, kind: kind, name: name, note: note, createdAt: createdAt, sourceURL: store,
            storeFileName: store.lastPathComponent, storeUUID: metadata.storeUUID,
            entityVersionHashes: metadata.entityVersionHashes, tables: copied.tables,
            databaseBytes: try size(of: database), externalFileCount: externalCount, externalBytes: externalBytes,
            verification: .init(verifiedAt: Date(), comparedWithStore: comparison != nil))
    }

    /// What is checked of a copied database, by itself.
    private enum Copy {
        struct Contents {
            let tables: [SnapshotManifest.TableCount]
        }

        /// Opens the copy read-only: `integrity_check` must say `ok`, Core Data's metadata must be there, and every
        /// table is counted.
        static func read(_ database: URL) throws -> Contents {
            let connection = try SQLiteConnection(readOnly: database)
            defer { connection.close() }
            let problems = try connection.query("PRAGMA integrity_check", maxRows: 5).compactMap { $0[0].string }
            guard problems == ["ok"] else {
                throw unverified(database, "SQLite’s integrity check failed: \(problems.joined(separator: "; ")).")
            }
            guard try connection.tableExists("Z_METADATA") else {
                throw unverified(database, "It has no Core Data metadata.")
            }
            return Contents(tables: try tableCounts(connection))
        }

        static func tableCounts(_ connection: SQLiteConnection) throws -> [SnapshotManifest.TableCount] {
            try connection.tableNames().filter { !$0.hasPrefix("sqlite_") }.map { table in
                let rows = try connection.scalar("SELECT count(*) FROM \(SQLiteConnection.quoteIdentifier(table))")
                return SnapshotManifest.TableCount(table: table, rows: Int(rows?.int64 ?? 0))
            }
        }
    }

    // MARK: Files

    /// Copies every file of `source` that `destination` does not have yet, keeping the layout. Clones on APFS.
    private static func mergeTree(from source: URL, into destination: URL) throws {
        let files = FileManager.default
        guard files.fileExists(atPath: source.path) else { return }
        try files.createDirectory(at: destination, withIntermediateDirectories: true)
        // Relative paths: the temporary folder is behind a symlink, and a walk may report either spelling.
        guard let walk = files.enumerator(atPath: source.path) else { return }
        while let relative = walk.nextObject() as? String {
            let item = source.appendingPathComponent(relative)
            let target = destination.appendingPathComponent(relative)
            if walk.fileAttributes?[.type] as? FileAttributeType == .typeDirectory {
                try files.createDirectory(at: target, withIntermediateDirectories: true)
            } else if !files.fileExists(atPath: target.path) {
                do {
                    try files.copyItem(at: item, to: target)
                } catch  where !files.fileExists(atPath: item.path) {
                    // Removed by the app since the folder was listed; the other pass has it, or nothing names it.
                }
            }
        }
    }

    private static func externalFiles(in folder: URL) throws -> (count: Int, bytes: Int64) {
        let keys: Set<URLResourceKey> = [.isRegularFileKey, .fileSizeKey]
        guard FileManager.default.fileExists(atPath: folder.path),
            let walk = FileManager.default.enumerator(at: folder, includingPropertiesForKeys: Array(keys))
        else { return (0, 0) }
        var count = 0
        var bytes: Int64 = 0
        for case let url as URL in walk {
            let values = try url.resourceValues(forKeys: keys)
            guard values.isRegularFile == true else { continue }
            count += 1
            bytes += Int64(values.fileSize ?? 0)
        }
        return (count, bytes)
    }

    private static func size(of url: URL) throws -> Int64 {
        Int64(try url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0)
    }

    // MARK: Errors

    private static func unverified(_ database: URL, _ reason: String) -> DabbiError {
        DabbiError(
            .snapshotUnverified, "The copy of \(database.lastPathComponent) did not hold up.",
            arguments: ["path": database.path], diagnosis: [reason],
            recovery: ["Nothing was changed, and the copy was removed. Try again."])
    }

    private static func explain(_ error: any Error, store: URL) -> DabbiError {
        if let error = error as? DabbiError,
            [.snapshotUnverified, .cancelled, .notSQLite, .readOnlyLocation, .fileNotFound].contains(error.code)
        {
            return error
        }
        return DabbiError(
            .snapshotFailed, "\(store.lastPathComponent) could not be copied.", arguments: ["path": store.path],
            recovery: ["Check the free space on the disk, and that the store can be read."], underlying: error)
    }
}
