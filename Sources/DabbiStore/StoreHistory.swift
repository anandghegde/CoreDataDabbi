@preconcurrency import CoreData
import DabbiBase
import DabbiModel
import DabbiSQLite
import Foundation

// Persistent history through the public Core Data API (ARCHITECTURE.md §6.6, TRK-10).
//
// This is the preferred of the two readers `DabbiTracking` chooses between, because it is the one Apple
// maintains: it resolves entity names, property names and tombstones itself, and it survives a change to the
// private table layout that would silently defeat the raw reader.
//
// What it costs is an option at open time — `NSPersistentHistoryTrackingKey`, which spike S7 showed is required
// even read-only and which is why `CoreDataStack` takes `tracksHistory`.
//
// Everything here returns `Sendable` values; no `NSPersistentHistoryTransaction` leaves a `perform` (ADR-02).
extension StoreSession {
    /// Whether this store records persistent history at all — whether anything below will answer.
    ///
    /// Read off the format probe, so it is the presence of the `ATRANSACTION` and `ACHANGE` tables and not a
    /// promise that they hold anything: an app can carry history tables and still save with tracking off.
    public nonisolated var tracksHistory: Bool { info.probe.hasHistory }

    /// The token standing for everything the store has recorded up to now.
    ///
    /// What a tracker takes at start-up so that its first batch reports only what happened *while it was
    /// watching*. Nothing older is ever fetched, which is also what keeps the first fetch cheap on a store with
    /// a long history.
    ///
    /// Returns `nil` when the coordinator will not give a token for the store, which leaves the caller with
    /// `HistoryToken.beginning` and a decision to make about how far back it wants to go.
    public func currentHistoryToken() async throws -> HistoryToken? {
        try ensureHistory()
        // The number and the opaque token come from different places because neither source has both: the
        // coordinator's token is opaque, and `ATRANSACTION.Z_PK` is the only place the number is written down.
        let number = try await latestTransactionNumber()
        guard let opaque = stack.currentHistoryTokenData() else {
            return number.map { HistoryToken(transactionNumber: $0) }
        }
        return HistoryToken(transactionNumber: number ?? 0, opaque: opaque)
    }

    /// Every transaction newer than `token`, oldest first.
    ///
    /// - Parameters:
    ///   - token: where to carry on from. `nil` or `.beginning` reads the whole history the store still holds.
    ///   - limit: at most this many transactions, keeping the *newest*. Applied here rather than by SQLite:
    ///     Core Data ignores `fetchLimit` on a history fetch request (it honours predicates and sorting, but
    ///     not the limit), so the rows are read either way and this only bounds what is converted and returned.
    public func historyTransactions(
        after token: HistoryToken? = nil, limit: Int? = nil
    ) async throws
        -> [HistoryTransaction]
    {
        try ensureHistory()
        if let limit, limit <= 0 { return [] }
        let (converter, model) = (stack.converter, info.model)
        let floor = token?.transactionNumber ?? 0
        let opaque = token?.opaque

        var transactions = try await stack.performTracking { context in
            let request = Self.historyRequest(after: opaque, in: context)
            let raw = try Self.execute(request, in: context)
            return raw.compactMap { transaction -> HistoryTransaction? in
                // The in-memory floor matters only when the token had no unarchivable opaque half — a token
                // minted by the raw reader, or one this version of Core Data would not take back.
                guard transaction.transactionNumber > floor else { return nil }
                return HistoryTransaction(transaction, model: model, converter: converter)
            }
        }
        if let limit, transactions.count > limit {
            transactions.removeFirst(transactions.count - limit)
        }
        return transactions
    }

    /// Everything history records about one row: the store's own answer to "what happened to this object"
    /// (§7.4 timeline).
    ///
    /// Each returned transaction carries only the changes to `ref`, so a transaction that touched a thousand
    /// rows still arrives as one change.
    ///
    /// A row the store has since deleted still appears — that is the point. Its last change carries the
    /// tombstone, the only values left of it.
    public func history(of ref: ObjectRef, limit: Int? = nil) async throws -> [HistoryTransaction] {
        try ensureHistory()
        if let limit, limit <= 0 { return [] }
        guard let objectID = stack.objectID(for: ref) else { return [] }
        let (converter, model) = (stack.converter, info.model)

        var transactions = try await stack.performTracking { context in
            let request = Self.historyRequest(after: nil, in: context)
            // Scoping by change rather than by transaction: Core Data then returns the transactions that touched
            // the row, each holding only the changes that did. `.changesOnly` would be the obvious alternative
            // and is the wrong one — it drops the `transaction` back-reference, and with it the author and the
            // timestamp, which are the whole reason a timeline is worth showing.
            if let entity = NSPersistentHistoryChange.entityDescription(with: context) {
                let fetch = NSFetchRequest<NSFetchRequestResult>()
                fetch.entity = entity
                fetch.predicate = NSPredicate(format: "changedObjectID == %@", objectID)
                request.fetchRequest = fetch
            }
            let raw = try Self.execute(request, in: context)
            return raw.map { HistoryTransaction($0, model: model, converter: converter) }
        }
        if let limit, transactions.count > limit {
            transactions.removeFirst(transactions.count - limit)
        }
        return transactions
    }

    // MARK: Plumbing

    private func ensureHistory() throws {
        try ensureOpen()
        guard tracksHistory, stack.tracksHistory else {
            throw DabbiError(
                .historyUnavailable, "This store does not record persistent history.",
                arguments: ["path": info.url.path],
                diagnosis: ["The file has no ATRANSACTION or ACHANGE table, so nothing was ever recorded."],
                recovery: [
                    "Persistent history is switched on by the app that owns the store "
                        + "(NSPersistentHistoryTrackingKey); it cannot be switched on from outside.",
                    "Changes are still detected by scanning, and still reported — without an author or a "
                        + "save time.",
                ])
        }
    }

    /// The newest transaction the file holds, straight out of SQLite.
    ///
    /// Core Data has no cheap equivalent: `transactionNumber` is not a queryable key path on the history
    /// transaction entity, so asking it this way would mean fetching every transaction to look at the last one.
    private func latestTransactionNumber() async throws -> Int64? {
        try? await reader.read { connection in
            try connection.scalar("SELECT MAX(Z_PK) FROM ATRANSACTION")?.int64
        }
    }

    private static func historyRequest(
        after opaque: Data?, in context: NSManagedObjectContext
    ) -> NSPersistentHistoryChangeRequest {
        let request: NSPersistentHistoryChangeRequest
        if let opaque, let token = Self.token(from: opaque) {
            request = NSPersistentHistoryChangeRequest.fetchHistory(after: token)
        } else {
            request = NSPersistentHistoryChangeRequest.fetchHistory(after: Date.distantPast)
        }
        request.resultType = .transactionsAndChanges
        return request
    }

    private static func token(from data: Data) -> NSPersistentHistoryToken? {
        try? NSKeyedUnarchiver.unarchivedObject(ofClass: NSPersistentHistoryToken.self, from: data)
    }

    /// Runs the request inside the exception bridge: a store that was opened without the history option raises
    /// through Objective-C rather than returning an error.
    private static func execute(
        _ request: NSPersistentHistoryChangeRequest, in context: NSManagedObjectContext
    ) throws -> [NSPersistentHistoryTransaction] {
        do {
            let result = try objcGuarded("Core Data rejected the history fetch.", code: .historyUnavailable) {
                try context.execute(request) as? NSPersistentHistoryResult
            }
            return result?.result as? [NSPersistentHistoryTransaction] ?? []
        } catch let error as DabbiError {
            throw error
        } catch {
            throw DabbiError(
                .historyUnavailable, "The store's persistent history could not be read.",
                diagnosis: ["Core Data refused the history fetch."],
                recovery: ["Changes are still detected by scanning, and still reported."],
                underlying: error)
        }
    }
}

// MARK: Conversion

extension HistoryTransaction {
    /// One Core Data transaction as values. Called inside `perform`; nothing it captures escapes.
    fileprivate init(
        _ transaction: NSPersistentHistoryTransaction, model: ModelDescription, converter: ValueConverter
    ) {
        // Archived here, while the object is still alive, so that the caller can hand this exact point back to
        // a later fetch. Failing to archive it is survivable: the transaction number alone still locates it.
        let opaque = try? NSKeyedArchiver.archivedData(
            withRootObject: transaction.token, requiringSecureCoding: true)
        self.init(
            number: transaction.transactionNumber,
            token: HistoryToken(transactionNumber: transaction.transactionNumber, opaque: opaque),
            timestamp: transaction.timestamp,
            author: transaction.author.flatMap { $0.isEmpty ? nil : $0 },
            contextName: transaction.contextName.flatMap { $0.isEmpty ? nil : $0 },
            // Non-optional in Core Data and empty in practice on a store written by a process that set nothing.
            bundleID: transaction.bundleID.isEmpty ? nil : transaction.bundleID,
            processID: transaction.processID.isEmpty ? nil : transaction.processID,
            changes: (transaction.changes ?? []).compactMap {
                HistoryChange($0, model: model, converter: converter)
            })
    }
}

extension HistoryChange {
    fileprivate init?(
        _ change: NSPersistentHistoryChange, model: ModelDescription, converter: ValueConverter
    ) {
        // A change whose object ID will not parse is a row of a store this session is not looking at.
        guard let ref = ObjectRef(uri: change.changedObjectID.uriRepresentation()) else { return nil }
        let kind: Kind =
            switch change.changeType {
            case .insert: .inserted
            case .update: .updated
            case .delete: .deleted
            @unknown default: .updated
            }

        // Only an update has property names to give; on an insert every property is new and on a delete the
        // tombstone is what is left. Empty is not the same as unknown, so an update that names nothing stays
        // `nil` (ADR-17).
        var updated: Set<String>?
        if kind == .updated, let properties = change.updatedProperties, !properties.isEmpty {
            updated = Set(properties.map(\.name))
        }

        var tombstone: [String: Value] = [:]
        if let raw = change.tombstone, let entity = model.entity(named: ref.entity) {
            for (key, value) in raw {
                guard let name = key as? String, let attribute = entity.attribute(named: name) else { continue }
                tombstone[name] = converter.value(value, of: attribute)
            }
        }
        self.init(entity: ref.entity, pk: ref.pk, kind: kind, updatedProperties: updated, tombstone: tombstone)
    }
}
