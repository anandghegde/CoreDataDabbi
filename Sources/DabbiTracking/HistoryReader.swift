import DabbiBase
import DabbiModel
import DabbiStore
import Foundation

/// Which of the two ways of reading a store's persistent history a reader uses (ARCHITECTURE.md §6.6).
public enum HistorySource: String, Sendable, Hashable, Codable, CaseIterable, CustomStringConvertible {
    /// `NSPersistentHistoryChangeRequest`, through the store session. Preferred: Apple maintains it, and it
    /// resolves entity names, property names and tombstones without this engine knowing how they are stored.
    case coreData
    /// `ATRANSACTION`, `ACHANGE` and `ATRANSACTIONSTRING`, read as tables. The fallback for a store the public
    /// API will not answer for — and the one thing that keeps history working if a future Core Data refuses a
    /// read-only history fetch again.
    case rawTables

    public var description: String {
        switch self {
        case .coreData: "Core Data's history API"
        case .rawTables: "the store's history tables"
        }
    }
}

/// Reads a store's persistent history: who saved, when, and which rows and properties they touched (TRK-10).
///
/// History is *enrichment*, never evidence. `ChangeScanner` stays the one answer to which rows changed, because
/// a store can carry history tables and still be written by a process that saves with tracking off — those saves
/// reach the file and never reach `ATRANSACTION`. A history-first tracker would miss them silently, which is the
/// one thing ADR-17 rules out. What history adds is everything the scan cannot get at any price: the author, the
/// context, the save time, and the names of the properties a save wrote to a row nobody had read before.
public protocol HistoryReader: Sendable {
    var source: HistorySource { get }

    /// Where the store's history stands now, for a caller that wants only what happens next.
    func currentToken() async throws -> HistoryToken?

    /// Transactions newer than `token`, oldest first.
    ///
    /// - Parameters:
    ///   - token: `nil` reads everything the store still holds.
    ///   - limit: at most this many, keeping the newest.
    func transactions(after token: HistoryToken?, limit: Int?) async throws -> [HistoryTransaction]

    /// Releases whatever the reader opened of its own.
    func close() async
}

extension HistoryReader {
    public func transactions(after token: HistoryToken?) async throws -> [HistoryTransaction] {
        try await transactions(after: token, limit: nil)
    }
}

/// History through `NSPersistentHistoryChangeRequest`, by way of the store session that already has the
/// coordinator open (see `StoreHistory.swift` in `DabbiStore`).
///
/// A thin adapter on purpose: everything that touches Core Data lives behind the session's API, so nothing here
/// holds a managed object or a token object (ADR-02, ADR-03).
public struct CoreDataHistoryReader: HistoryReader {
    public let source = HistorySource.coreData
    private let session: StoreSession

    /// - Parameter session: the store to read. It is not closed by `close()` — it belongs to whoever opened it.
    public init(session: StoreSession) {
        self.session = session
    }

    public func currentToken() async throws -> HistoryToken? {
        try await session.currentHistoryToken()
    }

    public func transactions(after token: HistoryToken?, limit: Int?) async throws -> [HistoryTransaction] {
        try await session.historyTransactions(after: token, limit: limit)
    }

    public func close() async {}
}

/// Chooses a history reader for a store, and proves the choice before handing it over.
public enum HistoryReaders {
    /// Opens the best reader the store will answer for, or `nil` when it records no history at all.
    ///
    /// The choice is *proved*, not assumed: each candidate is asked for the store's current token, and one that
    /// cannot answer is closed and passed over. That is what makes the fallback worth having — the failure mode
    /// it guards against (a Core Data that stops answering history fetches on a read-only store, as spike S7
    /// found it does without `NSPersistentHistoryTrackingKey`) shows up exactly here, at the first question.
    ///
    /// - Parameter source: tried first. The other is tried after it.
    public static func open(
        for session: StoreSession, preferring source: HistorySource = .coreData
    ) async -> (any HistoryReader)? {
        guard session.tracksHistory else { return nil }
        let order: [HistorySource] = source == .rawTables ? [.rawTables, .coreData] : [.coreData, .rawTables]
        for candidate in order {
            let reader = make(candidate, for: session)
            if (try? await reader.currentToken()) != nil { return reader }
            await reader.close()
        }
        return nil
    }

    private static func make(_ source: HistorySource, for session: StoreSession) -> any HistoryReader {
        switch source {
        case .coreData:
            CoreDataHistoryReader(session: session)
        case .rawTables:
            RawHistoryReader(
                url: session.info.url, model: session.info.model, schema: session.info.schemaMap)
        }
    }
}
