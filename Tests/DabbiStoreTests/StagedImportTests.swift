import DabbiBase
import DabbiTestSupport
import FixtureKit
import Foundation
import Testing

@testable import DabbiStore

/// IMX-2 – IMX-4: rows staged by an import. A dry run stages nothing; an import is one undoable edit; rows are
/// checked as the commit would check them, one at a time, and one that fails leaves nothing behind.
@Suite struct StagedImportTests {
    private let access = StoreAccess.editable(WriteAuthorization(author: "Tests"))

    private func open(_ fixture: Fixture) async throws -> StoreSession {
        let location = try TestFixtures.scratchCopy(fixture)
        return try await StoreSession.open(storeURL: location.storeURL, modelURL: location.modelURL, access: access)
    }

    private func refs(_ session: StoreSession, _ entity: String) async throws -> [ObjectRef] {
        try await session.references(FetchSpec(entity: entity, includeSubentities: false))
    }

    private func sample(_ line: Int, name: String, int16: Int64 = 1, uuid: UUID = UUID()) -> ImportRow {
        ImportRow(
            line: line,
            values: [
                "name": .value(.string(name)), "int16Value": .value(.int(int16)), "uuidValue": .value(.uuid(uuid)),
            ])
    }

    /// Two rows that pass, one too short a name, one out of the model's range.
    private var mixed: [ImportRow] {
        [sample(2, name: "one"), sample(3, name: ""), sample(4, name: "two"), sample(5, name: "big", int16: 2000)]
    }

    @Test func aDryRunReportsEveryRowAndStagesNothing() async throws {
        let session = try await open(.basic)
        defer { Task { await session.close() } }
        // Something to redo: a dry run must not lose it.
        let ref = try #require(try await refs(session, "Sample").first)
        try await session.setValue(.string("edited"), for: "name", of: PendingObjectID(ref))
        try await session.undo()

        let report = try await session.previewImport(mixed, into: "Sample")
        #expect(report.rows.map(\.outcome) == [.inserted, .failed, .inserted, .failed])
        #expect(!report.isApplied)
        #expect(report.rows[1].issues.map(\.property) == ["name"])
        #expect(report.rows[1].issues.first?.message == "Must be at least 1 character long.")
        #expect(report.rows[3].issues.map(\.property) == ["int16Value"])
        #expect(report.rows.allSatisfy { $0.object == nil })

        let changes = try await session.pendingChanges()
        #expect(changes.isEmpty)
        #expect(changes.canRedo && changes.redoActionName == "Edit name")
    }

    @Test func allOrNothingStagesNothingWhenARowFails() async throws {
        let session = try await open(.basic)
        defer { Task { await session.close() } }
        let (report, changes) = try await session.importRows(mixed, into: "Sample")
        #expect(!report.isApplied)
        #expect(report.failed.map(\.line) == [3, 5])
        #expect(changes.isEmpty && !changes.canUndo)

        let rows = [sample(2, name: "one"), sample(3, name: "two")]
        let (applied, staged) = try await session.importRows(rows, into: "Sample")
        #expect(applied.isApplied && applied.count(.inserted) == 2)
        #expect(staged.count(of: .inserted) == 2)
    }

    @Test func skippingInvalidRowsStagesTheRestAsOneEdit() async throws {
        let session = try await open(.basic)
        defer { Task { await session.close() } }
        let options = ImportOptions(mode: .skipInvalid, actionName: "Import Samples")
        let (report, changes) = try await session.importRows(mixed, into: "Sample", options: options)
        #expect(report.isApplied)
        #expect(report.rows.map(\.outcome) == [.inserted, .failed, .inserted, .failed])
        #expect(changes.count(of: .inserted) == 2)
        #expect(changes.undoDepth == 1 && changes.undoActionName == "Import Samples")
        #expect(changes.issues.isEmpty)

        // The report names the staged objects, which the session can edit like any other.
        let object = try #require(report.rows[0].object)
        #expect(changes.change(for: object) != nil)
        let edited = try await session.setValue(.string("renamed"), for: "name", of: object)
        #expect(edited.undoDepth == 2)

        try await session.undo()
        let undone = try await session.undo()
        #expect(undone.isEmpty)
        let redone = try await session.redo()
        #expect(redone.count(of: .inserted) == 2)

        let summary = try await session.commit()
        #expect(summary.inserted == 2)
        #expect(try await refs(session, "Sample").count == 42)
    }

    @Test func uniquenessIsCheckedAgainstTheStoreAndEarlierRows() async throws {
        let session = try await open(.basic)
        defer { Task { await session.close() } }
        let ref = try #require(try await refs(session, "Sample").first)
        guard case .uuid(let existing) = try await session.object(ref)["uuidValue"] else {
            Issue.record("the fixture's samples have UUIDs")
            return
        }
        let twin = UUID()
        let rows = [
            sample(2, name: "clash", uuid: existing), sample(3, name: "a", uuid: twin),
            sample(4, name: "b", uuid: twin),
        ]
        let report = try await session.previewImport(rows, into: "Sample")
        #expect(report.rows.map(\.outcome) == [.failed, .inserted, .failed])
        #expect(report.rows[0].issues.map(\.property) == ["uuidValue"])
        #expect(report.rows[2].issues.first?.message == "Must be unique, and another object has the same value.")
    }

    @Test func anUpsertUpdatesWhatMatchesByURIOrByConstraint() async throws {
        let session = try await open(.basic)
        defer { Task { await session.close() } }
        let samples = try await refs(session, "Sample")
        guard case .uuid(let uuid) = try await session.object(samples[1])["uuidValue"] else {
            Issue.record("the fixture's samples have UUIDs")
            return
        }
        let byID = ImportRow(line: 2, id: samples[0].uri, values: ["name": .value(.string("by URI"))])
        let byKey = sample(3, name: "by constraint", uuid: uuid)
        let unchanged = ImportRow(line: 4, id: samples[2].uri, values: [:])
        let fresh = sample(5, name: "new")
        let (report, changes) = try await session.importRows(
            [byID, byKey, unchanged, fresh], into: "Sample", options: ImportOptions(upsert: true))
        #expect(report.rows.map(\.outcome) == [.updated, .updated, .unchanged, .inserted])
        #expect(report.rows[0].object == PendingObjectID(samples[0]))
        #expect(changes.count(of: .updated) == 2 && changes.count(of: .inserted) == 1)
        #expect(try await session.object(samples[0])["name"] == .string("by URI"))
        #expect(try await session.object(samples[1])["name"] == .string("by constraint"))

        // Without upsert the same row is a new object, which the constraint refuses.
        let again = try await session.previewImport([byKey], into: "Sample")
        #expect(again.rows.map(\.outcome) == [.failed])
    }

    @Test func relationshipsAreLinkedByKeyOrByURI() async throws {
        let session = try await open(.company)
        defer { Task { await session.close() } }
        let tags = try await refs(session, "Tag")
        let department = try #require(try await refs(session, "Department").first)
        let rows = [
            ImportRow(
                line: 2,
                values: [
                    "name": .value(.string("Ada")),
                    "tags": .references([.key(["label": .string("tag-1")]), .uri(tags[3].uri)]),
                    "department": .references([.key(["name": .string("Department 2")])]),
                ]),
            ImportRow(
                line: 3,
                values: ["name": .value(.string("Nobody")), "tags": .references([.key(["label": .string("none")])])]),
            ImportRow(
                line: 4,
                values: [
                    "name": .value(.string("Ghost")),
                    "department": .references([.uri(department.uri), .uri(department.uri)]),
                ]),
            ImportRow(
                line: 5, values: ["name": .value(.string("Wrong")), "tags": .references([.uri(department.uri)])]),
        ]
        let (report, changes) = try await session.importRows(
            rows, into: "Employee", options: ImportOptions(mode: .skipInvalid))
        #expect(report.rows.map(\.outcome) == [.inserted, .failed, .failed, .failed])
        #expect(report.rows[1].issues.first?.message == "No Tag has the key given.")
        #expect(report.rows[2].issues.first?.message == "It is a to-one relationship; give it one object.")
        #expect(report.rows[3].issues.first?.message == "It leads to Tag, not Department.")

        let object = try #require(report.rows[0].object)
        let fields = try #require(changes.change(for: object)?.fields)
        #expect(fields.first { $0.property == "tags" }?.after == .toMany(count: 2))
        // The other end follows: the department lists its new employee.
        let departments = try await session.references(
            FetchSpec(entity: "Department", predicate: PredicateSource(format: "name == \"Department 2\"")))
        let employees = try await session.related(to: try #require(departments.first), through: "employees")
        #expect(employees.items.contains { $0.object == object })
    }

    @Test func aFailedRowLeavesWhatItLinkedAlone() async throws {
        let session = try await open(.company)
        defer { Task { await session.close() } }
        let organisation = try #require(try await refs(session, "Organisation").first)
        let before = try await session.related(to: organisation, through: "departments").count
        // A department is cascaded from its organisation; one whose row fails must not take anything with it.
        let row = ImportRow(
            line: 2,
            values: [
                "name": .value(.string("Doomed")), "organisation": .references([.uri(organisation.uri)]),
                "head": .references([.key(["name": .string("Nobody")])]),
            ])
        let report = try await session.previewImport([row], into: "Department")
        #expect(report.rows.map(\.outcome) == [.failed])
        let (_, changes) = try await session.importRows(
            [row], into: "Department", options: ImportOptions(mode: .skipInvalid))
        #expect(changes.isEmpty)
        #expect(try await session.related(to: organisation, through: "departments").count == before)
    }

    @Test func aRowTheMappingCouldNotReadIsNotTried() async throws {
        let session = try await open(.basic)
        defer { Task { await session.close() } }
        let row = ImportRow(
            line: 7, issues: [ImportIssue(property: "int16Value", message: "This is not a whole number.")])
        let report = try await session.previewImport(
            [row, ImportRow(line: 8, values: ["colour": .value(.string("red"))])], into: "Sample")
        #expect(report.rows.map(\.outcome) == [.failed, .failed])
        #expect(report.rows[0].issues == row.issues)
        #expect(report.rows[1].issues.map(\.property) == ["colour"])
        // An abstract entity takes no new objects.
        let company = try await open(.company)
        defer { Task { await company.close() } }
        let abstract = try await company.previewImport([ImportRow(line: 2)], into: "Party")
        #expect(abstract.rows.first?.issues.first?.message == "Party is abstract and cannot have objects of its own.")
    }
}
