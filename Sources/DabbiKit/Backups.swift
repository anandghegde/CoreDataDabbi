import DabbiSnapshots
import DabbiStore
import Foundation

extension PreCommitBackup {
    /// `~/Library/Application Support/CoreDataDabbi/Backups`: not a cache, so the system never purges it.
    public static var defaultRoot: URL {
        URL.applicationSupportDirectory.appending(path: "CoreDataDabbi/Backups", directoryHint: .isDirectory)
    }

    /// The backup for an editable session of the store `storeURL` names — the user's file, not a copy of it.
    public init(
        for session: StoreSession, storeURL: URL, root: URL = PreCommitBackup.defaultRoot,
        retention: SnapshotLibrary.Retention = .default, name: String = "Before editing"
    ) {
        self.init(
            store: storeURL,
            library: Self.library(forStoreUUID: session.info.metadata.storeUUID, at: storeURL, under: root),
            retention: retention, name: name)
    }
}

extension StoreSession {
    /// Commits what is staged once `backup` holds a verified copy of the store as it was before this session's
    /// first commit (EDT-9): the milestone's rule that no commit goes ahead without one. A backup that cannot be
    /// taken or does not verify fails the commit with `.commitPreparationFailed`, and nothing is written.
    public func commit(after backup: PreCommitBackup) async throws -> CommitSummary {
        try await commit { _ = try await backup.ensure() }
    }
}
