import DabbiBase
import Foundation

/// Puts a snapshot back in place of a store (§7.3, ARCHITECTURE.md §6.9).
///
/// In order, and each step refuses before anything is touched if it fails: the snapshot is verified against its
/// manifest; nobody else may have the store open; the store as it is now is backed up (so that the restore can
/// be undone by restoring that); the snapshot is copied next to the store. Only then are the files swapped: the
/// write-ahead log and its index are moved aside — a log left behind would be played into the restored database
/// the next time anything opened it — and the database is replaced in one rename, then the support folder.
///
/// The caller closes its own connections first. The process calling is not counted as a holder, so it is on the
/// caller not to leave one open.
public enum Restorer {
    private static let log = DabbiLog.logger(.snapshots)

    /// - Parameters:
    ///   - backups: Where the store as it is now is copied first; `nil` restores without a backup.
    /// - Returns: the backup taken before the store was replaced, if one was.
    @discardableResult
    public static func restore(
        _ manifest: SnapshotManifest, from library: SnapshotLibrary, over store: URL,
        backingUpInto backups: SnapshotLibrary?, backupName: String = "Before restoring",
        excluding excluded: Set<Int32> = [getpid()]
    ) async throws -> SnapshotManifest? {
        try Snapshotter.verify(manifest, in: library)
        try guardNobodyHolds(store, excluding: excluded)

        let files = FileManager.default
        var backup: SnapshotManifest?
        if let backups, files.fileExists(atPath: store.path) {
            backup = try await Snapshotter.take(of: store, into: backups, kind: .backup, name: backupName)
        }

        // Staged in the store's own folder, so that the swap is a rename within one volume.
        let staging = store.deletingLastPathComponent()
            .appendingPathComponent(".dabbi-restore-\(UUID().uuidString)", isDirectory: true)
        let aside = staging.appendingPathComponent("aside", isDirectory: true)
        let source = library.databaseURL(of: manifest)
        let stagedStore = staging.appendingPathComponent(store.lastPathComponent)
        let sourceSupport = StoreFiles.supportFolder(of: source)
        let stagedSupport = StoreFiles.supportFolder(of: stagedStore)
        defer { try? files.removeItem(at: staging) }
        do {
            try files.createDirectory(at: aside, withIntermediateDirectories: true)
            try files.copyItem(at: source, to: stagedStore)
            if files.fileExists(atPath: sourceSupport.path) {
                try files.copyItem(at: sourceSupport, to: stagedSupport)
            }
        } catch {
            throw failed(store, "The snapshot could not be copied next to the store. The store was not changed.", error)
        }

        // Once more: the copy took a while, and an app may have been launched in the meantime.
        try guardNobodyHolds(store, excluding: excluded)

        var movedAside: [(from: URL, to: URL)] = []
        do {
            for suffix in StoreFiles.sideFileSuffixes where files.fileExists(atPath: store.path + suffix) {
                let file = URL(fileURLWithPath: store.path + suffix)
                let parked = aside.appendingPathComponent(file.lastPathComponent)
                try files.moveItem(at: file, to: parked)
                movedAside.append((file, parked))
            }
            if files.fileExists(atPath: store.path) {
                _ = try files.replaceItemAt(store, withItemAt: stagedStore)
            } else {
                try files.moveItem(at: stagedStore, to: store)
            }
        } catch {
            for (file, parked) in movedAside.reversed() { try? files.moveItem(at: parked, to: file) }
            throw failed(store, "The store could not be replaced. It was left as it was.", error)
        }

        let support = StoreFiles.supportFolder(of: store)
        do {
            if files.fileExists(atPath: support.path) {
                try files.moveItem(at: support, to: aside.appendingPathComponent("support", isDirectory: true))
            }
            if files.fileExists(atPath: stagedSupport.path) {
                try files.moveItem(at: stagedSupport, to: support)
            }
        } catch {
            var failure = failed(
                store, "The database was restored, and its external data could not be.", error)
            if backup != nil { failure.recovery = ["Restore the backup taken just before, to go back."] }
            throw failure
        }
        log.notice("Restored a \(manifest.kind.rawValue, privacy: .public) over a store.")
        return backup
    }

    private static func guardNobodyHolds(_ store: URL, excluding excluded: Set<Int32>) throws {
        let holders = LiveProcesses.holding(store, excluding: excluded)
        guard holders.isEmpty else { throw LiveProcesses.inUse(store, by: holders) }
    }

    private static func failed(_ store: URL, _ message: String, _ error: any Error) -> DabbiError {
        DabbiError(.restoreFailed, message, arguments: ["path": store.path], underlying: error)
    }
}
