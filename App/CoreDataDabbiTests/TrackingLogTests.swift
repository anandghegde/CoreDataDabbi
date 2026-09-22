import DabbiKit
import FixtureKit
import Foundation
import Testing

@testable import CoreDataDabbi

/// The change log as a value: what it keeps, in what order, and what it says about it (TRK-1, TRK-2, TRK-9).
///
/// No window is involved. Everything the tracking table draws is decided here, which is what makes the ordering,
/// the folding, the wording and the strong-and-dim of a diff testable at all (ARCHITECTURE.md §11).
@MainActor
@Suite struct TrackingLogTests {
    private let english = Locale(identifier: "en_GB")
    private static let read = ColumnSet(["name", "age"])

    // MARK: Making changes to look at

    private func ref(_ pk: Int64, _ entity: String = "Person") throws -> ObjectRef {
        try #require(ObjectRef(storeUUID: "F1D0", entity: entity, pk: pk))
    }

    private func values(_ name: String, _ age: Int64) -> ObjectSnapshot {
        ObjectSnapshot(
            row: RowSnapshot(
                ref: ObjectRef(entity: "Person", pk: 0, uri: URL(fileURLWithPath: "/")),
                values: [.string(name), .int(age)]),
            columns: Self.read, generation: 1)
    }

    private func inserted(_ object: ObjectRef, _ name: String = "Ada", _ age: Int64 = 36) -> ChangeEvent {
        ChangeEvent(object: object, kind: .inserted, after: values(name, age), at: Date(timeIntervalSince1970: 0))
    }

    private func updated(
        _ object: ObjectRef, from: (String, Int64) = ("Ada", 36), to: (String, Int64) = ("Ada", 37),
        changed: Set<String>? = ["age"], links: [LinkChange] = [], transition: PredicateTransition? = nil
    ) -> ChangeEvent {
        ChangeEvent(
            object: object, kind: .updated, before: values(from.0, from.1), after: values(to.0, to.1),
            changedKeys: changed, links: links, transition: transition, at: Date(timeIntervalSince1970: 1))
    }

    private func deleted(_ object: ObjectRef, _ name: String = "Ada", _ age: Int64 = 37) -> ChangeEvent {
        ChangeEvent(object: object, kind: .deleted, before: values(name, age), at: Date(timeIntervalSince1970: 2))
    }

    /// A column of the log by name, over a real model so that the kinds and the titles are the model's own.
    private func column(_ property: String, of entity: String = "Person") async throws -> TrackingColumn {
        let model = try await TestProject.model(of: .company)
        let columns = TrackingColumn.columns(for: try #require(model.entity(named: entity)), in: model)
        return try #require(columns.first { $0.property == property })
    }

    private func cell(_ log: TrackingLog, line: Int, _ column: TrackingColumn) throws -> TrackingCell {
        try #require(log.cell(at: line, column: column, timeZone: .gmt, locale: english))
    }

    // MARK: Order and shape

    @Test func putsTheNewestChangeOnTopAndItsEarlierVersionsBeneathIt() throws {
        var log = TrackingLog()
        let ada = try ref(1)
        let grace = try ref(2)
        log.append(inserted(ada))
        log.append(inserted(grace, "Grace", 45))
        log.append(updated(ada))

        // Ada changed last, so Ada is first — and her own row is that change, not a re-print of her.
        #expect(log.entries.map(\.object) == [ada, grace])
        #expect(log.entry(at: 0)?.latest.kind == .updated)
        #expect(log.entry(at: 0)?.versionCount == 2)

        // Three changes, three lines: an identical line under every object's own row would say nothing.
        #expect(log.lineCount == 3)
        #expect(log.line(at: 0) == TrackingLog.Line(entry: 0, version: nil))
        #expect(log.line(at: 1) == TrackingLog.Line(entry: 0, version: 1))
        #expect(log.line(at: 2) == TrackingLog.Line(entry: 1, version: nil))
        #expect(log.version(at: 1)?.kind == .inserted)
        #expect(log.object(at: 2) == grace)
    }

    @Test func foldingAnObjectHidesItsOwnEarlierVersionsAndNothingElse() throws {
        var log = TrackingLog()
        let ada = try ref(1)
        let grace = try ref(2)
        log.append(inserted(grace, "Grace", 45))
        log.append(inserted(ada))
        log.append(updated(ada))
        #expect(log.lineCount == 3)

        log.setExpanded(false, ofEntryAt: 0)
        #expect(log.lineCount == 2)
        #expect(log.object(at: 0) == ada)
        #expect(log.object(at: 1) == grace)
        #expect(log.badge(at: 0)?.isExpanded == false)

        log.toggleExpanded(ofEntryAt: 0)
        #expect(log.lineCount == 3)
        #expect(log.badge(at: 0)?.isExpanded == true)
    }

    @Test func onlyAnObjectWithSomethingFoldedAwayCanBeFolded() throws {
        var log = TrackingLog()
        let ada = try ref(1)
        log.append(inserted(ada))
        #expect(log.badge(at: 0)?.canFold == false)

        log.append(updated(ada))
        #expect(log.badge(at: 0)?.canFold == true)
        // A version row is a leaf: it has nothing under it to fold.
        #expect(log.badge(at: 1)?.canFold == false)
        #expect(log.badge(at: 1)?.isVersion == true)
    }

    @Test func keepsAnObjectFindableAsTheRowsMoveUnderIt() throws {
        var log = TrackingLog()
        let ada = try ref(1)
        let grace = try ref(2)
        log.append(inserted(ada))
        #expect(log.line(of: ada) == 0)

        log.append(inserted(grace, "Grace", 45))
        #expect(log.line(of: ada) == 1)
        log.append(updated(ada))
        #expect(log.line(of: ada) == 0)
        #expect(log.line(of: grace) == 2)
        #expect(log.line(of: try ref(9)) == nil)
    }

    @Test func numbersVersionsOnceForTheLifeOfTheWindow() throws {
        var log = TrackingLog()
        let ada = try ref(1)
        log.append(inserted(ada))
        log.append(updated(ada))
        #expect(log.entries[0].versions.map(\.sequence) == [2, 1])

        // Emptying the log empties what is on screen, not the count of what has been seen: a version the user
        // has already read must never come back under a number they have also read.
        log.clear()
        #expect(log.isEmpty)
        #expect(log.lineCount == 0)
        #expect(log.counts.isEmpty)
        log.append(updated(ada))
        #expect(log.entries[0].versions.map(\.sequence) == [3])
    }

    @Test func ignoresABatchWithNothingInIt() throws {
        var log = TrackingLog()
        log.append(ChangeBatch(kind: .commit, events: []))
        #expect(log.isEmpty)
        #expect(log.counts.versions == 0)
    }

    // MARK: Bounds

    @Test func letsTheOldestGoAndSaysThatItDid() throws {
        var log = TrackingLog()
        log.objectLimit = 2
        log.versionLimit = 2

        let first = try ref(1)
        log.append(inserted(first))
        for pk in Int64(2)...3 { log.append(inserted(try ref(pk))) }
        #expect(log.entries.count == 2)
        #expect(log.droppedObjects == 1)
        #expect(log.line(of: first) == nil)

        let busy = try ref(3)
        for _ in 0..<3 { log.append(updated(busy)) }
        let entry = try #require(log.entries.first { $0.object == busy })
        #expect(entry.versions.count == 2)
        // Four changes to the row, two of them still readable — and the entry knows the difference.
        #expect(entry.versionCount == 4)
        #expect(entry.hasDroppedVersions)
        #expect(log.droppedVersions == 2)
        #expect(try #require(log.badge(at: 0)).detail?.contains("4 versions") == true)
        #expect(try #require(log.badge(at: 0)).detail?.contains("older versions dropped") == true)
    }

    @Test func countsWhatHappenedRatherThanWhatIsLeft() throws {
        var log = TrackingLog()
        log.objectLimit = 1
        log.append(inserted(try ref(1)))
        log.append(updated(try ref(2)))
        log.append(deleted(try ref(3)))

        #expect(log.counts.created == 1)
        #expect(log.counts.updated == 1)
        #expect(log.counts.deleted == 1)
        #expect(log.counts.versions == 3)
        // Objects is what the log is showing; versions is what the session has seen.
        #expect(log.counts.objects == 1)
        #expect(!log.counts.isEmpty)
    }

    // MARK: What a change is called (ADR-17)

    @Test func saysWhatIsNotKnownRatherThanShowingAnEmptyDiff() throws {
        var log = TrackingLog()
        let ada = try ref(1)
        log.append(updated(ada, changed: nil))
        #expect(log.badge(at: 0)?.title == "Updated · prior value unknown")

        log.append(updated(ada, changed: []))
        #expect(log.badge(at: 0)?.title == "Updated · nothing in the reading changed")

        log.append(updated(ada, changed: ["name", "age"]))
        #expect(log.badge(at: 0)?.title == "Updated · 2 fields")
        #expect(log.badge(at: 0)?.glyph == "✎")
    }

    @Test func tellsTheThreeKindsApartWithoutLeaningOnColour() throws {
        var log = TrackingLog()
        log.append(inserted(try ref(1)))
        #expect(log.badge(at: 0)?.glyph == "+")
        #expect(log.badge(at: 0)?.title == "Created")

        log.append(deleted(try ref(2)))
        #expect(log.badge(at: 0)?.glyph == "−")
        #expect(log.badge(at: 0)?.title == "Deleted")
        #expect(log.badge(at: 0)?.kind == .deleted)
    }

    @Test func saysWhichWayARowCrossedTheFilter() throws {
        var log = TrackingLog()
        log.append(updated(try ref(1), transition: .entered))
        let badge = try #require(log.badge(at: 0))
        #expect(badge.transition == .entered)
        #expect(badge.spoken.contains("entered the filter"))
        #expect(TrackingLog.glyph(for: .entered) == "↘")
        #expect(TrackingLog.glyph(for: .left) == "↗")
        #expect(TrackingLog.word(for: .left) == "left the filter")
    }

    @Test func saysHowManyCommitsOneLineStandsFor() throws {
        var log = TrackingLog()
        log.append(ChangeBatch(kind: .commit, events: [updated(try ref(1))], coalescedCommits: 4))
        let badge = try #require(log.badge(at: 0))
        #expect(badge.detail?.contains("4 commits") == true)
        #expect(badge.spoken.contains("4 commits"))
    }

    @Test func namesTheRelationshipsThatMovedAndNotTheObjectsInThem() throws {
        let tags = LinkChange(
            kind: .added, relationship: "tags", source: RowID(entity: "Person", pk: 1),
            destination: RowID(entity: "Tag", pk: 9))
        let untagged = LinkChange(
            kind: .removed, relationship: "tags", source: RowID(entity: "Person", pk: 1),
            destination: RowID(entity: "Tag", pk: 8))
        let moved = LinkChange(
            kind: .reordered, relationship: "projects", source: RowID(entity: "Person", pk: 1),
            destination: RowID(entity: "Project", pk: 2), order: 1)

        #expect(TrackingLog.linkSummary([]) == nil)
        #expect(
            TrackingLog.linkSummary([tags, untagged, moved])
                == "tags: 1 added, 1 removed · projects: 1 moved")

        var log = TrackingLog()
        log.append(updated(try ref(1), links: [tags]))
        #expect(log.badge(at: 0)?.detail == "tags: 1 added")
    }

    // MARK: Values, strong and dim (TRK-2)

    @Test func picksOutTheFieldsAChangeTouchedAndDimsTheRest() async throws {
        let name = try await column("name")
        let age = try await column("age")
        var log = TrackingLog()
        log.append(updated(try ref(1), from: ("Ada", 36), to: ("Ada", 37), changed: ["age"]))

        #expect(try cell(log, line: 0, age) == TrackingCell(value: GridValue(text: "37"), weight: .strong))
        #expect(try cell(log, line: 0, name).weight == .dim)
        // Drawn, and therefore also said.
        #expect(try cell(log, line: 0, age).spoken(column: "age") == "changed to 37")
        #expect(try cell(log, line: 0, name).spoken(column: "name") == "Ada, unchanged")
    }

    @Test func anUnknownPriorValueMakesNoFieldStandOut() async throws {
        let name = try await column("name")
        let age = try await column("age")
        var log = TrackingLog()
        log.append(
            ChangeEvent(object: try ref(1), kind: .updated, after: values("Ada", 37), changedKeys: nil))

        // Nothing is strong and nothing is dim: that the row changed is already said by the line itself.
        #expect(try cell(log, line: 0, age).weight == .normal)
        #expect(try cell(log, line: 0, name).weight == .normal)
        #expect(try cell(log, line: 0, name).spoken(column: "name") == "Ada")
    }

    @Test func everythingAnInsertCarriesIsNewAndEverythingADeleteCarriesIsGone() async throws {
        let name = try await column("name")
        var log = TrackingLog()
        log.append(inserted(try ref(1)))
        #expect(try cell(log, line: 0, name).weight == .strong)

        log.append(deleted(try ref(2)))
        // A delete has no "after"; what is shown is the last thing anybody read of the row.
        #expect(try cell(log, line: 0, name) == TrackingCell(value: GridValue(text: "Ada"), weight: .dim))
    }

    @Test func saysThatAValueWasNeverReadRatherThanShowingItBlank() async throws {
        let salary = try await column("salary")
        var log = TrackingLog()
        log.append(inserted(try ref(1)))

        // The event was read with name and age only, so the salary column has nothing to say about this row.
        let unread = try cell(log, line: 0, salary)
        #expect(unread.value.emphasis == .absent)
        #expect(unread.value.text.isEmpty)
        #expect(unread.value.accessibleText == "Not known")
    }

    @Test func showsTheObjectIDAndTheEntityWithoutFetchingAnything() async throws {
        let id = try await column(ColumnLayout.objectIDColumn)
        let entity = try await column(ColumnLayout.entityColumn)
        var log = TrackingLog()
        let ada = try ref(1)
        log.append(inserted(ada))

        #expect(try cell(log, line: 0, id).value.text == "1")
        #expect(try cell(log, line: 0, id).value.tooltip == ada.uri.absoluteString)
        #expect(try cell(log, line: 0, entity).value.text == "Person")
    }

    @Test func timesTheChangeInTheProjectsOwnTimeZone() throws {
        var log = TrackingLog()
        log.append(
            ChangeEvent(object: try ref(1), kind: .inserted, at: Date(timeIntervalSince1970: 3_600)))
        let noticed = try cell(log, line: 0, .when)
        #expect(noticed.value.text == "1:00:00")
        // The pointer gives the day as well: a log left running overnight is read the next morning.
        #expect(noticed.value.tooltip?.contains("1:00:00") == true)
        #expect(noticed.value.tooltip?.contains("1970") == true)
        #expect(noticed.weight == .normal)
    }

    @Test func aCopiedLineCarriesTheWordsTheChangeColumnDraws() throws {
        var log = TrackingLog()
        log.append(updated(try ref(1), changed: ["age"]))
        #expect(try cell(log, line: 0, .change).value.text == "Updated · 1 fields")
    }

    @Test func readsNothingOffTheEndOfTheLog() throws {
        var log = TrackingLog()
        log.append(inserted(try ref(1)))
        #expect(log.line(at: 7) == nil)
        #expect(log.entry(at: 7) == nil)
        #expect(log.version(at: 7) == nil)
        #expect(log.badge(at: 7) == nil)
        #expect(log.cell(at: 7, column: .when, timeZone: .gmt) == nil)
        // The object's own row is not a version row.
        #expect(log.version(at: 0) == nil)
    }

    // MARK: Columns

    @Test func showsTheLogsOwnTwoColumnsAndThenTheEntitysAsTheGridLaysThemOut() async throws {
        let model = try await TestProject.model(of: .company)
        let person = try #require(model.entity(named: "Person"))
        var layout = EntityLayout()
        layout.columns = [
            ColumnLayout(property: "name", width: 200, isHidden: false),
            ColumnLayout(property: "age", width: nil, isHidden: true),
        ]
        let columns = TrackingColumn.columns(for: person, in: model, layout: layout)

        #expect(
            columns.prefix(3).map(\.property) == [TrackingColumn.changeProperty, TrackingColumn.whenProperty, "name"])
        #expect(columns[0].title == "Change")
        #expect(columns[1].isTrailing)
        #expect(columns[2].width == 200)
        // A column the user hid in the grid is one they said they did not want to see.
        #expect(columns.map(\.property).contains("age"))
        #expect(!columns.visible.map(\.property).contains("age"))
        #expect(
            columns.visible.prefix(2).map(\.property)
                == [TrackingColumn.changeProperty, TrackingColumn.whenProperty])

        // The tracker materialises whole objects, so a subentity's fields are there whether the grid read them
        // or not.
        #expect(TrackingColumn.storedProperties(of: person, in: model).properties.contains("salary"))
    }
}
