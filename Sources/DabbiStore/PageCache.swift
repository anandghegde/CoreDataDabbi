import DabbiBase
import Foundation

/// What a front end knows about one position of a pager's list.
public enum CachedRow: Sendable, Hashable {
    /// The page holding the position has not been read, or has been dropped again.
    case notLoaded
    /// The page has been read, and the object was gone by then.
    case deleted
    case row(RowSnapshot)
}

/// A bounded store of pages, least recently used out first (ARCHITECTURE.md §6.4).
///
/// Pure bookkeeping — it fetches nothing. A million-row list is 5,000 pages; the cache keeps the fifty the user
/// was last near, so memory depends on the window, not on the store.
public struct PageCache: Sendable {
    public let pageSize: Int
    /// The number of pages kept.
    public let capacity: Int
    /// Pages of any other generation are refused: their positions mean something else.
    public private(set) var generation: Int

    private var pages: [Int: [RowSnapshot?]] = [:]
    /// Page indices, least recently used first. Fifty entries: an array beats anything cleverer.
    private var recency: [Int] = []

    public init(pageSize: Int = StoreSession.pageSize, capacity: Int = 50, generation: Int) {
        self.pageSize = max(1, pageSize)
        self.capacity = max(1, capacity)
        self.generation = generation
    }

    public var cachedPages: [Int] { recency }

    public func pageIndex(of position: Int) -> Int { position / pageSize }

    /// The positions page `index` covers in a list of `count` rows.
    public func range(ofPage index: Int, count: Int) -> Range<Int> {
        (index * pageSize..<(index + 1) * pageSize).clamped(to: 0..<max(0, count))
    }

    public func contains(page index: Int) -> Bool { pages[index] != nil }

    /// The rows of a cached page in position order, `nil` where the object was gone when the page was read.
    /// `nil` altogether when the page is not held.
    ///
    /// Unlike `row(at:)` this does not count as use, so walking everything in memory does not rearrange the
    /// queue. It is how the front end hands the tracker the rows it has already read (ARCHITECTURE.md 6.6).
    public func rows(ofPage index: Int) -> [RowSnapshot?]? { pages[index] }

    /// Looking a row up counts as using its page.
    public mutating func row(at position: Int) -> CachedRow {
        let index = pageIndex(of: position)
        guard position >= 0, let page = pages[index] else { return .notLoaded }
        touch(index)
        let offset = position - index * pageSize
        // A page cut at the end of a list that `loadMore` has since extended is shorter than the list there.
        guard page.indices.contains(offset) else { return .notLoaded }
        return page[offset].map(CachedRow.row) ?? .deleted
    }

    /// Stores a page. Returns `false`, storing nothing, when the page is of another generation or does not start
    /// on a page boundary.
    @discardableResult
    public mutating func insert(_ page: RowPage) -> Bool {
        guard page.generation == generation, page.range.lowerBound % pageSize == 0, !page.range.isEmpty,
            page.range.count <= pageSize
        else { return false }
        let index = pageIndex(of: page.range.lowerBound)
        pages[index] = page.rowsByPosition
        touch(index)
        while recency.count > capacity {
            pages[recency.removeFirst()] = nil
        }
        return true
    }

    public mutating func remove(page index: Int) {
        guard pages.removeValue(forKey: index) != nil else { return }
        recency.removeAll { $0 == index }
    }

    /// Empties the cache and moves it to `generation`.
    public mutating func reset(generation: Int) {
        self.generation = generation
        pages.removeAll()
        recency.removeAll()
    }

    private mutating func touch(_ index: Int) {
        // A grid asks for every cell of a row, and the rows of a page, in a run: nearly always a no-op.
        guard recency.last != index else { return }
        recency.removeAll { $0 == index }
        recency.append(index)
    }
}

/// The pages to have in memory for a visible range: those on screen first, then the `prefetch` pages on either
/// side, nearest first — the order they should be loaded in.
public func pagesWanted(visible: Range<Int>, count: Int, pageSize: Int, prefetch: Int) -> [Int] {
    let visible = visible.clamped(to: 0..<max(0, count))
    guard !visible.isEmpty, pageSize > 0 else { return [] }
    let lastPage = (count - 1) / pageSize
    let first = visible.lowerBound / pageSize
    let last = (visible.upperBound - 1) / pageSize
    var wanted = Array(first...last)
    for distance in stride(from: 1, through: max(0, prefetch), by: 1) {
        // Ahead before behind: people mostly scroll down.
        if last + distance <= lastPage { wanted.append(last + distance) }
        if first - distance >= 0 { wanted.append(first - distance) }
    }
    return wanted
}
