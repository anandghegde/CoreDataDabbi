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

    /// Adds the store read-only. `model` must already be sanitised.
    init(model: NSManagedObjectModel, description: ModelDescription, storeURL: URL) throws {
        converter = ValueConverter(model: description)
        let coordinator = NSPersistentStoreCoordinator(managedObjectModel: model)
        // No migration options, ever: a model that does not match is an error to explain, not to repair.
        let options: [String: Any] = [NSReadOnlyPersistentStoreOption: true]
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

        browse = NSManagedObjectContext(concurrencyType: .privateQueueConcurrencyType)
        browse.persistentStoreCoordinator = coordinator
        browse.stalenessInterval = 0
        browse.undoManager = nil
        browse.name = "browse"
    }

    /// Runs `body` on the browse context's queue. Rows leave as values, so the context is emptied afterwards
    /// and its memory stays bounded however far the user scrolls.
    func perform<T: Sendable>(_ body: @escaping @Sendable (NSManagedObjectContext) throws -> T) async throws -> T {
        try await browse.perform { [browse] in
            defer { browse.reset() }
            return try body(browse)
        }
    }

    func objectID(for ref: ObjectRef) -> NSManagedObjectID? {
        coordinator.managedObjectID(forURIRepresentation: ref.uri)
    }

    func close() {
        browse.performAndWait { browse.reset() }
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
