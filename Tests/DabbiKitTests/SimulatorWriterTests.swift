import DabbiKit
import DabbiTestSupport
import FixtureKit
import Foundation
import Testing

/// The end of M2: an app saves in an iOS simulator and the row lights up here (M2-11).
///
/// Every other tracking test builds its store with `StoreWriter` in a temporary folder, which proves the chain
/// but not the setting. These tests are the setting: a real app, in a real container, holding a real store open
/// while this process reads it — the simulator index, the container map, the read-only open, the watcher, the
/// scan, the diff and the log, all at once, against the one thing they exist for.
///
/// Both halves are driven by the same `WriterScript`, so what the app says it wrote and what the tracker says it
/// saw are two accounts of one program, and the test is whether they agree.
///
/// Off unless `DABBI_WRITER_APP` names a built `WriterApp.app`: building it needs Xcode and a simulator SDK,
/// which `swift test` on its own has neither of. `Scripts/e2e.sh` builds it and sets the variable.
///
/// Serialized, because each test installs the app afresh, and two installs of one bundle ID on one device are
/// one install.
@Suite(.serialized, .enabled(if: SimulatorWriter.isEnabled, SimulatorWriter.disabledReason))
struct SimulatorWriterTests {
    /// Long enough apart that each save is noticed on its own rather than debounced into its neighbour: the
    /// claim under test is one highlighted row per save, and coalescing two saves would quietly weaken it.
    static let interval = 250

    /// A watcher that answers quickly. The engine's default debounce is 150 ms, which is right for a window a
    /// person is looking at and wrong for a test that wants each of ten commits on its own.
    static var promptOptions: ChangeTracker.Options {
        var options = ChangeTracker.Options()
        options.watcher.debounce = .milliseconds(20)
        options.watcher.folderLatency = 0.1
        options.watcher.pollInterval = .milliseconds(200)
        return options
    }

    /// Collects what the tracker delivers, and keeps a `VersionLog` as the window would.
    actor Recorder {
        let log = VersionLog()
        private(set) var batches: [ChangeBatch] = []
        private var task: Task<Void, Never>?

        func drain(_ stream: AsyncStream<ChangeBatch>) {
            task = Task { [weak self] in
                for await batch in stream { await self?.add(batch) }
            }
        }

        var events: [ChangeEvent] { batches.flatMap(\.events) }
        var versions: [VersionLog.Version] { get async { await log.versions(from: 0, limit: 500) } }
        var versionCount: Int { get async { await log.count } }
        var slowestLatency: Duration { batches.map(\.latency).max() ?? .zero }
        var coalesced: Int { batches.map(\.coalescedCommits).max() ?? 0 }

        private func add(_ batch: ChangeBatch) async {
            batches.append(batch)
            await log.append(batch)
        }

        func finish() { task?.cancel() }
    }

    static func wait(upTo timeout: Duration = .seconds(30), for condition: @Sendable () async -> Bool) async -> Bool {
        let deadline = ContinuousClock.now.advanced(by: timeout)
        while ContinuousClock.now < deadline {
            if await condition() { return true }
            try? await Task.sleep(for: .milliseconds(20))
        }
        return await condition()
    }

    /// A tracker watching the app's store, with everything it says collected.
    static func watch(
        _ writer: SimulatorWriter, _ scope: TrackingScope
    ) async throws -> (OpenedStore, ChangeTracker, Recorder) {
        let opened = try await StoreOpener().open(storeURL: writer.storeURL)
        let tracker = ChangeTracker(session: opened.session, options: promptOptions)
        let recorder = Recorder()
        await recorder.drain(try await tracker.start(scope))
        return (opened, tracker, recorder)
    }

    // MARK: - Finding it (PRJ-8)

    /// Before anything can be tracked it has to be found, and nobody types a container path: the writer is an
    /// ordinary app that puts an ordinary store in `Library/Application Support`, and the index finds it the way
    /// it finds anybody's.
    @Test func theStoreIsFoundWhereAnOrdinaryAppWouldPutIt() async throws {
        let writer = try await SimulatorWriter.install()
        try await writer.seed()

        let devices = await SimulatorDeviceSource().listing().devices
        let device = try #require(devices.first { $0.udid == writer.udid })
        let contents = await SimulatorIndex().contents(of: device)

        let app = try #require(
            contents.apps.first { $0.app.bundleID == SimulatorWriter.bundleID },
            "the index did not list the writer among \(contents.apps.count) installed apps")
        let store = try #require(
            app.stores.first { $0.url.lastPathComponent == WriterScript.storeName },
            "the sniffer found \(app.stores.map(\.url.lastPathComponent)) and not the store")
        #expect(store.url.standardizedFileURL == writer.storeURL.standardizedFileURL)
        #expect(store.byteCount > 0)

        // The writer is the false positive `SwiftDataConventions` warns about in as many words: it builds its
        // model in code, so it ships no `.mom`, and that is the only hint a bundle gives. Pinned here rather
        // than worked around, because it is the behaviour and a later change to it should say so out loud —
        // and because it costs nothing: the badge is cosmetic, and the four tests below open and track this
        // very store through the Core Data path without noticing.
        #expect(app.usesSwiftData)
        #expect(store.kind == .swiftData)

        await writer.uninstall()
    }

    // MARK: - The demo (M2 exit criterion)

    /// The one the milestone is named for: ten saves in the simulator, ten versions in the log, in order, each
    /// with the values the app wrote — and each delivered inside the 500 ms budget.
    @Test func everySaveInTheSimulatorBecomesAVersionInTheLog() async throws {
        let writer = try await SimulatorWriter.install()
        let seeded = try await writer.seed()
        #expect(seeded.seeded.count == WriterScript.seedTitles.count)

        // Watching `Note` alone, so the log lines up with the script one for one: a note's folder change also
        // touches the folder, and a folder is not what the script is an account of.
        let (opened, tracker, recorder) = try await Self.watch(writer, .entities(["Note"]))

        try await writer.startRun(intervalMilliseconds: Self.interval)
        let script = try await writer.report("run")
        #expect(script.changes.count == WriterScript.program.count)
        #expect(script.writer == "iOS simulator")

        let arrived = await Self.wait { await recorder.versionCount >= script.changes.count }
        let logged = await recorder.versionCount
        #expect(arrived, "the log has \(logged) of \(script.changes.count) versions")

        // What the app says it did, and what the tracker says it saw, as two lists of the same shape.
        let versions = await recorder.versions
        let observed = versions.map { "\($0.event.kind.rawValue) Note#\($0.object.pk)" }
        let expected = script.changes.map { "\($0.operation.rawValue) \($0.entity)#\($0.pk)" }
        #expect(observed == expected)

        // Not just the right rows in the right order — the right values in them.
        for (version, change) in zip(versions, script.changes) {
            let event = version.event
            switch event.kind {
            case .inserted, .updated:
                #expect(event.currentValue(of: "title") == .string(change.title))
                if let pinned = change.pinned { #expect(event.currentValue(of: "pinned") == .bool(pinned)) }
            case .deleted:
                #expect(
                    event.priorValue(of: "title") == .string(change.title),
                    "a deleted row's title is what the tracker held for it, and it primed from the seed")
            }
        }

        // TRK-2: an edit says which field moved and what it was. The script names a note by its title and
        // rewrites its body, so `body` is what moved and `title` is what held still.
        var pk: [String: Int64] = [:]
        for change in seeded.seeded + script.changes { pk[change.title] = change.pk }
        let edit = try #require(versions.first { $0.event.isChanged("body") })
        #expect(edit.object.pk == pk["Seed 0"])
        #expect(edit.event.priorValue(of: "body") == .string("Body of Seed 0"))
        #expect(edit.event.currentValue(of: "body") == .string("Rewritten in transaction 1"))
        #expect(edit.event.isChanged("title") == false)
        #expect(versions.allSatisfy { $0.event.kind != .updated || $0.event.before != nil }, "primed from the seed")

        // And a pin moves one field and says so: the field diff is the difference between *something changed*
        // and *this changed*.
        let pin = try #require(versions.first { $0.object.pk == pk["Seed 0"] && $0.event.isChanged("pinned") })
        #expect(pin.event.changedKeys == ["pinned"])
        #expect(pin.event.priorValue(of: "pinned") == .bool(false))
        #expect(pin.event.currentValue(of: "pinned") == .bool(true))

        #expect(
            await recorder.coalesced == 1,
            "each save was noticed on its own; a higher number means the log is shorter than the script")
        let slowest = await recorder.slowestLatency
        #expect(slowest < .milliseconds(500), "save to version took \(slowest), and the budget is 500 ms")

        await recorder.finish()
        await tracker.stop()
        await opened.close()
        await writer.uninstall()
    }

    // MARK: - A saved view (TRK-7)

    /// The other half of the exit criterion: the same run, watched through a saved predicate. A row that was
    /// never in the view is not news; a row that crosses the boundary is, and which way it crossed is the point.
    @Test func aSavedViewSaysWhatEnteredAndLeftIt() async throws {
        let writer = try await SimulatorWriter.install()
        let seeded = try await writer.seed()

        let (opened, tracker, recorder) = try await Self.watch(
            writer, .entities(["Note"], predicate: PredicateSource(format: WriterScript.pinnedView)))

        try await writer.startRun(intervalMilliseconds: Self.interval)
        let script = try await writer.report("run")

        // The script pins two notes and unpins one; those three crossings are what the view is to report.
        var pk: [String: Int64] = [:]
        for change in seeded.seeded + script.changes { pk[change.title] = change.pk }
        let pinned = try #require(pk["Seed 0"]), alsoPinned = try #require(pk["Seed 2"])
        let unpinned = try #require(pk["Seed 1"]), neverInView = try #require(pk["Writer 0"])

        let joined = try #require(pk["Writer 1"]), departed = try #require(pk["Seed 3"])

        // Six of the ten steps touch the view, and each one crosses its boundary: two pins and an insert come
        // in, an unpin and two deletes go out. The other four never enter it and are never mentioned.
        let expected = [
            "updated Note#\(pinned) entered",  // `Seed 0` was pinned
            "inserted Note#\(joined) entered",  // `Writer 1` was created already pinned
            "updated Note#\(unpinned) left",  // `Seed 1` was unpinned
            "updated Note#\(alsoPinned) entered",  // `Seed 2` was pinned
            "deleted Note#\(departed) left",  // pinned `Seed 3` was deleted
            "deleted Note#\(joined) left",  // and so was `Writer 1`
        ]
        let arrived = await Self.wait { await recorder.events.count >= expected.count }
        let observed = await recorder.events.map {
            "\($0.kind.rawValue) \($0.object.entity)#\($0.object.pk) \($0.transition?.rawValue ?? "-")"
        }
        #expect(arrived, "the view saw \(observed)")
        #expect(observed == expected)
        #expect(
            !observed.contains { $0.contains("#\(neverInView) ") },
            "`Writer 0` was inserted and then edited, and was outside the view the whole time")

        await recorder.finish()
        await tracker.stop()
        await opened.close()
        await writer.uninstall()
    }

    // MARK: - A store that cannot be written to (S9)

    /// And on a read-only store: the app's own store, lifted out with its sidecars into a folder nothing can
    /// write to. The opener reads it — in place or through a copy, whichever it needs — and the tracker primes
    /// from it, with nothing at all left behind in the folder.
    @Test func aStoreThatCannotBeWrittenToIsStillReadAndTracked() async throws {
        let writer = try await SimulatorWriter.install()
        let seeded = try await writer.seed()

        let files = FileManager.default
        let folder = TestFixtures.root.appendingPathComponent("writer-readonly-\(UUID().uuidString)", isDirectory: true)
        try files.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? files.setAttributes([.posixPermissions: 0o755], ofItemAtPath: folder.path) }

        let copy = folder.appendingPathComponent(WriterScript.storeName)
        for suffix in ["", "-wal", "-shm"] where files.fileExists(atPath: writer.storeURL.path + suffix) {
            try files.copyItem(atPath: writer.storeURL.path + suffix, toPath: copy.path + suffix)
        }
        let before = try files.contentsOfDirectory(atPath: folder.path).sorted()
        try files.setAttributes([.posixPermissions: 0o555], ofItemAtPath: folder.path)

        let opened = try await StoreOpener(
            workingCopiesDirectory: TestFixtures.root.appendingPathComponent("copies-\(UUID().uuidString)")
        ).open(storeURL: copy)
        let counts = try await opened.session.entityCounts()
        let byEntity = Dictionary(uniqueKeysWithValues: counts.map { ($0.entity, $0.total) })
        #expect(byEntity["Note"] == seeded.seeded.count)
        #expect(byEntity["Folder"] == WriterScript.folderNames.count)

        // Starting is what a read-only store makes hard: priming reads every row in scope, and there is nowhere
        // to put a journal. It reports what it holds, and it holds the seed.
        let tracker = ChangeTracker(session: opened.session, options: Self.promptOptions)
        let recorder = Recorder()
        await recorder.drain(try await tracker.start(.entities(["Note"])))
        let statistics = await tracker.statistics()
        #expect(statistics.isTracking)
        #expect(statistics.heldRows == seeded.seeded.count)
        #expect(statistics.lastFailure == nil)

        #expect(try files.contentsOfDirectory(atPath: folder.path).sorted() == before, "nothing was written beside it")

        await recorder.finish()
        await tracker.stop()
        await opened.close()
        await writer.uninstall()
    }

    // MARK: - The canary (S9)

    /// Inspecting an app's store must not change the app's folder. The writer is running the whole time, so the
    /// files themselves move; what must not happen is a new one appearing.
    @Test func trackingALiveAppWritesNothingIntoItsContainer() async throws {
        let writer = try await SimulatorWriter.install()
        try await writer.seed()

        let files = FileManager.default
        let before = try files.contentsOfDirectory(atPath: writer.storeDirectory.path).sorted()
        #expect(before.contains(WriterScript.storeName))

        let (opened, tracker, recorder) = try await Self.watch(writer, .allEntities)
        try await writer.startRun(intervalMilliseconds: Self.interval)
        let script = try await writer.report("run")
        #expect(await Self.wait { await recorder.versionCount >= script.changes.count })

        #expect(opened.isWorkingCopy == false, "a store that can be read in place is read in place")
        #expect(try files.contentsOfDirectory(atPath: writer.storeDirectory.path).sorted() == before)

        await recorder.finish()
        await tracker.stop()
        await opened.close()
        #expect(try files.contentsOfDirectory(atPath: writer.storeDirectory.path).sorted() == before)
        await writer.uninstall()
    }
}
