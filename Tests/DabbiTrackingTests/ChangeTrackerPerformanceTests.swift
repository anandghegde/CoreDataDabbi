@preconcurrency import CoreData
import DabbiBase
import DabbiModel
import DabbiSQLite
import DabbiStore
import DabbiTestSupport
import FixtureKit
import Foundation
import Testing

@testable import DabbiTracking

/// The second half of §6.6's 500 ms budget, on the million-row `large` fixture: what materialising the rows a scan
/// named costs, and what a save by another process costs from the commit to the batch in hand. Off in an ordinary
/// test run, like the scan's baselines beside it — `Scripts/perf.sh` gives them a release build and the rows.
@Suite(.enabled(if: PerfBaseline.isEnabled), .serialized)
struct ChangeTrackerPerformanceTests {
    /// Materialising on its own, read-only, against the fixture itself: no writer, no watcher, no debounce.
    @Test func materialiseBaselines() async throws {
        let location = try PerfBaseline.largeFixture()
        let rows = try #require(location.manifest.entityCounts["Event"])
        let session = try await StoreSession.open(storeURL: location.storeURL)
        var results: [String: Double] = ["rows": Double(rows)]

        let refs = try await session.references(FetchSpec(entity: "Event"), limit: 5_000)
        let oneBatch = Array(refs.prefix(500))

        // Warm: the first read of these pages times the disk, and the first fetch of an entity also builds Core
        // Data's own caches for it.
        _ = try await session.objects(oneBatch)

        var samples: [Double] = []
        for _ in 0..<5 {
            samples.append(try await PerfBaseline.measure { _ = try await session.objects(oneBatch) })
        }
        results["materialise500"] = PerfBaseline.median(samples)
        results["materialise5000"] = try await PerfBaseline.measure { _ = try await session.objects(refs) }
        // With the watched view's predicate evaluated per row (TRK-7), which is the tracking case.
        results["materialise500Matching"] = try await PerfBaseline.measure {
            _ = try await session.objects(oneBatch, matching: PredicateSource(format: "flagged == YES"))
        }

        // The to-many side: sixteen sources holding a million events between them, counted in one grouped fetch
        // rather than one fetch each.
        // The to-many count is a grouped fetch over every child row, so what it costs depends on how much of the
        // Event table is in the file cache — hence a median rather than one reading.
        let sources = try await session.references(FetchSpec(entity: "Source"))
        results["sources"] = Double(sources.count)
        var sourceSamples: [Double] = []
        for _ in 0..<3 {
            sourceSamples.append(try await PerfBaseline.measure { _ = try await session.objects(sources) })
        }
        results["materialiseSources"] = PerfBaseline.median(sourceSamples)

        // What priming asks first, to decide which entities it can afford values for: a count of every entity,
        // and a million of them are counted one row at a time whatever is asked for.
        results["entityCounts"] = try await PerfBaseline.measure { _ = try await session.entityCounts() }
        await session.close()
        try PerfBaseline.report(results, as: "materialise")

        // What §6.6's 500 ms has left once the debounce (150 ms) and the scan (~100 ms, Appendix D) have taken
        // theirs. `materialiseBatch` is 500, so this is one batch — the unit the tracker actually reads in.
        #expect(try #require(results["materialise500"]) < 250)
    }

    /// The whole chain, with the real 150 ms debounce: another process saves, and a `ChangeBatch` arrives. This is
    /// the M2 exit criterion minus the drawing (the tracking UI is M2-10).
    @Test func aSaveReachesTheTrackerInsideTheBudget() async throws {
        let location = try PerfBaseline.largeFixture()
        let rows = try #require(location.manifest.entityCounts["Event"])

        // This one writes, so it writes to a copy — the fixture is shared with every other baseline. Copying
        // 200 MB is not part of any measurement here.
        let directory = TestFixtures.root
            .appendingPathComponent("tracker-perf-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let storeURL = directory.appendingPathComponent(location.storeURL.lastPathComponent)
        for suffix in ["", "-wal", "-shm"] {
            let source = URL(fileURLWithPath: location.storeURL.path + suffix)
            guard FileManager.default.fileExists(atPath: source.path) else { continue }
            try FileManager.default.copyItem(at: source, to: URL(fileURLWithPath: storeURL.path + suffix))
        }

        // The writer plays the app; the model comes out of the store, because that is all an inspector ever has.
        let connection = try SQLiteConnection(readOnly: storeURL)
        let model = try ModelLoader.cachedModel(in: connection)
        connection.close()
        let writer = try StoreWriter(model: model, storeURL: storeURL, author: "app")
        let session = try await StoreSession.open(storeURL: storeURL)
        // Default options: the 150 ms debounce and the 50k priming threshold a shipping tracker runs with.
        let tracker = ChangeTracker(session: session, options: .init())
        let sink = ChangeTrackerTests.Sink()
        var results: [String: Double] = ["rows": Double(rows)]

        // Starting reads every key in the store, and *values* only for the entities under `primeUpTo` — a million
        // Events are far over it, so only the sixteen sources are read. The first pass over a store this size is
        // the disk's: the copy above was just written and none of it is in the file cache yet. Stop and start
        // again is what a warm one costs, and what Play/Stop/Play (TRK-1) costs every time after the first.
        results["startCold"] = try await PerfBaseline.measure { _ = try await tracker.start(.allEntities) }
        await tracker.stop()
        var stream: AsyncStream<ChangeBatch>?
        results["start"] = try await PerfBaseline.measure { stream = try await tracker.start(.allEntities) }
        await sink.drain(try #require(stream))
        let statistics = await tracker.statistics()
        results["heldRowValues"] = Double(statistics.heldRows)
        results["heldKeyMegabytes"] = Double(statistics.heldKeyBytes) / 1_048_576

        var latencies: [Double] = []
        var scans: [Double] = []
        var materialisings: [Double] = []
        for round in 0..<3 {
            let before = await sink.count
            try writer.perform { writer in
                let request = NSFetchRequest<NSManagedObject>(entityName: "Event")
                request.predicate = NSPredicate(
                    format: "sequence >= %ld AND sequence < %ld", round * 100, round * 100 + 100)
                for object in try writer.context.fetch(request) {
                    object.setValue("Touched in round \(round)", forKey: "name")
                }
            }
            // From the save returning — the moment the commit is on disk — to the batch being in hand.
            let committed = ContinuousClock.now
            #expect(await ChangeTrackerTests.wait { await sink.count > before })
            latencies.append(PerfBaseline.milliseconds(committed.duration(to: ContinuousClock.now)))

            let batch = try #require(await sink.batches.last)
            #expect(batch.count == 100, "a hundred rows saved over, a hundred events")
            scans.append(PerfBaseline.milliseconds(batch.scanDuration))
            materialisings.append(PerfBaseline.milliseconds(batch.materialiseDuration))
        }
        results["saveToBatchMedian"] = PerfBaseline.median(latencies)
        results["saveToBatchWorst"] = latencies.max() ?? 0
        results["scanMedian"] = PerfBaseline.median(scans)
        results["materialise100Median"] = PerfBaseline.median(materialisings)

        await tracker.stop()
        await session.close()
        try? writer.close()
        try PerfBaseline.report(results, as: "tracker")

        // §6.6's budget is 500 ms, of which the debounce is 150; the bound here is loose enough for a machine
        // doing something else at the same time, and the measured figure is what Appendix D records.
        #expect(try #require(results["saveToBatchMedian"]) < 750)
        // Starting is not in the latency budget — nothing is being reported yet — but it is a click. Warm, it is
        // the key baseline and little else; cold, it is however long the disk takes to give up a million rows.
        #expect(try #require(results["start"]) < 500)
        #expect(try #require(results["startCold"]) < 5_000)
    }
}
