import DabbiBase
import DabbiStore
import DabbiTestSupport
import FixtureKit
import Foundation
import Testing

/// The performance baselines of PRD §10, on the `large` fixture. Off in an ordinary test run: they want a
/// million rows and a release build, which is what `Scripts/perf.sh` gives them.
///
/// The budgets are the PRD's targets with room for a slow CI machine, not measurements; what a run measured is
/// printed, and written to `DABBI_PERF_OUTPUT` when that names a file.
@Suite(.enabled(if: ProcessInfo.processInfo.environment["DABBI_PERF"] != nil), .serialized)
struct PagerPerformanceTests {
    private static let clock = ContinuousClock()

    /// A fixture generated ahead of time (`DABBI_FIXTURES`) is used when it has the rows asked for: writing a
    /// million objects takes longer than everything measured here together.
    private static func largeFixture() throws -> FixtureLocation {
        let environment = ProcessInfo.processInfo.environment
        if let root = environment["DABBI_FIXTURES"],
            let existing = FixtureBuilder.existing(.large, in: URL(fileURLWithPath: root, isDirectory: true)),
            existing.manifest.entityCounts["Event"] == LargeFixture.rowCount()
        {
            return existing
        }
        return try TestFixtures.location(.large)
    }

    private static func milliseconds(_ duration: Duration) -> Double {
        let parts = duration.components
        return Double(parts.seconds) * 1000 + Double(parts.attoseconds) / 1e15
    }

    private static func median(_ samples: [Double]) -> Double {
        let sorted = samples.sorted()
        return sorted.isEmpty ? 0 : sorted[sorted.count / 2]
    }

    @Test func baselines() async throws {
        let location = try Self.largeFixture()
        let rows = try #require(location.manifest.entityCounts["Event"])
        var results: [String: Double] = ["rows": Double(rows)]

        // Measured warm. Straight after the fixture is written its pages are not in the file cache yet, and the
        // first walk over them times the disk, not this code.
        let warmUp = try await StoreSession.open(storeURL: location.storeURL)
        _ = try await warmUp.openPager(FetchSpec(entity: "Event"))
        await warmUp.close()
        var firstRows: RowPage?
        var session: StoreSession?

        // Open to first rows: what the user waits for after choosing a store.
        results["openToFirstRows"] = Self.milliseconds(
            try await Self.clock.measure {
                let opened = try await StoreSession.open(storeURL: location.storeURL)
                let pager = try await opened.openPager(FetchSpec(entity: "Event"))
                firstRows = try await opened.page(pager, range: 0..<StoreSession.pageSize)
                await opened.closePager(pager)
                session = opened
            })
        #expect(firstRows?.rows.count == min(rows, StoreSession.pageSize))
        let store = try #require(session)

        var unsorted: PagerHandle?
        results["openPagerUnsorted"] = Self.milliseconds(
            try await Self.clock.measure { unsorted = try await store.openPager(FetchSpec(entity: "Event")) })
        let pager = try #require(unsorted)
        #expect(pager.count == rows)

        results["openPagerSortedUnindexed"] = Self.milliseconds(
            try await Self.clock.measure {
                let sorted = try await store.openPager(
                    FetchSpec(entity: "Event", sort: [SortKey(keyPath: "timestamp", ascending: false)]))
                await store.closePager(sorted)
            })

        results["openPagerFiltered"] = Self.milliseconds(
            try await Self.clock.measure {
                let filtered = try await store.openPager(
                    FetchSpec(entity: "Event", predicate: PredicateSource(format: "kind == 'crash' AND code > 50000")))
                await store.closePager(filtered)
            })

        // Pages from all over the list, as a scrub through the scroll bar asks for them.
        var random = SystemRandomNumberGenerator()
        let lastPage = max(0, (rows - 1) / StoreSession.pageSize)
        var full: [Double] = []
        var lazy: [Double] = []
        let few = ColumnSet(["name", "kind", "timestamp"])
        for _ in 0..<40 {
            let start = Int.random(in: 0...lastPage, using: &random) * StoreSession.pageSize
            let range = start..<start + StoreSession.pageSize
            full.append(
                Self.milliseconds(try await Self.clock.measure { _ = try await store.page(pager, range: range) }))
            lazy.append(
                Self.milliseconds(
                    try await Self.clock.measure { _ = try await store.page(pager, range: range, columns: few) }))
        }
        results["pageMedian"] = Self.median(full)
        results["pageWorst"] = full.max() ?? 0
        results["lazyPageMedian"] = Self.median(lazy)
        await store.close()

        for (name, value) in results.sorted(by: { $0.key < $1.key }) {
            print("PERF \(name): \(String(format: "%.1f", value))")
        }
        if let output = ProcessInfo.processInfo.environment["DABBI_PERF_OUTPUT"] {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            try encoder.encode(results).write(to: URL(fileURLWithPath: output))
        }

        // PRD §10: first rows of a 100 MB store in under a second. A page has to arrive well inside the time
        // the two pages read ahead buy at scrolling speed.
        #expect(try #require(results["openToFirstRows"]) < 1_000)
        #expect(try #require(results["openPagerUnsorted"]) < 1_000)
        #expect(try #require(results["openPagerSortedUnindexed"]) < 3_000)
        #expect(try #require(results["pageMedian"]) < 50)
        #expect(try #require(results["lazyPageMedian"]) < 50)
    }
}
