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

/// Persistent history, read both ways (ARCHITECTURE.md §6.6, TRK-10).
///
/// The suite's centre of gravity is `bothReadersAgree`. Everything `RawHistoryReader` knows about `ATRANSACTION`
/// and `ACHANGE` is private format knowledge, and the only honest way to hold it is to check it against the one
/// reader that cannot be wrong about it — Apple's. When a future Core Data moves a bit, that test says so.
@Suite struct HistoryReaderTests {
    /// The history fixture, open, with both readers on it.
    struct World {
        let location: FixtureLocation
        let session: StoreSession

        init() async throws {
            location = try TestFixtures.location(.history)
            session = try await StoreSession.open(storeURL: location.storeURL)
        }

        var coreData: CoreDataHistoryReader { CoreDataHistoryReader(session: session) }

        var raw: RawHistoryReader {
            RawHistoryReader(url: session.info.url, model: session.info.model, schema: session.info.schemaMap)
        }

        func close() async { await session.close() }
    }

    // MARK: The fixture, as both readers see it

    @Test func bothReadersAgree() async throws {
        let world = try await World()
        let (raw, coreData) = (world.raw, world.coreData)
        let fromTables = try await raw.transactions(after: nil)
        let fromAPI = try await coreData.transactions(after: nil)

        #expect(fromTables.map(\.number) == fromAPI.map(\.number))
        #expect(fromTables.map(\.author) == fromAPI.map(\.author))
        #expect(fromTables.map(\.contextName) == fromAPI.map(\.contextName))
        for (tables, api) in zip(fromTables, fromAPI) {
            #expect(tables.timestamp == api.timestamp, "transaction \(tables.number)")
            // Order is the reader's business, not the format's: compare as sets of (entity, pk, kind).
            let keys = { (transaction: HistoryTransaction) in
                Set(transaction.changes.map { "\($0.entity)#\($0.pk):\($0.kind.rawValue)" })
            }
            #expect(keys(tables) == keys(api), "transaction \(tables.number)")
            for change in tables.changes {
                let twin = try #require(api.change(ofEntity: change.entity, pk: change.pk))
                #expect(change.updatedProperties == twin.updatedProperties, "\(change.entity)#\(change.pk)")
                #expect(change.tombstone == twin.tombstone, "\(change.entity)#\(change.pk)")
            }
        }
        await raw.close()
        await world.close()
    }

    @Test func namesWhoSavedAndWhen() async throws {
        let world = try await World()
        let transactions = try await world.coreData.transactions(after: nil)
        #expect(transactions.count == 5, "the fixture's five saves")
        #expect(transactions.map(\.author) == ["app", "app", "sync", "app", "sync"])
        #expect(transactions.allSatisfy { $0.contextName == "fixture-writer" })
        #expect(transactions.allSatisfy { $0.timestamp != nil })
        #expect(transactions.map(\.number) == transactions.map(\.number).sorted(), "oldest first")
        // The attribution line a UI shows, and the one thing here that may be logged (§10).
        #expect(HistoryInfo(transactions[2]).attribution == "sync")
        await world.close()
    }

    /// The gap M2-09 left open, at the source: history knows which fields a save wrote even though nobody read
    /// the row before it.
    @Test func namesTheFieldsASaveWrote() async throws {
        let world = try await World()
        let transactions = try await world.coreData.transactions(after: nil)
        let pinning = try #require(transactions.first { $0.author == "sync" })
        let updates = pinning.changes.filter { $0.kind == .updated }
        #expect(updates.count == 3, "three notes were pinned")
        #expect(updates.allSatisfy { $0.updatedProperties == ["pinned"] })
        await world.close()
    }

    @Test func keepsWhatADeletedRowHeld() async throws {
        let world = try await World()
        for reader in [AnyReader(world.coreData), AnyReader(world.raw)] {
            let transactions = try await reader.reader.transactions(after: nil)
            let deletion = try #require(
                transactions.flatMap(\.changes).first { $0.kind == .deleted },
                "the fixture deletes one note")
            // Only the two attributes the model preserves: a tombstone is not a reading of the row.
            #expect(Set(deletion.tombstone.keys) == ["title", "modifiedAt"], "\(reader.name)")
            #expect(deletion.tombstone["title"] == .string("Note 9"), "\(reader.name)")
            if case .date = deletion.tombstone["modifiedAt"] {
            } else {
                Issue.record("\(reader.name): modifiedAt should have come back as a date")
            }
            await reader.reader.close()
        }
        await world.close()
    }

    @Test func carriesOnFromATokenEitherReaderMinted() async throws {
        let world = try await World()
        let raw = world.raw
        let all = try await world.coreData.transactions(after: nil)
        let third = all[2]

        // Each reader's own token, and then the other's: a token is a transaction number plus, sometimes, an
        // archived object, and either reader can take either.
        #expect(try await world.coreData.transactions(after: third.token).map(\.number) == [4, 5])
        #expect(try await raw.transactions(after: third.token).map(\.number) == [4, 5])
        let rawThird = try #require(try await raw.transactions(after: nil).first { $0.number == third.number })
        #expect(try await world.coreData.transactions(after: rawThird.token).map(\.number) == [4, 5])
        #expect(try await raw.transactions(after: HistoryToken.beginning).count == all.count)
        await raw.close()
        await world.close()
    }

    @Test func aLimitKeepsTheNewest() async throws {
        let world = try await World()
        let raw = world.raw
        #expect(try await world.coreData.transactions(after: nil, limit: 2).map(\.number) == [4, 5])
        #expect(try await raw.transactions(after: nil, limit: 2).map(\.number) == [4, 5])
        #expect(try await raw.transactions(after: nil, limit: 0).isEmpty)
        await raw.close()
        await world.close()
    }

    @Test func currentTokenLeavesNothingBehindIt() async throws {
        let world = try await World()
        let raw = world.raw
        let token = try #require(try await world.coreData.currentToken())
        #expect(token.transactionNumber == 5)
        #expect(try await world.coreData.transactions(after: token).isEmpty)
        #expect(try await raw.currentToken() == HistoryToken(transactionNumber: 5))
        #expect(try await raw.transactions(after: token).isEmpty)
        await raw.close()
        await world.close()
    }

    // MARK: Choosing a reader

    @Test func prefersTheOneItIsAskedFor() async throws {
        let world = try await World()
        #expect(world.session.tracksHistory)
        let preferred = try #require(await HistoryReaders.open(for: world.session))
        #expect(preferred.source == .coreData)
        await preferred.close()
        let fallback = try #require(await HistoryReaders.open(for: world.session, preferring: .rawTables))
        #expect(fallback.source == .rawTables)
        await fallback.close()
        await world.close()
    }

    @Test func aStoreWithoutHistorySaysSoRatherThanGuessing() async throws {
        let session = try await StoreSession.open(storeURL: try TestFixtures.location(.basic).storeURL)
        #expect(!session.tracksHistory)
        #expect(await HistoryReaders.open(for: session) == nil)
        let error = await #expect(throws: DabbiError.self) { try await session.historyTransactions() }
        #expect(error?.code == .historyUnavailable)
        #expect(error?.recovery.isEmpty == false, "a store nobody can switch history on for needs a way forward")
        // The raw reader is just as blunt about it.
        let raw = RawHistoryReader(url: session.info.url, model: session.info.model, schema: session.info.schemaMap)
        await #expect(throws: DabbiError.self) { try await raw.currentToken() }
        await raw.close()
        await session.close()
    }

    // MARK: One object's timeline (§7.4)

    @Test func tellsOneObjectsStory() async throws {
        let world = try await World()
        // Primary keys are the store's business, not the fixture's: the one note that was retitled is found by
        // what happened to it, which is the thing under test anyway.
        let transactions = try await world.coreData.transactions(after: nil)
        let retitled = try #require(
            transactions.flatMap(\.changes).first { $0.updatedProperties == ["title"] },
            "the fixture retitles one note")
        let edited = try #require(await world.session.reference(entity: retitled.entity, pk: retitled.pk))
        let story = try await world.session.history(of: edited)

        #expect(story.count == 3, "inserted, pinned, retitled")
        #expect(story.map(\.author) == ["app", "sync", "app"])
        // Scoped by change, so a transaction that touched ten rows arrives holding only this one.
        #expect(story.allSatisfy { $0.changes.count == 1 })
        #expect(story.map { $0.changes.first?.kind } == [.inserted, .updated, .updated])
        #expect(story.dropFirst().map { $0.changes.first?.updatedProperties } == [["pinned"], ["title"]])
        #expect(try await world.session.history(of: edited, limit: 1).map(\.number) == [story.last?.number])
        await world.close()
    }

    @Test func aDeletedRowStillHasAStory() async throws {
        let world = try await World()
        let transactions = try await world.coreData.transactions(after: nil)
        let deletion = try #require(transactions.flatMap(\.changes).first { $0.kind == .deleted })
        // Its row is gone, and the reference still resolves: an identity is a number, not a row.
        let gone = try #require(await world.session.reference(entity: deletion.entity, pk: deletion.pk))
        let story = try await world.session.history(of: gone)
        #expect(story.count == 2, "inserted, then deleted")
        #expect(story.last?.changes.first?.kind == .deleted)
        #expect(story.last?.changes.first?.tombstone["title"] == .string("Note 9"))
        await world.close()
    }

    // MARK: The raw reader's private knowledge

    /// The bit order of `ACHANGE.ZCOLUMNS`, checked against the model it is derived from.
    ///
    /// Every non-transient property, attributes and relationships in one list sorted by name — not attributes and
    /// then relationships, and not the order the columns sit in the table. The Notes model rules both out: `Note`
    /// stores its columns as pinned, folder, modifiedAt, body, title, and `pinned` is bit 3, which is where it
    /// lands only under one sorted list of body, folder, modifiedAt, pinned, title.
    @Test func decodesTheChangedColumnBitmap() throws {
        let model = ModelDescription(NotesFixture.makeHistoryModel())
        let note = RawHistoryReader.Layout(try #require(model.entity(named: "Note")))
        #expect(note.properties == ["body", "folder", "modifiedAt", "pinned", "title"])
        #expect(note.properties(in: Data([0x10])) == ["pinned"])
        #expect(note.properties(in: Data([0x08])) == ["title"])
        #expect(note.properties(in: Data([0x18])) == ["pinned", "title"])
        #expect(note.properties(in: Data([0x00]))?.isEmpty == true, "a bitmap with no bits set names no fields")

        let folder = RawHistoryReader.Layout(try #require(model.entity(named: "Folder")))
        #expect(folder.properties == ["name", "notes"])
        #expect(folder.properties(in: Data([0x40])) == ["notes"])
        // A bit past the end of the model is a model that no longer matches the store. Half an answer would read
        // as "these fields and no others", so the answer is that nobody knows (ADR-17).
        #expect(folder.properties(in: Data([0x20])) == nil)
        #expect(folder.properties(in: Data([0x40, 0x80])) == nil)
    }

    /// `ZTOMBSTONE<n>` is the *n*-th preserving attribute by name — which the fixture puts in the opposite order
    /// from the one the model declares them in, so a reader that used declaration order would swap the two.
    @Test func decodesTombstoneColumnOrder() throws {
        let model = ModelDescription(NotesFixture.makeHistoryModel())
        let note = RawHistoryReader.Layout(try #require(model.entity(named: "Note")))
        #expect(note.tombstones.map(\.name) == ["modifiedAt", "title"])
        #expect(RawHistoryReader.Layout(try #require(model.entity(named: "Folder"))).tombstones.isEmpty)
    }

    /// An inheritance hierarchy, where a bit means a different name depending on which entity's row it is.
    ///
    /// Two sub-entities share one table and one `ACHANGE`; only `ZENTITY` says which is which, and each one's
    /// property list — its own and everything it inherits — is what its bits are counted against.
    @Test func readsASubEntitysOwnBitOrder() async throws {
        let directory = TestFixtures.root.appendingPathComponent("history-\(UUID().uuidString)", isDirectory: true)
        let storeURL = directory.appendingPathComponent("Shapes.sqlite")
        let writer = try StoreWriter(
            model: Self.shapesModel(), storeURL: storeURL, options: NotesFixture.historyOptions, author: "app")
        var circle: NSManagedObject?
        var square: NSManagedObject?
        try writer.perform { writer in
            circle = writer.insert("Circle", ["label": "c", "radius": 1.0])
            square = writer.insert("Square", ["label": "s", "side": 2.0])
        }
        try writer.perform { _ in
            // `radius` and `side` are each their entity's last property by name, and each is a different bit.
            circle?.setValue(3.0, forKey: "radius")
            square?.setValue(4.0, forKey: "side")
        }
        try writer.close()

        let session = try await StoreSession.open(storeURL: storeURL)
        let raw = RawHistoryReader(url: storeURL, model: session.info.model, schema: session.info.schemaMap)
        let updates = try await raw.transactions(after: nil).flatMap(\.changes).filter { $0.kind == .updated }
        #expect(Set(updates.map(\.entity)) == ["Circle", "Square"])
        #expect(updates.first { $0.entity == "Circle" }?.updatedProperties == ["radius"])
        #expect(updates.first { $0.entity == "Square" }?.updatedProperties == ["side"])

        // And Core Data agrees, which is what makes the answer above worth anything.
        let api = try await CoreDataHistoryReader(session: session).transactions(after: nil)
        let apiUpdates = api.flatMap(\.changes).filter { $0.kind == .updated }
        #expect(
            Set(apiUpdates.map { "\($0.entity):\($0.updatedProperties ?? [])" }) == [
                "Circle:[\"radius\"]", "Square:[\"side\"]",
            ])
        await raw.close()
        await session.close()
        try? FileManager.default.removeItem(at: directory)
    }

    /// Abstract `Shape` with `label`, and two sub-entities that each add one attribute.
    private static func shapesModel() -> NSManagedObjectModel {
        func number(_ name: String) -> NSAttributeDescription {
            let attribute = NSAttributeDescription()
            attribute.name = name
            attribute.attributeType = .doubleAttributeType
            attribute.isOptional = true
            return attribute
        }
        let label = NSAttributeDescription()
        label.name = "label"
        label.attributeType = .stringAttributeType
        label.isOptional = true

        let shape = NSEntityDescription()
        shape.name = "Shape"
        shape.managedObjectClassName = "FixtureApp.Shape"
        shape.isAbstract = true
        shape.properties = [label]

        let circle = NSEntityDescription()
        circle.name = "Circle"
        circle.managedObjectClassName = "FixtureApp.Circle"
        circle.properties = [number("radius")]

        let square = NSEntityDescription()
        square.name = "Square"
        square.managedObjectClassName = "FixtureApp.Square"
        square.properties = [number("side")]

        shape.subentities = [circle, square]
        let model = NSManagedObjectModel()
        model.entities = [shape, circle, square]
        model.versionIdentifiers = ["shapes-1"]
        return model
    }

    /// An existential in a `for` loop needs a box; this is it.
    private struct AnyReader {
        let reader: any HistoryReader
        var name: String { reader.source.rawValue }
        init(_ reader: any HistoryReader) { self.reader = reader }
    }
}
