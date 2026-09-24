import DabbiKit
import Foundation
import Observation

/// The open store's snapshots and backups, as the sidebar lists them, and what is being done with them (§7.3).
///
/// One library per store, shared by the user's snapshots and the pre-commit backups
/// (`PreCommitBackup.library(forStoreUUID:at:under:)`): a backup is a snapshot the app took, and restoring one
/// is how a commit is undone. It is not in the project package — NSDocument rewrites the package on every save,
/// an untitled project has none, and a copy of a store is no size to autosave (ARCHITECTURE.md §6.9).
///
/// It does not know the project context, which hands it the store and its library; restoring, which closes and
/// reopens the store, is the context's.
@MainActor
@Observable
final class SnapshotsSession {
    enum Activity: Equatable {
        case taking
        case restoring
    }

    /// Newest first, as the library lists them.
    private(set) var snapshots: [SnapshotManifest] = []
    /// At most one thing at a time: a snapshot taken while another is restored would be of neither.
    private(set) var activity: Activity?

    /// Something the user asked for could not be done. Nothing was taken, changed or restored by it.
    @ObservationIgnored var onError: ((DabbiError) -> Void)?

    @ObservationIgnored private(set) var library: SnapshotLibrary?
    @ObservationIgnored private var store: URL?
    @ObservationIgnored private var work: Task<Void, Never>?
    @ObservationIgnored private var listing: Task<Void, Never>?

    var isAttached: Bool { library != nil }
    var canTake: Bool { store != nil && activity == nil }
    var isBusy: Bool { activity != nil }

    func snapshot(_ id: UUID) -> SnapshotManifest? {
        snapshots.first { $0.id == id }
    }

    // MARK: The store

    /// Lists the snapshots of the store at `store`, kept in `library`. The same library again only lists anew:
    /// reopening a store keeps its snapshots on screen rather than blinking them away.
    func attach(store: URL, library: SnapshotLibrary) {
        if library != self.library { snapshots = [] }
        self.store = store
        self.library = library
        refresh()
    }

    /// No store is open, or another one is about to be.
    func detach() {
        listing?.cancel()
        store = nil
        library = nil
        snapshots = []
    }

    /// Reads the library again: a backup taken by a commit, a snapshot taken by another window of the store.
    func refresh() {
        guard let library else { return }
        listing?.cancel()
        listing = Task { [weak self] in
            let found = await Task.detached(priority: .userInitiated) { library.list() }.value
            guard let self, !Task.isCancelled, self.library == library else { return }
            self.snapshots = found
        }
    }

    // MARK: Taking and changing

    /// Copies the store as it is on disk — not what is staged — and verifies the copy.
    ///
    /// - Returns: a task whose value is the new snapshot, or `nil` when it could not be taken.
    @discardableResult
    func take(name: String, note: String = "") -> Task<SnapshotManifest?, Never>? {
        guard canTake, let store, let library else { return nil }
        let name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        activity = .taking
        let task = Task { [weak self] () -> SnapshotManifest? in
            let result: Result<SnapshotManifest, DabbiError>
            do {
                result = .success(
                    try await Snapshotter.take(
                        of: store, into: library, kind: .snapshot,
                        name: name.isEmpty ? Self.defaultName(at: .now) : name, note: note))
            } catch {
                result = .failure(Self.dabbiError(error, "The snapshot could not be taken."))
            }
            guard let self else { return nil }
            self.activity = nil
            switch result {
            case .success(let manifest):
                if self.library == library { self.insert(manifest) }
                return manifest
            case .failure(let error):
                self.onError?(error)
                return nil
            }
        }
        work = Task { _ = await task.value }
        return task
    }

    /// What a snapshot is called when the user does not say.
    static func defaultName(at date: Date) -> String {
        String(
            localized: "Snapshot \(date.formatted(date: .abbreviated, time: .shortened))",
            comment: "Default name of a snapshot; the argument is when it was taken")
    }

    /// Renames a snapshot. An empty name is not one.
    func rename(_ id: UUID, to name: String) {
        let name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty, snapshot(id)?.name != name else { return }
        update(id) { try $0.update(id, name: name) }
    }

    func setNote(_ note: String, of id: UUID) {
        guard snapshot(id).map({ $0.note != note }) ?? false else { return }
        update(id) { try $0.update(id, note: note) }
    }

    func delete(_ id: UUID) {
        guard let library, !isBusy else { return }
        do {
            try library.delete(id)
            snapshots.removeAll { $0.id == id }
        } catch {
            onError?(Self.dabbiError(error, "The snapshot could not be deleted."))
            refresh()
        }
    }

    private func update(_ id: UUID, _ change: (SnapshotLibrary) throws -> SnapshotManifest) {
        guard let library else { return }
        do {
            let manifest = try change(library)
            if let index = snapshots.firstIndex(where: { $0.id == id }) { snapshots[index] = manifest }
        } catch {
            onError?(Self.dabbiError(error, "The snapshot could not be changed."))
            refresh()
        }
    }

    private func insert(_ manifest: SnapshotManifest) {
        snapshots.removeAll { $0.id == manifest.id }
        snapshots.append(manifest)
        snapshots.sort { $0.createdAt > $1.createdAt }
    }

    // MARK: Restoring

    /// Marks a restore as under way, for the context that does it. `false` when something else is.
    func beginRestoring() -> Bool {
        guard activity == nil, library != nil else { return false }
        activity = .restoring
        return true
    }

    /// The restore is over; `error` says why it did not happen, or did not finish.
    func endRestoring(_ error: (any Error)? = nil) {
        guard activity == .restoring else { return }
        activity = nil
        refresh()
        if let error { onError?(Self.dabbiError(error, "The snapshot could not be restored.")) }
    }

    /// Returns once nothing is being taken or listed. Nothing in the app waits for that; the tests do.
    func whenSettled() async {
        await work?.value
        await listing?.value
    }

    private static func dabbiError(_ error: any Error, _ message: String) -> DabbiError {
        error as? DabbiError ?? DabbiError(.internal, message, underlying: error)
    }
}
