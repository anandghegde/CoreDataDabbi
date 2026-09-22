@preconcurrency import CoreData
import DabbiBase
import DabbiModel
import DabbiSQLite
import DabbiTestSupport
import FixtureKit
import Foundation
import Testing

@testable import DabbiTracking

/// The scan strategy of ARCHITECTURE.md §6.6, against real Core Data stores written by a real writer. Every
/// assertion here is about what the *file* says, which is the only thing the scanner reads.
@Suite struct ChangeScannerTests {
    /// A store with a writer holding it open, the model the writer used, and the schema map built against the
    /// file — the three things a scanner is made from.
    struct World {
        let directory: URL
        let storeURL: URL
        let writer: StoreWriter
        let model: ModelDescription
        let schema: SchemaMap

        init(
            model managedObjectModel: NSManagedObjectModel,
            name: String,
            seed: (StoreWriter) throws -> Void = { _ in }
        ) throws {
            directory = TestFixtures.root.appendingPathComponent("scanner-\(UUID().uuidString)", isDirectory: true)
            storeURL = directory.appendingPathComponent(name)
            writer = try StoreWriter(model: managedObjectModel, storeURL: storeURL, author: "app")
            // Seeded before anything is scanned, so the tables exist and the baseline has something in it.
            try writer.perform { writer in try seed(writer) }
            model = ModelDescription(managedObjectModel)
            let connection = try SQLiteConnection(readOnly: storeURL)
            defer { connection.close() }
            schema = try SchemaMap.build(model: model, connection: connection)
        }

        func scanner(scope: TrackingScope = .allEntities, schema: SchemaMap? = nil) -> ChangeScanner {
            ChangeScanner(url: storeURL, model: model, schema: schema ?? self.schema, scope: scope)
        }

        /// A primed scanner: the store as it is now is the baseline.
        func primedScanner(scope: TrackingScope = .allEntities) async throws -> ChangeScanner {
            let scanner = scanner(scope: scope)
            let baseline = try await scanner.prime()
            #expect(baseline.isBaseline)
            #expect(baseline.isEmpty)
            return scanner
        }

        func commit(_ body: (StoreWriter) throws -> Void) throws {
            try writer.perform(body)
        }
    }

    /// A Folder ⟷ Note store: one-to-many, no inheritance, no join table.
    static func notes() throws -> World {
        try World(model: NotesFixture.makeModel(), name: "Notes.sqlite") { writer in
            let inbox = writer.insert("Folder", ["name": "Inbox"])
            for index in 0..<5 {
                writer.insert("Note", ["title": "Note \(index)", "folder": inbox])
            }
        }
    }

    /// The company model: `Party` ⟵ `Organisation`, `Person` ⟵ `Employee` ⟵ `Manager` sharing one table, and
    /// `Person.tags` ⟷ `Tag.people` in a join table.
    static func company() throws -> World {
        try World(model: CompanyFixture.makeModel(), name: "Company.sqlite") { writer in
            writer.insert("Person", ["name": "Ada"])
            writer.insert("Tag", ["label": "founder"])
        }
    }

    /// `Z_PK` of a saved object — what the scanner reports.
    static func pk(_ object: NSManagedObject) throws -> Int64 {
        try #require(ObjectRef(uri: object.objectID.uriRepresentation())?.pk)
    }

    // MARK: The baseline

    /// The rows a store already has are not news. Priming reads them all and reports nothing.
    @Test func theBaselineIsNotNews() async throws {
        let world = try Self.notes()
        let scanner = world.scanner()
        #expect(await scanner.isPrimed == false)

        let baseline = try await scanner.scan()
        #expect(baseline.isBaseline)
        #expect(baseline.isEmpty)
        #expect(baseline.scannedRows == 6, "one folder and five notes")
        #expect(baseline.isReducedFidelity == false)
        #expect(await scanner.isPrimed)
        #expect(await scanner.heldRows == 6)
        await scanner.close()
    }

    /// Priming twice does not re-read: the second call has nothing to establish.
    @Test func primingIsIdempotent() async throws {
        let world = try Self.notes()
        let scanner = try await world.primedScanner()
        let again = try await scanner.prime()
        #expect(again.isBaseline == false)
        #expect(again.isEmpty)
        await scanner.close()
    }

    @Test func aStoreNobodyTouchedScansEmpty() async throws {
        let world = try Self.notes()
        let scanner = try await world.primedScanner()

        let changes = try await scanner.scan()
        #expect(changes.isBaseline == false)
        #expect(changes.isEmpty)
        #expect(changes.scannedRows == 6, "nothing changed, but everything was still walked")
        await scanner.close()
    }

    // MARK: Rows

    @Test func noticesAnInsert() async throws {
        let world = try Self.notes()
        let scanner = try await world.primedScanner()

        var inserted: NSManagedObject?
        try world.commit { writer in inserted = writer.insert("Note", ["title": "Sixth"]) }

        let changes = try await scanner.scan()
        #expect(changes.inserted == [RowID(entity: "Note", pk: try Self.pk(#require(inserted)))])
        #expect(changes.updated.isEmpty)
        #expect(changes.deleted.isEmpty)
        #expect(changes.links.isEmpty)
        await scanner.close()
    }

    /// An update is a `Z_OPT` that moved (Appendix A): the save counter is 1 after the insert and one more per
    /// saved update. Nothing about the row's *values* is read to know this.
    @Test func noticesAnUpdate() async throws {
        let world = try Self.notes()
        var note: NSManagedObject?
        try world.commit { writer in note = writer.insert("Note", ["title": "Before"]) }
        let scanner = try await world.primedScanner()

        try world.commit { _ in note?.setValue("After", forKey: "title") }

        let changes = try await scanner.scan()
        #expect(changes.updated == [RowID(entity: "Note", pk: try Self.pk(#require(note)))])
        #expect(changes.inserted.isEmpty)
        #expect(changes.deleted.isEmpty)
        await scanner.close()
    }

    /// A deleted row's entity can only come from the snapshot taken before it went: the row is not there to ask.
    @Test func noticesADeleteAndKnowsWhatItWas() async throws {
        let world = try Self.notes()
        var note: NSManagedObject?
        try world.commit { writer in note = writer.insert("Note", ["title": "Doomed"]) }
        let deletedPK = try Self.pk(#require(note))
        let scanner = try await world.primedScanner()

        try world.commit { writer in writer.context.delete(try #require(note)) }

        let changes = try await scanner.scan()
        #expect(changes.deleted == [RowID(entity: "Note", pk: deletedPK)])
        #expect(changes.inserted.isEmpty)
        await scanner.close()
    }

    @Test func noticesInsertUpdateAndDeleteInOneCommit() async throws {
        let world = try Self.notes()
        var kept: NSManagedObject?
        var doomed: NSManagedObject?
        try world.commit { writer in
            kept = writer.insert("Note", ["title": "Kept"])
            doomed = writer.insert("Note", ["title": "Doomed"])
        }
        let doomedPK = try Self.pk(#require(doomed))
        let scanner = try await world.primedScanner()

        var fresh: NSManagedObject?
        try world.commit { writer in
            fresh = writer.insert("Note", ["title": "Fresh"])
            kept?.setValue("Edited", forKey: "title")
            writer.context.delete(try #require(doomed))
        }

        let changes = try await scanner.scan()
        #expect(changes.inserted == [RowID(entity: "Note", pk: try Self.pk(#require(fresh)))])
        #expect(changes.updated.contains(RowID(entity: "Note", pk: try Self.pk(#require(kept)))))
        #expect(changes.deleted == [RowID(entity: "Note", pk: doomedPK)])
        await scanner.close()
    }

    /// One transaction, so a save that touched two entities is one answer rather than two that arrive in
    /// whatever order the tables were read in.
    @Test func oneScanSeesEveryTableAtOnce() async throws {
        let world = try Self.notes()
        let scanner = try await world.primedScanner()

        try world.commit { writer in
            let folder = writer.insert("Folder", ["name": "Archive"])
            writer.insert("Note", ["title": "Filed", "folder": folder])
        }

        let changes = try await scanner.scan()
        #expect(changes.inserted.map(\.entity) == ["Folder", "Note"], "sorted by entity, then key")
        await scanner.close()
    }

    // MARK: Inheritance

    /// `Organisation`, `Person`, `Employee` and `Manager` all live in `ZPARTY`, told apart by `Z_ENT`. The
    /// entity a change is reported under is the row's own, not the root whose table it shares.
    @Test func tellsSubEntitiesApart() async throws {
        let world = try Self.company()
        let scanner = try await world.primedScanner()

        var manager: NSManagedObject?
        var person: NSManagedObject?
        try world.commit { writer in
            manager = writer.insert("Manager", ["name": "Grace", "level": 3])
            person = writer.insert("Person", ["name": "Alan"])
        }

        let changes = try await scanner.scan()
        #expect(changes.inserted.count == 2)
        #expect(
            changes.inserted.contains(RowID(entity: "Manager", pk: try Self.pk(#require(manager)))),
            "a Manager row is a Manager, not a Party")
        #expect(changes.inserted.contains(RowID(entity: "Person", pk: try Self.pk(#require(person)))))
        await scanner.close()
    }

    // MARK: Scope

    @Test func reportsOnlyWhatIsInScope() async throws {
        let world = try Self.notes()
        let scanner = try await world.primedScanner(scope: .entities(["Folder"]))

        try world.commit { writer in
            writer.insert("Note", ["title": "Ignored"])
            writer.insert("Folder", ["name": "Watched"])
        }

        let changes = try await scanner.scan()
        #expect(changes.inserted.map(\.entity) == ["Folder"])
        #expect(changes.scannedRows == 2, "only the folder table is read at all")
        await scanner.close()
    }

    /// Asking for `Person` means asking for the people, however specific: a fetch of `Person` in the app returns
    /// `Employee` and `Manager` rows too.
    @Test func trackingAnEntityTracksItsDescendants() async throws {
        let world = try Self.company()
        let scanner = try await world.primedScanner(scope: .entities(["Person"]))

        var manager: NSManagedObject?
        try world.commit { writer in
            manager = writer.insert("Manager", ["name": "Grace", "level": 1])
            writer.insert("Organisation", ["name": "Untracked Ltd", "registration": "REG-1"])
        }

        let changes = try await scanner.scan()
        #expect(changes.inserted == [RowID(entity: "Manager", pk: try Self.pk(#require(manager)))])
        await scanner.close()
    }

    // MARK: Links

    /// A many-to-many is kept in a table of its own with no `Z_PK`, so the row diff cannot see it change. This
    /// is the diff that can.
    @Test func noticesLinksAddedAndRemoved() async throws {
        let world = try Self.company()
        var person: NSManagedObject?
        var first: NSManagedObject?
        var second: NSManagedObject?
        try world.commit { writer in
            person = writer.insert("Person", ["name": "Ada"])
            first = writer.insert("Tag", ["label": "first"])
            second = writer.insert("Tag", ["label": "second"])
        }
        let scanner = try await world.primedScanner()

        try world.commit { _ in
            person?.setValue(NSSet(array: [try #require(first), try #require(second)]), forKey: "tags")
        }

        let added = try await scanner.scan()
        #expect(added.links.count == 2)
        #expect(added.links.allSatisfy { $0.kind == .added })
        #expect(added.links.allSatisfy { $0.relationship == "tags" })
        #expect(added.links.allSatisfy { $0.source.pk == (try? Self.pk(#require(person))) })
        #expect(added.links.map(\.destination.entity) == ["Tag", "Tag"])
        #expect(added.links.allSatisfy { $0.order == nil }, "the relationship is not ordered")

        try world.commit { _ in person?.setValue(NSSet(array: [try #require(first)]), forKey: "tags") }

        let removed = try await scanner.scan()
        #expect(removed.links.count == 1)
        #expect(removed.links.first?.kind == .removed)
        #expect(removed.links.first?.destination.pk == (try? Self.pk(#require(second))))
        await scanner.close()
    }

    /// An ordered many-to-many that is only reordered changes nothing but `Z_FOK_…`; a diff that compared pairs
    /// alone would say nothing happened.
    @Test func noticesAReorderOfAnOrderedManyToMany() async throws {
        let world = try World(model: OrderedFixture.makeModel(), name: "Ordered.sqlite")
        var playlist: NSManagedObject?
        var tracks: [NSManagedObject] = []
        try world.commit { writer in
            playlist = writer.insert("Playlist", ["name": "Mix"])
            tracks = (0..<3).map { writer.insert("Track", ["title": "Track \($0)", "duration": 100.0]) }
            playlist?.setValue(NSOrderedSet(array: tracks), forKey: "featured")
        }
        let scanner = try await world.primedScanner()

        try world.commit { _ in
            playlist?.setValue(NSOrderedSet(array: tracks.reversed()), forKey: "featured")
        }

        let changes = try await scanner.scan()
        #expect(changes.links.isEmpty == false)
        #expect(changes.links.allSatisfy { $0.kind == .reordered })
        #expect(changes.links.allSatisfy { $0.relationship == "featured" })
        #expect(changes.links.allSatisfy { $0.order != nil })
        await scanner.close()
    }

    /// The other kind of to-many. Moving a note between folders rewrites `ZNOTE.ZFOLDER`, so it is the note's
    /// own row that changed and there is no link to report.
    @Test func aOneToManyLinkChangeIsAnUpdateOfTheRowThatHoldsIt() async throws {
        let world = try Self.notes()
        var note: NSManagedObject?
        var archive: NSManagedObject?
        try world.commit { writer in
            note = writer.insert("Note", ["title": "Movable"])
            archive = writer.insert("Folder", ["name": "Archive"])
        }
        let scanner = try await world.primedScanner()

        try world.commit { _ in note?.setValue(archive, forKey: "folder") }

        let changes = try await scanner.scan()
        #expect(changes.updated.contains(RowID(entity: "Note", pk: try Self.pk(#require(note)))))
        #expect(changes.links.isEmpty, "a one-to-many has no join table to diff")
        await scanner.close()
    }

    // MARK: Degrading

    /// The schema map is a pile of guesses that were checked (§6.5). When one of them is wrong the scan says so
    /// and carries on with the rest — it does not fail, and it does not quietly report less.
    @Test func aTableThatIsNotThereIsALimitation() async throws {
        let world = try Self.notes()
        var schema = world.schema
        schema.entities["Note"]?.table = "ZNOTEXISTS"
        let scanner = world.scanner(schema: schema)
        _ = try await scanner.prime()

        try world.commit { writer in
            writer.insert("Note", ["title": "Unseen"])
            writer.insert("Folder", ["name": "Seen"])
        }

        let changes = try await scanner.scan()
        #expect(changes.isReducedFidelity)
        #expect(changes.limitations == [ScanLimitation(reason: .missingTable, subject: "ZNOTEXISTS")])
        #expect(changes.inserted.map(\.entity) == ["Folder"], "the tables that are there are still scanned")
        await scanner.close()
    }

    /// An entity the schema map could not confirm at all — no entity number, no table.
    @Test func anUnverifiedEntityIsALimitation() async throws {
        let world = try Self.notes()
        var schema = world.schema
        schema.entities["Note"]?.verified = false
        let scanner = world.scanner(schema: schema)
        _ = try await scanner.prime()

        try world.commit { writer in writer.insert("Note", ["title": "Unseen"]) }

        let changes = try await scanner.scan()
        #expect(changes.limitations == [ScanLimitation(reason: .unverifiedTable, subject: "Note")])
        #expect(changes.isEmpty)
        await scanner.close()
    }

    /// Without `Z_OPT` there is no save counter, so a row that was written over looks exactly like one nobody
    /// touched. Inserts and deletes are still exact, and the session is labelled reduced-fidelity.
    @Test func aTableWithoutTheSaveCounterLosesUpdatesOnly() async throws {
        let world = try Self.notes()
        var note: NSManagedObject?
        try world.commit { writer in note = writer.insert("Note", ["title": "Before"]) }
        let notePK = try Self.pk(#require(note))
        // The column is dropped on a copy, with nobody holding the original open: Core Data would not start on
        // a store shaped like this, which is the point — the scanner still has to cope.
        try world.writer.close()
        let copy = world.directory.appendingPathComponent("NoOpt.sqlite")
        try FileManager.default.copyItem(at: world.storeURL, to: copy)
        try RawSQLite.execute("ALTER TABLE ZNOTE DROP COLUMN Z_OPT", at: copy)

        let scanner = ChangeScanner(url: copy, model: world.model, schema: world.schema)
        let baseline = try await scanner.scan()
        #expect(baseline.limitations == [ScanLimitation(reason: .noOptimisticLockColumn, subject: "ZNOTE")])

        try RawSQLite.execute(
            """
            UPDATE ZNOTE SET ZTITLE = 'After' WHERE Z_PK = \(notePK);
            INSERT INTO ZNOTE (Z_ENT, ZTITLE) SELECT Z_ENT, 'Added' FROM ZNOTE WHERE Z_PK = \(notePK);
            """, at: copy)

        let changes = try await scanner.scan()
        #expect(changes.inserted.count == 1, "an insert is still exact")
        #expect(changes.updated.isEmpty, "the update cannot be seen, and is not guessed at")
        #expect(changes.isReducedFidelity)
        await scanner.close()
    }

    // MARK: Lifecycle

    /// What a `.storeReplaced` commit calls for: every key held is about a file that is no longer there.
    @Test func resetForgetsTheBaseline() async throws {
        let world = try Self.notes()
        let scanner = try await world.primedScanner()
        #expect(await scanner.heldRows == 6)

        await scanner.reset()
        #expect(await scanner.isPrimed == false)
        #expect(await scanner.heldRows == 0)

        let changes = try await scanner.scan()
        #expect(changes.isBaseline, "the store as it is now is the new baseline")
        #expect(changes.isEmpty)
        await scanner.close()
    }

    // MARK: The merge walk itself

    /// The diff, away from any database: every shape the walk has to get right, including the ends.
    @Test func theMergeWalkPairsKeysUp() {
        let old = TableSnapshot(pks: [1, 2, 3, 5], ents: [1, 1, 1, 1], opts: [1, 1, 1, 1])
        let new = TableSnapshot(pks: [2, 3, 4, 6], ents: [1, 1, 1, 1], opts: [1, 2, 1, 1])
        var inserted: [Int64] = []
        var updated: [Int64] = []
        var deleted: [Int64] = []
        TableSnapshot.walk(
            from: old, to: new,
            deleted: { deleted.append(old.pks[$0]) },
            inserted: { inserted.append(new.pks[$0]) },
            updated: { updated.append(new.pks[$0]) })

        #expect(deleted == [1, 5])
        #expect(inserted == [4, 6])
        #expect(updated == [3], "only the row whose save counter moved")
    }

    /// A row does not change entity. If it looks as though one has, the file underneath was replaced without a
    /// reset, and the honest answer is that the old row went and a new one arrived.
    @Test func aKeyThatChangedEntityIsADeleteAndAnInsert() {
        let old = TableSnapshot(pks: [7], ents: [1], opts: [1])
        let new = TableSnapshot(pks: [7], ents: [2], opts: [1])
        var events: [String] = []
        TableSnapshot.walk(
            from: old, to: new,
            deleted: { _ in events.append("deleted") },
            inserted: { _ in events.append("inserted") },
            updated: { _ in events.append("updated") })

        #expect(events == ["deleted", "inserted"])
    }

    @Test func theJoinWalkComparesPairsThenOrder() {
        let old = JoinSnapshot(sources: [1, 1, 2], destinations: [10, 11, 10], orders: [0, 1, 0])
        let new = JoinSnapshot(sources: [1, 1, 3], destinations: [11, 12, 10], orders: [0, 1, 0])
        var added: [Int64] = []
        var removed: [Int64] = []
        var reordered: [Int64] = []
        JoinSnapshot.walk(
            from: old, to: new,
            removed: { removed.append(old.destinations[$0]) },
            added: { added.append(new.destinations[$0]) },
            reordered: { reordered.append(new.destinations[$0]) })

        #expect(removed == [10, 10], "1→10 went, and so did 2→10")
        #expect(added == [12, 10], "1→12 arrived, and so did 3→10")
        #expect(reordered == [11], "1→11 stayed, in a different place")
    }
}
