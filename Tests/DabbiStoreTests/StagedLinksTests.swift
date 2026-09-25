import DabbiBase
import DabbiTestSupport
import FixtureKit
import Foundation
import Testing

@testable import DabbiStore

/// EDT-3: relationships edited by linking and unlinking. Each is one staged edit — undone and redone on its own —
/// Core Data keeps the other end in step, and nothing is written before the commit.
@Suite struct StagedLinksTests {
    private let access = StoreAccess.editable(WriteAuthorization(author: "Tests"))

    private func open(_ fixture: Fixture) async throws -> (StoreSession, FixtureLocation) {
        let location = try TestFixtures.scratchCopy(fixture)
        let session = try await StoreSession.open(
            storeURL: location.storeURL, modelURL: location.modelURL, access: access)
        return (session, location)
    }

    private func refs(_ session: StoreSession, _ entity: String) async throws -> [ObjectRef] {
        try await session.references(FetchSpec(entity: entity, includeSubentities: false))
    }

    private func linked(_ session: StoreSession, _ ref: ObjectRef, _ name: String) async throws -> [PendingObjectID] {
        try await session.related(to: ref, through: name).items.map(\.object)
    }

    @Test func aToManyIsLinkedAndUnlinkedAndTheOtherEndFollows() async throws {
        let (session, location) = try await open(.company)
        let person = try #require(try await refs(session, "Person").first)
        let tags = try await linked(session, person, "tags")
        let tag = try #require(try await refs(session, "Tag").first { !tags.contains(PendingObjectID($0)) })

        let changes = try await session.link([PendingObjectID(tag)], to: PendingObjectID(person), through: "tags")
        #expect(changes.undoActionName == "Link tags" && changes.undoDepth == 1)
        #expect(try await linked(session, person, "tags").contains(PendingObjectID(tag)))
        // Core Data keeps the inverse: the tag lists the person without being told.
        #expect(try await linked(session, tag, "people").contains(PendingObjectID(person)))

        // Linking what is already linked is no edit.
        let again = try await session.link([PendingObjectID(tag)], to: PendingObjectID(person), through: "tags")
        #expect(again.undoDepth == 1)

        let unlinked = try await session.unlink(
            [PendingObjectID(tag)], from: PendingObjectID(person), through: "tags")
        #expect(unlinked.undoActionName == "Unlink tags" && unlinked.undoDepth == 2)
        #expect(try await linked(session, person, "tags") == tags)
        let people = try await linked(session, tag, "people")
        #expect(!people.contains(PendingObjectID(person)))
        // The tag itself stays: unlinking deletes nothing.
        #expect(try await refs(session, "Tag").contains(tag))

        try await session.undo()
        #expect(try await linked(session, person, "tags").contains(PendingObjectID(tag)))
        try await session.redo()
        #expect(try await linked(session, person, "tags") == tags)

        // Nothing reached the file.
        try await session.discardChanges()
        await session.close()
        let reader = try await StoreSession.open(storeURL: location.storeURL, modelURL: location.modelURL)
        #expect(try await linked(reader, person, "tags") == tags)
        await reader.close()
    }

    @Test func anOrderedToManyTakesNewObjectsAtTheEnd() async throws {
        let (session, _) = try await open(.ordered)
        let playlist = try #require(try await refs(session, "Playlist").first)
        let featured = try await linked(session, playlist, "featured")
        #expect(featured.count == 3)
        let track = try #require(try await refs(session, "Track").first { !featured.contains(PendingObjectID($0)) })

        try await session.link([PendingObjectID(track)], to: PendingObjectID(playlist), through: "featured")
        #expect(try await linked(session, playlist, "featured") == featured + [PendingObjectID(track)])

        // Taking one out keeps the order of the rest.
        try await session.unlink([featured[0]], from: PendingObjectID(playlist), through: "featured")
        let rest = try await linked(session, playlist, "featured")
        #expect(rest == Array(featured.dropFirst()) + [PendingObjectID(track)])
        await session.close()
    }

    @Test func aToOneTakesOneObjectAndReplacesWhatItHeld() async throws {
        let (session, _) = try await open(.company)
        let people = try await refs(session, "Person")
        #expect(people.count >= 3)
        let (person, first, second) = (people[0], people[1], people[2])
        let object = PendingObjectID(person)

        try await session.link([PendingObjectID(first)], to: object, through: "boss")
        #expect(try await linked(session, person, "boss") == [PendingObjectID(first)])
        try await session.link([PendingObjectID(second)], to: object, through: "boss")
        #expect(try await linked(session, person, "boss") == [PendingObjectID(second)])
        // The first boss no longer has this person reporting to them.
        let reports = try await linked(session, first, "reports")
        #expect(!reports.contains(object))

        let error = await #expect(throws: DabbiError.self) {
            try await session.link([PendingObjectID(first), PendingObjectID(second)], to: object, through: "boss")
        }
        #expect(error?.code == .invalidValue)

        // Unlinking what it does not hold changes nothing; unlinking what it does empties it.
        let depth = try await session.pendingChanges().undoDepth
        let unchanged = try await session.unlink([PendingObjectID(first)], from: object, through: "boss")
        #expect(unchanged.undoDepth == depth)
        try await session.unlink([PendingObjectID(second)], from: object, through: "boss")
        #expect(try await linked(session, person, "boss").isEmpty)
        await session.close()
    }

    @Test func aNewRelatedObjectIsInsertedAndLinkedAsOneEdit() async throws {
        let (session, _) = try await open(.company)
        let department = try #require(try await refs(session, "Department").first)
        let before = try await linked(session, department, "employees")

        let (employee, changes) = try await session.insertRelatedObject(
            to: PendingObjectID(department), through: "employees")
        #expect(employee.isInserted && employee.entity == "Employee")
        #expect(changes.undoActionName == "New Employee" && changes.undoDepth == 1)
        #expect(changes.change(for: employee)?.kind == .inserted)

        // Listed on the department's side after the saved objects, and pointing back at it from its own.
        let related = try await session.related(to: department, through: "employees")
        #expect(related.count == before.count + 1)
        #expect(related.items.map(\.object) == before + [employee])
        #expect(related.items.last?.ref == nil)
        guard case .toOne(let back, _)? = try await session.stagedObject(employee)["department"] else {
            Issue.record("the new employee has no department")
            await session.close()
            return
        }
        #expect(back == department)

        // A sub-entity of the destination may be asked for; anything else may not.
        let (manager, _) = try await session.insertRelatedObject(
            to: PendingObjectID(department), through: "employees", entity: "Manager")
        #expect(manager.entity == "Manager")
        let error = await #expect(throws: DabbiError.self) {
            try await session.insertRelatedObject(to: PendingObjectID(department), through: "employees", entity: "Tag")
        }
        #expect(error?.code == .invalidValue)

        // One undo takes the manager back, another the employee and its link.
        try await session.undo()
        try await session.undo()
        #expect(try await linked(session, department, "employees") == before)
        await #expect(throws: DabbiError.self) { try await session.stagedObject(employee) }
        await session.close()
    }

    @Test func aToOneLeadsToANewObjectByItsStagedIdentityUntilTheCommit() async throws {
        let (session, location) = try await open(.company)
        let department = try #require(try await refs(session, "Department").first)
        let object = PendingObjectID(department)
        let saved = try #require(try await session.object(department)["head"])

        // Made at the far end of a to-one, the new object replaces what it held, and the department leads to it
        // by the identity it was staged under: it has no reference yet. Its name is empty, so it has no label.
        let (manager, changes) = try await session.insertRelatedObject(to: object, through: "head")
        #expect(manager.isInserted && manager.entity == "Manager")
        #expect(changes.undoActionName == "New Manager" && changes.undoDepth == 1)
        #expect(try await session.object(department)["head"] == .toOneInserted(manager, display: nil))
        #expect(try await linked(session, department, "head") == [manager])

        // As a value, it is set and checked like a saved object.
        try await session.setValue(saved, for: "head", of: object)
        #expect(try await session.object(department)["head"] == saved)
        try await session.setValue(.toOneInserted(manager, display: "ignored"), for: "head", of: object)
        #expect(try await session.object(department)["head"] == .toOneInserted(manager, display: nil))
        let (tag, _) = try await session.insertObject(entity: "Tag")
        let wrongEntity = await #expect(throws: DabbiError.self) {
            try await session.setValue(.toOneInserted(tag, display: nil), for: "head", of: object)
        }
        #expect(wrongEntity?.code == .invalidValue)
        // What an identity resolves to is checked, not only the entity it names.
        let disguised = PendingObjectID(uri: tag.uri, entity: "Manager")
        let posing = await #expect(throws: DabbiError.self) {
            try await session.setValue(.toOneInserted(disguised, display: nil), for: "head", of: object)
        }
        #expect(posing?.code == .invalidValue)
        let linkedPosing = await #expect(throws: DabbiError.self) {
            try await session.link([disguised], to: object, through: "head")
        }
        #expect(linkedPosing?.code == .invalidValue)
        let savedTag = try #require(try await refs(session, "Tag").first)
        let posingRef = ObjectRef(entity: "Manager", pk: savedTag.pk, uri: savedTag.uri)
        let savedPosing = await #expect(throws: DabbiError.self) {
            try await session.setValue(.toOne(posingRef, display: nil), for: "head", of: object)
        }
        #expect(savedPosing?.code == .invalidValue)
        // One whose insert was undone is no longer there to lead to.
        let (undone, _) = try await session.insertObject(entity: "Manager")
        try await session.undo()
        let gone = await #expect(throws: DabbiError.self) {
            try await session.setValue(.toOneInserted(undone, display: nil), for: "head", of: object)
        }
        #expect(gone?.code == .objectNotFound)
        #expect(try await session.object(department)["head"] == .toOneInserted(manager, display: nil))

        // The commit gives it a reference, and the department leads to it by that from then on.
        let summary = try await session.commit()
        let committed = try #require(summary.insertedRefs[manager])
        #expect(committed.entity == "Manager")
        #expect(try await session.object(department)["head"] == .toOne(committed, display: nil))
        await session.close()
        let reader = try await StoreSession.open(storeURL: location.storeURL, modelURL: location.modelURL)
        #expect(try await reader.object(department)["head"] == .toOne(committed, display: nil))
        await reader.close()
    }

    @Test func whatARelationshipCannotHoldIsRefusedBeforeAnythingIsStaged() async throws {
        let (session, _) = try await open(.company)
        let department = PendingObjectID(try #require(try await refs(session, "Department").first))
        let tag = PendingObjectID(try #require(try await refs(session, "Tag").first))

        let wrongEntity = await #expect(throws: DabbiError.self) {
            try await session.link([tag], to: department, through: "employees")
        }
        #expect(wrongEntity?.code == .invalidValue)
        let noSuchRelationship = await #expect(throws: DabbiError.self) {
            try await session.link([tag], to: department, through: "tags")
        }
        #expect(noSuchRelationship?.code == .unknownProperty)
        #expect(try await session.pendingChanges() == .none)
        await session.close()

        let location = try TestFixtures.scratchCopy(.company)
        let reader = try await StoreSession.open(storeURL: location.storeURL, modelURL: location.modelURL)
        let readOnly = await #expect(throws: DabbiError.self) {
            try await reader.unlink([tag], from: department, through: "employees")
        }
        #expect(readOnly?.code == .notEditable)
        await reader.close()
    }
}
