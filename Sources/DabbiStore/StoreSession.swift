@preconcurrency import CoreData
import DabbiBase
import DabbiModel
import DabbiSQLite
import Foundation

/// One open store. Everything in and out is a `Sendable` value; Core Data objects never cross this API
/// (ADR-02, ADR-03).
public actor StoreSession {
    /// Rows fetched per Core Data round trip; also the page size front ends should ask for.
    public static let pageSize = 200

    public nonisolated let info: StoreInfo
    /// Bumped by anything that invalidates row positions. Pagers and pages from an older generation are stale.
    public private(set) var generation = 0

    private let stack: CoreDataStack
    private let reader: SQLiteReader
    private var pagers: [UUID: [NSManagedObjectID]] = [:]
    private var isClosed = false

    // MARK: Opening

    /// Opens the store at `storeURL` read-only.
    ///
    /// - Parameter modelURL: a `.mom`, a `.momd`, or an app bundle to find the model in. Without it the model
    ///   cached inside the store is used.
    public static func open(storeURL: URL, modelURL: URL? = nil) async throws -> StoreSession {
        let storeURL = storeURL.standardizedFileURL
        _ = try SQLiteHeader.read(from: storeURL)
        let reader = try SQLiteReader(url: storeURL)
        do {
            let probe = try await reader.read { try FormatProbe.probe($0) }
            guard probe.kind == .coreData else { throw FormatProbe.notCoreDataError(at: storeURL) }

            let loaded = try await reader.read {
                try ModelLoader.resolve(storeURL: storeURL, modelURL: modelURL, connection: $0)
            }
            let metadata = try StoreMetadata.read(from: storeURL)
            let compatibility = ModelCompatibility.check(model: loaded.model, metadata: metadata)
            guard compatibility.isCompatible else { throw compatibility.error(storeURL: storeURL) }

            let description = loaded.description
            let schemaMap = try await reader.read { try SchemaMap.build(model: description, connection: $0) }
            let stack = try CoreDataStack(
                model: try ModelSanitiser.sanitised(loaded.model), description: description, storeURL: storeURL)
            let info = StoreInfo(
                url: storeURL, accessMode: .readOnly, model: description, modelSource: loaded.source,
                metadata: metadata, probe: probe, schemaMap: schemaMap)
            return StoreSession(info: info, stack: stack, reader: reader)
        } catch {
            await reader.close()
            throw error
        }
    }

    private init(info: StoreInfo, stack: CoreDataStack, reader: SQLiteReader) {
        self.info = info
        self.stack = stack
        self.reader = reader
    }

    /// Releases the store. Every later call fails with `.storeClosed`.
    public func close() async {
        guard !isClosed else { return }
        isClosed = true
        pagers.removeAll()
        stack.close()
        await reader.close()
    }

    /// Drops every pager and starts a new generation, so that the next fetch sees what the app wrote since.
    public func invalidate() {
        generation += 1
        pagers.removeAll()
    }

    // MARK: Counts

    public func count(_ spec: FetchSpec) async throws -> Int {
        let request = try fetchRequest(for: spec, resultType: NSManagedObjectID.self)
        let failure: DabbiError.Code = spec.predicate == nil ? .fetchFailed : .invalidPredicate
        return try await stack.perform { try CoreDataStack.count(request.value, in: $0, failure: failure) }
    }

    /// Row counts of every entity, in model order.
    public func entityCounts() async throws -> [EntityCount] {
        try ensureOpen()
        let entities = info.model.entities.map { (name: $0.name, isLeaf: $0.subentities.isEmpty) }
        return try await stack.perform { context in
            try entities.map { entity in
                let request = NSFetchRequest<NSManagedObjectID>(entityName: entity.name)
                request.resultType = .managedObjectIDResultType
                let total = try CoreDataStack.count(request, in: context)
                guard !entity.isLeaf else { return EntityCount(entity: entity.name, own: total, total: total) }
                request.includesSubentities = false
                return EntityCount(
                    entity: entity.name, own: try CoreDataStack.count(request, in: context), total: total)
            }
        }
    }

    // MARK: Paging

    /// Runs the fetch once, for object IDs only, and keeps the list. Pages are cut from it on demand.
    public func openPager(_ spec: FetchSpec) async throws -> PagerHandle {
        let request = try fetchRequest(for: spec, resultType: NSManagedObjectID.self)
        let failure: DabbiError.Code = spec.predicate == nil ? .fetchFailed : .invalidPredicate
        let ids = try await stack.perform { try CoreDataStack.fetch(request.value, in: $0, failure: failure) }
        try ensureOpen()
        let handle = PagerHandle(
            id: UUID(), spec: spec, count: ids.count,
            columns: stack.converter.columns(for: spec.entity, includeSubentities: spec.includeSubentities),
            generation: generation)
        pagers[handle.id] = ids
        return handle
    }

    public func closePager(_ handle: PagerHandle) {
        pagers[handle.id] = nil
    }

    /// The rows at `range` of the pager's list. The range is clamped to the list; rows deleted since the pager
    /// was opened are absent.
    public func page(_ handle: PagerHandle, range: Range<Int>) async throws -> RowPage {
        try ensureOpen()
        guard handle.generation == generation, let ids = pagers[handle.id] else {
            throw DabbiError(
                .stalePager, "This list of rows is out of date.", recovery: ["Fetch again to see current rows."])
        }
        let range = range.clamped(to: 0..<ids.count)
        let slice = Array(ids[range])
        let (spec, columns, converter) = (handle.spec, handle.columns, stack.converter)
        let rows = try await stack.perform { context in
            try stride(from: 0, to: slice.count, by: Self.pageSize).flatMap { start in
                let chunk = Array(slice[start..<min(start + Self.pageSize, slice.count)])
                return try Self.rows(for: chunk, spec: spec, columns: columns, converter: converter, in: context)
            }
        }
        return RowPage(range: range, rows: rows, columns: columns, generation: handle.generation)
    }

    private static func rows(
        for ids: [NSManagedObjectID],
        spec: FetchSpec,
        columns: ColumnSet,
        converter: ValueConverter,
        in context: NSManagedObjectContext
    ) throws -> [RowSnapshot] {
        let request = NSFetchRequest<NSManagedObject>(entityName: spec.entity)
        request.predicate = NSPredicate(format: "self IN %@", ids)
        request.includesSubentities = spec.includeSubentities
        request.returnsObjectsAsFaults = false
        request.shouldRefreshRefetchedObjects = true
        // To-one labels come from the destination rows; prefetching avoids one fault per cell.
        request.relationshipKeyPathsForPrefetching = converter.toOneRelationships(in: columns, of: spec.entity)
        let objects = try CoreDataStack.fetch(request, in: context)

        var counts: ValueConverter.ToManyCounts = [:]
        let countable = converter.batchCountableRelationships(
            in: columns, of: spec.entity, includeSubentities: spec.includeSubentities)
        for relationship in countable {
            // Without the batch the converter counts per row; slower, never wrong.
            counts[relationship.name] = try? CoreDataStack.toManyCounts(relationship, of: objects, in: context)
        }

        let byID = Dictionary(objects.map { ($0.objectID, $0) }, uniquingKeysWith: { first, _ in first })
        return ids.compactMap { id in byID[id].flatMap { converter.row($0, columns: columns, counts: counts) } }
    }

    // MARK: Single objects

    /// Every stored property of one object, by its own entity's layout.
    public func object(_ ref: ObjectRef) async throws -> ObjectSnapshot {
        let id = try objectID(for: ref)
        let (converter, generation) = (stack.converter, generation)
        return try await stack.perform { context in
            let object = try Self.existingObject(id, ref: ref, in: context)
            let columns = converter.columns(for: object.entity.name ?? ref.entity, includeSubentities: false)
            guard let row = converter.row(object, columns: columns) else {
                throw DabbiError(.internal, "The object has no permanent identity.")
            }
            return ObjectSnapshot(row: row, columns: columns, generation: generation)
        }
    }

    /// The full bytes of a binary or transformable attribute — what `BlobSummary` only summarises.
    /// `attribute` may be a path into a composite (`attachment.preview`).
    public func blob(for ref: ObjectRef, attribute: String) async throws -> Data? {
        let id = try objectID(for: ref)
        let converter = stack.converter
        return try await stack.perform { context in
            try converter.data(of: Self.existingObject(id, ref: ref, in: context), path: attribute)
        }
    }

    private func objectID(for ref: ObjectRef) throws -> NSManagedObjectID {
        try ensureOpen()
        guard let id = stack.objectID(for: ref) else {
            throw DabbiError(
                .objectNotFound, "\(ref) does not belong to this store.",
                diagnosis: ["The object's URI names a different store, or an entity the model does not have."])
        }
        return id
    }

    private static func existingObject(
        _ id: NSManagedObjectID, ref: ObjectRef, in context: NSManagedObjectContext
    ) throws -> NSManagedObject {
        do {
            return try objcGuarded("The object could not be read.", code: .fetchFailed) {
                try context.existingObject(with: id)
            }
        } catch let error as DabbiError {
            throw error
        } catch {
            throw DabbiError(.objectNotFound, "\(ref) no longer exists.", underlying: error)
        }
    }

    // MARK: Requests

    /// `NSFetchRequest` is not `Sendable`; this one is built here and only ever used inside one `perform`.
    private struct Request<Result: NSFetchRequestResult>: @unchecked Sendable {
        let value: NSFetchRequest<Result>
    }

    private func fetchRequest<Result: NSFetchRequestResult>(
        for spec: FetchSpec, resultType: Result.Type
    ) throws -> Request<Result> {
        try ensureOpen()
        guard info.model.entity(named: spec.entity) != nil else {
            throw DabbiError(
                .unknownEntity, "The model has no entity named “\(spec.entity)”.",
                arguments: ["entity": spec.entity],
                recovery: ["Entities: " + info.model.entities.map(\.name).joined(separator: ", ")])
        }
        let request = NSFetchRequest<Result>(entityName: spec.entity)
        request.resultType = .managedObjectIDResultType
        request.includesSubentities = spec.includeSubentities
        request.predicate = try spec.predicate.map(PredicateGuard.parse)
        // Object-ID order last: it is the whole order when there are no sort keys — SQLite would otherwise walk
        // whichever index covers the query — and the tie-break when there are. It is the rowid, so it costs nothing.
        request.sortDescriptors =
            try stack.converter.sortDescriptors(for: spec.sort, entity: spec.entity)
            + [NSSortDescriptor(key: "self", ascending: true)]
        if let limit = spec.limit { request.fetchLimit = max(0, limit) }
        return Request(value: request)
    }

    private func ensureOpen() throws {
        guard !isClosed else { throw DabbiError(.storeClosed, "The store has been closed.") }
    }
}
