import DabbiKit
import Foundation

/// What the user said to a commit's guards (EDT-10, EDT-11).
enum CommitGuardAnswer: Sendable, Hashable {
    case commit
    /// Quit the apps that have the store open, then commit: they read the rows afresh when they are next run.
    case quitAndCommit
    case cancel
}

/// The project's side of a commit's questions: the window asks them, and quitting the store's holders is done
/// here, as it is for a restore.
extension ProjectContext {
    /// Puts `guards` to the window, and quits the holders first when that is the answer. Whether to commit.
    func confirmCommit(through guards: CommitGuards) async -> Bool {
        guard let ask = onCommitGuards, let store = storeURL else { return false }
        let location = project.store
        let devices = devicesDirectory
        let canQuit = !guards.holders.isEmpty && StoreHolders.canQuit(guards.holders, of: location)
        let answer = await withCheckedContinuation { answer in ask(guards, canQuit) { answer.resume(returning: $0) } }
        switch answer {
        case .cancel:
            return false
        case .commit:
            return true
        case .quitAndCommit:
            let quitHolders =
                self.quitHolders ?? { holders, store in
                    try await StoreHolders.quit(holders, of: location, store: store, devicesDirectory: devices)
                }
            do {
                try await quitHolders(guards.holders, store)
                return storeURL == store
            } catch {
                editing.onError?(DabbiError.wrapping(error))
                return false
            }
        }
    }

    /// Puts `conflicts` to the window. A choice per object, or `nil` to commit nothing.
    func askAboutConflicts(_ conflicts: [CommitConflict]) async -> [PendingObjectID: CommitConflict.Choice]? {
        guard let ask = onCommitConflicts else { return nil }
        return await withCheckedContinuation { answer in ask(conflicts) { answer.resume(returning: $0) } }
    }
}
