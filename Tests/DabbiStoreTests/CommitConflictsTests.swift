import DabbiBase
import DabbiSQLite
import DabbiTestSupport
import FixtureKit
import Foundation
import Testing

@testable import DabbiStore

/// EDT-10: a commit never writes over what somebody else saved since the rows were edited here — not even after
/// browsing has refreshed them — until the user has chosen, per object, whose values stand.
@Suite struct CommitConflictsTests {
    private let access = StoreAccess.editable(WriteAuthorization(author: "Tests"))

    /// A session of this app and one of “somebody else” — another coordinator, as the store's own app would be.
    private func open(_ fixture: Fixture) async throws -> (mine: StoreSession, theirs: StoreSession, FixtureLocation) {
        let location = try TestFixtures.scratchCopy(fixture)
        let mine = try await StoreSession.open(
            storeURL: location.storeURL, modelURL: location.modelURL, access: access)
        let theirs = try await StoreSession.open(
            storeURL: location.storeURL, modelURL: location.modelURL,
            access: .editable(WriteAuthorization(author: "Other")))
        return (mine, theirs, location)
    }

    private func rows(_ session: StoreSession, _ count: Int) async throws -> [ObjectRef] {
        let refs = try await session.references(FetchSpec(entity: "Sample"), limit: count)
        try #require(refs.count == count)
        return refs
    }

    private func fileValue(_ location: FixtureLocation, _ sql: String) throws -> SQLiteValue? {
        let connection = try SQLiteConnection(readOnly: location.storeURL)
        defer { connection.close() }
        return try connection.scalar(sql)
    }

    private func name(_ location: FixtureLocation, _ ref: ObjectRef) throws -> SQLiteValue? {
        try fileValue(location, "SELECT ZNAME FROM ZSAMPLE WHERE Z_PK = \(ref.pk)")
    }

    /// Stages “Mine” here; somebody else then saves “Theirs” and a string value of their own, and this session
    /// browses — which is what used to let the commit write over them without a word.
    private func conflicted() async throws -> (StoreSession, StoreSession, FixtureLocation, ObjectRef, Value?) {
        let (mine, theirs, location) = try await open(.basic)
        let ref = try #require(try await rows(mine, 1).first)
        let original = try await mine.object(ref)["name"]
        try await mine.setValue(.string("Mine"), for: "name", of: PendingObjectID(ref))
        try await theirs.setValue(.string("Theirs"), for: "name", of: PendingObjectID(ref))
        try await theirs.setValue(.string("their string"), for: "stringValue", of: PendingObjectID(ref))
        _ = try await theirs.commit()
        _ = try await mine.object(ref)
        return (mine, theirs, location, ref, original)
    }

    @Test func aRowSavedElsewhereIsAConflictEvenAfterBrowsing() async throws {
        let (mine, theirs, location, ref, original) = try await conflicted()

        let error = await #expect(throws: DabbiError.self) { try await mine.commit() }
        #expect(error?.code == .commitConflict)
        #expect(error?.arguments["count"] == "1")
        #expect(try name(location, ref) == .text("Theirs"), "nothing was written")
        #expect(try await mine.pendingChanges().changes.count == 1, "everything is still staged")

        let conflicts = try await mine.commitConflicts()
        let conflict = try #require(conflicts.first)
        #expect(conflicts.count == 1)
        #expect(conflict.object == PendingObjectID(ref))
        #expect(conflict.kind == .changed && conflict.staged == .updated)
        #expect(conflict.choices == [.mine, .theirs])
        #expect(conflict.fields.map(\.property) == ["name", "stringValue"])
        let nameField = try #require(conflict.fields.first)
        #expect(nameField.mine == .string("Mine") && nameField.theirs == .string("Theirs"))
        #expect(nameField.original == original)
        #expect(nameField.isClash)
        let stringField = conflict.fields[1]
        #expect(stringField.mine == nil && stringField.theirs == .string("their string"))
        #expect(!stringField.isClash)
        if case .string(let label)? = original { #expect(conflict.label == label) }
        await mine.close()
        await theirs.close()
    }

    @Test func mineWritesTheStagedValuesOverTheirs() async throws {
        let (mine, theirs, location, ref, _) = try await conflicted()

        let changes = try await mine.resolveConflicts([PendingObjectID(ref): .mine])
        #expect(changes.changes.count == 1)
        #expect(!changes.canUndo, "settling is not an edit")
        #expect(try await mine.commitConflicts().isEmpty)
        #expect(try await mine.commit().updated == 1)

        #expect(try name(location, ref) == .text("Mine"))
        // What nothing was staged for is theirs.
        #expect(
            try fileValue(location, "SELECT ZSTRINGVALUE FROM ZSAMPLE WHERE Z_PK = \(ref.pk)") == .text("their string"))
        await mine.close()
        await theirs.close()
    }

    @Test func theirsLetsTheStagedValuesGo() async throws {
        let (mine, theirs, location, ref, _) = try await conflicted()

        let changes = try await mine.resolveConflicts([PendingObjectID(ref): .theirs])
        #expect(changes.changes.isEmpty)
        #expect(try await mine.object(ref)["name"] == .string("Theirs"))
        #expect(try await mine.commit().updated == 0)
        #expect(try name(location, ref) == .text("Theirs"))
        await mine.close()
        await theirs.close()
    }

    @Test func aChoiceSettlesOnlyTheObjectItNames() async throws {
        let (mine, theirs, location) = try await open(.basic)
        let refs = try await rows(mine, 3)
        for ref in refs { try await mine.setValue(.string("Mine"), for: "name", of: PendingObjectID(ref)) }
        for ref in refs.prefix(2) {
            try await theirs.setValue(.string("Theirs"), for: "name", of: PendingObjectID(ref))
        }
        _ = try await theirs.commit()

        let both = refs.prefix(2).map(PendingObjectID.init).sorted { $0.uri.absoluteString < $1.uri.absoluteString }
        #expect(try await mine.commitConflicts().map(\.object) == both)
        try await mine.resolveConflicts([PendingObjectID(refs[0]): .theirs])
        #expect(try await mine.commitConflicts().map(\.object) == [PendingObjectID(refs[1])])
        await #expect(throws: DabbiError.self) { try await mine.commit() }

        try await mine.resolveConflicts([PendingObjectID(refs[1]): .mine])
        #expect(try await mine.commit().updated == 2)
        #expect(try refs.map { try name(location, $0) } == [.text("Theirs"), .text("Mine"), .text("Mine")])
        await mine.close()
        await theirs.close()
    }

    @Test func aStagedDeleteOfARowSavedElsewhere() async throws {
        for choice in [CommitConflict.Choice.mine, .theirs] {
            let (mine, theirs, location) = try await open(.basic)
            let ref = try #require(try await rows(mine, 1).first)
            try await mine.delete([PendingObjectID(ref)])
            try await theirs.setValue(.string("Theirs"), for: "name", of: PendingObjectID(ref))
            _ = try await theirs.commit()

            let conflict = try #require(try await mine.commitConflicts().first)
            #expect(conflict.kind == .changed && conflict.staged == .deleted)
            #expect(conflict.fields.map(\.property) == ["name"])
            #expect(conflict.fields.first?.mine == nil)

            try await mine.resolveConflicts([PendingObjectID(ref): choice])
            _ = try await mine.commit()
            let count = try fileValue(location, "SELECT COUNT(*) FROM ZSAMPLE WHERE Z_PK = \(ref.pk)")
            #expect(count == .integer(choice == .mine ? 0 : 1), "\(choice)")
            await mine.close()
            await theirs.close()
        }
    }

    @Test func aRowDeletedElsewhereCanOnlyBeLetGo() async throws {
        let (mine, theirs, location) = try await open(.basic)
        let ref = try #require(try await rows(mine, 1).first)
        let before = try fileValue(location, "SELECT COUNT(*) FROM ZSAMPLE")
        try await mine.setValue(.string("Mine"), for: "name", of: PendingObjectID(ref))
        try await theirs.delete([PendingObjectID(ref)])
        _ = try await theirs.commit()

        let conflict = try #require(try await mine.commitConflicts().first)
        #expect(conflict.kind == .deleted && conflict.staged == .updated)
        #expect(conflict.choices == [.theirs])
        #expect(conflict.fields.map(\.property) == ["name"])
        #expect(conflict.fields.first?.theirs == nil)

        // `.mine` is taken as `.theirs`: there is no row to write the edit to.
        let changes = try await mine.resolveConflicts([PendingObjectID(ref): .mine])
        #expect(changes.changes.isEmpty)
        _ = try await mine.commit()
        guard case .integer(let count)? = before else { return }
        #expect(try fileValue(location, "SELECT COUNT(*) FROM ZSAMPLE") == .integer(count - 1))
        await mine.close()
        await theirs.close()
    }

    @Test func otherRowsSavedElsewhereAreNoConflict() async throws {
        let (mine, theirs, location) = try await open(.basic)
        let refs = try await rows(mine, 2)
        try await mine.setValue(.string("Mine"), for: "name", of: PendingObjectID(refs[0]))
        try await theirs.setValue(.string("Theirs"), for: "name", of: PendingObjectID(refs[1]))
        // Somebody else saving a property of the same row to the value it had is no change either.
        let unchanged = try await mine.object(refs[0])["stringValue"] ?? .null
        try await theirs.setValue(.string("x"), for: "stringValue", of: PendingObjectID(refs[0]))
        try await theirs.setValue(unchanged, for: "stringValue", of: PendingObjectID(refs[0]))
        _ = try await theirs.commit()

        #expect(try await mine.commitConflicts().isEmpty)
        #expect(try await mine.commit().updated == 1)
        #expect(try refs.map { try name(location, $0) } == [.text("Mine"), .text("Theirs")])
        await mine.close()
        await theirs.close()
    }

    @Test func editsMadeAfterADiscardAreMadeAgainstTheRowAsItIsThen() async throws {
        let (mine, theirs, location) = try await open(.basic)
        let ref = try #require(try await rows(mine, 1).first)
        try await mine.setValue(.string("First"), for: "name", of: PendingObjectID(ref))
        try await theirs.setValue(.string("Theirs"), for: "name", of: PendingObjectID(ref))
        _ = try await theirs.commit()
        try await mine.discardChanges()

        try await mine.setValue(.string("Second"), for: "name", of: PendingObjectID(ref))
        #expect(try await mine.commitConflicts().isEmpty)
        _ = try await mine.commit()
        #expect(try name(location, ref) == .text("Second"))

        // And after a commit, against the row the commit wrote.
        try await mine.setValue(.string("Third"), for: "name", of: PendingObjectID(ref))
        #expect(try await mine.commitConflicts().isEmpty)
        _ = try await mine.commit()
        #expect(try name(location, ref) == .text("Third"))
        await mine.close()
        await theirs.close()
    }

    @Test func aToOneSavedElsewhereIsAConflict() async throws {
        let (mine, theirs, location) = try await open(.company)
        let people = try await mine.references(FetchSpec(entity: "Employee"), limit: 3)
        try #require(people.count == 3)
        let target = PendingObjectID(people[0])
        try await mine.setValue(.toOne(people[1], display: nil), for: "boss", of: target)
        try await theirs.setValue(.toOne(people[2], display: nil), for: "boss", of: target)
        _ = try await theirs.commit()

        let conflict = try #require(try await mine.commitConflicts().first)
        let field = try #require(conflict.fields.first { $0.property == "boss" })
        guard case .toOne(let mineRef, _)? = field.mine, case .toOne(let theirRef, _)? = field.theirs else {
            Issue.record("both sides are to-ones")
            return
        }
        #expect(mineRef == people[1] && theirRef == people[2])
        #expect(field.isClash)
        try await mine.resolveConflicts([target: .mine])
        _ = try await mine.commit()
        let boss = try fileValue(location, "SELECT ZBOSS FROM ZPARTY WHERE Z_PK = \(people[0].pk)")
        #expect(boss == .integer(people[1].pk))
        await mine.close()
        await theirs.close()
    }
}
