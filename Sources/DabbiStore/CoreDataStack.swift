@preconcurrency import CoreData
import DabbiBase
import DabbiModel
import Foundation

/// The coordinator and the contexts of one open store.
///
/// A read-only stack has `browse` and `track`. An editable one has `track` and, in `browse`'s place, the `edit`
/// context (ARCHITECTURE.md §6.4): browsing and staging share it, so that the grid shows what is staged and a
/// commit is that one context's save.
///
/// `@unchecked Sendable` because it is owned by exactly one `StoreSession` and touches Core Data objects only
/// inside `context.perform`. It never appears in public API (ADR-03).
final class CoreDataStack: @unchecked Sendable {
    let converter: ValueConverter
    private let coordinator: NSPersistentStoreCoordinator
    /// Read-only: the browse context, emptied after every call. Editable: the edit context, which holds the
    /// staged edits and their undo stack and is only ever refreshed.
    private let browse: NSManagedObjectContext
    /// The tracker's own context (ARCHITECTURE.md §6.6). Materialising five hundred changed rows and paging the
    /// grid then never wait on each other, which is what keeps a save's round trip inside its budget while the
    /// user is scrolling.
    private let track: NSManagedObjectContext

    /// Whether the store was opened with history tracking on, and so whether `NSPersistentHistoryChangeRequest`
    /// can be asked anything (spike S7).
    let tracksHistory: Bool

    /// What the store was opened for. Editable stacks carry the author their saves are recorded under.
    let access: StoreAccess

    /// Adds the store, read-only unless `access` says otherwise. `model` must already be sanitised.
    ///
    /// Editable (EDT-1) is the same stack without `NSReadOnlyPersistentStoreOption`: it is an open-time option,
    /// which is why a mode switch is a new session and not a flag. Either way no migration is ever attempted,
    /// and the contexts carry the authorization's author, so that the history of a store that records it says
    /// whose saves are ours (EDT-5).
    ///
    /// `tracksHistory` should be `FormatProbe.hasHistory` — whether the file already carries the `ATRANSACTION`
    /// and `ACHANGE` tables. Two findings from spike S7 make that the right gate, and both are one-way:
    ///
    /// - Without `NSPersistentHistoryTrackingKey`, every history fetch fails with error 134091, "No history
    ///   tracking option detected on store" — read-only or not. The key is not optional.
    /// - With the key on a store that has no history tables, the open still succeeds and the tables are *not*
    ///   created (read-only sees to that), but the first fetch fails with `no such table: ATRANSACTION` after
    ///   Core Data has logged its own noise to the console. Asking a store that never tracked is pointless and
    ///   not silent, so it is not asked.
    ///
    /// S7 also checked what the key costs: with the store read-only, the `.sqlite` and `-wal` bytes are byte-identical
    /// before and after, and only `-shm` changes — identically whether the key is passed or not. On a file the user
    /// has made unwritable, nothing changes at all and history still reads.
    ///
    /// `keepsWAL` is `SQLiteHeader.isWAL`: whether the file is in write-ahead-log mode now. It matters only to an
    /// editable open, which keeps the store in the journal mode it found it in.
    init(
        model: NSManagedObjectModel, description: ModelDescription, storeURL: URL, tracksHistory: Bool = false,
        access: StoreAccess = .readOnly, keepsWAL: Bool = true
    ) throws {
        converter = ValueConverter(model: description)
        self.tracksHistory = tracksHistory
        self.access = access
        let coordinator = NSPersistentStoreCoordinator(managedObjectModel: model)
        // No migration, ever: a model that does not match is an error to explain, not to repair. Said outright
        // rather than left to the defaults, because an editable store is one a migration could actually write.
        var options: [String: Any] = [
            NSMigratePersistentStoresAutomaticallyOption: false,
            NSInferMappingModelAutomaticallyOption: false,
        ]
        if access.mode == .readOnly {
            options[NSReadOnlyPersistentStoreOption] = true
        } else if !keepsWAL {
            // Core Data puts every store it opens read-write into WAL mode, and the switch rewrites the file's
            // header. A store the app keeps on a rollback journal stays on one: its format is the app's choice.
            options[NSSQLitePragmasOption] = ["journal_mode": "DELETE"]
        }
        if tracksHistory {
            options[NSPersistentHistoryTrackingKey] = true
        }
        do {
            _ = try objcGuarded("The store could not be opened.", code: .storeOpenFailed) {
                try coordinator.addPersistentStore(type: .sqlite, at: storeURL, options: options)
            }
        } catch let error as DabbiError {
            throw error
        } catch {
            throw DabbiError(
                .storeOpenFailed, "Core Data could not open \(storeURL.lastPathComponent).",
                arguments: ["path": storeURL.path], underlying: error)
        }
        self.coordinator = coordinator

        if let authorization = access.authorization {
            browse = Self.editContext(coordinator: coordinator, author: authorization.author)
        } else {
            browse = Self.readingContext(named: "browse", coordinator: coordinator, author: nil)
        }
        track = Self.readingContext(named: "track", coordinator: coordinator, author: access.authorization?.author)
    }

    /// A private-queue context that always reads through to the file: no staleness allowance, no undo stack.
    ///
    /// Neither context saves; the author is set anyway, so that nothing saved through this stack is ever
    /// recorded as nobody's.
    private static func readingContext(
        named name: String, coordinator: NSPersistentStoreCoordinator, author: String?
    ) -> NSManagedObjectContext {
        let context = NSManagedObjectContext(concurrencyType: .privateQueueConcurrencyType)
        context.persistentStoreCoordinator = coordinator
        context.stalenessInterval = 0
        context.undoManager = nil
        context.name = name
        context.transactionAuthor = author
        return context
    }

    /// The context staged edits are made in (EDT-8).
    ///
    /// Its undo manager is driven by hand — `groupsByEvent` is off, since a private queue has no event loop to
    /// close groups — and every staged edit is one group (`edit(actionName:_:)`). Conflicts are errors, not
    /// merges: a commit never overwrites what somebody else saved without saying so (EDT-10).
    private static func editContext(
        coordinator: NSPersistentStoreCoordinator, author: String
    ) -> NSManagedObjectContext {
        let context = NSManagedObjectContext(concurrencyType: .privateQueueConcurrencyType)
        context.persistentStoreCoordinator = coordinator
        context.stalenessInterval = 0
        context.mergePolicy = NSMergePolicy.error
        context.name = "edit"
        context.transactionAuthor = author
        let undoManager = UndoManager()
        undoManager.groupsByEvent = false
        undoManager.levelsOfUndo = 0
        context.undoManager = undoManager
        return context
    }

    var isEditable: Bool { access.mode == .editable }

    /// Runs `body` on the browse context's queue. Rows leave as values, so the context is emptied afterwards
    /// and its memory stays bounded however far the user scrolls.
    ///
    /// On an editable stack this is the edit context, which cannot be emptied without losing what is staged.
    /// It is refreshed instead: unchanged objects turn back into faults, changed ones keep their edits.
    func perform<T: Sendable>(_ body: @escaping @Sendable (NSManagedObjectContext) throws -> T) async throws -> T {
        guard isEditable, let undoManager = browse.undoManager else { return try await Self.perform(on: browse, body) }
        return try await browse.perform { [browse] in
            // Reading registers nothing — but refreshing a changed object re-applies its changes, and Core Data
            // would record that as a new edit of its own and forget the redo stack.
            undoManager.disableUndoRegistration()
            defer {
                browse.refreshAllObjects()
                browse.processPendingChanges()
                undoManager.enableUndoRegistration()
            }
            return try body(browse)
        }
    }

    /// Runs one staged edit on the edit context as one undo group named `actionName`.
    ///
    /// The undo stack only ever holds whole edits that changed something. An edit that changes nothing leaves
    /// no group behind — `UndoManager` keeps empty groups, and undoing one would do nothing, visibly. An edit
    /// that throws halfway is taken back, so that it leaves nothing staged either; `body` should still check
    /// what it can before it changes anything.
    ///
    /// Returns `body`'s result and what is staged once the group is closed — named, and on the undo stack.
    func edit<T: Sendable>(
        actionName: String, _ body: @escaping @Sendable (NSManagedObjectContext) throws -> T
    ) async throws -> (T, PendingChanges) {
        guard isEditable, let undoManager = browse.undoManager else { throw Self.notEditable }
        let converter = converter
        return try await browse.perform { [browse] in
            let changed = ChangeFlag()
            let observer = NotificationCenter.default.addObserver(
                forName: .NSManagedObjectContextObjectsDidChange, object: browse, queue: nil
            ) { _ in changed.isSet = true }
            defer { NotificationCenter.default.removeObserver(observer) }

            undoManager.beginUndoGrouping()
            let result = Result {
                try objcGuarded("The edit could not be made.", code: .invalidValue) { try body(browse) }
            }
            browse.processPendingChanges()
            // With `groupsByEvent` off the name has to be set while the group is open.
            undoManager.setActionName(actionName)
            undoManager.endUndoGrouping()
            if case .failure = result, changed.isSet {
                // Taken back without registering its redo: a failed edit is not something to redo.
                undoManager.disableUndoRegistration()
                undoManager.undo()
                browse.processPendingChanges()
                undoManager.enableUndoRegistration()
            } else if !changed.isSet {
                // Empty: popping it undoes nothing and leaves the stack as it was.
                undoManager.undo()
            } else {
                Self.adjustUndoDepth(of: browse, by: 1)
            }
            return (try result.get(), Self.pendingChanges(in: browse, converter: converter))
        }
    }

    /// What is staged in the edit context, and where its undo stack stands. Inside `perform` only.
    static func pendingChanges(in context: NSManagedObjectContext, converter: ValueConverter) -> PendingChanges {
        let undoManager = context.undoManager
        return PendingChanges(
            changes: converter.pendingChanges(in: context),
            canUndo: undoManager?.canUndo ?? false, canRedo: undoManager?.canRedo ?? false,
            undoActionName: undoManager?.undoActionName ?? "", redoActionName: undoManager?.redoActionName ?? "",
            undoDepth: undoDepth(of: context))
    }

    /// How many edits the undo stack holds. `UndoManager` does not say, and a front end that mirrors the stack
    /// in its own needs to know whether a call added one. Kept in the context's `userInfo`, so that it lives on
    /// the context's queue with the stack it counts. Inside `perform` only.
    static func undoDepth(of context: NSManagedObjectContext) -> Int {
        context.userInfo[undoDepthKey] as? Int ?? 0
    }

    static func adjustUndoDepth(of context: NSManagedObjectContext, by delta: Int) {
        context.userInfo[undoDepthKey] = max(undoDepth(of: context) + delta, 0)
    }

    static func resetUndoDepth(of context: NSManagedObjectContext) {
        context.userInfo[undoDepthKey] = 0
    }

    /// Takes back the context's last edit, if it has one. The context's own `undo()`, not the manager's: it
    /// processes the pending changes inside the undo, so that what the undo changed is registered as its redo and
    /// not as a new edit.
    static func undoLastEdit(in context: NSManagedObjectContext) {
        guard context.undoManager?.canUndo == true else { return }
        context.undo()
        adjustUndoDepth(of: context, by: -1)
    }

    static func redoLastEdit(in context: NSManagedObjectContext) {
        guard context.undoManager?.canRedo == true else { return }
        context.redo()
        adjustUndoDepth(of: context, by: 1)
    }

    /// Forgets every edit the context could undo or redo.
    static func clearUndo(of context: NSManagedObjectContext) {
        context.undoManager?.removeAllActions()
        resetUndoDepth(of: context)
    }

    private static let undoDepthKey = "org.coredatadabbi.undoDepth"

    /// Set from a notification posted synchronously on the context's own queue, and read there.
    private final class ChangeFlag: @unchecked Sendable {
        var isSet = false
    }

    /// Runs `body` on the edit context outside any undo group: undo, redo, discard, commit and reading what is
    /// staged.
    func performEditing<T: Sendable>(
        _ body: @escaping @Sendable (NSManagedObjectContext, UndoManager) throws -> T
    ) async throws -> T {
        guard isEditable, let undoManager = browse.undoManager else { throw Self.notEditable }
        return try await browse.perform { [browse] in try body(browse, undoManager) }
    }

    static let notEditable = DabbiError(
        .notEditable, "The store is open read-only.",
        recovery: ["Allow editing to stage changes, then commit them to the store."])

    /// Runs `body` on the tracking context's queue, for the same reasons and with the same emptying afterwards.
    func performTracking<T: Sendable>(
        _ body: @escaping @Sendable (NSManagedObjectContext) throws -> T
    ) async throws -> T {
        try await Self.perform(on: track, body)
    }

    private static func perform<T: Sendable>(
        on context: NSManagedObjectContext, _ body: @escaping @Sendable (NSManagedObjectContext) throws -> T
    ) async throws -> T {
        try await context.perform {
            defer { context.reset() }
            return try body(context)
        }
    }

    func objectID(for ref: ObjectRef) -> NSManagedObjectID? {
        coordinator.managedObjectID(forURIRepresentation: ref.uri)
    }

    /// The coordinator's current persistent history token, archived.
    ///
    /// Archived rather than handed over, because an `NSPersistentHistoryToken` is a class and nothing outside
    /// this file is allowed to hold one (ADR-03). `nil` when the store records no history, or when the token
    /// will not archive.
    func currentHistoryTokenData() -> Data? {
        guard tracksHistory, let token = coordinator.currentPersistentHistoryToken(fromStores: nil) else {
            return nil
        }
        return try? NSKeyedArchiver.archivedData(withRootObject: token, requiringSecureCoding: true)
    }

    func close() {
        browse.performAndWait { browse.reset() }
        track.performAndWait { track.reset() }
        for store in coordinator.persistentStores {
            try? coordinator.remove(store)
        }
    }

    // MARK: Guarded fetches — called inside `perform`

    /// Executes a fetch inside the exception bridge: a key path that does not exist raises, it does not throw.
    static func fetch<Result: NSFetchRequestResult>(
        _ request: NSFetchRequest<Result>,
        in context: NSManagedObjectContext,
        failure: DabbiError.Code = .fetchFailed
    ) throws -> [Result] {
        do {
            return try objcGuarded("Core Data rejected the fetch.", code: failure) { try context.fetch(request) }
        } catch let error as DabbiError {
            throw error
        } catch {
            throw DabbiError(.fetchFailed, "The fetch failed.", underlying: error)
        }
    }

    static func count<Result: NSFetchRequestResult>(
        _ request: NSFetchRequest<Result>,
        in context: NSManagedObjectContext,
        failure: DabbiError.Code = .fetchFailed
    ) throws -> Int {
        do {
            return try objcGuarded("Core Data rejected the fetch.", code: failure) { try context.count(for: request) }
        } catch let error as DabbiError {
            throw error
        } catch {
            throw DabbiError(.fetchFailed, "The count failed.", underlying: error)
        }
    }

    /// Counts a to-many relationship for a whole page with one grouped fetch on the destination:
    /// `SELECT inverse, count(*) … WHERE inverse IN page GROUP BY inverse`. Public API only.
    static func toManyCounts(
        _ relationship: RelationshipDescription,
        of objects: [NSManagedObject],
        in context: NSManagedObjectContext
    ) throws -> [NSManagedObjectID: Int] {
        guard let inverse = relationship.inverseName, !objects.isEmpty else { return [:] }
        let count = NSExpressionDescription()
        count.name = "count"
        // Counting the rows themselves, not `inverse`: a to-one whose destination has sub-entities is two columns
        // (`ZBOSS`, `Z4_BOSS`), and SQLite's COUNT() takes one.
        count.expression = NSExpression(
            forFunction: "count:", arguments: [NSExpression.expressionForEvaluatedObject()])
        count.resultType = .integer64

        let request = NSFetchRequest<NSDictionary>(entityName: relationship.destinationEntity)
        request.resultType = .dictionaryResultType
        request.predicate = NSPredicate(format: "%K IN %@", inverse, objects)
        request.propertiesToFetch = [inverse, count]
        request.propertiesToGroupBy = [inverse]

        var counts: [NSManagedObjectID: Int] = [:]
        for group in try fetch(request, in: context) {
            if let id = group[inverse] as? NSManagedObjectID, let number = group["count"] as? NSNumber {
                counts[id] = number.intValue
            }
        }
        return counts
    }
}
