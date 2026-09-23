import AppKit
import DabbiKit
import FixtureKit
import Foundation
import Testing

@testable import CoreDataDabbi

/// When the basic fixture's rows are dated from (`FixtureKit`'s epoch): row *i* is *i* days and a half-second
/// per day after it.
private let epoch = Date(timeIntervalSince1970: 1_704_067_200)

/// Fetch-request templates as the project runs them (BRW-1): the basic fixture's model has one,
/// `RecentSamples` — `dateValue > $SINCE AND boolValue == YES`, newest first.
@MainActor
@Suite struct FetchRequestContextTests {
    private func recentSamples(in context: ProjectContext) throws -> FetchTemplatePlan {
        try #require(context.fetchRequestPlans.first { $0.name == "RecentSamples" })
    }

    private func rowCount(of context: ProjectContext) async throws -> Int {
        let location = try #require(context.navigation.current)
        let session = try #require(context.session)
        let layout = context.layout(at: location)
        return try await session.count(FetchSpec(entity: location.entity, predicate: layout.filter, sort: layout.sort))
    }

    @Test func theModelsTemplatesAreReadWithTheirVariables() async throws {
        let context = try await TestProject.context(on: .basic)
        let plan = try recentSamples(in: context)
        #expect(plan.isRunnable)
        #expect(plan.entity == "Sample")
        #expect(plan.variables == [FetchTemplateVariable(name: "SINCE", keyPath: "dateValue", kind: .date)])
        context.shutDown()
    }

    @Test func runningOneShowsItsEntityThroughIt() async throws {
        let context = try await TestProject.context(on: .basic)
        let plan = try recentSamples(in: context)
        let since = epoch.addingTimeInterval(20 * 86_400)
        try context.run(fetchRequest: plan, values: ["SINCE": .date(since)])

        let run = try #require(context.shownFetchRequest)
        #expect(run.name == "RecentSamples")
        #expect(context.navigation.current?.entity == "Sample")
        #expect(context.shownLayout.filter?.format.contains("$SINCE") == false)
        #expect(context.shownLayout.sort == [SortKey(keyPath: "dateValue", ascending: false)])
        // Even rows from the twentieth on, less the ones left sparse: 20, 22, 26, 28, 30, 32, 36, 38.
        #expect(try await rowCount(of: context) == 8)
        #expect(context.lastValues(forFetchRequest: "RecentSamples") == ["SINCE": .date(since)])
        // Running it is going somewhere, not changing the project.
        #expect(context.layout(of: "Sample") == EntityLayout())

        context.goBack()
        #expect(context.shownFetchRequest == nil)
        #expect(try await rowCount(of: context) == 40)
        context.shutDown()
    }

    @Test func aValueOfTheWrongKindIsRefusedAndNothingMoves() async throws {
        let context = try await TestProject.context(on: .basic)
        let before = context.navigation.current
        #expect(throws: DabbiError.self) {
            try context.run(fetchRequest: try recentSamples(in: context), values: ["SINCE": .string("last week")])
        }
        #expect(context.navigation.current == before)
        context.shutDown()
    }

    @Test func changesWhileARunIsShownAreTheRunsOrTheEntitys() async throws {
        let context = try await TestProject.context(on: .basic)
        let changes = Changes()
        context.onChange = { changes.all.append($0) }
        try context.run(fetchRequest: try recentSamples(in: context), values: ["SINCE": .date(epoch)])

        // Its sort and filter are the run's: the entity keeps its own, and the project is not edited.
        context.updateShownLayout { $0.sort = [SortKey(keyPath: "name")] }
        context.setShownFilter(PredicateSource(format: "boolValue == YES"))
        #expect(context.shownFetchRequest?.sort == [SortKey(keyPath: "name")])
        #expect(context.shownFetchRequest?.filter == PredicateSource(format: "boolValue == YES"))
        #expect(context.layout(of: "Sample").sort.isEmpty)
        #expect(context.layout(of: "Sample").filter == nil)
        #expect(!changes.all.contains { if case .project = $0 { true } else { false } })

        // Its columns are the entity's.
        context.updateShownLayout { $0.columns = [ColumnLayout(property: "name", width: 200)] }
        #expect(context.layout(of: "Sample").columns == [ColumnLayout(property: "name", width: 200)])
        context.shutDown()
    }

    @Test func aRunCanBeKeptAsASavedPredicate() async throws {
        let context = try await TestProject.context(on: .basic)
        let since = epoch.addingTimeInterval(20 * 86_400)
        try context.run(fetchRequest: try recentSamples(in: context), values: ["SINCE": .date(since)])
        let filter = context.shownLayout.filter
        #expect(context.canSavePredicate)

        let saved = try #require(context.saveShownPredicate())
        #expect(saved.name == "RecentSamples")
        #expect(saved.entity == "Sample")
        #expect(saved.predicate == filter)
        #expect(saved.sort == [SortKey(keyPath: "dateValue", ascending: false)])
        #expect(context.navigation.current == BrowseLocation(entity: "Sample", savedPredicate: saved.id))
        #expect(try await rowCount(of: context) == 8)
        context.shutDown()
    }

    final class Changes {
        var all: [ProjectContext.Change] = []
    }
}

@MainActor
@Suite struct FetchRequestPromptModelTests {
    private let plan = FetchTemplatePlan(
        template: FetchRequestTemplate(
            name: "Find", entity: "Sample",
            predicateFormat: "name BEGINSWITH $PREFIX AND int16Value IN $SIZES AND dateValue > $SINCE"),
        model: {
            let model = NSManagedObjectModel()
            let sample = NSEntityDescription()
            sample.name = "Sample"
            sample.properties = [
                ("name", NSAttributeType.stringAttributeType), ("int16Value", .integer16AttributeType),
                ("dateValue", .dateAttributeType),
            ].map { name, type in
                let attribute = NSAttributeDescription()
                attribute.name = name
                attribute.attributeType = type
                return attribute
            }
            model.entities = [sample]
            return ModelDescription(model)
        }())

    @Test func itStartsFromTheLastRunsValuesWhereTheyStillFit() {
        let today = Date(timeIntervalSince1970: 1_790_121_600)
        let model = FetchRequestPromptModel(
            plan: plan, previous: ["PREFIX": .string("sam"), "SIZES": .string("not a list")], today: today)
        #expect(model.texts["PREFIX"] == "sam")
        #expect(model.texts["SIZES"] == "", "a value it cannot take is not offered again")
        #expect(model.picked["SINCE"] == .date(today))
        #expect(model.values == nil)
        #expect(model.problem == "$SIZES needs a comma-separated list of a whole number.")
    }

    @Test func itHasValuesOnceEveryFieldHoldsOne() {
        var model = FetchRequestPromptModel(plan: plan, previous: [:])
        model.setText("s", for: "PREFIX")
        model.setText("25, 50", for: "SIZES")
        model.pick(.date(epoch), for: "SINCE")
        #expect(model.problem == nil)
        #expect(
            model.values == ["PREFIX": .string("s"), "SIZES": .array([.int(25), .int(50)]), "SINCE": .date(epoch)])

        let again = FetchRequestPromptModel(plan: plan, previous: model.values ?? [:])
        #expect(again.texts["SIZES"] == "25, 50")
        #expect(again.values == model.values)
    }
}

@MainActor
@Suite struct FetchRequestWindowTests {
    private func window() async throws -> (ProjectDocument, NSWindow) {
        let document = try ProjectDocument(type: ProjectPackage.typeIdentifier)
        document.context.workingCopiesDirectory = try AppFixtures.scratchFolder("copies")
        document.context.adoptStore(at: try AppFixtures.location(.basic).storeURL)
        document.makeWindowControllers()
        let window = try #require(document.windowControllers.first?.window)
        window.setFrame(NSRect(x: 0, y: 0, width: 1320, height: 820), display: false)
        window.orderFront(nil)
        await document.context.whenSettled()
        try await settle()
        return (document, window)
    }

    private func settle(_ grid: GridViewController? = nil) async throws {
        for _ in 0..<5 { await Task.yield() }
        await grid?.whenSettled()
        for _ in 0..<5 { await Task.yield() }
        try await Task.sleep(for: .milliseconds(50))
    }

    @Test func clickingATemplateAsksForItsVariablesAndShowsWhatItFetches() async throws {
        let (document, window) = try await window()
        let sidebar = try #require(window.firstController(of: SidebarViewController.self))
        let grid = try #require(window.firstController(of: GridViewController.self))
        let outline = sidebar.outlineView
        #expect(sidebar.rowTitles.contains("Fetch Requests"))

        let row = try #require(sidebar.rowTitles.firstIndex(of: "RecentSamples"))
        outline.selectRowIndexes([row], byExtendingSelection: false)
        try await settle()
        let prompt = try #require(sidebar.presentedViewControllers?.first as? FetchRequestPromptController)
        #expect(prompt.model.variables.map(\.name) == ["SINCE"])

        prompt.pick(.date(epoch.addingTimeInterval(20 * 86_400)), for: "SINCE")
        prompt.run(nil)
        try await settle(grid)

        #expect(sidebar.presentedViewControllers?.isEmpty ?? true)
        #expect(document.context.shownFetchRequest?.name == "RecentSamples")
        #expect(grid.tableView.numberOfRows == 8)
        #expect(window.subtitle == "RecentSamples")
        #expect(outline.selectedRow == row)
        document.close()
    }

    @Test func cancellingLeavesTheGridWhereItWas() async throws {
        let (document, window) = try await window()
        let sidebar = try #require(window.firstController(of: SidebarViewController.self))
        let outline = sidebar.outlineView
        let before = document.context.navigation.current
        let entityRow = outline.selectedRow

        outline.selectRowIndexes(
            [try #require(sidebar.rowTitles.firstIndex(of: "RecentSamples"))], byExtendingSelection: false)
        try await settle()
        let prompt = try #require(sidebar.presentedViewControllers?.first as? FetchRequestPromptController)
        prompt.cancel(nil)
        try await settle()

        #expect(document.context.navigation.current == before)
        #expect(outline.selectedRow == entityRow)
        document.close()
    }
}
