import DabbiBase
import DabbiSQLite
import DabbiTestSupport
import FixtureKit
import Foundation
import Testing

@testable import DabbiStore

/// EDT-8: staged edits — nothing reaches the file before the commit, every edit undoes and redoes, the pending
/// changes say what differs, and the commit writes it all at once or nothing at all.
@Suite struct StagedEditsTests {
    private let access = StoreAccess.editable(WriteAuthorization(author: "Tests"))

    private func open(_ fixture: Fixture) async throws -> (StoreSession, FixtureLocation) {
        let location = try TestFixtures.scratchCopy(fixture)
        let session = try await StoreSession.open(
            storeURL: location.storeURL, modelURL: location.modelURL, access: access)
        return (session, location)
    }

    private func firstRow(_ session: StoreSession, _ entity: String) async throws -> ObjectRef {
        try #require(try await session.references(FetchSpec(entity: entity), limit: 1).first)
    }

    /// What the file says, read by a connection of its own — not through the session.
    private func fileValue(_ location: FixtureLocation, _ sql: String) throws -> SQLiteValue? {
        let connection = try SQLiteConnection(readOnly: location.storeURL)
        defer { connection.close() }
        return try connection.scalar(sql)
    }

    @Test func aStagedValueShowsInTheSessionAndNotInTheFile() async throws {
        let (session, location) = try await open(.basic)
        let ref = try await firstRow(session, "Sample")
        let before = try fileValue(location, "SELECT ZNAME FROM ZSAMPLE WHERE Z_PK = \(ref.pk)")

        let changes = try await session.setValue(.string("Staged"), for: "name", of: PendingObjectID(ref))

        #expect(changes.changes.count == 1)
        let change = try #require(changes.changes.first)
        #expect(change.kind == .updated)
        #expect(change.object.ref == ref)
        #expect(change.label == "Staged")
        #expect(change.fields.map(\.property) == ["name"])
        #expect(change.fields.first?.after == .string("Staged"))
        #expect(change.fields.first?.before != .string("Staged"))
        #expect(changes.canUndo && !changes.canRedo)
        #expect(changes.undoActionName == "Edit name")

        // The grid and the inspector see what is staged; the file does not.
        #expect(try await session.object(ref)["name"] == .string("Staged"))
        let pager = try await session.openPager(FetchSpec(entity: "Sample"))
        let page = try await session.page(pager, range: 0..<40)
        #expect(page.rows.first { $0.ref == ref }?.values[page.columns.index(of: "name")!] == .string("Staged"))
        #expect(try fileValue(location, "SELECT ZNAME FROM ZSAMPLE WHERE Z_PK = \(ref.pk)") == before)
        await session.close()
    }

    @Test func undoAndRedoWalkTheEditsOneAtATime() async throws {
        let (session, _) = try await open(.basic)
        let ref = try await firstRow(session, "Sample")
        let object = PendingObjectID(ref)
        let original = try await session.object(ref)["int32Value"]

        try await session.setValue(.int(7), for: "int32Value", of: object, actionName: "Seven")
        try await session.setValue(.int(8), for: "int32Value", of: object, actionName: "Eight")

        var changes = try await session.undo()
        #expect(changes.undoActionName == "Seven" && changes.redoActionName == "Eight")
        #expect(changes.undoDepth == 1)
        #expect(try await session.object(ref)["int32Value"] == .int(7))

        changes = try await session.undo()
        #expect(changes.isEmpty && !changes.canUndo && changes.canRedo)
        #expect(try await session.object(ref)["int32Value"] == original)

        changes = try await session.redo()
        changes = try await session.redo()
        #expect(changes.change(for: object)?.fields.first?.after == .int(8))
        #expect(changes.canUndo && !changes.canRedo && changes.undoDepth == 2)
        await session.close()
    }

    @Test func anEditThatChangesNothingLeavesNothingToUndo() async throws {
        let (session, _) = try await open(.basic)
        let ref = try await firstRow(session, "Sample")
        let current = try #require(try await session.object(ref)["name"])
        try await session.setValue(.int(1), for: "int32Value", of: PendingObjectID(ref), actionName: "One")

        let changes = try await session.setValue(current, for: "name", of: PendingObjectID(ref), actionName: "Same")
        #expect(changes.undoActionName == "One" && changes.undoDepth == 1)
        await session.close()
    }

    @Test func valuesTheAttributeCannotHoldAreRefusedBeforeAnythingIsStaged() async throws {
        let (session, _) = try await open(.basic)
        let object = PendingObjectID(try await firstRow(session, "Sample"))

        await #expect(throws: DabbiError.self) {
            try await session.setValue(.int(70_000), for: "int16Value", of: object)
        }
        await #expect(throws: DabbiError.self) {
            try await session.setValue(.string("seven"), for: "int32Value", of: object)
        }
        await #expect(throws: DabbiError.self) {
            try await session.setValue(.int(1), for: "noSuchProperty", of: object)
        }
        let changes = try await session.pendingChanges()
        #expect(changes.isEmpty && !changes.canUndo)
        await session.close()
    }

    @Test func aReadOnlySessionStagesNothing() async throws {
        let location = try TestFixtures.scratchCopy(.basic)
        let session = try await StoreSession.open(storeURL: location.storeURL, modelURL: location.modelURL)
        let ref = try await firstRow(session, "Sample")
        let error = await #expect(throws: DabbiError.self) {
            try await session.setValue(.string("x"), for: "name", of: PendingObjectID(ref))
        }
        #expect(error?.code == .notEditable)
        #expect(try await session.pendingChanges() == .none)
        await session.close()
    }

    @Test func commitWritesEverythingOnceTheBackupIsDone() async throws {
        let (session, location) = try await open(.basic)
        let ref = try await firstRow(session, "Sample")
        try await session.setValue(.string("Committed"), for: "name", of: PendingObjectID(ref))
        let (inserted, _) = try await session.insertObject(entity: "Sample")
        #expect(inserted.isInserted)
        try await session.setValue(.string("New one"), for: "name", of: inserted)
        let generation = await session.generation

        let prepared = Flag()
        let summary = try await session.commit {
            // The backup runs while the file still has none of it.
            let name = try fileValue(location, "SELECT ZNAME FROM ZSAMPLE WHERE Z_PK = \(ref.pk)")
            #expect(name != .text("Committed"))
            prepared.set()
        }
        #expect(prepared.isSet)
        #expect(summary.inserted == 1 && summary.updated == 1 && summary.deleted == 0)
        #expect(summary.generation == generation + 1)
        #expect(try fileValue(location, "SELECT ZNAME FROM ZSAMPLE WHERE Z_PK = \(ref.pk)") == .text("Committed"))
        #expect(try fileValue(location, "SELECT COUNT(*) FROM ZSAMPLE") == .integer(41))

        let after = try await session.pendingChanges()
        #expect(after.isEmpty && !after.canUndo && !after.canRedo)
        await session.close()
    }

    @Test func aFailedPreparationWritesNothingAndKeepsEverythingStaged() async throws {
        let (session, location) = try await open(.basic)
        let ref = try await firstRow(session, "Sample")
        try await session.setValue(.string("Never"), for: "name", of: PendingObjectID(ref))

        let error = await #expect(throws: DabbiError.self) {
            try await session.commit { throw DabbiError(.snapshotUnverified, "The backup does not hold up.") }
        }
        #expect(error?.code == .commitPreparationFailed)
        #expect(try fileValue(location, "SELECT ZNAME FROM ZSAMPLE WHERE Z_PK = \(ref.pk)") != .text("Never"))
        #expect(try await session.pendingChanges().changes.count == 1)
        await session.close()
    }

    @Test func validationFailuresNameTheObjectAndPropertyAndKeepTheEdits() async throws {
        let (session, location) = try await open(.basic)
        let ref = try await firstRow(session, "Sample")
        // `name` must be at least one character long.
        try await session.setValue(.string(""), for: "name", of: PendingObjectID(ref))

        let error = await #expect(throws: DabbiError.self) { try await session.commit() }
        #expect(error?.code == .validationFailed)
        #expect(error?.diagnosis.contains { $0.contains("\(ref)") && $0.contains("name") } == true)
        #expect(error?.diagnosis.contains { $0.contains("\"\"") } == false)
        #expect(try fileValue(location, "SELECT ZNAME FROM ZSAMPLE WHERE Z_PK = \(ref.pk)") != .text(""))
        #expect(try await session.pendingChanges().changes.count == 1)
        await session.close()
    }

    @Test func deleteStagesTheCascadeAndCommitHonoursDeny() async throws {
        let (session, _) = try await open(.company)
        let department = try await firstRow(session, "Department")
        var changes = try await session.delete([PendingObjectID(department)])
        #expect(changes.change(for: PendingObjectID(department))?.kind == .deleted)
        #expect(changes.change(for: PendingObjectID(department))?.label?.hasPrefix("Department") == true)

        // Its employees deny the delete; nothing is written.
        let error = await #expect(throws: DabbiError.self) { try await session.commit() }
        #expect(error?.code == .validationFailed)
        #expect(error?.diagnosis.contains { $0.contains("employees") } == true)

        changes = try await session.undo()
        #expect(changes.isEmpty)
        #expect(try await session.object(department)["name"] != nil)
        await session.close()
    }

    @Test func deletedRowsLeaveTheirPagesUntilTheyAreUndone() async throws {
        let (session, _) = try await open(.basic)
        let pager = try await session.openPager(FetchSpec(entity: "Sample"))
        let first = try #require(try await session.page(pager, range: 0..<1).rows.first?.ref)

        try await session.delete([PendingObjectID(first)])
        #expect(try await session.page(pager, range: 0..<1).missing == [0])
        #expect(try await session.count(FetchSpec(entity: "Sample")) == 39)

        try await session.undo()
        #expect(try await session.page(pager, range: 0..<1).rows.first?.ref == first)
        await session.close()
    }

    @Test func insertedObjectsAreListedButNotPaged() async throws {
        let (session, _) = try await open(.basic)
        let (object, changes) = try await session.insertObject(entity: "Sample", actionName: "New Sample")
        #expect(changes.change(for: object)?.kind == .inserted)
        #expect(changes.undoActionName == "New Sample")

        let pager = try await session.openPager(FetchSpec(entity: "Sample"))
        #expect(pager.count == 40)
        await #expect(throws: DabbiError.self) { try await session.insertObject(entity: "NoSuchEntity") }

        let undone = try await session.undo()
        #expect(undone.isEmpty)
        await #expect(throws: DabbiError.self) {
            try await session.setValue(.string("x"), for: "name", of: object)
        }
        await session.close()
    }

    @Test func abstractEntitiesCannotBeInserted() async throws {
        let (session, _) = try await open(.company)
        let error = await #expect(throws: DabbiError.self) { try await session.insertObject(entity: "Party") }
        #expect(error?.code == .invalidValue)
        await session.close()
    }

    @Test func toOnesAreSetByReference() async throws {
        let (session, _) = try await open(.company)
        let person = try await firstRow(session, "Person")
        let tag = try await firstRow(session, "Tag")
        let manager = try await firstRow(session, "Manager")

        await #expect(throws: DabbiError.self) {
            try await session.setValue(.toOne(tag, display: nil), for: "boss", of: PendingObjectID(person))
        }
        let changes = try await session.setValue(
            .toOne(manager, display: nil), for: "boss", of: PendingObjectID(person))
        let field = try #require(changes.change(for: PendingObjectID(person))?.fields.first { $0.property == "boss" })
        guard case .toOne(let destination, _) = field.after else {
            Issue.record("boss is not a to-one: \(String(describing: field.after))")
            return
        }
        #expect(destination == manager)
        // The manager gained a report: its side of the relationship is staged too.
        #expect(changes.change(for: PendingObjectID(manager))?.kind == .updated)
        await session.close()
    }

    @Test func discardThrowsAwayEverythingAndTheUndoStack() async throws {
        let (session, _) = try await open(.basic)
        let ref = try await firstRow(session, "Sample")
        let original = try await session.object(ref)["name"]
        try await session.setValue(.string("Gone"), for: "name", of: PendingObjectID(ref))
        _ = try await session.insertObject(entity: "Sample")

        let changes = try await session.discardChanges()
        #expect(changes == .none)
        #expect(try await session.pendingChanges() == .none)
        #expect(try await session.object(ref)["name"] == original)
        await session.close()
    }

    @Test func aCommitWithNothingStagedDoesNothing() async throws {
        let (session, _) = try await open(.basic)
        let generation = await session.generation
        let summary = try await session.commit { Issue.record("prepared a commit with nothing to write") }
        #expect(summary.total == 0 && summary.generation == generation)
        await session.close()
    }
}

/// Set from a `@Sendable` closure the test awaits.
private final class Flag: @unchecked Sendable {
    private(set) var isSet = false
    func set() { isSet = true }
}
