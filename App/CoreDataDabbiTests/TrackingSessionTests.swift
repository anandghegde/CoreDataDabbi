@preconcurrency import CoreData
import DabbiKit
import FixtureKit
import Foundation
import Testing

@testable import CoreDataDabbi

/// The window's side of the tracker: a real app writing to a real store, and what the log says about it
/// (TRK-1, TRK-2, TRK-9).
///
/// The tracker itself is tested in `DabbiTrackingTests`; what is tested here is the part a window depends on —
/// the states the toolbar validates against, the log filling as commits arrive, the rows the grid had already
/// read becoming *before* values, and the store being replaced under it all.
///
/// Serialized, because every test waits on a file-system event: a machine running six other suites delivers one
/// late, and a late event is indistinguishable from a missing one.
@MainActor
@Suite(.serialized) struct TrackingSessionTests {
    /// A store with a writer holding it open — a running app — and a window tracking the same file.
    @MainActor
    struct World {
        let directory: URL
        let storeURL: URL
        let writer: StoreWriter
        let session: StoreSession
        let tracking = TrackingSession()

        init(name: String = "Notes.sqlite", seed: (StoreWriter) throws -> Void = { _ in }) async throws {
            directory = try AppFixtures.scratchFolder("tracking")
            storeURL = directory.appendingPathComponent(name)
            writer = try StoreWriter(model: NotesFixture.makeModel(), storeURL: storeURL, author: "app")
            try writer.perform { writer in try seed(writer) }
            session = try await StoreSession.open(storeURL: storeURL)
            // The watcher's defaults budget for a busy app, not for a test that commits once and waits.
            tracking.options.watcher.debounce = .milliseconds(20)
            tracking.options.watcher.folderLatency = 0.1
            tracking.options.watcher.pollInterval = .milliseconds(200)
        }

        /// Starts tracking and returns once the baseline has been read.
        func track(
            _ entity: String = "Note", filter: PredicateSource? = nil,
            alreadyRead: @escaping @MainActor () -> [RowPage] = { [] }
        ) async {
            tracking.start(on: session, entity: entity, filter: filter, alreadyRead: alreadyRead)
            await tracking.whenStarted()
        }

        func commit(_ body: (StoreWriter) throws -> Void) throws {
            try writer.perform(body)
        }

        /// The rows a grid would have in memory, as the front end hands them over.
        func pageOfRows(_ entity: String = "Note") async throws -> RowPage {
            let handle = try await session.openPager(FetchSpec(entity: entity))
            let page = try await session.page(handle, range: 0..<handle.count)
            await session.closePager(handle)
            return page
        }

        func close() async {
            tracking.close()
            await session.close()
            try? writer.close()
        }
    }

    /// Waits for something the tracker will get to in its own time. Polling beats a fixed sleep: it is as fast
    /// as the machine allows and as patient as a loaded one needs.
    static func wait(
        upTo timeout: Duration = .seconds(10), for condition: @MainActor () async -> Bool
    ) async -> Bool {
        let deadline = ContinuousClock.now.advanced(by: timeout)
        while ContinuousClock.now < deadline {
            if await condition() { return true }
            try? await Task.sleep(for: .milliseconds(20))
        }
        return await condition()
    }

    // MARK: Starting and stopping (TRK-1)

    @Test func showsWhatTheWatchedAppJustDid() async throws {
        let world = try await World()
        #expect(world.tracking.state == .idle)
        #expect(!world.tracking.isShowingLog)

        await world.track()
        #expect(world.tracking.state == .tracking)
        #expect(world.tracking.entity == "Note")
        #expect(world.tracking.isShowingLog)
        #expect(world.tracking.log.isEmpty, "what was already in the store is not news")

        try world.commit { writer in writer.insert("Note", ["title": "Milk"]) }
        #expect(await Self.wait { world.tracking.log.counts.created == 1 })

        let entry = try #require(world.tracking.log.entry(at: 0))
        #expect(entry.object.entity == "Note")
        #expect(entry.kind == .inserted)
        #expect(entry.latest.values?["title"] == .string("Milk"))
        #expect(world.tracking.log.badge(at: 0)?.title == "Created")
        // What §6.6 budgets 500 ms for, measured end to end.
        #expect(try #require(world.tracking.lastLatency) < .seconds(5))
        #expect(world.tracking.revision > 0)
        #expect(world.tracking.limitations.isEmpty)
        await world.close()
    }

    @Test func stoppingLeavesTheLogUpAndClosingPutsItAway() async throws {
        let world = try await World()
        await world.track()
        try world.commit { writer in writer.insert("Note", ["title": "Milk"]) }
        #expect(await Self.wait { !world.tracking.log.isEmpty })

        world.tracking.stop()
        #expect(world.tracking.state == .stopped)
        #expect(world.tracking.isRunning == false)
        // What happened is still worth reading, so the log stays where it is.
        #expect(world.tracking.isShowingLog)
        #expect(world.tracking.log.counts.created == 1)
        #expect(world.tracking.canClear)

        try world.commit { writer in writer.insert("Note", ["title": "Not watched"]) }
        try? await Task.sleep(for: .milliseconds(300))
        #expect(world.tracking.log.counts.created == 1, "a stopped tracker reads nothing")

        world.tracking.close()
        #expect(world.tracking.state == .idle)
        #expect(world.tracking.isShowingLog == false)
        #expect(world.tracking.log.isEmpty)
        #expect(world.tracking.entity == nil)
        await world.close()
    }

    @Test func pausingHoldsCommitsAndResumingSaysHowManyItStoodFor() async throws {
        let world = try await World()
        await world.track()
        #expect(world.tracking.canPause)
        #expect(!world.tracking.canResume)

        world.tracking.pause()
        #expect(world.tracking.state == .paused)
        #expect(world.tracking.isRunning, "paused is still tracking; it is reading that stopped")
        #expect(world.tracking.canResume)

        // One at a time: three saves inside the watcher's debounce are one commit to anything outside SQLite.
        try world.commit { writer in writer.insert("Note", ["title": "First"]) }
        #expect(await Self.wait { (await world.tracking.statistics()?.pendingCommits ?? 0) >= 1 })
        try world.commit { writer in writer.insert("Note", ["title": "Second"]) }
        #expect(await Self.wait { (await world.tracking.statistics()?.pendingCommits ?? 0) >= 2 })
        #expect(world.tracking.log.isEmpty, "nothing is read while paused")

        world.tracking.resume()
        #expect(world.tracking.state == .tracking)
        #expect(await Self.wait { world.tracking.log.counts.created == 2 })
        // A log that quietly merged two commits into one line would be a log nobody could trust.
        let badge = try #require(world.tracking.log.badge(at: 0))
        #expect(badge.detail?.contains("2 commits") == true)
        await world.close()
    }

    @Test func clearingEmptiesTheLogWithoutStoppingTheTracker() async throws {
        let world = try await World()
        await world.track()
        try world.commit { writer in writer.insert("Note", ["title": "Milk"]) }
        #expect(await Self.wait { !world.tracking.log.isEmpty })

        let revision = world.tracking.revision
        world.tracking.clear()
        #expect(world.tracking.log.isEmpty)
        #expect(world.tracking.revision > revision)
        #expect(world.tracking.state == .tracking, "the log is emptied; the watching goes on")

        try world.commit { writer in writer.insert("Note", ["title": "Bread"]) }
        #expect(await Self.wait { world.tracking.log.counts.created == 1 })
        await world.close()
    }

    @Test func clearingAStoppedLogPutsItAwayAltogether() async throws {
        let world = try await World()
        await world.track()
        try world.commit { writer in writer.insert("Note", ["title": "Milk"]) }
        #expect(await Self.wait { !world.tracking.log.isEmpty })

        world.tracking.stop()
        world.tracking.clear()
        // Nothing left to read and nothing arriving: an empty table with a footer would say less than the grid.
        #expect(world.tracking.state == .idle)
        #expect(world.tracking.isShowingLog == false)
        await world.close()
    }

    // MARK: Prior values (TRK-2)

    @Test func theRowsTheGridHadReadBecomeTheBeforeValues() async throws {
        let world = try await World { writer in writer.insert("Note", ["title": "Milk", "body": "Two pints"]) }
        // Nothing is primed, so the only prior values the tracker can have are the ones the grid hands over —
        // and it must take them *after* starting, which resets what it holds.
        world.tracking.options.primeUpTo = 0
        let page = try await world.pageOfRows()
        await world.track(alreadyRead: { [page] })

        try world.commit { writer in
            let note = try #require(writer.context.fetch(NSFetchRequest<NSManagedObject>(entityName: "Note")).first)
            note.setValue("Three pints", forKey: "body")
        }
        #expect(await Self.wait { world.tracking.log.counts.updated == 1 })

        let version = try #require(world.tracking.log.entry(at: 0)).latest
        #expect(version.event.priorValue(of: "body") == .string("Two pints"))
        #expect(version.event.isChanged("body"))
        #expect(!version.event.isChanged("title"))
        #expect(world.tracking.log.badge(at: 0)?.title == "Updated · 1 fields")
        await world.close()
    }

    @Test func aRowNobodyHadReadSaysSoRatherThanShowingAnEmptyBefore() async throws {
        let world = try await World { writer in writer.insert("Note", ["title": "Milk", "body": "Two pints"]) }
        world.tracking.options.primeUpTo = 0
        await world.track()

        try world.commit { writer in
            let note = try #require(writer.context.fetch(NSFetchRequest<NSManagedObject>(entityName: "Note")).first)
            note.setValue("Three pints", forKey: "body")
        }
        #expect(await Self.wait { world.tracking.log.counts.updated == 1 })
        #expect(world.tracking.log.badge(at: 0)?.title == "Updated · prior value unknown")
        await world.close()
    }

    // MARK: The filter the grid is showing (TRK-7)

    @Test func watchesTheEntityThroughTheFilterTheGridIsShowingItThrough() async throws {
        let world = try await World { writer in writer.insert("Note", ["title": "Draft", "pinned": false]) }
        await world.track(filter: PredicateSource(format: "pinned == YES"))
        #expect(world.tracking.filter?.format == "pinned == YES")

        try world.commit { writer in writer.insert("Note", ["title": "Chore", "pinned": false]) }
        try world.commit { writer in writer.insert("Folder", ["name": "Inbox"]) }
        try? await Task.sleep(for: .milliseconds(400))
        #expect(world.tracking.log.isEmpty, "rows outside the filter, and an entity nobody asked about")

        try world.commit { writer in
            let notes = try writer.context.fetch(NSFetchRequest<NSManagedObject>(entityName: "Note"))
            try #require(notes.first { $0.value(forKey: "title") as? String == "Draft" })
                .setValue(true, forKey: "pinned")
        }
        #expect(await Self.wait { !world.tracking.log.isEmpty })
        let badge = try #require(world.tracking.log.badge(at: 0))
        #expect(badge.transition == .entered)
        #expect(badge.spoken.contains("entered the filter"))
        await world.close()
    }

    @Test func trackingAnotherEntityStartsAgainRatherThanAddingToTheSameLog() async throws {
        let world = try await World()
        await world.track("Note")
        try world.commit { writer in writer.insert("Note", ["title": "Milk"]) }
        #expect(await Self.wait { !world.tracking.log.isEmpty })

        await world.track("Folder")
        #expect(world.tracking.entity == "Folder")
        try world.commit { writer in writer.insert("Folder", ["name": "Inbox"]) }
        #expect(await Self.wait { world.tracking.log.counts.created == 1 })
        #expect(world.tracking.log.entry(at: 0)?.object.entity == "Folder")
        // The numbering does not start again: a version the user has seen keeps its number.
        #expect(try #require(world.tracking.log.entry(at: 0)).latest.sequence == 2)
        await world.close()
    }

    // MARK: The file going away (Appendix D)

    @Test func saysWhenTheStoreWasReplacedUnderItAndAsksForItToBeOpenedAgain() async throws {
        let world = try await World()
        let replacement = try await World(name: "Replacement.sqlite") { writer in
            writer.insert("Note", ["title": "From the other store"])
        }
        var reopened = 0
        world.tracking.onStoreReplaced = { reopened += 1 }
        await world.track()

        // Closed first: a file Core Data still holds open is not one to move another over.
        try world.writer.close()
        try replacement.writer.close()
        let files = FileManager.default
        try files.removeItem(at: world.storeURL)
        try files.moveItem(at: replacement.storeURL, to: world.storeURL)

        #expect(await Self.wait { world.tracking.storeWasReplaced })
        #expect(world.tracking.state == .stopped)
        #expect(reopened == 1, "the window reopens the store; the log is not left claiming to be live")
        #expect(world.tracking.log.isEmpty, "nothing read about the old file says anything about this one")
        await world.close()
        await replacement.close()
    }
}
