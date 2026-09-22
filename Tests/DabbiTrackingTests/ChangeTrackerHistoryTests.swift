@preconcurrency import CoreData
import DabbiBase
import DabbiModel
import DabbiStore
import DabbiTestSupport
import FixtureKit
import Foundation
import Testing

@testable import DabbiTracking

/// What persistent history adds to a tracked change, and what it is not allowed to take away (TRK-10).
///
/// The contract these tests hold the tracker to: **the scan says which rows changed; history says who changed
/// them** — never the other way round. A store can carry history tables and still be written by a process saving
/// with tracking off; those saves reach the file and never reach `ATRANSACTION`, so a history-first tracker would
/// miss them in silence, which is the one thing ADR-17 rules out. What history adds is what the scan cannot get
/// at any price: the author, the save time, the field names of a row nobody had read, and the last values of a
/// row nobody will ever read again.
///
/// Serialized for the same reason as `ChangeTrackerTests`: every test here waits on a file-system event, and a
/// late event is indistinguishable from a missing one.
@Suite(.serialized) struct ChangeTrackerHistoryTests {
    typealias World = ChangeTrackerTests.World
    typealias Sink = ChangeTrackerTests.Sink

    /// A tracked store that records history, with a writer holding it open.
    static func world(seed: (StoreWriter) throws -> Void = { _ in }) async throws -> World {
        try await World(
            model: NotesFixture.makeHistoryModel(), name: "History.sqlite",
            storeOptions: NotesFixture.historyOptions, seed: seed)
    }

    static func wait(
        upTo timeout: Duration = .seconds(10), for condition: @Sendable () async -> Bool
    ) async -> Bool {
        await ChangeTrackerTests.wait(upTo: timeout, for: condition)
    }

    // MARK: Enrichment

    @Test func namesWhoSavedAndWhen() async throws {
        let world = try await Self.world()
        let (tracker, sink) = try await world.tracking()
        #expect(await tracker.statistics().historySource == .coreData)

        let before = Date()
        try world.commit { writer in writer.insert("Note", ["title": "From the app"]) }
        #expect(await Self.wait { await sink.count == 1 })

        let event = try #require(await sink.events.first)
        let history = try #require(event.history, "the store records history, so the change has an author")
        #expect(history.author == "app")
        #expect(history.transactionNumber > 0)
        #expect(history.transactionCount == 1)
        #expect(history.attribution == "app")
        // When the *app* saved, which is not when the tracker noticed; `at` stays what it says it is.
        let saved = try #require(history.timestamp)
        #expect(saved >= before.addingTimeInterval(-1))
        #expect(saved <= event.at.addingTimeInterval(1))

        let batch = try #require(await sink.batches.first)
        #expect(batch.authors == ["app"])
        #expect(batch.savedAt?.contains(saved) == true)
        #expect(!batch.isReducedFidelity, "history accounted for every row, so nothing was reduced")
        await tracker.stop()
        await world.close()
    }

    @Test func separatesTwoAuthorsInOneBatch() async throws {
        var seeded: NSManagedObject?
        let world = try await Self.world { writer in seeded = writer.insert("Note", ["title": "Shared"]) }
        let note = try #require(seeded)
        let (tracker, sink) = try await world.tracking()

        try world.writer.perform(author: "sync") { _ in note.setValue(true, forKey: "pinned") }
        try world.writer.perform(author: "app") { writer in writer.insert("Note", ["title": "Second"]) }

        #expect(await Self.wait { await sink.events.count >= 2 })
        let events = await sink.events
        #expect(events.first { $0.kind == .updated }?.history?.author == "sync")
        #expect(events.first { $0.kind == .inserted }?.history?.author == "app")
        #expect(Set(await sink.batches.flatMap(\.authors)) == ["sync", "app"])
        await tracker.stop()
        await world.close()
    }

    /// The gap M2-09 left open, closed: a row nobody had read still names the fields the save wrote.
    @Test func namesChangedFieldsForARowNobodyHeld() async throws {
        var seeded: NSManagedObject?
        let world = try await Self.world { writer in
            seeded = writer.insert("Note", ["title": "Untouched", "body": "Original"])
        }
        let note = try #require(seeded)
        // Nothing primed and nothing remembered: the tracker holds no prior values at all.
        let (tracker, sink) = try await world.tracking(options: ChangeTrackerTests.withoutPriming)

        try world.commit { _ in note.setValue("Rewritten", forKey: "body") }
        #expect(await Self.wait { await sink.count == 1 })

        let event = try #require(await sink.events.first)
        #expect(event.before == nil, "nobody read this row, so nothing can be said about what it held")
        #expect(event.changedKeys == ["body"], "but history knows which field the save wrote")
        #expect(event.isChanged("body"))
        #expect(!event.isChanged("title"))
        #expect(!event.isOpaque, "a change with named fields is not an opaque one")
        #expect(event.priorValue(of: "body") == nil, "naming a field is not knowing what it was")
        await tracker.stop()
        await world.close()
    }

    /// History says what a save *wrote*; the diff says what *changed*. Where both can speak, the diff wins.
    @Test func theDiffOutranksHistory() async throws {
        var seeded: NSManagedObject?
        let world = try await Self.world { writer in
            seeded = writer.insert("Note", ["title": "Same", "body": "Different soon"])
        }
        let note = try #require(seeded)
        let (tracker, sink) = try await world.tracking()

        // Two fields written, one of them with the value it already held.
        try world.commit { _ in
            note.setValue("Same", forKey: "title")
            note.setValue("Different now", forKey: "body")
        }
        #expect(await Self.wait { await sink.count == 1 })

        let event = try #require(await sink.events.first)
        #expect(event.history?.author == "app", "the enrichment still arrives")
        #expect(
            event.changedKeys == ["body"],
            "whatever the save wrote, writing a field the value it already held changed nothing")
        #expect(event.priorValue(of: "body") == .string("Different soon"))
        await tracker.stop()
        await world.close()
    }

    @Test func aDeletedRowKeepsWhatTheModelPreserved() async throws {
        var seeded: NSManagedObject?
        let world = try await Self.world { writer in
            seeded = writer.insert("Note", ["title": "Doomed", "body": "Not preserved"])
        }
        let note = try #require(seeded)
        let (tracker, sink) = try await world.tracking(options: ChangeTrackerTests.withoutPriming)

        try world.commit { writer in writer.context.delete(note) }
        #expect(await Self.wait { await sink.count == 1 })

        let event = try #require(await sink.events.first)
        #expect(event.kind == .deleted)
        #expect(event.beforeIsTombstone, "nobody ever read this row; this is what history kept of it")
        #expect(event.priorValue(of: "title") == .string("Doomed"))
        #expect(event.priorValue(of: "body") == nil, "body is not preserved in history, so it is simply gone")
        #expect(event.before?.columns.properties.contains("title") == true)
        #expect(event.before?.columns.properties.contains("body") == false, "a tombstone is not a reading")
        #expect(event.history?.author == "app")
        await tracker.stop()
        await world.close()
    }

    @Test func aRememberedRowIsShownAsReadNotAsATombstone() async throws {
        var seeded: NSManagedObject?
        let world = try await Self.world { writer in
            seeded = writer.insert("Note", ["title": "Doomed", "body": "Held by the grid"])
        }
        let note = try #require(seeded)
        // Primed: the tracker holds this row's values, and something somebody read beats a tombstone.
        let (tracker, sink) = try await world.tracking()

        try world.commit { writer in writer.context.delete(note) }
        #expect(await Self.wait { await sink.count == 1 })

        let event = try #require(await sink.events.first)
        #expect(event.kind == .deleted)
        #expect(!event.beforeIsTombstone)
        #expect(event.priorValue(of: "body") == .string("Held by the grid"), "the whole row, not the preserved bit")
        await tracker.stop()
        await world.close()
    }

    // MARK: What history cannot account for

    /// The reason the scan, and not history, decides which rows changed.
    ///
    /// A second writer on the same file with tracking switched off saves rows that never reach `ATRANSACTION`.
    /// The tracker must still report them — and must say it could not name who saved them.
    @Test func reportsSavesHistoryNeverSaw() async throws {
        let world = try await Self.world()
        let (tracker, sink) = try await world.tracking()

        let untracked = try StoreWriter(
            model: NotesFixture.makeHistoryModel(), storeURL: world.storeURL, author: "invisible")
        try untracked.perform { writer in writer.insert("Note", ["title": "Saved without history"]) }
        try untracked.close()

        #expect(await Self.wait { await sink.events.contains { $0.kind == .inserted } })
        let event = try #require(await sink.events.first { $0.kind == .inserted })
        #expect(event.after?["title"] == .string("Saved without history"), "reported, which is the point")
        #expect(event.history == nil, "and nameless, which is said rather than hidden")

        let batch = try #require(await sink.batches.first { $0.events.contains { $0.kind == .inserted } })
        #expect(batch.isReducedFidelity)
        #expect(batch.limitations.contains(ScanLimitation(reason: .historyIncomplete, subject: "Note")))
        #expect(batch.authors.isEmpty)
        await tracker.stop()
        await world.close()
    }

    @Test func aStoreWithoutHistoryIsNotReducedFidelity() async throws {
        // The ordinary case: no history tables at all. Saying "no author" on every batch of every ordinary store
        // would make `isReducedFidelity` mean nothing at all.
        let world = try await World()
        let (tracker, sink) = try await world.tracking()
        #expect(await tracker.statistics().historySource == nil)

        try world.commit { writer in writer.insert("Note", ["title": "No history here"]) }
        #expect(await Self.wait { await sink.count == 1 })

        let batch = try #require(await sink.batches.first)
        #expect(batch.events.first?.history == nil)
        #expect(!batch.isReducedFidelity)
        #expect(batch.limitations.isEmpty)
        #expect(batch.authors.isEmpty)
        await tracker.stop()
        await world.close()
    }

    @Test func switchingEnrichmentOffChangesNothingElse() async throws {
        var options = World.promptOptions
        options.history.isEnabled = false
        var seeded: NSManagedObject?
        let world = try await Self.world { writer in seeded = writer.insert("Note", ["title": "Before"]) }
        let note = try #require(seeded)
        let (tracker, sink) = try await world.tracking(options: options)
        #expect(await tracker.statistics().historySource == nil)

        try world.commit { _ in note.setValue("After", forKey: "title") }
        #expect(await Self.wait { await sink.count == 1 })

        let batch = try #require(await sink.batches.first)
        #expect(batch.events.first?.history == nil)
        #expect(batch.events.first?.changedKeys == ["title"], "the diff still works; it never needed history")
        #expect(batch.limitations.isEmpty, "nothing was promised, so nothing is owed")
        await tracker.stop()
        await world.close()
    }

    // MARK: Starting and stopping

    @Test func startsFromNowNotFromTheStoresWholeHistory() async throws {
        let world = try await Self.world { writer in
            for index in 0..<5 { writer.insert("Note", ["title": "Old \(index)"]) }
        }
        // Several transactions are already in ATRANSACTION before the tracker ever looks at the store.
        for index in 0..<4 {
            try world.commit { writer in writer.insert("Note", ["title": "Older \(index)"]) }
        }
        let (tracker, sink) = try await world.tracking()

        try world.commit { writer in writer.insert("Note", ["title": "New"]) }
        #expect(await Self.wait { await sink.count >= 1 })

        let events = await sink.events
        #expect(events.count == 1, "a tracker reports what happened while it was watching, not the store's past")
        #expect(events.first?.after?["title"] == .string("New"))
        #expect(events.first?.history?.transactionCount == 1)
        await tracker.stop()
        await world.close()
    }

    @Test func stoppingLetsGoOfTheReader() async throws {
        let world = try await Self.world()
        let (tracker, _) = try await world.tracking()
        #expect(await tracker.statistics().historySource == .coreData)
        await tracker.stop()
        #expect(await tracker.statistics().historySource == nil)
        await world.close()
    }

    // MARK: Folding a batch

    @Test func foldsSeveralTransactionsPerRow() throws {
        let first = HistoryTransaction(
            number: 1, timestamp: Date(timeIntervalSinceReferenceDate: 1), author: "app",
            changes: [HistoryChange(entity: "Note", pk: 7, kind: .updated, updatedProperties: ["title"])])
        let second = HistoryTransaction(
            number: 2, timestamp: Date(timeIntervalSinceReferenceDate: 2), author: "sync",
            changes: [HistoryChange(entity: "Note", pk: 7, kind: .updated, updatedProperties: ["body"])])

        let row = try #require(HistoryDigest([first, second])[RowID(entity: "Note", pk: 7)])
        #expect(row.updatedProperties == ["title", "body"], "between them, that is what the batch wrote")
        #expect(row.info.author == "sync", "the save that left the row as the scan found it")
        #expect(row.info.transactionCount == 2, "and two saves are standing behind that one name")
    }

    @Test func oneUnknownTransactionMakesTheWholeUnionUnknown() {
        let named = HistoryTransaction(
            number: 1,
            changes: [HistoryChange(entity: "Note", pk: 7, kind: .updated, updatedProperties: ["title"])])
        let silent = HistoryTransaction(
            number: 2, changes: [HistoryChange(entity: "Note", pk: 7, kind: .updated, updatedProperties: nil)])
        // Half an answer would read as "these fields and no others", which is a claim nobody can make (ADR-17).
        #expect(HistoryDigest([named, silent])[RowID(entity: "Note", pk: 7)]?.updatedProperties == nil)
        #expect(HistoryDigest([silent, named])[RowID(entity: "Note", pk: 7)]?.updatedProperties == nil)
    }

    @Test func namesOneEntityPerUnaccountedRow() {
        let digest = HistoryDigest([
            HistoryTransaction(number: 1, changes: [HistoryChange(entity: "Note", pk: 1, kind: .updated)])
        ])
        let scanned = [
            RowID(entity: "Note", pk: 1), RowID(entity: "Note", pk: 2), RowID(entity: "Note", pk: 3),
            RowID(entity: "Folder", pk: 9),
        ]
        // Two notes and a folder went unaccounted for; the limitation names entities, never rows (§10).
        let expected = [
            ScanLimitation(reason: .historyIncomplete, subject: "Folder"),
            ScanLimitation(reason: .historyIncomplete, subject: "Note"),
        ]
        #expect(digest.limitations(accountingFor: scanned) == expected)
        #expect(digest.limitations(accountingFor: [RowID(entity: "Note", pk: 1)]).isEmpty)
    }

    @Test func aTruncatedReadSaysSo() {
        let digest = HistoryDigest([HistoryTransaction(number: 9)], isTruncated: true)
        #expect(
            digest.limitations(accountingFor: []) == [
                ScanLimitation(reason: .historyIncomplete, subject: "ATRANSACTION")
            ])
    }
}
