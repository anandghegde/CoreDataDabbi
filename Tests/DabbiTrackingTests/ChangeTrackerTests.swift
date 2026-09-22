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

/// The last stage of the tracker chain (ARCHITECTURE.md §6.6): rows the scanner named, materialised, diffed, and
/// placed inside or outside the watched view.
///
/// Serialized, because every test here waits on a file-system event: a machine running six other suites delivers
/// one late, and a late event is indistinguishable from a missing one.
@Suite(.serialized) struct ChangeTrackerTests {
    /// A store with a writer holding it open — a running app — and a read-only session on the same file, which is
    /// what the tracker materialises through.
    struct World {
        let directory: URL
        let storeURL: URL
        let writer: StoreWriter
        let session: StoreSession

        init(
            model managedObjectModel: NSManagedObjectModel = NotesFixture.makeModel(),
            name: String = "Notes.sqlite",
            storeOptions: [String: Any] = [:],
            seed: (StoreWriter) throws -> Void = { _ in }
        ) async throws {
            directory = TestFixtures.root.appendingPathComponent("tracker-\(UUID().uuidString)", isDirectory: true)
            storeURL = directory.appendingPathComponent(name)
            writer = try StoreWriter(
                model: managedObjectModel, storeURL: storeURL, options: storeOptions, author: "app")
            try writer.perform { writer in try seed(writer) }
            session = try await StoreSession.open(storeURL: storeURL)
        }

        func commit(_ body: (StoreWriter) throws -> Void) throws {
            try writer.perform(body)
        }

        func tracker(_ options: ChangeTracker.Options = Self.promptOptions) -> ChangeTracker {
            ChangeTracker(session: session, options: options)
        }

        /// A tracker that is watching, with everything it saw collected.
        func tracking(
            _ scope: TrackingScope = .allEntities, options: ChangeTracker.Options = Self.promptOptions
        ) async throws -> (ChangeTracker, Sink) {
            let tracker = tracker(options)
            let sink = Sink()
            await sink.drain(try await tracker.start(scope))
            return (tracker, sink)
        }

        func close() async {
            await session.close()
            try? writer.close()
        }

        /// A watcher that answers quickly, so a test does not spend the default 150 ms debounce per commit.
        static var promptOptions: ChangeTracker.Options {
            var options = ChangeTracker.Options()
            options.watcher.debounce = .milliseconds(20)
            options.watcher.folderLatency = 0.1
            options.watcher.pollInterval = .milliseconds(200)
            return options
        }
    }

    /// Collects batches, so a test can wait for one without holding a stream iterator across an `await`.
    actor Sink {
        private(set) var batches: [ChangeBatch] = []
        private(set) var isFinished = false
        private var task: Task<Void, Never>?

        func drain(_ stream: AsyncStream<ChangeBatch>) {
            task = Task { [weak self] in
                for await batch in stream { await self?.add(batch) }
                await self?.finish()
            }
        }

        var count: Int { batches.count }
        /// Every event of every batch, in arrival order.
        var events: [ChangeEvent] { batches.flatMap(\.events) }
        func event(of kind: ChangeEvent.Kind) -> ChangeEvent? { events.first { $0.kind == kind } }
        func events(about ref: ObjectRef) -> [ChangeEvent] { events.filter { $0.object == ref } }

        private func add(_ batch: ChangeBatch) { batches.append(batch) }
        private func finish() { isFinished = true }
    }

    static func wait(
        upTo timeout: Duration = .seconds(10), for condition: @Sendable () async -> Bool
    ) async -> Bool {
        let deadline = ContinuousClock.now.advanced(by: timeout)
        while ContinuousClock.now < deadline {
            if await condition() { return true }
            try? await Task.sleep(for: .milliseconds(20))
        }
        return await condition()
    }

    static func ref(_ session: StoreSession, _ object: NSManagedObject) throws -> ObjectRef {
        try #require(ObjectRef(uri: object.objectID.uriRepresentation()))
    }

    /// Options that hold nothing: no priming, no copy. What a tracker on a store too large to prime does.
    static var withoutPriming: ChangeTracker.Options {
        var options = World.promptOptions
        options.primeUpTo = 0
        return options
    }

    // MARK: Inserts

    @Test func reportsAnInsertWithItsValues() async throws {
        let world = try await World()
        let (tracker, sink) = try await world.tracking()

        var note: NSManagedObject?
        try world.commit { writer in note = writer.insert("Note", ["title": "Sixth", "body": "Fresh"]) }

        #expect(await Self.wait { await sink.count == 1 })
        let event = try #require(await sink.events.first)
        #expect(event.kind == .inserted)
        #expect(event.object == (try Self.ref(world.session, #require(note))))
        #expect(event.before == nil, "there was nothing before an insert")
        #expect(event.after?["title"] == .string("Sixth"))
        #expect(event.after?["body"] == .string("Fresh"))
        #expect(event.changedKeys == nil, "every field of a new row is new; none of them is *changed*")
        #expect(event.transition == nil, "no predicate, no transition")

        let batch = try #require(await sink.batches.first)
        #expect(batch.kind == .commit)
        #expect(batch.coalescedCommits == 1)
        #expect(batch.isReducedFidelity == false)
        #expect(batch.latency > .zero)
        await tracker.stop()
        await world.close()
    }

    // MARK: Updates and the field diff (TRK-2)

    /// The point of the whole package: which fields differ, with both values.
    @Test func reportsAnUpdateAsBeforeAndAfter() async throws {
        var note: NSManagedObject?
        let world = try await World { writer in
            note = writer.insert("Note", ["title": "Before", "body": "Unchanged", "pinned": false])
        }
        let (tracker, sink) = try await world.tracking()

        try world.commit { _ in
            note?.setValue("After", forKey: "title")
            note?.setValue(true, forKey: "pinned")
        }

        #expect(await Self.wait { await sink.count == 1 })
        let event = try #require(await sink.events.first)
        #expect(event.kind == .updated)
        #expect(event.changedKeys == ["title", "pinned"], "and not `body`, which was written over with itself")
        #expect(event.isChanged("title"))
        #expect(event.isChanged("body") == false)
        #expect(event.priorValue(of: "title") == .string("Before"))
        #expect(event.currentValue(of: "title") == .string("After"))
        #expect(event.priorValue(of: "body") == .string("Unchanged"))
        #expect(event.isOpaque == false)
        await tracker.stop()
        await world.close()
    }

    /// A row nobody had read is still reported — it changed — but its before-values are `nil` rather than empty,
    /// which would read as "it used to be blank".
    @Test func aRowNobodyHadReadHasNoBefore() async throws {
        var note: NSManagedObject?
        let world = try await World { writer in note = writer.insert("Note", ["title": "Before"]) }
        let (tracker, sink) = try await world.tracking(options: Self.withoutPriming)
        #expect(await tracker.statistics().heldRows == 0)

        try world.commit { _ in note?.setValue("After", forKey: "title") }

        #expect(await Self.wait { await sink.count == 1 })
        let event = try #require(await sink.events.first)
        #expect(event.kind == .updated)
        #expect(event.before == nil)
        #expect(event.after?["title"] == .string("After"))
        #expect(event.changedKeys == nil, "unknown, which is not the same as nothing")
        #expect(event.isOpaque, "the UI says *changed — prior value unknown* rather than showing an empty diff")
        await tracker.stop()
        await world.close()
    }

    /// The cheap half of prior values: the grid has the rows on screen anyway, so handing them over gives a store
    /// too large to prime a before-column for the part of it the user is looking at.
    @Test func whatTheFrontEndRemembersBecomesTheBefore() async throws {
        var note: NSManagedObject?
        let world = try await World { writer in note = writer.insert("Note", ["title": "Before"]) }
        let (tracker, sink) = try await world.tracking(options: Self.withoutPriming)

        let pager = try await world.session.openPager(FetchSpec(entity: "Note"))
        let page = try await world.session.page(pager, range: 0..<pager.count)
        await world.session.closePager(pager)
        await tracker.remember(page)
        #expect(await tracker.statistics().heldRows == 1)

        try world.commit { _ in note?.setValue("After", forKey: "title") }

        #expect(await Self.wait { await sink.count == 1 })
        let event = try #require(await sink.events.first)
        #expect(event.priorValue(of: "title") == .string("Before"))
        #expect(event.changedKeys == ["title"])
        await tracker.stop()
        await world.close()
    }

    /// Only the newest rows are held. A change to one whose values were dropped reads as *prior value unknown* —
    /// the same as a row that was never read, which is what it now is.
    @Test func theValueCacheIsBounded() async throws {
        var first: NSManagedObject?
        var second: NSManagedObject?
        let world = try await World { writer in
            first = writer.insert("Note", ["title": "First"])
            second = writer.insert("Note", ["title": "Second"])
        }
        var options = Self.withoutPriming
        options.priorValueLimit = 1
        let (tracker, sink) = try await world.tracking(options: options)

        // Handed over in pager order, so which one the cache keeps is not a matter of luck: the second arrives
        // last and pushes the first out.
        let pager = try await world.session.openPager(FetchSpec(entity: "Note", sort: [SortKey(keyPath: "title")]))
        let page = try await world.session.page(pager, range: 0..<pager.count)
        await world.session.closePager(pager)
        await tracker.remember(page)
        #expect(await tracker.statistics().heldRows == 1, "two rows were handed over; one is kept")

        try world.commit { _ in
            first?.setValue("First, edited", forKey: "title")
            second?.setValue("Second, edited", forKey: "title")
        }

        #expect(await Self.wait { await sink.count == 1 })
        let firstRef = try Self.ref(world.session, #require(first))
        let secondRef = try Self.ref(world.session, #require(second))
        let evicted = try #require(await sink.events(about: firstRef).first)
        #expect(evicted.before == nil, "the oldest arrival went first, and this was the first")
        #expect(evicted.after?["title"] == .string("First, edited"))
        let kept = try #require(await sink.events(about: secondRef).first)
        #expect(kept.priorValue(of: "title") == .string("Second"))
        await tracker.stop()
        await world.close()
    }

    // MARK: Deletes

    @Test func reportsADeleteWithWhatWasThere() async throws {
        var note: NSManagedObject?
        let world = try await World { writer in note = writer.insert("Note", ["title": "Doomed"]) }
        let deleted = try Self.ref(world.session, #require(note))
        let (tracker, sink) = try await world.tracking()

        try world.commit { writer in writer.context.delete(try #require(note)) }

        #expect(await Self.wait { await sink.count == 1 })
        let event = try #require(await sink.events.first)
        #expect(event.kind == .deleted)
        #expect(event.object == deleted)
        #expect(event.priorValue(of: "title") == .string("Doomed"), "primed before it went")
        #expect(event.after == nil)
        // Nothing is held about a row that is not there any more.
        #expect(await tracker.statistics().heldRows == 0)
        await tracker.stop()
        await world.close()
    }

    // MARK: Predicate views (TRK-7)

    /// ↘ and ↗: the rows a saved view gained and lost. A predicate answers "does it match *now*", so this is only
    /// possible because the tracker remembers which side each row was on.
    @Test func reportsRowsEnteringAndLeavingTheView() async throws {
        var draft: NSManagedObject?
        var kept: NSManagedObject?
        let world = try await World { writer in
            draft = writer.insert("Note", ["title": "Draft"])
            kept = writer.insert("Note", ["title": "Keep me"])
        }
        let scope = TrackingScope.entities(["Note"], predicate: PredicateSource(format: "title BEGINSWITH 'Keep'"))
        let (tracker, sink) = try await world.tracking(scope)

        try world.commit { _ in draft?.setValue("Keep this too", forKey: "title") }
        #expect(await Self.wait { await sink.count == 1 })
        let entered = try #require(await sink.events.last)
        #expect(entered.object == (try Self.ref(world.session, #require(draft))))
        #expect(entered.transition == .entered)

        try world.commit { _ in kept?.setValue("Dropped", forKey: "title") }
        #expect(await Self.wait { await sink.count == 2 })
        let left = try #require(await sink.events.last)
        #expect(left.object == (try Self.ref(world.session, #require(kept))))
        #expect(left.transition == .left)
        #expect(left.currentValue(of: "title") == .string("Dropped"), "the row leaving still says what it became")
        await tracker.stop()
        await world.close()
    }

    /// A row that was never in the view and still is not is not news to somebody looking at the view.
    @Test func changesOutsideTheViewAreNotReported() async throws {
        var outside: NSManagedObject?
        let world = try await World { writer in outside = writer.insert("Note", ["title": "Draft"]) }
        let scope = TrackingScope.entities(["Note"], predicate: PredicateSource(format: "title BEGINSWITH 'Keep'"))
        let (tracker, sink) = try await world.tracking(scope)

        try world.commit { writer in
            outside?.setValue("Still a draft", forKey: "title")
            writer.insert("Note", ["title": "New draft"])
        }

        #expect(await Self.wait { await sink.count == 1 }, "the commit is still delivered")
        let batch = try #require(await sink.batches.first)
        #expect(batch.isEmpty, "and carries nothing, because nothing in the view changed")
        await tracker.stop()
        await world.close()
    }

    /// Without a predicate nothing is claimed about a boundary that does not exist.
    @Test func aScopeWithoutAPredicateReportsNoTransitions() async throws {
        let world = try await World()
        let (tracker, sink) = try await world.tracking()

        try world.commit { writer in writer.insert("Note", ["title": "Anything"]) }

        #expect(await Self.wait { await sink.count == 1 })
        #expect(await sink.events.allSatisfy { $0.transition == nil })
        await tracker.stop()
        await world.close()
    }

    // MARK: Links (TRK-9)

    /// A many-to-many lives in a join table, and gaining a link need not touch either row's save counter — so the
    /// rows at its ends are reported because of the link, not because the scan found them.
    ///
    /// The entity is the row's own: `Person.tags` names `Person`, but a `Manager` row is a `Manager`, and that is
    /// the layout its values come back in.
    @Test func reportsLinkChangesAgainstTheRowsAtBothEnds() async throws {
        var manager: NSManagedObject?
        var tag: NSManagedObject?
        let world = try await World(model: CompanyFixture.makeModel(), name: "Company.sqlite") { writer in
            manager = writer.insert("Manager", ["name": "Grace", "level": 3])
            tag = writer.insert("Tag", ["label": "founder"])
        }
        let (tracker, sink) = try await world.tracking()

        try world.commit { _ in manager?.setValue(NSSet(array: [try #require(tag)]), forKey: "tags") }

        #expect(await Self.wait { await sink.count == 1 })
        let managerRef = try Self.ref(world.session, #require(manager))
        let tagRef = try Self.ref(world.session, #require(tag))

        let onTheManager = try #require(await sink.events(about: managerRef).first)
        #expect(onTheManager.kind == .updated)
        #expect(onTheManager.links.count == 1)
        #expect(onTheManager.links.first?.kind == .added)
        #expect(onTheManager.links.first?.relationship == "tags")
        #expect(onTheManager.links.first?.source == RowID(entity: "Manager", pk: managerRef.pk))
        #expect(
            onTheManager.after?["level"] == .int(3),
            "the row was read by its own entity's layout, not the one the relationship declares")

        let onTheTag = try #require(await sink.events(about: tagRef).first)
        #expect(onTheTag.links.count == 1, "the other end of the same link")
        #expect(onTheTag.after?["label"] == .string("founder"))
        await tracker.stop()
        await world.close()
    }

    /// A to-many is part of the reading as a count, so gaining a link is a field that differs as well as a link
    /// that moved — the same change told twice, at two levels of detail.
    @Test func aLinkChangeShowsAsTheToManyCountChanging() async throws {
        var person: NSManagedObject?
        var tag: NSManagedObject?
        let world = try await World(model: CompanyFixture.makeModel(), name: "Company.sqlite") { writer in
            person = writer.insert("Person", ["name": "Ada"])
            tag = writer.insert("Tag", ["label": "founder"])
        }
        let (tracker, sink) = try await world.tracking()

        try world.commit { _ in person?.setValue(NSSet(array: [try #require(tag)]), forKey: "tags") }

        #expect(await Self.wait { await sink.count == 1 })
        let personRef = try Self.ref(world.session, #require(person))
        let event = try #require(await sink.events(about: personRef).first)
        #expect(event.changedKeys == ["tags"], "nothing else about the person changed")
        #expect(event.priorValue(of: "tags") == .toMany(count: 0))
        #expect(event.currentValue(of: "tags") == .toMany(count: 1))
        #expect(event.isOpaque == false)
        #expect(event.links.count == 1, "and the link itself says which tag it was")
        #expect(event.links.first?.destination.entity == "Tag")
        await tracker.stop()
        await world.close()
    }

    // MARK: Pause and resume (TRK-9)

    /// Commits are counted while paused and reported as one batch that says how many it stands for. A row that was
    /// inserted and deleted again in the meantime is not news.
    @Test func pausedCommitsAreReportedAsTheirNetDifference() async throws {
        let world = try await World()
        let (tracker, sink) = try await world.tracking()
        await tracker.pause()
        #expect(await tracker.isPaused)

        // Waited for one at a time: three saves inside the watcher's debounce are one commit as far as anybody
        // outside SQLite can tell, and this test is about the counting, not the debouncing.
        var transient: NSManagedObject?
        try world.commit { writer in transient = writer.insert("Note", ["title": "Here and gone"]) }
        #expect(await Self.wait { await tracker.statistics().pendingCommits >= 1 })
        try world.commit { writer in writer.insert("Note", ["title": "Kept"]) }
        #expect(await Self.wait { await tracker.statistics().pendingCommits >= 2 })
        try world.commit { writer in writer.context.delete(try #require(transient)) }
        #expect(await Self.wait { await tracker.statistics().pendingCommits == 3 })
        #expect(await sink.count == 0, "nothing is read while paused")

        await tracker.resume()
        #expect(await Self.wait { await sink.count == 1 })
        let batch = try #require(await sink.batches.first)
        #expect(batch.coalescedCommits == 3, "and says so, rather than pretending to be one commit")
        #expect(batch.events.count == 1)
        #expect(batch.events.first?.kind == .inserted)
        #expect(batch.events.first?.after?["title"] == .string("Kept"))
        #expect(await tracker.isPaused == false)
        await tracker.stop()
        await world.close()
    }

    // MARK: The version log (TRK-2, TRK-5)

    @Test func everyChangeBecomesAVersion() async throws {
        var note: NSManagedObject?
        let world = try await World { writer in note = writer.insert("Note", ["title": "One"]) }
        let (tracker, sink) = try await world.tracking()

        try world.commit { _ in note?.setValue("Two", forKey: "title") }
        #expect(await Self.wait { await sink.count == 1 })
        try world.commit { _ in note?.setValue("Three", forKey: "title") }
        #expect(await Self.wait { await sink.count == 2 })

        let ref = try Self.ref(world.session, #require(note))
        let versions = await tracker.versions.versions(of: ref)
        #expect(versions.count == 2)
        #expect(versions.map(\.sequence) == [2, 1], "newest first")
        #expect(versions.first?.event.currentValue(of: "title") == .string("Three"))
        #expect(versions.first?.event.priorValue(of: "title") == .string("Two"), "each version diffs the last")

        let objects = await tracker.versions.objects()
        #expect(objects.count == 1)
        #expect(objects.first?.object == ref)
        #expect(objects.first?.versions == 2)
        await tracker.stop()
        #expect(await tracker.versions.count == 2, "the user is still reading it after tracking stops")
        await world.close()
    }

    // MARK: Deep tracking (§6.6)

    /// With a copy of the store to hand, *every* row's prior values are knowable — not only the ones that were
    /// primed or paged in.
    @Test func deepTrackingKnowsThePriorValuesOfARowNobodyRead() async throws {
        var note: NSManagedObject?
        let world = try await World { writer in note = writer.insert("Note", ["title": "Before"]) }
        var options = Self.withoutPriming
        options.deepTracking = true
        let (tracker, sink) = try await world.tracking(options: options)
        #expect(await tracker.deepTrackingIsActive)
        #expect(await tracker.statistics().heldRows == 0, "nothing was primed; the copy is the before")

        try world.commit { _ in note?.setValue("After", forKey: "title") }

        #expect(await Self.wait { await sink.count == 1 })
        let event = try #require(await sink.events.first)
        #expect(event.priorValue(of: "title") == .string("Before"))
        #expect(event.changedKeys == ["title"])
        await tracker.stop()
        #expect(await tracker.deepTrackingIsActive == false, "and the copy is deleted with it")
        await world.close()
    }

    /// Deep tracking copies the database with SQLite's backup API, and a blob Core Data keeps in the support
    /// folder beside the store is not in that copy. What that may cost is the blob's prior value; what it must not
    /// cost is the event, or the fields that are in the copy.
    @Test func aDeepCopyHoldsTheDatabaseAndNotTheBlobsBesideIt() async throws {
        // The fixture's own copy, support folder and all, because this one is written to.
        let fixture = try TestFixtures.scratchCopy(.externalData)
        let connection = try SQLiteConnection(readOnly: fixture.storeURL)
        let model = try ModelLoader.cachedModel(in: connection)
        connection.close()
        let writer = try StoreWriter(model: model, storeURL: fixture.storeURL, author: "app")
        let session = try await StoreSession.open(storeURL: fixture.storeURL)
        var options = Self.withoutPriming
        options.deepTracking = true
        let tracker = ChangeTracker(session: session, options: options)
        let sink = Sink()
        await sink.drain(try await tracker.start())
        #expect(await tracker.deepTrackingIsActive)

        // Document 4 carries the 1.2 MB payload, which is the one Core Data stores as a file.
        try writer.perform { writer in
            let request = NSFetchRequest<NSManagedObject>(entityName: "Document")
            request.predicate = NSPredicate(format: "title == %@", "Document 4")
            for document in try writer.context.fetch(request) {
                document.setValue("Renamed", forKey: "title")
            }
        }

        #expect(await Self.wait { await sink.count == 1 })
        let event = try #require(await sink.events.first)
        #expect(event.priorValue(of: "title") == .string("Document 4"), "read out of the copy")
        #expect(event.isChanged("title"))
        #expect(event.isChanged("payload") == false, "not touched, and not in the copy either: unknown, not empty")
        #expect(event.priorValue(of: "payload") == nil, "the copy cannot speak for it")
        #expect(event.currentValue(of: "payload")?.isNull == false, "the live store still has it")
        #expect(event.isChanged("thumbnail") == false, "a blob inside the database compares as usual")
        #expect(event.priorValue(of: "thumbnail")?.isNull == false)
        await tracker.stop()
        await session.close()
        try? writer.close()
    }

    // MARK: A store replaced underneath (§6.6)

    /// A reinstall, a restore, a copy put back: the same name, a different file. Every key and every value held is
    /// about a file that is gone, so the batch reporting it carries no events, nothing goes into the log, and
    /// tracking stops — reopening the store is the front end's to do, because the model may have changed with it.
    @Test func aStoreReplacedStopsTracking() async throws {
        let world = try await World { writer in writer.insert("Note", ["title": "Before"]) }
        let replacement = try await World(name: "Replacement.sqlite") { writer in
            writer.insert("Note", ["title": "From the other store"])
        }
        let (tracker, sink) = try await world.tracking()

        // Closed first: a file Core Data still holds open is not one to move another over.
        try world.writer.close()
        try replacement.writer.close()
        let files = FileManager.default
        try files.removeItem(at: world.storeURL)
        try files.moveItem(at: replacement.storeURL, to: world.storeURL)

        #expect(await Self.wait { await sink.batches.contains { $0.kind == .storeReplaced } })
        let batch = try #require(await sink.batches.last)
        #expect(batch.isEmpty, "nothing read about the old file says anything about this one")
        #expect(await tracker.versions.count == 0, "and a batch with no events is not a version")
        #expect(await Self.wait { await tracker.isTracking == false })
        #expect(await Self.wait { await sink.isFinished }, "the stream ends; the front end starts a new tracker")
        await world.close()
        await replacement.close()
    }

    // MARK: Lifetime

    @Test func statisticsSayWhatIsHeld() async throws {
        let world = try await World { writer in
            let folder = writer.insert("Folder", ["name": "Inbox"])
            for index in 0..<3 { writer.insert("Note", ["title": "Note \(index)", "folder": folder]) }
        }
        let (tracker, _) = try await world.tracking()

        let statistics = await tracker.statistics()
        #expect(statistics.isTracking)
        #expect(statistics.isPaused == false)
        #expect(statistics.heldRows == 4, "a folder and three notes, all small enough to prime")
        #expect(statistics.heldKeys == 4)
        #expect(statistics.heldKeyBytes > 0)
        #expect(statistics.pendingCommits == 0)
        #expect(statistics.limitations.isEmpty)
        #expect(statistics.deepTrackingIsActive == false)
        #expect(statistics.lastFailure == nil)
        await tracker.stop()

        let stopped = await tracker.statistics()
        #expect(stopped.isTracking == false)
        #expect(stopped.heldRows == 0)
        #expect(stopped.heldKeys == 0)
        await world.close()
    }

    @Test func stoppingFinishesTheStream() async throws {
        let world = try await World()
        let (tracker, sink) = try await world.tracking()
        #expect(await sink.isFinished == false)

        await tracker.stop()

        #expect(await Self.wait { await sink.isFinished })
        #expect(await tracker.isTracking == false)
        await world.close()
    }

    /// A second `start` while tracking is another window onto the same pipeline, not a second scan of the store.
    @Test func everySubscriberSeesTheSameBatches() async throws {
        let world = try await World()
        let (tracker, first) = try await world.tracking()
        let second = Sink()
        await second.drain(try await tracker.start())

        try world.commit { writer in writer.insert("Note", ["title": "Shared"]) }

        #expect(await Self.wait { await first.count == 1 })
        #expect(await Self.wait { await second.count == 1 })
        #expect(await first.batches == second.batches)
        await tracker.stop()
        await world.close()
    }
}
