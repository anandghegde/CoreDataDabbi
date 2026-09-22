@preconcurrency import CoreData
import DabbiBase
import DabbiModel
import Foundation

/// The coordinator and the `browse` context of one open store.
///
/// `@unchecked Sendable` because it is owned by exactly one `StoreSession` and touches Core Data objects only
/// inside `context.perform`. It never appears in public API (ADR-03).
final class CoreDataStack: @unchecked Sendable {
    let converter: ValueConverter
    private let coordinator: NSPersistentStoreCoordinator
    private let browse: NSManagedObjectContext
    /// The tracker's own context (ARCHITECTURE.md §6.6). Materialising five hundred changed rows and paging the
    /// grid then never wait on each other, which is what keeps a save's round trip inside its budget while the
    /// user is scrolling.
    private let track: NSManagedObjectContext

    /// Whether the store was opened with history tracking on, and so whether `NSPersistentHistoryChangeRequest`
    /// can be asked anything (spike S7).
    let tracksHistory: Bool

    /// Adds the store read-only. `model` must already be sanitised.
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
    init(
        model: NSManagedObjectModel, description: ModelDescription, storeURL: URL, tracksHistory: Bool = false
    ) throws {
        converter = ValueConverter(model: description)
        self.tracksHistory = tracksHistory
        let coordinator = NSPersistentStoreCoordinator(managedObjectModel: model)
        // No migration options, ever: a model that does not match is an error to explain, not to repair.
        var options: [String: Any] = [NSReadOnlyPersistentStoreOption: true]
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

        browse = Self.readingContext(named: "browse", coordinator: coordinator)
        track = Self.readingContext(named: "track", coordinator: coordinator)
    }

    /// A private-queue context that always reads through to the file: no staleness allowance, no undo stack.
    private static func readingContext(
        named name: String, coordinator: NSPersistentStoreCoordinator
    ) -> NSManagedObjectContext {
        let context = NSManagedObjectContext(concurrencyType: .privateQueueConcurrencyType)
        context.persistentStoreCoordinator = coordinator
        context.stalenessInterval = 0
        context.undoManager = nil
        context.name = name
        return context
    }

    /// Runs `body` on the browse context's queue. Rows leave as values, so the context is emptied afterwards
    /// and its memory stays bounded however far the user scrolls.
    func perform<T: Sendable>(_ body: @escaping @Sendable (NSManagedObjectContext) throws -> T) async throws -> T {
        try await Self.perform(on: browse, body)
    }

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
