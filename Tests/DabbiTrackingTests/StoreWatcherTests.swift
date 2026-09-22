import DabbiBase
import DabbiSQLite
import DabbiTestSupport
import FixtureKit
import Foundation
import Testing

@testable import DabbiTracking

/// The watcher is a timing component, so these tests run one at a time: a machine busy running six other suites
/// delivers file-system events late, and a late event looks like a missing one.
@Suite(.serialized) struct StoreWatcherTests {
    /// A Notes store with a writer holding it open — a running app, from the watcher's point of view. The
    /// writer's connection is the "other" connection whose commits `PRAGMA data_version` reports.
    struct World {
        let directory: URL
        let storeURL: URL
        let writer: StoreWriter

        init(name: String = "Notes.sqlite") throws {
            directory = TestFixtures.root.appendingPathComponent("watcher-\(UUID().uuidString)", isDirectory: true)
            storeURL = directory.appendingPathComponent(name)
            writer = try StoreWriter(model: NotesFixture.makeModel(), storeURL: storeURL, author: "app")
            // One transaction before anybody watches, so the store is in the state a running app's store is in:
            // open, with a write-ahead log and its shared-memory file beside it.
            try writer.perform { writer in writer.insert("Folder", ["name": "Inbox"]) }
        }

        func commit(_ title: String) throws {
            try writer.perform { writer in writer.insert("Note", ["title": title]) }
        }
    }

    /// Collects what a watcher says, so a test can wait for it without holding a stream iterator across an
    /// `await`.
    actor Sink {
        private(set) var commits: [StoreCommit] = []
        private var task: Task<Void, Never>?

        func drain(_ stream: AsyncStream<StoreCommit>) {
            task = Task { [weak self] in
                for await commit in stream { await self?.add(commit) }
            }
        }

        var count: Int { commits.count }
        var kinds: [StoreCommit.Kind] { commits.map(\.kind) }
        private func add(_ commit: StoreCommit) { commits.append(commit) }
    }

    /// Waits for `condition`, checking often. Returns `false` if it never came true.
    static func wait(
        upTo timeout: Duration = .seconds(5), for condition: @Sendable () async -> Bool
    ) async -> Bool {
        let deadline = ContinuousClock.now.advanced(by: timeout)
        while ContinuousClock.now < deadline {
            if await condition() { return true }
            try? await Task.sleep(for: .milliseconds(20))
        }
        return await condition()
    }

    /// Watches a store and collects what comes out.
    static func watch(_ url: URL, options: StoreWatcher.Options) async throws -> (StoreWatcher, Sink) {
        let watcher = StoreWatcher(url: url, options: options)
        let sink = Sink()
        await sink.drain(try await watcher.commits())
        return (watcher, sink)
    }

    static func inode(of path: String) throws -> UInt64 {
        try FileManager.default.attributesOfItem(atPath: path)[.systemFileNumber] as? UInt64 ?? 0
    }

    /// Everything the file-system paths are asked to do, with the timer switched off: a test that passes here
    /// passes because an event arrived, not because a poll came round.
    static var eventsOnly: StoreWatcher.Options {
        var options = StoreWatcher.Options()
        options.pollInterval = nil
        options.folderLatency = 0.1
        return options
    }

    // MARK: The gate

    /// The assumption the whole watcher rests on (§6.6): `PRAGMA data_version` on one connection changes when
    /// *another* connection commits, and stays put otherwise. A format canary — if an OS update breaks this, the
    /// tracker's cheap no-op filter is gone, and this test is where that shows up.
    @Test func dataVersionReportsOtherConnectionsOnly() async throws {
        let world = try World()
        let reader = try SQLiteReader(url: world.storeURL)

        let before = try await reader.read { try $0.dataVersion() }
        _ = try await reader.read { try $0.query("SELECT count(*) FROM Z_PRIMARYKEY") }
        let afterOurOwnRead = try await reader.read { try $0.dataVersion() }
        #expect(afterOurOwnRead == before, "a read of our own must not count as a change")

        try world.commit("First")
        let afterTheirCommit = try await reader.read { try $0.dataVersion() }
        #expect(afterTheirCommit != before)
        await reader.close()
    }

    // MARK: Noticing a commit

    @Test func noticesACommit() async throws {
        let world = try World()
        let (watcher, sink) = try await Self.watch(world.storeURL, options: Self.eventsOnly)
        let baseline = await watcher.dataVersion
        #expect(baseline != nil, "the store as it is when watching starts is the baseline")

        try world.commit("First")

        #expect(await Self.wait { await sink.count == 1 })
        let commit = await sink.commits.first
        #expect(commit?.kind == .commit)
        #expect(commit?.dataVersion != nil)
        #expect(commit?.dataVersion != baseline)
        await watcher.stop()
    }

    /// The budget is 500 ms from the app's save to a highlighted row (§6.6), of which 150 ms is the debounce and
    /// the rest belongs to the scan and to Core Data. The bound here is loose on purpose: what it guards is that
    /// noticing costs a debounce and a pragma — not a poll interval, not a folder-event latency.
    @Test func noticesWithinTheLatencyBudget() async throws {
        let world = try World()
        let (watcher, sink) = try await Self.watch(world.storeURL, options: Self.eventsOnly)

        let start = ContinuousClock.now
        try world.commit("First")
        #expect(await Self.wait { await sink.count == 1 })
        let elapsed = ContinuousClock.now - start
        #expect(elapsed < .milliseconds(750), "noticed after \(elapsed)")
        await watcher.stop()
    }

    /// Something happening in the store's folder is not a commit. This is the gate doing its job: without it the
    /// tracker would go and look every time the app opened the store or checkpointed its log.
    @Test func saysNothingWhenTheStoreDidNotChange() async throws {
        let world = try World()
        let (watcher, sink) = try await Self.watch(world.storeURL, options: Self.eventsOnly)

        // A file appearing next to the store, and the store's own timestamp moving, both raise events.
        try Data("not a store".utf8).write(to: world.directory.appendingPathComponent("scratch.txt"))
        try FileManager.default.setAttributes([.modificationDate: Date()], ofItemAtPath: world.storeURL.path)

        try await Task.sleep(for: .milliseconds(800))
        #expect(await sink.count == 0)
        await watcher.stop()
    }

    /// Five transactions inside one debounce window are one thing to go and look at, not five.
    @Test func coalescesABurst() async throws {
        let world = try World()
        let (watcher, sink) = try await Self.watch(world.storeURL, options: Self.eventsOnly)

        for index in 0..<5 { try world.commit("Note \(index)") }

        #expect(await Self.wait { await sink.count >= 1 })
        try await Task.sleep(for: .milliseconds(500))
        let count = await sink.count
        #expect(count <= 2, "five transactions in one window became \(count) rounds")
        await watcher.stop()
    }

    /// The poll is insurance, not a second voice: the gate keeps it quiet when nothing committed, and keeps it
    /// from reporting again what the events already reported.
    @Test func pollingDoesNotDoubleReport() async throws {
        let world = try World()
        var options = StoreWatcher.Options()
        options.pollInterval = .milliseconds(100)
        let (watcher, sink) = try await Self.watch(world.storeURL, options: options)

        try world.commit("First")
        #expect(await Self.wait { await sink.count == 1 })
        try await Task.sleep(for: .milliseconds(600))
        #expect(await sink.count == 1)
        await watcher.stop()
    }

    // MARK: Files that come and go

    /// What Core Data actually does when a store is closed and opened again (Appendix C): it checkpoints the log,
    /// truncates the `-wal` to nothing and keeps both companions, same files. Nothing is recreated, so an app
    /// restart must not disturb the watcher at all — and must not be reported as a store replacement either.
    @Test func survivesTheAppRestarting() async throws {
        let world = try World()
        let (watcher, sink) = try await Self.watch(world.storeURL, options: Self.eventsOnly)

        try world.commit("Before the restart")
        #expect(await Self.wait { await sink.count == 1 })

        try world.writer.close()
        let log = world.storeURL.path + "-wal"
        let before = try Self.inode(of: log)
        #expect(FileManager.default.fileExists(atPath: log), "Core Data keeps the log")

        let restarted = try StoreWriter(
            model: NotesFixture.makeModel(), storeURL: world.storeURL, author: "app again")
        try restarted.perform { writer in writer.insert("Note", ["title": "After the restart"]) }

        #expect(await Self.wait { await sink.count >= 2 })
        #expect(await sink.kinds.allSatisfy { $0 == .commit }, "the same files, so nothing was replaced")
        #expect(try Self.inode(of: log) == before, "the same log file, reused")
        try restarted.close()
        await watcher.stop()
    }

    /// A reinstall, a restore, a container recreated: the companion files are deleted and different ones take
    /// their place beside the same store. Two things have to happen or tracking dies quietly — the sources on the
    /// vnodes that no longer exist have to be replaced, and the gate connection has to be opened again, because a
    /// connection that was looking at the old shared-memory file will not see commits going into the new log.
    @Test func rearmsWhenTheCompanionFilesAreReplaced() async throws {
        let world = try World()
        let (watcher, sink) = try await Self.watch(world.storeURL, options: Self.eventsOnly)

        try world.commit("Before")
        #expect(await Self.wait { await sink.count == 1 })

        // Closing checkpoints the log into the store, so the two files being deleted here hold nothing.
        try world.writer.close()
        let log = world.storeURL.path + "-wal"
        let oldLog = try Self.inode(of: log)
        try FileManager.default.removeItem(atPath: log)
        try FileManager.default.removeItem(atPath: world.storeURL.path + "-shm")

        // A WAL store with neither companion cannot be opened read-only at all (§6.2), so the watcher has
        // nothing to say here — and says nothing, rather than inventing a change out of the files moving.
        try await Task.sleep(for: .milliseconds(500))
        #expect(await sink.count == 1)

        // Opening this has to work, which is the other half of what is being tested: a connection still holding
        // the deleted `-shm` makes the store unopenable for everybody else — Apple's SQLite raises
        // SQLITE_IOERR_VNODE — so an inspector that did not let go would stop the app from starting.
        let reinstalled = try StoreWriter(
            model: NotesFixture.makeModel(), storeURL: world.storeURL, author: "app again")
        try reinstalled.perform { writer in writer.insert("Note", ["title": "After"]) }
        #expect(try Self.inode(of: log) != oldLog, "a different log file, or this test proves nothing")

        #expect(await Self.wait { await sink.count >= 2 })
        #expect(await sink.kinds.allSatisfy { $0 == .commit }, "the store file itself was never replaced")

        // And it is still watching afterwards, rather than having spent its one reopen.
        try reinstalled.perform { writer in writer.insert("Note", ["title": "And again"]) }
        #expect(await Self.wait { await sink.count >= 3 })

        try reinstalled.close()
        await watcher.stop()
    }

    /// A reinstall, a restore, a copy put back: the same file name, a different file. Nothing the tracker cached
    /// about the old one means anything any more, which is why this is not a plain commit.
    @Test func noticesTheStoreBeingReplaced() async throws {
        let world = try World()
        let replacement = try World(name: "Replacement.sqlite")
        try replacement.commit("From the other store")
        try replacement.writer.close()

        let (watcher, sink) = try await Self.watch(world.storeURL, options: Self.eventsOnly)

        try world.writer.close()
        let files = FileManager.default
        try files.removeItem(at: world.storeURL)
        try files.moveItem(at: replacement.storeURL, to: world.storeURL)

        #expect(await Self.wait { await sink.kinds.contains(.storeReplaced) })
        await watcher.stop()
    }

    // MARK: Lifecycle

    @Test func stoppingFinishesTheStream() async throws {
        let world = try World()
        let watcher = StoreWatcher(url: world.storeURL, options: Self.eventsOnly)
        let stream = try await watcher.commits()
        let consumer = Task {
            for await _ in stream {}
            return true
        }

        await watcher.stop()
        #expect(await consumer.value)
    }

    /// Play, Stop, Play again (TRK-1): the second start has to work as well as the first, and what happened
    /// while nobody was watching is the new baseline rather than a flood of stale news.
    @Test func watchesAgainAfterStopping() async throws {
        let world = try World()
        let (watcher, first) = try await Self.watch(world.storeURL, options: Self.eventsOnly)
        try world.commit("While watching")
        #expect(await Self.wait { await first.count == 1 })
        await watcher.stop()

        try world.commit("While not watching")
        let second = Sink()
        await second.drain(try await watcher.commits())
        try await Task.sleep(for: .milliseconds(300))
        #expect(await second.count == 0)

        try world.commit("Watching again")
        #expect(await Self.wait { await second.count == 1 })
        await watcher.stop()
    }

    /// Nothing to watch: the same error opening the store for reading would give, not a stream that never says
    /// anything.
    @Test func refusesAStoreItCannotOpen() async throws {
        let missing = TestFixtures.root.appendingPathComponent("no-such-store-\(UUID().uuidString).sqlite")
        let watcher = StoreWatcher(url: missing)
        await #expect(throws: DabbiError.self) { try await watcher.commits() }
    }
}
