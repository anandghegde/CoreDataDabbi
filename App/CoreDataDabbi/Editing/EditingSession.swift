import DabbiKit
import Foundation
import Observation

/// One window's staged edits: what is waiting to be committed, the undo stack the Edit menu drives, and Commit
/// and Discard (EDT-8).
///
/// The window's side of the session's edit context. Every staged edit, undo and commit goes to the session in
/// the order the user asked for it — each waits for the one before, as tracking's buttons do — and what comes
/// back is the whole of what is staged, which is what the Pending Changes panel and the grid read.
///
/// The session keeps the real undo stack; `undoManager` mirrors it for the window, one entry per staged edit,
/// so that ⌘Z, the Edit menu's titles and the text fields' own undo all go through the one manager AppKit
/// expects. An entry is registered only once the session says the edit added one to its stack
/// (`PendingChanges.undoDepth`): an edit that changed nothing, or was refused, leaves nothing to undo.
///
/// It does not know the project context, which hands it a session and a backup, so the tests can drive it
/// against a fixture without a window.
@MainActor
@Observable
final class EditingSession {
    /// Everything staged, and where the session's undo stack stands.
    private(set) var changes: PendingChanges = .none {
        didSet { issuesByObject = Dictionary(grouping: changes.issues, by: \.object) }
    }
    /// `changes.issues` by object, for the grid and the inspector, which ask once per field (EDT-2). Observed, so
    /// that a view reading one object's issues is redrawn when they change.
    private var issuesByObject: [PendingObjectID: [ValidationIssue]] = [:]
    /// Bumped whenever what is staged may have changed, so that the grid re-reads its rows.
    private(set) var revision = 0
    /// Bumped by each commit that wrote something: the session is in a new generation, and every pager is stale.
    private(set) var commits = 0
    private(set) var isCommitting = false
    /// What the last commit wrote.
    private(set) var lastCommit: CommitSummary?
    /// The last thing that went wrong: a value refused, a commit refused. The window shows it as it happens.
    private(set) var lastError: DabbiError?

    /// Something the user asked for could not be done. Nothing was staged or written by it.
    @ObservationIgnored var onError: ((DabbiError) -> Void)?
    /// A commit is over, written or not: the first one of a session will have taken a backup either way.
    @ObservationIgnored var onCommitFinished: (() -> Void)?

    /// The window's undo manager while the store is editable. Grouped by event, as AppKit's own are, so the text
    /// fields' typing can share it.
    @ObservationIgnored let undoManager = UndoManager()

    @ObservationIgnored private var session: StoreSession?
    @ObservationIgnored private var backup: PreCommitBackup?
    /// The last operation sent to the session.
    @ObservationIgnored private var control: Task<Void, Never>?
    /// Bumped per attached session; anything that arrives from an earlier one is dropped.
    @ObservationIgnored private var generation = 0

    // MARK: What the window asks

    /// Whether there is an editable session to stage edits in.
    var isEditable: Bool { session != nil }
    var hasChanges: Bool { !changes.isEmpty }
    var canCommit: Bool { isEditable && hasChanges && !isCommitting }

    /// The rules of the model `object` breaks as staged: what the commit would refuse (EDT-2).
    func issues(for object: PendingObjectID) -> [ValidationIssue] {
        issuesByObject[object] ?? []
    }

    /// The first rule `property` of `object` breaks, for a field or a cell to be marked with.
    func issue(for object: PendingObjectID, property: String) -> ValidationIssue? {
        issuesByObject[object]?.first { $0.property == property }
    }

    // MARK: The session

    /// Starts staging edits in `session`, which is editable, backing it up with `backup` before its first commit.
    func attach(_ session: StoreSession, backup: PreCommitBackup) {
        detach()
        self.session = session
        self.backup = backup
    }

    /// The session is closing, or has been reopened read-only: whatever it staged goes with it.
    func detach() {
        generation += 1
        session = nil
        backup = nil
        isCommitting = false
        undoManager.removeAllActions(withTarget: self)
        guard changes != .none else { return }
        changes = .none
        revision += 1
    }

    // MARK: Staging

    /// Stages a new value for an attribute or a to-one relationship of `object`.
    func setValue(_ value: Value, for property: String, of object: PendingObjectID) {
        let name = String(localized: "Edit \(property)")
        stage { try await $0.setValue(value, for: property, of: object, actionName: name) }
    }

    /// Stages the deletion of `objects`, and whatever their delete rules take along.
    ///
    /// With `confirm`, the session is asked first what the delete rules would do (EDT-2). When that is more than
    /// the objects themselves — a Cascade takes others along, references are left pointing at nothing, or the
    /// commit would be refused — `confirm` is shown it, and the delete is staged only if it answers yes. A plain
    /// delete is staged without asking. The question is part of the edit's turn: nothing sent after it runs
    /// before it is answered.
    func delete(_ objects: [PendingObjectID], confirm: (@MainActor (DeletePreview) async -> Bool)? = nil) {
        guard !objects.isEmpty else { return }
        let name =
            objects.count == 1
            ? String(localized: "Delete \(objects[0].entity)") : String(localized: "Delete \(objects.count) Objects")
        stage { session in
            // A preview that cannot be read is no reason not to delete: the delete says what is wrong itself.
            if let confirm, let preview = try? await session.deletePreview(of: objects), !preview.isPlain {
                // Declined: what is staged is unchanged, and with it the undo stack.
                guard await confirm(preview) else { return try await session.pendingChanges() }
            }
            return try await session.delete(objects, actionName: name)
        }
    }

    /// Stages a new object of `entity`, and hands `inserted` the identity it is staged under — once it is, and
    /// only if this session is still the one attached.
    func insertObject(of entity: String, inserted: (@MainActor (PendingObjectID) -> Void)? = nil) {
        let name = String(localized: "New \(entity)")
        stage { [weak self] session in
            let (object, changes) = try await session.insertObject(entity: entity, actionName: name)
            if self?.session === session { inserted?(object) }
            return changes
        }
    }

    /// Links `objects` to `object` through its relationship `relationship`: added to a to-many, or set as a to-one,
    /// replacing what it held (EDT-3).
    func link(_ objects: [PendingObjectID], to object: PendingObjectID, through relationship: String) {
        guard !objects.isEmpty else { return }
        let name = String(localized: "Link \(relationship)")
        stage { try await $0.link(objects, to: object, through: relationship, actionName: name) }
    }

    /// Unlinks `objects` from `object`'s relationship `relationship`: out of a to-many, or a to-one emptied. The
    /// objects themselves stay (EDT-3).
    func unlink(_ objects: [PendingObjectID], from object: PendingObjectID, through relationship: String) {
        guard !objects.isEmpty else { return }
        let name = String(localized: "Unlink \(relationship)")
        stage { try await $0.unlink(objects, from: object, through: relationship, actionName: name) }
    }

    /// Stages a new object of `entity` already linked to `object` through `relationship`, as one edit, and hands
    /// `inserted` the identity it is staged under — once it is, and only if this session is still the one
    /// attached.
    func insertRelatedObject(
        of entity: String, to object: PendingObjectID, through relationship: String,
        inserted: (@MainActor (PendingObjectID) -> Void)? = nil
    ) {
        let name = String(localized: "New \(entity)")
        stage { [weak self] session in
            let (created, changes) = try await session.insertRelatedObject(
                to: object, through: relationship, entity: entity, actionName: name)
            if self?.session === session { inserted?(created) }
            return changes
        }
    }

    /// Throws away everything staged. The file is not touched.
    func discard() {
        undoManager.removeAllActions(withTarget: self)
        send { try await $0.discardChanges() }
    }

    /// Writes everything staged to the store, once the session's backup is taken and verified (EDT-9).
    ///
    /// - Returns: a task that finishes with whether the commit went through; a caller that has something to do
    ///   afterwards — close, reload, lock — waits for it.
    @discardableResult
    func commit() -> Task<Bool, Never> {
        guard let session, let backup, !isCommitting else { return Task { false } }
        isCommitting = true
        let generation = generation
        let previous = control
        let task = Task { [weak self] () -> Bool in
            await previous?.value
            do {
                let summary = try await session.commit(after: backup)
                guard let self, self.generation == generation else { return false }
                self.isCommitting = false
                self.lastCommit = summary
                self.undoManager.removeAllActions(withTarget: self)
                self.changes = .none
                if summary.total > 0 { self.commits += 1 }
                self.revision += 1
                self.onCommitFinished?()
                return true
            } catch {
                guard let self, self.generation == generation else { return false }
                self.isCommitting = false
                self.onCommitFinished?()
                self.fail(error)
                return false
            }
        }
        control = Task { _ = await task.value }
        return task
    }

    /// Returns once everything sent to the session has been done. Nothing in the app waits for that; the tests
    /// do.
    func whenSettled() async {
        await control?.value
    }

    // MARK: Undo

    /// An edit the session added to its stack: one entry in the window's.
    ///
    /// The session's answer arrives in a task, not in the event that asked for it, so the entry is made a group
    /// of its own rather than left to the event grouping: two answers in one pass of the run loop would otherwise
    /// share the event's group and undo as one.
    private func registerUndo(named name: String) {
        let byEvent = undoManager.groupsByEvent && undoManager.groupingLevel == 0
        if byEvent { undoManager.groupsByEvent = false }
        defer { if byEvent { undoManager.groupsByEvent = true } }
        undoManager.beginUndoGrouping()
        undoManager.registerUndo(withTarget: self) { target in
            MainActor.assumeIsolated { target.stepBack(named: name) }
        }
        undoManager.setActionName(name)
        undoManager.endUndoGrouping()
    }

    /// Called by the undo manager while it undoes: what is registered here is the redo.
    private func stepBack(named name: String) {
        undoManager.registerUndo(withTarget: self) { target in
            MainActor.assumeIsolated { target.stepForward(named: name) }
        }
        undoManager.setActionName(name)
        send { try await $0.undo() }
    }

    private func stepForward(named name: String) {
        undoManager.registerUndo(withTarget: self) { target in
            MainActor.assumeIsolated { target.stepBack(named: name) }
        }
        undoManager.setActionName(name)
        send { try await $0.redo() }
    }

    // MARK: Talking to the session

    /// Sends an edit, and mirrors it in the window's undo stack if the session added one to its own.
    private func stage(_ operation: @escaping @MainActor (StoreSession) async throws -> PendingChanges) {
        send(operation) { [weak self] before, after in
            guard let self, after.undoDepth > before.undoDepth else { return }
            self.registerUndo(named: after.undoActionName)
        }
    }

    private func send(
        _ operation: @escaping @MainActor (StoreSession) async throws -> PendingChanges,
        then: (@MainActor (_ before: PendingChanges, _ after: PendingChanges) -> Void)? = nil
    ) {
        guard let session else { return }
        let generation = generation
        let previous = control
        control = Task { [weak self] in
            await previous?.value
            do {
                let after = try await operation(session)
                guard let self, self.generation == generation else { return }
                let before = self.changes
                self.show(after)
                then?(before, after)
            } catch {
                guard let self, self.generation == generation else { return }
                self.fail(error)
            }
        }
    }

    private func show(_ changes: PendingChanges) {
        self.changes = changes
        revision += 1
        // The window's stack mirrors the session's; when the session has nothing to undo or redo, neither does
        // the window — whatever it still holds would undo nothing.
        if changes.undoDepth == 0, !changes.canRedo { undoManager.removeAllActions(withTarget: self) }
    }

    private func fail(_ error: any Error) {
        let error = DabbiError.wrapping(error)
        lastError = error
        onError?(error)
    }
}
