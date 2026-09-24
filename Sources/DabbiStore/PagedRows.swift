import DabbiBase
import Foundation

/// A scrolling window onto one pager: the rows near where the user is looking, kept in memory and read ahead
/// (BRW-11, ARCHITECTURE.md §6.4).
///
/// This is the engine half of the grid's data source. A table view asks for a cell's value synchronously, on the
/// main thread, and must never wait for the store — so `row(at:)` answers from memory, `.notLoaded` included,
/// and `setVisible(_:)` decides what to read next. It is main-actor bound because its one consumer is; the CLI
/// and the MCP server call `StoreSession.page` directly.
///
/// Reads go to the session one page at a time. The session runs them one after another anyway, and a single
/// request in flight means a fast scrub through a million rows leaves one stale page behind, not a queue of them.
@MainActor
public final class PagedRows {
    public enum Event: Sendable, Hashable {
        /// Rows at these positions can now be read with `row(at:)`.
        case loaded(Range<Int>)
        /// Loading stopped. `.stalePager` means the list itself is out of date: open a new pager.
        case failed(DabbiError)
    }

    public let session: StoreSession
    public private(set) var handle: PagerHandle
    /// The columns rows are read with; `nil` = all of the pager's. See `setColumns(_:)`.
    public private(set) var columns: ColumnSet?
    /// Pages read ahead of, and behind, the visible ones.
    public let prefetchPages: Int
    /// Called on the main actor.
    public var onEvent: ((Event) -> Void)?

    private var cache: PageCache
    private var visible: Range<Int> = 0..<0
    private var wanted: [Int] = []
    private var loader: Task<Void, Never>?
    /// Which loader `loader` is: one that was cancelled must not clear its successor on the way out.
    private var loaderID = 0
    /// Bumped whenever what a page would contain changes; a read that started before is thrown away.
    private var epoch = 0

    public init(
        session: StoreSession, handle: PagerHandle, columns: ColumnSet? = nil,
        pageSize: Int = StoreSession.pageSize, cachedPages: Int = 50, prefetchPages: Int = 2
    ) {
        self.session = session
        self.handle = handle
        self.columns = columns
        self.prefetchPages = max(0, prefetchPages)
        // The visible pages and their neighbours must all fit, or loading one would evict another for ever.
        cache = PageCache(
            pageSize: pageSize, capacity: max(cachedPages, 2 * prefetchPages + 3), generation: handle.generation)
    }

    /// The number of rows in the list — the table's row count.
    public var count: Int { handle.count }
    public var hasMore: Bool { handle.hasMore }
    public var isLoading: Bool { loader != nil }

    /// The row at `position`, if it is in memory. Never touches the store.
    public func row(at position: Int) -> CachedRow {
        cache.row(at: position)
    }

    /// Tells the window what is on screen. Pages there are read first, then their neighbours; pages that have
    /// fallen out of interest and are not yet being read never will be.
    public func setVisible(_ range: Range<Int>) {
        visible = range
        wanted = pagesWanted(
            visible: range, count: handle.count, pageSize: cache.pageSize, prefetch: prefetchPages)
        startLoading()
    }

    /// Changes which columns are read — a column was shown, hidden, or lazy loading switched. Rows in memory
    /// were read with the old set, so they go.
    public func setColumns(_ columns: ColumnSet?) {
        guard columns != self.columns else { return }
        self.columns = columns
        invalidateRows()
    }

    /// “Load more”: extends a list its fetch limit cut short. Returns the positions added.
    @discardableResult
    public func loadMore(count: Int? = nil) async throws -> Range<Int> {
        let before = handle.count
        let extended = try await session.loadMore(handle, count: count)
        guard extended.id == handle.id, extended.count >= before else { return before..<before }
        handle = extended
        // The page the list used to end in was cut short there; it has to be read again to get its new rows.
        // Likewise a read of it that is under way.
        if before % cache.pageSize != 0 {
            epoch += 1
            cache.remove(page: cache.pageIndex(of: before))
        }
        setVisible(visible)
        return before..<extended.count
    }

    /// Reads the rows in memory again, from the same pager: an edit was staged, undone or discarded, and the
    /// values held were read before it. The list itself is the pager's and stays as it is.
    public func reload() {
        invalidateRows()
    }

    /// Moves the window to another pager — after a new fetch, or a new generation. Nothing is kept.
    public func replace(handle: PagerHandle) {
        let old = self.handle
        self.handle = handle
        invalidateRows()
        if old.id != handle.id { Task { [session] in await session.closePager(old) } }
    }

    /// Stops loading and releases the pager's list in the session.
    public func close() {
        epoch += 1
        wanted.removeAll()
        loader?.cancel()
        loader = nil
        Task { [session, handle] in await session.closePager(handle) }
    }

    /// The pages that are in memory — what the front end hands the tracker so that a change to a row the user
    /// is already looking at can be shown as *before -> after* (ARCHITECTURE.md 6.6, TRK-2).
    ///
    /// Nothing is fetched and nothing is waited for: a page here is one that has already been read. The cache
    /// is not rearranged by the walk either, so asking costs no eviction.
    public func loadedPages() -> [RowPage] {
        let columns = self.columns ?? handle.columns
        return cache.cachedPages.sorted().compactMap { index in
            guard let held = cache.rows(ofPage: index) else { return nil }
            let range = cache.range(ofPage: index, count: handle.count)
            guard !range.isEmpty else { return nil }
            var rows: [RowSnapshot] = []
            var missing: [Int] = []
            // A page read before `loadMore` extended the list can be shorter than the range it now covers; the
            // positions past its end are simply not part of the page.
            for offset in 0..<min(range.count, held.count) {
                if let row = held[offset] {
                    rows.append(row)
                } else {
                    missing.append(range.lowerBound + offset)
                }
            }
            let covered = range.lowerBound..<(range.lowerBound + min(range.count, held.count))
            return RowPage(
                range: covered, rows: rows, columns: columns, generation: handle.generation, missing: missing)
        }
    }

    /// Returns once nothing is left to load. For tests and command-line callers; a grid listens to `onEvent`.
    public func waitUntilIdle() async {
        while let loader { await loader.value }
    }

    private func invalidateRows() {
        epoch += 1
        cache.reset(generation: handle.generation)
        setVisible(visible)
    }

    private func startLoading() {
        guard loader == nil, wanted.contains(where: { !cache.contains(page: $0) }) else { return }
        loaderID += 1
        loader = Task { [weak self, loaderID] in await self?.load(loaderID) }
    }

    private func load(_ id: Int) async {
        defer { if id == loaderID { loader = nil } }
        while !Task.isCancelled, let index = wanted.first(where: { !cache.contains(page: $0) }) {
            let range = cache.range(ofPage: index, count: handle.count)
            let epoch = epoch
            do {
                let page = try await session.page(handle, range: range, columns: columns)
                // Columns or pager changed while the store was being read: not the page anybody wants now.
                guard epoch == self.epoch else { continue }
                // A page the cache refuses would be asked for again and again.
                guard cache.insert(page) else {
                    wanted.removeAll { $0 == index }
                    continue
                }
                onEvent?(.loaded(page.range))
            } catch {
                guard epoch == self.epoch else { continue }
                wanted.removeAll()
                onEvent?(
                    .failed(
                        error as? DabbiError
                            ?? DabbiError(.fetchFailed, "The rows could not be read.", underlying: error)))
            }
        }
    }
}
