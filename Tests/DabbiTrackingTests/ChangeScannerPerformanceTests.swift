import DabbiModel
import DabbiSQLite
import FixtureKit
import Foundation
import Testing

@testable import DabbiTracking

/// What a scan of a million rows costs, on the `large` fixture. Off in an ordinary test run, like the pager's
/// baselines beside it: `Scripts/perf.sh` is what gives them a release build and the rows.
///
/// The number that matters is the scan's share of the tracker's 500 ms budget (ARCHITECTURE.md §6.6): 150 ms of
/// it is already spent on the watcher's debounce, and materialising has to happen after this.
@Suite(.enabled(if: PerfBaseline.isEnabled), .serialized)
struct ChangeScannerPerformanceTests {
    @Test func baselines() async throws {
        let location = try PerfBaseline.largeFixture()
        let rows = try #require(location.manifest.entityCounts["Event"])

        // The model and the map the way the app gets them: out of the store itself.
        let connection = try SQLiteConnection(readOnly: location.storeURL)
        let model = ModelDescription(try ModelLoader.cachedModel(in: connection))
        let schema = try SchemaMap.build(model: model, connection: connection)
        connection.close()

        let scanner = ChangeScanner(url: location.storeURL, model: model, schema: schema)
        var results: [String: Double] = ["rows": Double(rows)]

        // Warm: straight after the fixture is written its pages are not in the file cache, and the first pass
        // over them times the disk rather than this code.
        _ = try await scanner.prime()
        await scanner.reset()

        results["prime"] = try await PerfBaseline.measure { _ = try await scanner.prime() }
        results["heldRows"] = Double(await scanner.heldRows)
        // What the scanner has actually reserved, rather than the process's footprint: the footprint moves with
        // everything else in the test process, and freeing the arrays again would not give the pages back.
        results["heldMegabytes"] = Double(await scanner.heldBytes) / 1_048_576

        // The steady state: nothing changed, which is the case the tracker is in almost every time it looks.
        var quiet: [Double] = []
        for _ in 0..<5 {
            var changes: RawChangeSet?
            quiet.append(try await PerfBaseline.measure { changes = try await scanner.scan() })
            #expect(changes?.isEmpty == true)
            #expect(changes?.scannedRows == rows + 16)
        }
        results["scanUnchangedMedian"] = PerfBaseline.median(quiet)
        results["scanUnchangedWorst"] = quiet.max() ?? 0
        await scanner.close()

        try PerfBaseline.report(results, as: "scan")

        // The budget §6.6 leaves the scan once the debounce has taken its 150 ms, with room for a slow machine.
        #expect(try #require(results["scanUnchangedMedian"]) < 250)
        #expect(try #require(results["prime"]) < 1_000)
        // §6.6 budgets about 20 bytes a row. Doubling growth is why the bound is not tighter.
        #expect(try #require(results["heldMegabytes"]) < Double(rows) * 40 / 1_048_576)
    }
}
