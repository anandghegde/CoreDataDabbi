import AppKit
import DabbiKit
import FixtureKit
import Testing

@testable import CoreDataDabbi

/// M1's exit criterion, measured through the app rather than through the engine (PRD §10, spike S5): a big
/// store opens in under a second, and scrolling a million rows builds a screenful of cells well inside a
/// 60 fps frame.
///
/// Off in an ordinary test run — it wants the million-row fixture, which is written once by `Scripts/perf.sh`
/// and found through `DABBI_FIXTURES`. What a run measured is printed either way; the budgets have room for a
/// slow machine, because they are targets, not measurements.
@MainActor
@Suite(.enabled(if: ProcessInfo.processInfo.environment["DABBI_PERF"] != nil), .serialized)
struct GridPerformanceTests {
    private static let clock = ContinuousClock()

    private static func milliseconds(_ duration: Duration) -> Double {
        let parts = duration.components
        return Double(parts.seconds) * 1000 + Double(parts.attoseconds) / 1e15
    }

    private static func median(_ samples: [Double]) -> Double {
        let sorted = samples.sorted()
        return sorted.isEmpty ? 0 : sorted[sorted.count / 2]
    }

    /// Waits for what the user waits for: the store open, the grid's first page in, and the rows on screen
    /// drawn. Polled rather than awaited once, because the work is a chain — the store settles, observation
    /// reaches the grid a turn later, and only then is there a pager to wait for. `ready` says what else has
    /// to have happened, for a step whose starting state already satisfies the rest.
    private static func settle(
        _ context: ProjectContext, _ grid: GridViewController, until ready: () -> Bool = { true }
    ) async {
        for _ in 0..<2_000 {
            await context.whenSettled()
            await Task.yield()
            await grid.whenSettled()
            grid.view.layoutSubtreeIfNeeded()
            grid.view.displayIfNeeded()
            if ready(), grid.tableView.numberOfRows > 0, grid.rows?.row(at: 0) != .notLoaded { return }
            try? await Task.sleep(for: .milliseconds(1))
        }
    }

    @Test func opensAndScrollsAMillionRows() async throws {
        let location = try AppFixtures.prebuilt(.large) ?? AppFixtures.location(.large)
        let total = try #require(location.manifest.entityCounts["Event"])
        var results: [String: Double] = ["rows": Double(total)]

        let document = try ProjectDocument(type: ProjectPackage.typeIdentifier)
        document.context.workingCopiesDirectory = try AppFixtures.scratchFolder("copies")
        document.makeWindowControllers()
        let window = try #require(document.windowControllers.first?.window)
        window.setFrame(NSRect(x: 0, y: 0, width: 1320, height: 820), display: true)
        window.orderFront(nil)
        let grid = try #require(window.firstController(of: GridViewController.self))

        // Choosing a store to the first screenful of rows: everything the user waits for — opening the store,
        // loading the model, counting the entity, reading a page, and drawing it. `chooseStore` is what the
        // Open Database panel calls.
        results["openToFirstRows"] = Self.milliseconds(
            await Self.clock.measure {
                document.context.chooseStore(at: location.storeURL)
                await Self.settle(document.context, grid)
            })
        #expect(document.context.selectedEntity == "Event")
        // The grid opens on a bounded first fetch, however big the entity is (BRW-11).
        let rows = try #require(grid.rows)
        #expect(rows.hasMore)
        #expect(grid.tableView.numberOfRows == rows.count)
        #expect(rows.count < total)

        // "Load more" all the way, so that what is scrolled below is the whole million and not a window onto
        // it. One fetch of a million object IDs is the worst this list can be asked for.
        results["loadAllRows"] = Self.milliseconds(
            await Self.clock.measure {
                _ = try? await rows.loadMore(count: total)
                grid.tableView.noteNumberOfRowsChanged()
                await Self.settle(document.context, grid, until: { grid.tableView.numberOfRows == total })
            })
        #expect(grid.tableView.numberOfRows == total)

        // A frame of scrolling: the table asks for the cell views a screenful needs and draws them. Rows whose
        // page has not arrived draw as placeholders, which is the point — the list never waits for the store.
        var random = SystemRandomNumberGenerator()
        var frames: [Double] = []
        for _ in 0..<60 {
            let row = Int.random(in: 0..<total, using: &random)
            frames.append(
                Self.milliseconds(
                    Self.clock.measure {
                        grid.tableView.scrollRowToVisible(row)
                        grid.view.layoutSubtreeIfNeeded()
                        grid.view.displayIfNeeded()
                    }))
            // The pages the jump asked for arrive between frames, as they do while a person scrolls.
            await Task.yield()
        }
        results["scrollFrameMedian"] = Self.median(frames)
        results["scrollFrameWorst"] = frames.max() ?? 0

        // Sorting a column the store has no index for is the slowest thing the grid asks of it. Clicking a
        // header is what sets this; the delegate takes it from there, and the list starts bounded again.
        #expect(try #require(grid.columns.first { $0.property == "timestamp" }).isSortable)
        // The old list is what is waited out: sorting opens another pager, and holding on to this one keeps
        // the two apart.
        let unsorted = ObjectIdentifier(rows)
        results["sortUnindexed"] = Self.milliseconds(
            await Self.clock.measure {
                grid.tableView.sortDescriptors = [NSSortDescriptor(key: "timestamp", ascending: false)]
                await Self.settle(
                    document.context, grid, until: { grid.rows.map(ObjectIdentifier.init) != unsorted })
            })
        #expect(grid.rows !== rows)
        #expect(grid.tableView.numberOfRows > 0)

        for (name, value) in results.sorted(by: { $0.key < $1.key }) {
            print("PERF app.\(name): \(String(format: "%.1f", value))")
        }

        // PRD §10: the first rows of a 100 MB store inside a second, and 60 fps while scrolling it. A frame
        // has 16.7 ms; what the grid does in one is only part of that, so the budget is the whole frame.
        #expect(try #require(results["openToFirstRows"]) < 1_000)
        #expect(try #require(results["scrollFrameMedian"]) < 16.7)
        #expect(try #require(results["sortUnindexed"]) < 3_000)
        document.close()
    }
}
