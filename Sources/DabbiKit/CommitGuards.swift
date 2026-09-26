import DabbiBase
import DabbiSnapshots
import DabbiStore
import Foundation

/// What stands in the way of a commit, and has to be acknowledged before one goes ahead (EDT-10, EDT-11,
/// ARCHITECTURE.md §6.4): the store is mirrored to CloudKit, or another process has it open.
///
/// Neither is a reason the commit would fail. A mirrored store takes the edits — and `NSPersistentCloudKitContainer`
/// exports them to iCloud when the app next runs, to every device on the account. A process with the store open
/// does not see the edits until it reads the rows again, and may save its own over them. The user decides; the
/// engine only refuses a commit whose guards were not put to them.
public struct CommitGuards: Sendable, Hashable {
    /// The store has CloudKit mirroring tables (`ANSCK…`): what is committed is exported on the app's next launch.
    public var mirroredToCloudKit: Bool
    /// The processes, other than this one, that have the store's files open.
    public var holders: [LiveProcess]

    public init(mirroredToCloudKit: Bool = false, holders: [LiveProcess] = []) {
        self.mirroredToCloudKit = mirroredToCloudKit
        self.holders = holders
    }

    public static let clear = CommitGuards()

    public var isClear: Bool { !mirroredToCloudKit && holders.isEmpty }

    /// Whether acknowledging `self` acknowledges `other`: CloudKit, if `other` has it, and every process of
    /// `other`'s. A process that has opened the store since is asked about afresh.
    public func covers(_ other: CommitGuards) -> Bool {
        (mirroredToCloudKit || !other.mirroredToCloudKit)
            && Set(other.holders.map(\.pid)).isSubset(of: holders.map(\.pid))
    }

    /// Both acknowledged: what a session remembers, so that the same guard is not put to the user every commit.
    public func merging(_ other: CommitGuards) -> CommitGuards {
        var pids = Set(holders.map(\.pid))
        return CommitGuards(
            mirroredToCloudKit: mirroredToCloudKit || other.mirroredToCloudKit,
            holders: holders + other.holders.filter { pids.insert($0.pid).inserted })
    }

    /// The guards of `session`'s store, whose file `storeURL` is. Asking the kernel who has the files open takes a
    /// while — tens of milliseconds a path — and is done off the caller's thread.
    public static func check(_ session: StoreSession, storeURL: URL) async -> CommitGuards {
        let mirrored = session.info.probe.hasCloudKitMirroring
        let holders = await Task.detached(priority: .userInitiated) { LiveProcesses.holding(storeURL) }.value
        return CommitGuards(mirroredToCloudKit: mirrored, holders: holders)
    }

    /// The commit's refusal while `self` stands unacknowledged. Process names, never row values.
    public var refusal: DabbiError {
        var diagnosis: [String] = []
        var recovery: [String] = []
        if mirroredToCloudKit {
            diagnosis.append(
                "The store is mirrored to CloudKit: committed edits are exported to iCloud when its app next runs.")
            recovery.append("Commit to a copy instead, if the edits should not reach iCloud.")
        }
        if !holders.isEmpty {
            let names = holders.map { "\($0.name) (\($0.pid))" }.joined(separator: ", ")
            diagnosis.append("Open by: \(names).")
            recovery.append("Quit the app that uses the store, then commit again.")
        }
        return DabbiError(
            .commitUnconfirmed, "The commit was not confirmed. Nothing was written.",
            arguments: [
                "cloudKit": mirroredToCloudKit ? "yes" : "no",
                "processes": holders.map { "\($0.name) (\($0.pid))" }.joined(separator: ", "),
            ],
            diagnosis: diagnosis, recovery: recovery + ["Confirm the commit when asked."])
    }
}

extension StoreSession {
    /// Commits what is staged, after the guards (EDT-10, EDT-11) and the backup (EDT-9), in that order.
    ///
    /// The guards are checked again here, just before the backup: a guard that stands and that `acknowledged` does
    /// not cover — a process that opened the store after the user was asked — refuses the commit with
    /// `.commitUnconfirmed`, and nothing is written. Conflicts are checked before either (`commit(prepare:)`).
    public func commit(
        after backup: PreCommitBackup, acknowledging acknowledged: CommitGuards
    ) async throws -> CommitSummary {
        try await commit {
            let guards = await CommitGuards.check(self, storeURL: backup.store)
            guard acknowledged.covers(guards) else { throw guards.refusal }
            _ = try await backup.ensure()
        }
    }
}
