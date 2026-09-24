import DabbiBase
import DabbiTestSupport
import FixtureKit
import Foundation
import Testing

@testable import DabbiStore

/// EDT-2: every staged edit is validated as the commit would validate it, each broken rule is an issue on its
/// object and property, in words and without the value, and a delete says what its rules would do before it is
/// staged.
@Suite struct ValidationTests {
    private let access = StoreAccess.editable(WriteAuthorization(author: "Tests"))

    private func open(_ fixture: Fixture) async throws -> StoreSession {
        let location = try TestFixtures.scratchCopy(fixture)
        return try await StoreSession.open(
            storeURL: location.storeURL, modelURL: location.modelURL, access: access)
    }

    private func firstRow(_ session: StoreSession, _ entity: String) async throws -> ObjectRef {
        try #require(try await session.references(FetchSpec(entity: entity), limit: 1).first)
    }

    // MARK: Issues

    @Test func aBrokenRuleIsAnIssueOnItsFieldAsSoonAsItIsStaged() async throws {
        let session = try await open(.basic)
        let object = PendingObjectID(try await firstRow(session, "Sample"))

        // `name` must be at least one character long, and `int16Value` at most 1000.
        try await session.setValue(.string(""), for: "name", of: object)
        let changes = try await session.setValue(.int(2000), for: "int16Value", of: object)

        let name = try #require(changes.issues.first { $0.property == "name" })
        #expect(name.object == object)
        #expect(name.rule == .tooShort && name.limit == "1")
        #expect(name.message == "Must be at least 1 character long.")
        let number = try #require(changes.issues.first { $0.property == "int16Value" })
        #expect(number.rule == .aboveMaximum && number.limit == "1000")
        #expect(number.message == "Must be at most 1000.")
        #expect(changes.issues(for: object).count == 2)
        // The rule, never the value.
        #expect(!changes.issues.contains { $0.message.contains("2000") || $0.description.contains("2000") })
        await session.close()
    }

    @Test func aMissingRequiredValueIsAnIssue() async throws {
        let session = try await open(.basic)
        let object = PendingObjectID(try await firstRow(session, "Sample"))
        let changes = try await session.setValue(.null, for: "name", of: object)
        let issue = try #require(changes.issues.first { $0.property == "name" && $0.rule == .required })
        #expect(issue.message == "A value is required.")
        await session.close()
    }

    @Test func insertedObjectsAreValidatedForInsert() async throws {
        let session = try await open(.basic)
        let (object, inserted) = try await session.insertObject(entity: "Sample")
        // The model's defaults keep its own rules.
        #expect(inserted.issues.isEmpty)

        let changes = try await session.setValue(
            .string(String(repeating: "x", count: 101)), for: "name", of: object)
        let issue = try #require(changes.issues.first)
        #expect(issue.object == object && issue.property == "name")
        #expect(issue.rule == .tooLong && issue.limit == "100")
        #expect(issue.description == "Sample#new · name: Must be at most 100 characters long.")
        await session.close()
    }

    @Test func issuesComeAndGoWithTheEditsThatCauseThem() async throws {
        let session = try await open(.basic)
        let object = PendingObjectID(try await firstRow(session, "Sample"))
        #expect(try await session.setValue(.string(""), for: "name", of: object).issues.count == 1)
        #expect(try await session.undo().issues.isEmpty)
        #expect(try await session.redo().issues.count == 1)
        #expect(try await session.pendingChanges().issues.count == 1)
        #expect(try await session.setValue(.string("Fixed"), for: "name", of: object).issues.isEmpty)
        #expect(try await session.discardChanges().issues.isEmpty)
        await session.close()
    }

    @Test func aRefusedCommitListsTheSameIssues() async throws {
        let session = try await open(.basic)
        let object = PendingObjectID(try await firstRow(session, "Sample"))
        let changes = try await session.setValue(.int(-5), for: "int16Value", of: object)
        let issue = try #require(changes.issues.first)
        #expect(issue.rule == .belowMinimum && issue.limit == "0")

        let error = await #expect(throws: DabbiError.self) { try await session.commit() }
        #expect(error?.code == .validationFailed)
        #expect(error?.diagnosis.contains(issue.description) == true)
        #expect(try await session.pendingChanges().issues == changes.issues)
        await session.close()
    }

    @Test func aDeniedDeleteIsAnIssueOnceStaged() async throws {
        let session = try await open(.company)
        let department = PendingObjectID(try await firstRow(session, "Department"))
        let changes = try await session.delete([department])

        let issue = try #require(changes.issues.first { $0.object == department })
        #expect(issue.property == "employees" && issue.rule == .deleteDenied)
        #expect((issue.count ?? 0) > 0)
        #expect(issue.message.hasSuffix("and its delete rule is Deny."))
        #expect(try await session.undo().issues.isEmpty)
        await session.close()
    }

    @Test func messagesSayTheRuleAndItsFigure() {
        func message(
            _ rule: ValidationIssue.Rule, _ limit: String? = nil, count: Int? = nil, relationship: Bool = false
        ) -> String {
            ValidationTranslator.message(for: rule, limit: limit, count: count, isRelationship: relationship)
        }
        #expect(message(.tooShort, "1") == "Must be at least 1 character long.")
        #expect(message(.tooLong, "20") == "Must be at most 20 characters long.")
        #expect(message(.tooShort) == "Is shorter than the model allows.")
        #expect(message(.required) == "A value is required.")
        #expect(message(.required, relationship: true) == "An object is required.")
        #expect(message(.tooFewObjects, "2", relationship: true) == "Must have at least 2 objects.")
        #expect(message(.tooManyObjects, "1", relationship: true) == "Must have at most 1 object.")
        #expect(message(.deleteDenied, count: 1) == "Still has 1 object, and its delete rule is Deny.")
        #expect(message(.deleteDenied) == "Still has objects, and its delete rule is Deny.")
        #expect(message(.other, "SELF != 3") == "Does not satisfy the model's rule SELF != 3.")
        #expect(message(.other) == "Does not pass the model's validation.")
    }

    // MARK: Delete previews

    @Test func previewingADeleteStagesNothingAndKeepsTheRedoStack() async throws {
        let session = try await open(.company)
        let tag = try await firstRow(session, "Tag")
        try await session.setValue(.string("Renamed"), for: "label", of: PendingObjectID(tag), actionName: "Rename")
        let before = try await session.undo()
        #expect(before.canRedo)

        let preview = try await session.deletePreview(of: [PendingObjectID(tag)])
        #expect(preview.requested == 1)
        let after = try await session.pendingChanges()
        #expect(after == before)
        #expect(after.canRedo && after.redoActionName == "Rename")
        #expect(try await session.object(tag)["label"] != .string("Renamed"))
        await session.close()
    }

    @Test func unlinkingAloneIsAPlainDelete() async throws {
        let session = try await open(.company)
        let tag = PendingObjectID(try await firstRow(session, "Tag"))
        let preview = try await session.deletePreview(of: [tag])

        // A tag is on people: deleting it unlinks them (Nullify) and takes nothing else along.
        #expect(preview.isPlain)
        #expect(preview.cascaded.isEmpty && preview.dangling.isEmpty && preview.issues.isEmpty)
        #expect(!preview.nullified.isEmpty)
        #expect(preview.nullified.allSatisfy { ["Person", "Employee", "Manager"].contains($0.entity) })
        await session.close()
    }

    @Test func aCascadeIsListedWithTheDenialsItWouldMeet() async throws {
        let session = try await open(.company)
        let organisation = PendingObjectID(try await firstRow(session, "Organisation"))
        let preview = try await session.deletePreview(of: [organisation])

        // Its departments go with it (Cascade), and every one of them still has employees (Deny).
        #expect(preview.requested == 1)
        #expect(!preview.isPlain)
        #expect(preview.cascaded.map(\.entity) == ["Department"])
        let departments = try #require(preview.cascaded.first)
        #expect(departments.count >= 1 && departments.sample.count == departments.count)
        #expect(preview.cascadedCount == departments.count)
        #expect(preview.issues.count == departments.count)
        #expect(
            preview.issues.allSatisfy {
                $0.rule == .deleteDenied && $0.property == "employees" && ($0.count ?? 0) > 0
            })
        #expect(Set(preview.issues.map(\.object)) == Set(departments.sample))
        #expect(try await session.pendingChanges().isEmpty)
        await session.close()
    }

    @Test func referencesWithoutAnInverseAreFoundDangling() async throws {
        let session = try await open(.company)
        let department = try await firstRow(session, "Department")
        // `head` has no inverse, so deleting the manager does nothing to the department that names it.
        guard case .toOne(let head?, _) = try await session.object(department)["head"] else {
            Issue.record("the department has no head")
            return
        }
        let preview = try await session.deletePreview(of: [PendingObjectID(head)])

        #expect(!preview.isPlain)
        let dangling = try #require(preview.dangling.first { $0.entity == "Department" })
        #expect(dangling.sample.contains(PendingObjectID(department)))
        // Its reports lose their boss, and its own department an employee: unlinked, and nothing refused.
        #expect(preview.nullified.contains { $0.entity == "Department" })
        #expect(preview.nullified.contains { $0.entity == "Employee" })
        #expect(preview.cascaded.isEmpty && preview.issues.isEmpty)
        await session.close()
    }
}
