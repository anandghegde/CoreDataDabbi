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

    /// Not `private`: the history reader is an extension in its own file (`StoreHistory.swift`).
    let stack: CoreDataStack
    let reader: SQLiteReader
    private var pagers: [UUID: Pager] = [:]
    private var isClosed = false
    /// Objects inserted in the edit context, by their temporary URI: the coordinator cannot resolve those.
    /// Not `private`: staging is an extension in its own file (`StagedEdits.swift`).
    var insertedObjectIDs: [URL: NSManagedObjectID] = [:]

    // MARK: Opening

    /// Opens the store at `storeURL`, read-only unless `access` says otherwise.
    ///
    /// - Parameters:
    ///   - modelURL: a `.mom`, a `.momd`, or an app bundle to find the model in. Without it the model cached
    ///     inside the store is used.
    ///   - access: `.editable` opens the store for writing (EDT-1). It is refused with `.storeNotWritable`
    ///     before Core Data is asked, when the file, its folder or its companions cannot be written.
    public static func open(
        storeURL: URL, modelURL: URL? = nil, access: StoreAccess = .readOnly
    ) async throws -> StoreSession {
        let storeURL = storeURL.standardizedFileURL
        let header = try SQLiteHeader.read(from: storeURL)
        if access.mode == .editable { try checkWritable(storeURL) }
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
            // The history key only where the store already tracks: on a store that does not, it would buy a
            // `no such table: ATRANSACTION` and a page of Core Data's console noise (spike S7).
            let stack = try CoreDataStack(
                model: try ModelSanitiser.sanitised(loaded.model), description: description, storeURL: storeURL,
                tracksHistory: probe.hasHistory, access: access, keepsWAL: header.isWAL)
            let info = StoreInfo(
                url: storeURL, accessMode: access.mode, model: description, modelSource: loaded.source,
                metadata: metadata, probe: probe, schemaMap: schemaMap)
            return StoreSession(info: info, stack: stack, reader: reader)
        } catch {
            await reader.close()
            throw error
        }
    }

    /// Whether an editable open can write everything it has to: the store, the folder its journal or log is
    /// created in, and the log and shared memory when they are there already.
    ///
    /// Core Data would find out too, at the first save or not at all — a store whose folder is read-only opens
    /// happily and fails when the journal cannot be made. Asking first is what lets the lock say no at once.
    private static func checkWritable(_ storeURL: URL) throws {
        let files = FileManager.default
        let folder = storeURL.deletingLastPathComponent()
        let companions = ["-wal", "-shm"].map { URL(fileURLWithPath: storeURL.path + $0) }
        let unwritable =
            ([storeURL, folder] + companions.filter { files.fileExists(atPath: $0.path) })
            .filter { !files.isWritableFile(atPath: $0.path) }
        guard let first = unwritable.first else { return }
        throw DabbiError(
            .storeNotWritable, "The store cannot be edited where it is.",
            arguments: ["path": storeURL.path],
            diagnosis: unwritable.map { "\($0.lastPathComponent) cannot be written to." },
            recovery: [
                first == folder
                    ? "Copy the store to a folder you can write to, and open the copy."
                    : "Check the file's permissions in the Finder's Get Info window.",
                "Keep browsing read-only: nothing is lost.",
            ])
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

    /// The list a pager's pages are cut from. It stays here; front ends hold the `PagerHandle`.
    private struct Pager {
        var ids: [NSManagedObjectID]
        var hasMore: Bool
    }

    /// Runs the fetch once, for object IDs only, and keeps the list. Pages are cut from it on demand.
    ///
    /// With a fetch limit the list stops there, and `hasMore` tells whether `loadMore` would add to it.
    public func openPager(_ spec: FetchSpec) async throws -> PagerHandle {
        // One more than the limit: the extra row is never shown, it only says that there is more.
        let window = spec.limit.map { (offset: 0, limit: max(0, $0) + 1) }
        let request = try fetchRequest(for: spec, resultType: NSManagedObjectID.self, window: window)
        let failure: DabbiError.Code = spec.predicate == nil ? .fetchFailed : .invalidPredicate
        // An editable session's fetches include what is staged. An object that is only inserted has a temporary
        // identity and no reference yet, so it has no row to show; it is listed with the pending changes.
        var ids = try await stack.perform {
            try CoreDataStack.fetch(request.value, in: $0, failure: failure).filter { !$0.isTemporaryID }
        }
        try ensureOpen()
        let hasMore = spec.limit.map { ids.count > max(0, $0) } ?? false
        if hasMore { ids.removeLast() }
        let handle = PagerHandle(
            id: UUID(), spec: spec, count: ids.count, hasMore: hasMore,
            columns: stack.converter.columns(for: spec.entity, includeSubentities: spec.includeSubentities),
            generation: generation)
        pagers[handle.id] = Pager(ids: ids, hasMore: hasMore)
        return handle
    }

    /// Appends the next rows of a pager whose fetch limit cut it short — “Load more” (BRW-11).
    ///
    /// The handle that comes back names the same list, only longer; pages cut with the old handle stay valid.
    /// - Parameter count: how many rows to add; by default as many as the spec's limit.
    public func loadMore(_ handle: PagerHandle, count: Int? = nil) async throws -> PagerHandle {
        let pager = try pager(for: handle)
        guard pager.hasMore else { return Self.handle(handle, reflecting: pager) }
        let batch = max(1, count ?? handle.spec.limit ?? Self.pageSize)
        let offset = pager.ids.count
        let request = try fetchRequest(
            for: handle.spec, resultType: NSManagedObjectID.self, window: (offset: offset, limit: batch + 1))
        var more = try await stack.perform {
            try CoreDataStack.fetch(request.value, in: $0).filter { !$0.isTemporaryID }
        }

        // The actor was free during the fetch: the pager may be gone, or somebody else may have extended it.
        var current = try self.pager(for: handle)
        guard current.ids.count == offset else { return Self.handle(handle, reflecting: current) }
        current.hasMore = more.count > batch
        if current.hasMore { more.removeLast() }
        // The app may have inserted rows since; one that sorts before the offset pushes a known row into
        // this batch a second time.
        let known = Set(current.ids)
        current.ids.append(contentsOf: more.filter { !known.contains($0) })
        pagers[handle.id] = current
        return Self.handle(handle, reflecting: current)
    }

    public func closePager(_ handle: PagerHandle) {
        pagers[handle.id] = nil
    }

    /// The rows at `range` of the pager's list. The range is clamped to the list; rows deleted since the pager
    /// was opened are absent, and `RowPage.missing` names their positions.
    ///
    /// - Parameter columns: *lazy loading* (BRW-11) — read only these of the pager's columns. Values of the
    ///   others are never fetched from the store, which matters most for wide entities and large blobs.
    public func page(_ handle: PagerHandle, range: Range<Int>, columns: ColumnSet? = nil) async throws -> RowPage {
        let ids = try pager(for: handle).ids
        if let columns, let unknown = columns.properties.first(where: { handle.columns.index(of: $0) == nil }) {
            throw DabbiError(
                .unknownProperty, "\(handle.spec.entity) has no property “\(unknown)”.",
                arguments: ["entity": handle.spec.entity, "property": unknown])
        }
        let range = range.clamped(to: 0..<ids.count)
        let slice = Array(ids[range])
        let (spec, converter) = (handle.spec, stack.converter)
        let isPartial = columns != nil && columns != handle.columns
        let columns = columns ?? handle.columns
        let rows = try await stack.perform { context in
            try stride(from: 0, to: slice.count, by: Self.pageSize).flatMap { start in
                let chunk = Array(slice[start..<min(start + Self.pageSize, slice.count)])
                return try Self.rows(
                    for: chunk, spec: spec, columns: columns, isPartial: isPartial, converter: converter,
                    in: context)
            }
        }
        let missing = zip(range, rows).compactMap { position, row in row == nil ? position : nil }
        return RowPage(
            range: range, rows: rows.compactMap { $0 }, columns: columns, generation: handle.generation,
            missing: missing)
    }

    private func pager(for handle: PagerHandle) throws -> Pager {
        try ensureOpen()
        guard handle.generation == generation, let pager = pagers[handle.id] else {
            throw DabbiError(
                .stalePager, "This list of rows is out of date.", recovery: ["Fetch again to see current rows."])
        }
        return pager
    }

    private static func handle(_ handle: PagerHandle, reflecting pager: Pager) -> PagerHandle {
        PagerHandle(
            id: handle.id, spec: handle.spec, count: pager.ids.count, hasMore: pager.hasMore,
            columns: handle.columns, generation: handle.generation)
    }

    /// One row per ID, in the order of `ids`; `nil` for an object that no longer exists.
    private static func rows(
        for ids: [NSManagedObjectID],
        spec: FetchSpec,
        columns: ColumnSet,
        isPartial: Bool,
        converter: ValueConverter,
        in context: NSManagedObjectContext
    ) throws -> [RowSnapshot?] {
        let request = NSFetchRequest<NSManagedObject>(entityName: spec.entity)
        request.predicate = NSPredicate(format: "self IN %@", ids)
        request.includesSubentities = spec.includeSubentities
        request.returnsObjectsAsFaults = false
        request.shouldRefreshRefetchedObjects = true
        // To-one labels come from the destination rows; prefetching avoids one fault per cell.
        request.relationshipKeyPathsForPrefetching = converter.toOneRelationships(in: columns, of: spec.entity)

        var objects: [NSManagedObject]?
        if isPartial, let properties = converter.partialFetchProperties(for: columns, of: spec.entity) {
            // Partial faults: the columns nobody looks at stay in the file. Should Core Data refuse the
            // property list, the full fetch below is slower, never wrong.
            request.propertiesToFetch = properties
            objects = try? CoreDataStack.fetch(request, in: context)
            request.propertiesToFetch = nil
        }
        let fetched = try objects ?? CoreDataStack.fetch(request, in: context)

        var counts: ValueConverter.ToManyCounts = [:]
        let countable = converter.batchCountableRelationships(
            in: columns, of: spec.entity, includeSubentities: spec.includeSubentities)
        for relationship in countable {
            // Without the batch the converter counts per row; slower, never wrong.
            counts[relationship.name] = try? CoreDataStack.toManyCounts(relationship, of: fetched, in: context)
        }

        let byID = Dictionary(fetched.map { ($0.objectID, $0) }, uniquingKeysWith: { first, _ in first })
        return ids.map { id in byID[id].flatMap { converter.row($0, columns: columns, counts: counts) } }
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

    /// What is on the far side of one of `ref`'s relationships (REL-1, REL-2).
    ///
    /// `limit` bounds what comes back, not what is read: Core Data has to know the whole set to count it, so a
    /// relationship with a hundred thousand rows costs a list of identities either way. Only the objects that
    /// are returned are faulted in for their labels.
    public func related(to ref: ObjectRef, through name: String, limit: Int = 500) async throws -> RelatedObjects {
        let id = try objectID(for: ref)
        guard let relationship = info.model.entity(named: ref.entity)?.relationship(named: name) else {
            throw DabbiError(
                .unknownProperty, "“\(ref.entity)” has no relationship named “\(name)”.",
                arguments: ["entity": ref.entity, "property": name])
        }
        let (converter, generation) = (stack.converter, generation)
        return try await stack.perform { context in
            let object = try Self.existingObject(id, ref: ref, in: context)
            var count = 0
            var objects: [NSManagedObject] = []
            switch object.value(forKey: name) {
            case let destination as NSManagedObject:
                count = 1
                objects = [destination]
            case let ordered as NSOrderedSet:
                count = ordered.count
                objects = ordered.prefix(limit).compactMap { $0 as? NSManagedObject }
            case let set as NSSet:
                count = set.count
                // A set has no order of its own; object-ID order is what the grid shows, so the panel shows it
                // too — and it means the first page of a relationship is the same every time it is opened.
                // Everything a relationship can point at shares one table, so the key alone orders them all.
                objects =
                    set.compactMap { $0 as? NSManagedObject }
                    .map { (object: $0, pk: ObjectRef(uri: $0.objectID.uriRepresentation())?.pk ?? 0) }
                    .sorted { $0.pk < $1.pk }
                    .prefix(limit)
                    .map(\.object)
            default:
                break
            }
            return RelatedObjects(
                relationship: name, destinationEntity: relationship.destinationEntity,
                isToMany: relationship.isToMany, isOrdered: relationship.isOrdered, count: count,
                items: objects.compactMap(converter.item), generation: generation)
        }
    }

    func objectID(for ref: ObjectRef) throws -> NSManagedObjectID {
        try ensureOpen()
        guard let id = stack.objectID(for: ref) else {
            throw DabbiError(
                .objectNotFound, "\(ref) does not belong to this store.",
                diagnosis: ["The object's URI names a different store, or an entity the model does not have."])
        }
        return id
    }

    static func existingObject(
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

    // MARK: Many objects

    /// The reference of a row of this store, from its entity and its primary key.
    ///
    /// The tracker's scan reads keys straight out of SQLite (`Z_PK`, `Z_ENT`) and needs identities before it can
    /// read any values; this is where the store's UUID comes from. Nothing is checked against the file — a key no
    /// row has simply fails to materialise.
    public nonisolated func reference(entity: String, pk: Int64) -> ObjectRef? {
        guard let uuid = info.metadata.storeUUID else { return nil }
        return ObjectRef(storeUUID: uuid, entity: entity, pk: pk)
    }

    /// Which objects a fetch matches, and none of their values.
    ///
    /// The object-ID fetch a pager runs, except that the list comes out instead of staying here. The tracker primes
    /// a predicate view with it — which rows the view holds *before* the next save (TRK-7).
    ///
    /// - Parameter limit: fetched instead of the spec's own limit. Ask for one more than you can use to learn
    ///   whether there are more.
    public func references(_ spec: FetchSpec, limit: Int? = nil) async throws -> [ObjectRef] {
        if let limit, limit <= 0 { return [] }
        let window = limit.map { (offset: 0, limit: $0) }
        let request = try fetchRequest(for: spec, resultType: NSManagedObjectID.self, window: window)
        let failure: DabbiError.Code = spec.predicate == nil ? .fetchFailed : .invalidPredicate
        let ids = try await stack.perform { try CoreDataStack.fetch(request.value, in: $0, failure: failure) }
        return ids.compactMap { ObjectRef(uri: $0.uriRepresentation()) }
    }

    /// Reads many objects at once, each by its own entity's layout — how the tracker materialises the primary keys
    /// a scan handed it (§6.6).
    ///
    /// Runs on the tracking context, so materialising and the grid's paging never queue behind each other, in
    /// batches grouped by entity, each batch refreshing whatever Core Data had cached: the values are the ones in
    /// the file now, not the ones an earlier fetch saw.
    ///
    /// A reference the store has no row for is absent from the result rather than an error — that is how the
    /// tracker learns a row it was told about has gone again.
    ///
    /// - Parameters:
    ///   - predicate: evaluated in memory against each object, for the tracked view (TRK-7). A predicate the
    ///     object's entity cannot answer leaves `matchesPredicate` `nil` instead of failing the batch.
    ///   - batchSize: objects per Core Data round trip.
    public func objects(
        _ refs: [ObjectRef],
        matching predicate: PredicateSource? = nil,
        batchSize: Int = 500
    ) async throws -> [ObjectRef: MaterialisedObject] {
        try ensureOpen()
        // Parsed once, here: a predicate Foundation refuses is an error before anything is read.
        let parsed = try predicate.map { Guarded(value: try PredicateGuard.parse($0)) }
        let (converter, generation, size) = (stack.converter, generation, max(1, batchSize))
        var result: [ObjectRef: MaterialisedObject] = [:]
        result.reserveCapacity(refs.count)

        for (entity, group) in Dictionary(grouping: Set(refs), by: \.entity) {
            // An entity this model does not have belongs to another store's model, not to this one.
            guard info.model.entity(named: entity) != nil else { continue }
            let columns = converter.columns(for: entity, includeSubentities: false)
            let ids = group.compactMap { stack.objectID(for: $0) }
            for start in stride(from: 0, to: ids.count, by: size) {
                let batch = Array(ids[start..<min(start + size, ids.count)])
                let materialised = try await stack.performTracking { context in
                    try Self.materialised(
                        batch, entity: entity, columns: columns, predicate: parsed, converter: converter,
                        generation: generation, in: context)
                }
                result.merge(materialised) { first, _ in first }
            }
        }
        return result
    }

    /// One batch, all of one entity. Absent objects are left out; the caller knows which keys it asked for.
    private static func materialised(
        _ ids: [NSManagedObjectID],
        entity: String,
        columns: ColumnSet,
        predicate: Guarded<NSPredicate>?,
        converter: ValueConverter,
        generation: Int,
        in context: NSManagedObjectContext
    ) throws -> [ObjectRef: MaterialisedObject] {
        guard !ids.isEmpty else { return [:] }
        let request = NSFetchRequest<NSManagedObject>(entityName: entity)
        request.predicate = NSPredicate(format: "self IN %@", ids)
        // The keys came from Z_ENT, so every one of them is exactly this entity.
        request.includesSubentities = false
        request.returnsObjectsAsFaults = false
        // The app has saved since these rows were last read; without this Core Data hands back its cached row,
        // which is the very state the change is being measured against.
        request.shouldRefreshRefetchedObjects = true
        request.relationshipKeyPathsForPrefetching = converter.toOneRelationships(in: columns, of: entity)
        let objects = try CoreDataStack.fetch(request, in: context)

        var counts: ValueConverter.ToManyCounts = [:]
        for relationship in converter.batchCountableRelationships(
            in: columns, of: entity, includeSubentities: false)
        {
            // Without the batch the converter counts per row; slower, never wrong.
            counts[relationship.name] = try? CoreDataStack.toManyCounts(relationship, of: objects, in: context)
        }

        var result: [ObjectRef: MaterialisedObject] = [:]
        result.reserveCapacity(objects.count)
        for object in objects {
            guard let row = converter.row(object, columns: columns, counts: counts) else { continue }
            var matches: Bool?
            if let predicate {
                // A predicate written for another entity raises rather than answering; unknown, not false.
                matches = try? objcGuarded("The predicate could not be evaluated.", code: .invalidPredicate) {
                    predicate.value.evaluate(with: object)
                }
            }
            result[row.ref] = MaterialisedObject(
                snapshot: ObjectSnapshot(row: row, columns: columns, generation: generation),
                matchesPredicate: matches)
        }
        return result
    }

    // MARK: Structure

    /// How `entity` is stored: its table, its columns and its indexes as SQLite has them (BRW-8).
    ///
    /// Entities that share a table — everything in one inheritance chain — get the same answer, with `entity`
    /// naming the one that was asked about.
    public func structure(of entity: String) async throws -> TableStructure {
        try ensureOpen()
        guard let map = info.schemaMap.entities[entity] else {
            throw DabbiError(
                .unknownEntity, "The model has no entity named \u{201C}\(entity)\u{201D}.",
                arguments: ["entity": entity])
        }
        let joins = map.relationships.compactMapValues { relationship in
            relationship.storage == .joinTable ? relationship.table : nil
        }
        return try await reader.read { connection in
            var structure = try TableStructure.read(table: map.table, entity: entity, connection: connection)
            structure.joinTables = try joins.mapValues {
                try TableStructure.read(table: $0, entity: entity, connection: connection)
            }
            return structure
        }
    }

    // MARK: Requests

    /// A Foundation or Core Data reference that is not `Sendable`, carried from the actor into one `perform`
    /// closure and touched only inside it.
    private struct Guarded<Value>: @unchecked Sendable {
        let value: Value
    }

    /// `NSFetchRequest` is not `Sendable`; this one is built here and only ever used inside one `perform`.
    private struct Request<Result: NSFetchRequestResult>: @unchecked Sendable {
        let value: NSFetchRequest<Result>
    }

    /// - Parameter window: the rows of the result to fetch, instead of the spec's limit.
    private func fetchRequest<Result: NSFetchRequestResult>(
        for spec: FetchSpec, resultType: Result.Type, window: (offset: Int, limit: Int)? = nil
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
        if let window {
            request.fetchOffset = window.offset
            request.fetchLimit = window.limit
        } else if let limit = spec.limit {
            request.fetchLimit = max(0, limit)
        }
        return Request(value: request)
    }

    func ensureOpen() throws {
        guard !isClosed else { throw DabbiError(.storeClosed, "The store has been closed.") }
    }
}
