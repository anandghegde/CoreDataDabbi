import DabbiBase
import DabbiTestSupport
import FixtureKit
import Foundation
import SQLite3
import Testing

@testable import DabbiStore

private func open(_ fixture: Fixture) async throws -> StoreSession {
    let location = try TestFixtures.location(fixture)
    return try await StoreSession.open(storeURL: location.storeURL, modelURL: location.modelURL)
}

private func snapshot(_ pk: Int64) -> RowSnapshot {
    RowSnapshot(
        ref: ObjectRef(uri: URL(string: "x-coredata://6F0C7A2E-51B0-4E0B-9B70-0D6B1C0E4A11/Sample/p\(pk)")!)!,
        values: [.int(pk)])
}

private func page(_ range: Range<Int>, generation: Int = 0, missing: [Int] = []) -> RowPage {
    RowPage(
        range: range, rows: range.filter { !missing.contains($0) }.map { snapshot(Int64($0)) },
        columns: ColumnSet(["value"]), generation: generation, missing: missing)
}

@Suite struct RowPageTests {
    @Test func positionsSurviveDeletedRows() {
        let whole = page(10..<15)
        #expect(whole.row(at: 12) == snapshot(12))
        #expect(whole.row(at: 9) == nil && whole.row(at: 15) == nil)
        #expect(whole.rowsByPosition == (10..<15).map { snapshot(Int64($0)) })

        let holed = page(10..<15, missing: [10, 13])
        #expect(holed.rows.count == 3)
        #expect(holed.row(at: 10) == nil && holed.row(at: 13) == nil)
        #expect(holed.row(at: 11) == snapshot(11) && holed.row(at: 12) == snapshot(12))
        #expect(holed.row(at: 14) == snapshot(14))
        #expect(holed.rowsByPosition == [nil, snapshot(11), snapshot(12), nil, snapshot(14)])
    }
}

@Suite struct PageCacheTests {
    @Test func leastRecentlyUsedGoesFirst() {
        var cache = PageCache(pageSize: 10, capacity: 3, generation: 0)
        // Lookups and inserts are mutating — a lookup is a use — and `#expect` only takes values.
        let at = { (position: Int) in cache.row(at: position) }
        let insert = { (page: RowPage) in cache.insert(page) }
        for index in 0..<3 { #expect(insert(page(index * 10..<index * 10 + 10))) }
        #expect(cache.cachedPages == [0, 1, 2])

        #expect(at(5) == .row(snapshot(5)))  // page 0 is in use again
        _ = insert(page(30..<40))
        #expect(cache.cachedPages == [2, 0, 3])
        #expect(at(15) == .notLoaded)
        #expect(at(35) == .row(snapshot(35)))
    }

    @Test func tellsDeletedFromNotLoaded() {
        var cache = PageCache(pageSize: 10, capacity: 3, generation: 0)
        // Lookups and inserts are mutating — a lookup is a use — and `#expect` only takes values.
        let at = { (position: Int) in cache.row(at: position) }
        let insert = { (page: RowPage) in cache.insert(page) }
        _ = insert(page(0..<10, missing: [4]))
        #expect(at(4) == .deleted)
        #expect(at(3) == .row(snapshot(3)) && at(5) == .row(snapshot(5)))
        #expect(at(10) == .notLoaded && at(-1) == .notLoaded)
    }

    @Test func refusesWhatDoesNotBelong() {
        var cache = PageCache(pageSize: 10, capacity: 3, generation: 2)
        // Lookups and inserts are mutating — a lookup is a use — and `#expect` only takes values.
        let at = { (position: Int) in cache.row(at: position) }
        let insert = { (page: RowPage) in cache.insert(page) }
        #expect(!insert(page(0..<10, generation: 1)))
        #expect(!insert(page(5..<15, generation: 2)))
        #expect(!insert(page(0..<20, generation: 2)))
        #expect(!insert(page(0..<0, generation: 2)))
        #expect(cache.cachedPages.isEmpty)

        #expect(insert(page(20..<27, generation: 2)))  // the short page a list ends in
        #expect(at(26) == .row(snapshot(26)) && at(27) == .notLoaded)
        cache.reset(generation: 3)
        #expect(at(26) == .notLoaded && insert(page(0..<10, generation: 3)))
    }

    @Test func visiblePagesFirstThenNeighboursNearestFirst() {
        #expect(pagesWanted(visible: 0..<50, count: 10_000, pageSize: 200, prefetch: 2) == [0, 1, 2])
        #expect(pagesWanted(visible: 990..<1_040, count: 10_000, pageSize: 200, prefetch: 2) == [4, 5, 6, 3, 7, 2])
        #expect(pagesWanted(visible: 9_900..<10_000, count: 10_000, pageSize: 200, prefetch: 2) == [49, 48, 47])
        #expect(pagesWanted(visible: 100..<5_000, count: 150, pageSize: 200, prefetch: 2) == [0])
        #expect(pagesWanted(visible: 0..<50, count: 0, pageSize: 200, prefetch: 2).isEmpty)
        #expect(pagesWanted(visible: 0..<50, count: 10_000, pageSize: 200, prefetch: 0) == [0])
    }
}

@Suite struct LoadMoreTests {
    @Test func aLimitedPagerGrowsByItsLimit() async throws {
        let session = try await open(.company)
        let sort = [SortKey(keyPath: "name")]
        let everyone = try await session.openPager(FetchSpec(entity: "Person", sort: sort))
        #expect(everyone.count == 60 && !everyone.hasMore)
        let expected = try await session.page(everyone, range: 0..<60).rows.map(\.ref)

        var pager = try await session.openPager(FetchSpec(entity: "Person", sort: sort, limit: 25))
        #expect(pager.count == 25 && pager.hasMore)
        let first = pager
        pager = try await session.loadMore(pager)
        #expect(pager.id == first.id && pager.count == 50 && pager.hasMore)
        pager = try await session.loadMore(pager)
        #expect(pager.count == 60 && !pager.hasMore)
        #expect(try await session.loadMore(pager) == pager)  // nothing left: nothing happens

        // One list, whichever handle asks — and the same list an unlimited fetch gives.
        #expect(try await session.page(pager, range: 0..<60).rows.map(\.ref) == expected)
        #expect(try await session.page(first, range: 20..<30).rows.map(\.ref) == Array(expected[20..<30]))
        await session.close()
    }

    @Test func aLimitTheStoreDoesNotReachLeavesNothingToLoad() async throws {
        let session = try await open(.company)
        let exact = try await session.openPager(FetchSpec(entity: "Person", limit: 60))
        #expect(exact.count == 60 && !exact.hasMore)
        let generous = try await session.openPager(FetchSpec(entity: "Person", limit: 500))
        #expect(generous.count == 60 && !generous.hasMore)

        let few = try await session.openPager(FetchSpec(entity: "Person", limit: 10))
        let more = try await session.loadMore(few, count: 3)
        #expect(more.count == 13 && more.hasMore)
        await session.close()
    }

    @Test func concurrentRequestsExtendTheListOnce() async throws {
        let session = try await open(.company)
        let pager = try await session.openPager(FetchSpec(entity: "Person", limit: 10))
        async let one = session.loadMore(pager)
        async let two = session.loadMore(pager)
        let counts = try await [one.count, two.count]
        #expect(counts.allSatisfy { $0 == 20 })
        let refs = try await session.page(pager, range: 0..<100).rows.map(\.ref)
        #expect(refs.count == 20 && Set(refs).count == 20)
        await session.close()
    }

    @Test func aHandleTheListHasOutgrownDoesNotExtendItAgain() async throws {
        let session = try await open(.company)
        let pager = try await session.openPager(FetchSpec(entity: "Person", limit: 10))
        let extended = try await session.loadMore(pager)
        #expect(extended.count == 20)
        // The second of two requests made with one handle, arriving after the first is done: the list is as the
        // first left it.
        let again = try await session.loadMore(pager)
        #expect(again.count == 20 && again.hasMore)
        #expect(try await session.loadMore(extended).count == 30)
        await session.close()
    }

    @Test func aStalePagerCannotGrow() async throws {
        let session = try await open(.company)
        let pager = try await session.openPager(FetchSpec(entity: "Person", limit: 10))
        await session.invalidate()
        let error = await #expect(throws: DabbiError.self) { try await session.loadMore(pager) }
        #expect(error?.code == .stalePager)
        await session.close()
    }
}

@Suite struct LazyColumnTests {
    @Test func aPageCarriesOnlyTheColumnsAskedFor() async throws {
        let session = try await open(.company)
        let pager = try await session.openPager(FetchSpec(entity: "Person", sort: [SortKey(keyPath: "name")]))
        let full = try await session.page(pager, range: 0..<60)
        // An attribute, a to-one, a batch-counted to-many and a join-table to-many — not in the pager's order.
        let subset = ColumnSet(["boss", "name", "reports", "tags"])
        let lazy = try await session.page(pager, range: 0..<60, columns: subset)

        #expect(lazy.columns == subset && lazy.rows.count == 60)
        let indices = try subset.properties.map { try #require(full.columns.index(of: $0)) }
        for (lazyRow, fullRow) in zip(lazy.rows, full.rows) {
            #expect(lazyRow.ref == fullRow.ref)
            #expect(lazyRow.values == indices.map { fullRow.values[$0] })
        }
        await session.close()
    }

    @Test func columnsAPartialFetchCannotNameStillRead() async throws {
        // `level` exists on Manager only; the request is for Employee.
        let session = try await open(.company)
        let pager = try await session.openPager(FetchSpec(entity: "Employee", sort: [SortKey(keyPath: "name")]))
        let lazy = try await session.page(pager, range: 0..<pager.count, columns: ColumnSet(["name", "level"]))
        let levels = lazy.rows.filter { $0.values[1] != .null }
        #expect(levels.count == 5 && levels.allSatisfy { $0.values[0].displayString().hasPrefix("Manager") })
        await session.close()

        let composites = try await open(.composites)
        let entity = try #require(composites.info.model.entities.first)
        let composite = try #require(entity.attributes.first { $0.type == .composite })
        let all = try await composites.openPager(FetchSpec(entity: entity.name))
        let full = try await composites.page(all, range: 0..<all.count)
        let only = try await composites.page(all, range: 0..<all.count, columns: ColumnSet([composite.name]))
        let index = try #require(full.columns.index(of: composite.name))
        #expect(only.rows.map { $0.values[0] } == full.rows.map { $0.values[index] })
        await composites.close()
    }

    @Test func whatGoesIntoAPartialFetch() async throws {
        let session = try await open(.company)
        let converter = ValueConverter(model: session.info.model)
        #expect(
            converter.partialFetchProperties(for: ColumnSet(["name", "boss", "tags"]), of: "Person")
                == ["name", "boss"])
        #expect(converter.partialFetchProperties(for: ColumnSet(["name", "level"]), of: "Employee") == nil)
        #expect(converter.partialFetchProperties(for: ColumnSet(["name"]), of: "Nobody") == nil)
        await session.close()
    }

    @Test func anUnknownColumnIsRefused() async throws {
        let session = try await open(.basic)
        let pager = try await session.openPager(FetchSpec(entity: "Sample"))
        let error = await #expect(throws: DabbiError.self) {
            try await session.page(pager, range: 0..<10, columns: ColumnSet(["name", "nope"]))
        }
        #expect(error?.code == .unknownProperty && error?.arguments["property"] == "nope")
        await session.close()
    }
}

@Suite struct DeletedRowTests {
    /// Plays the app deleting rows while the inspector has the store open.
    private func delete(primaryKeys: [Int], from table: String, at url: URL) throws {
        var db: OpaquePointer?
        try #require(sqlite3_open_v2(url.path, &db, SQLITE_OPEN_READWRITE, nil) == SQLITE_OK)
        defer { sqlite3_close_v2(db) }
        let keys = primaryKeys.map(String.init).joined(separator: ",")
        try #require(sqlite3_exec(db, "DELETE FROM \(table) WHERE Z_PK IN (\(keys))", nil, nil, nil) == SQLITE_OK)
    }

    @Test func rowsDeletedUnderAPagerLeaveNamedGaps() async throws {
        let location = try TestFixtures.scratchCopy(.basic)
        let session = try await StoreSession.open(storeURL: location.storeURL)
        let pager = try await session.openPager(FetchSpec(entity: "Sample"))
        try delete(primaryKeys: [3, 11, 12], from: "ZSAMPLE", at: location.storeURL)

        let page = try await session.page(pager, range: 0..<20)
        #expect(page.missing == [2, 10, 11])  // positions, not keys: the list starts at key 1
        #expect(page.rows.count == 17 && page.row(at: 2) == nil)
        #expect(page.row(at: 3)?.ref.pk == 4 && page.row(at: 12)?.ref.pk == 13)
        await session.close()
    }
}

@MainActor
@Suite struct PagedRowsTests {
    /// Collects what a window reports.
    @MainActor final class Log {
        var events: [PagedRows.Event] = []
        var loaded: [Range<Int>] {
            events.compactMap { if case .loaded(let range) = $0 { range } else { nil } }
        }
    }

    private func window(
        _ session: StoreSession, _ spec: FetchSpec, cachedPages: Int = 50
    ) async throws -> (PagedRows, Log) {
        let rows = PagedRows(session: session, handle: try await session.openPager(spec), cachedPages: cachedPages)
        let log = Log()
        rows.onEvent = { log.events.append($0) }
        return (rows, log)
    }

    private func isLoaded(_ rows: PagedRows, _ position: Int) -> Bool {
        if case .row = rows.row(at: position) { true } else { false }
    }

    @Test func readsWhatIsOnScreenFirstThenAround() async throws {
        let session = try await open(.large)
        let (rows, log) = try await window(session, FetchSpec(entity: "Event"))
        #expect(rows.count == LargeFixture.rowCount())
        #expect(rows.row(at: 0) == .notLoaded)

        rows.setVisible(0..<50)
        #expect(rows.isLoading)
        await rows.waitUntilIdle()
        #expect(log.loaded == [0..<200, 200..<400, 400..<600])
        #expect(isLoaded(rows, 0) && isLoaded(rows, 599) && !isLoaded(rows, 600))

        rows.setVisible(10_150..<10_210)  // straddles pages 50 and 51
        await rows.waitUntilIdle()
        #expect(
            log.loaded.dropFirst(3).map(\.lowerBound) == [10_000, 10_200, 10_400, 9_800, 10_600, 9_600])
        if case .row(let row) = rows.row(at: 10_150) {
            #expect(row.ref.pk == 10_151)  // unsorted = primary-key order
        } else {
            Issue.record("row 10,150 should be in memory")
        }

        // Asking again for what is there reads nothing.
        rows.setVisible(10_160..<10_220)
        #expect(!rows.isLoading)
        rows.close()
        await session.close()
    }

    @Test func memoryIsBoundedByTheCacheNotTheList() async throws {
        let session = try await open(.large)
        let (rows, _) = try await window(session, FetchSpec(entity: "Event"), cachedPages: 7)
        for start in stride(from: 0, to: 12_000, by: 3_000) {
            rows.setVisible(start..<start + 40)
            await rows.waitUntilIdle()
        }
        #expect(isLoaded(rows, 9_000) && isLoaded(rows, 9_399))
        #expect(!isLoaded(rows, 0) && !isLoaded(rows, 3_000))
        rows.close()
        await session.close()
    }

    @Test func changingColumnsReadsTheRowsAgain() async throws {
        let session = try await open(.large)
        let (rows, log) = try await window(session, FetchSpec(entity: "Event"))
        rows.setVisible(0..<40)
        await rows.waitUntilIdle()
        guard case .row(let full) = rows.row(at: 7) else {
            Issue.record("row 7 should be in memory")
            return
        }
        #expect(full.values.count == rows.handle.columns.properties.count)

        rows.setColumns(ColumnSet(["name", "source"]))
        #expect(rows.row(at: 7) == .notLoaded)
        await rows.waitUntilIdle()
        #expect(log.loaded.count == 6)
        guard case .row(let lazy) = rows.row(at: 7) else {
            Issue.record("row 7 should be in memory again")
            return
        }
        #expect(lazy.ref == full.ref)
        #expect(lazy.values.count == 2 && lazy.values[0].displayString().hasPrefix("Event "))
        if case .toOne(let ref, let display) = lazy.values[1] {
            #expect(ref?.entity == "Source" && display?.hasPrefix("Source ") == true)
        } else {
            Issue.record("source should be a to-one")
        }
        rows.close()
        await session.close()
    }

    @Test func loadMoreExtendsTheWindow() async throws {
        let session = try await open(.large)
        let (rows, _) = try await window(session, FetchSpec(entity: "Event", limit: 300))
        #expect(rows.count == 300 && rows.hasMore)
        rows.setVisible(260..<300)
        await rows.waitUntilIdle()
        #expect(isLoaded(rows, 299))

        let added = try await rows.loadMore()
        #expect(added == 300..<600 && rows.count == 600 && rows.hasMore)
        rows.setVisible(280..<320)
        await rows.waitUntilIdle()
        // Page 1 ended at row 299 when it was first read; it has to have been read again.
        #expect(isLoaded(rows, 299) && isLoaded(rows, 300) && isLoaded(rows, 399))
        rows.close()
        await session.close()
    }

    @Test func aStaleListIsReportedAndReplaced() async throws {
        let session = try await open(.large)
        let (rows, log) = try await window(session, FetchSpec(entity: "Event"))
        await session.invalidate()
        rows.setVisible(0..<40)
        await rows.waitUntilIdle()
        #expect(log.events.count == 1)
        if case .failed(let error) = log.events.first {
            #expect(error.code == .stalePager)
        } else {
            Issue.record("expected a failure")
        }

        rows.replace(handle: try await session.openPager(FetchSpec(entity: "Event")))
        await rows.waitUntilIdle()
        #expect(isLoaded(rows, 0))
        rows.close()
        await session.close()
    }

    /// What the front end hands the tracker so that the first change to a row on screen reads as before → after
    /// (ARCHITECTURE.md §6.6, TRK-2).
    @Test func handsOverThePagesItHasWithoutReadingAnyMore() async throws {
        let session = try await open(.large)
        let (rows, log) = try await window(session, FetchSpec(entity: "Event"), cachedPages: 7)
        #expect(rows.loadedPages().isEmpty, "nothing has been read, so there is nothing to hand over")

        rows.setVisible(0..<50)
        await rows.waitUntilIdle()
        let pages = rows.loadedPages()
        #expect(pages.map(\.range) == [0..<200, 200..<400, 400..<600])
        #expect(pages.allSatisfy { $0.rows.count == 200 && $0.missing.isEmpty })
        #expect(pages[0].columns == rows.handle.columns)
        #expect(pages[0].generation == rows.handle.generation)
        #expect(pages[0].row(at: 7)?.ref.pk == 8)

        // A walk over what is in memory: nothing is fetched, and nothing is evicted to make room for the walk.
        let events = log.events.count
        #expect(rows.loadedPages().map(\.range) == pages.map(\.range))
        #expect(!rows.isLoading)
        #expect(log.events.count == events)

        // The rows are handed over as the grid is reading them — a narrowed column set included, or the tracker
        // would diff values against columns nobody read.
        rows.setColumns(ColumnSet(["name"]))
        await rows.waitUntilIdle()
        #expect(rows.loadedPages().allSatisfy { $0.columns == ColumnSet(["name"]) })
        rows.close()
        await session.close()
    }
}
