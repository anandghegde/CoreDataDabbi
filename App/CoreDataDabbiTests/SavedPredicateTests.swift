import AppKit
import DabbiKit
import FixtureKit
import Foundation
import Testing

@testable import CoreDataDabbi

/// Saved predicates as the project holds them (PRD-3, PRD-5, BRW-3): what saving takes, where later changes go,
/// and what the predicate bar makes of it. The sidebar and the menu commands are the window's (below).
@MainActor
@Suite struct SavedPredicateContextTests {
    private func context() async throws -> (ProjectContext, Changes) {
        let context = try await TestProject.context(on: .company)
        let changes = Changes()
        context.onChange = { changes.all.append($0) }
        return (context, changes)
    }

    final class Changes {
        var all: [ProjectContext.Change] = []
    }

    @Test func savingTakesTheEntitysFilterColumnsAndSortAndLeavesTheEntityUnfiltered() async throws {
        let (context, changes) = try await context()
        let filter = PredicateSource(format: #"name BEGINSWITH "Department""#)
        context.updateLayout(of: "Department") {
            $0.filter = filter
            $0.sort = [SortKey(keyPath: "name", ascending: false)]
            $0.columns = [ColumnLayout(property: "name", width: 180)]
        }
        #expect(context.canSavePredicate)

        let saved = try #require(context.saveShownPredicate())
        #expect(saved.name == #"name BEGINSWITH "Department""#)
        #expect(saved.entity == "Department")
        #expect(saved.predicate == filter)
        #expect(saved.sort == [SortKey(keyPath: "name", ascending: false)])
        #expect(saved.columns == [ColumnLayout(property: "name", width: 180)])
        #expect(context.package.predicates == [saved])
        // The rows the user filtered their way to are the predicate's now; the entity has all of them again.
        #expect(context.layout(of: "Department").filter == nil)
        #expect(context.layout(of: "Department").sort == [SortKey(keyPath: "name", ascending: false)])
        #expect(context.navigation.current == BrowseLocation(entity: "Department", savedPredicate: saved.id))
        #expect(context.shownPredicate == saved)
        #expect(context.shownLayout.filter == filter)
        // A new predicate is a change to the project, worth asking about on closing.
        #expect(changes.all.contains { if case .project = $0 { true } else { false } })
        // There is no saving a saved predicate as itself.
        #expect(!context.canSavePredicate)
        context.shutDown()
    }

    @Test func aPredicateWithNoConditionIsNamedAfterItsEntity() async throws {
        let (context, _) = try await context()
        let first = try #require(context.saveShownPredicate())
        #expect(first.name == "Department")
        #expect(first.predicate == nil)
        context.select(entity: "Department")
        let second = try #require(context.saveShownPredicate())
        #expect(second.name == "Department 2")
        context.shutDown()
    }

    @Test func changesWhileAPredicateIsShownAreThePredicatesOwn() async throws {
        let (context, changes) = try await context()
        context.setFilter(PredicateSource(format: "name != nil"), of: "Department")
        let saved = try #require(context.saveShownPredicate())
        changes.all = []

        context.updateShownLayout { $0.sort = [SortKey(keyPath: "name", ascending: true)] }
        #expect(context.savedPredicate(saved.id)?.sort == [SortKey(keyPath: "name", ascending: true)])
        #expect(context.layout(of: "Department").sort.isEmpty)
        // How it is looked at is saved along, like an entity's layout, and not asked about.
        #expect(changes.all.allSatisfy { if case .layout = $0 { true } else { false } })

        changes.all = []
        context.setShownFilter(PredicateSource(format: #"name == "Department 1""#))
        #expect(context.savedPredicate(saved.id)?.predicate?.format == #"name == "Department 1""#)
        #expect(context.layout(of: "Department").filter == nil)
        // What it filters by is what it is: that is an edit.
        #expect(changes.all.contains { if case .project = $0 { true } else { false } })
        context.shutDown()
    }

    @Test func duplicatesRenamesAndDeletes() async throws {
        let (context, _) = try await context()
        context.setFilter(PredicateSource(format: "name != nil"), of: "Department")
        let saved = try #require(context.saveShownPredicate())

        let copy = try #require(context.duplicate(savedPredicate: saved.id))
        #expect(copy.id != saved.id)
        #expect(copy.name == "name != nil 2")
        #expect(copy.predicate == saved.predicate)
        #expect(context.navigation.current?.savedPredicate == copy.id)

        // A taken name gets a number; an empty one is not a name.
        context.rename(savedPredicate: copy.id, to: "  Named  ")
        #expect(context.savedPredicate(copy.id)?.name == "Named")
        context.rename(savedPredicate: saved.id, to: "named")
        #expect(context.savedPredicate(saved.id)?.name == "named 2")
        context.rename(savedPredicate: saved.id, to: "   ")
        #expect(context.savedPredicate(saved.id)?.name == "named 2")
        #expect(context.savedPredicates.map(\.name) == ["Named", "named 2"])

        // Deleting the one on screen leaves its entity there, unfiltered by it.
        context.delete(savedPredicate: copy.id)
        #expect(context.savedPredicate(copy.id) == nil)
        #expect(context.navigation.current == BrowseLocation(entity: "Department"))
        // Deleting another leaves the grid where it is.
        context.show(savedPredicate: saved.id)
        context.delete(savedPredicate: UUID())
        #expect(context.navigation.current?.savedPredicate == saved.id)
        context.shutDown()
    }

    @Test func revertingToAVersionWithoutTheShownPredicateShowsItsEntity() async throws {
        let (context, _) = try await context()
        let before = context.package
        let saved = try #require(context.saveShownPredicate())
        #expect(context.navigation.current?.savedPredicate == saved.id)
        context.replace(before)
        #expect(context.navigation.current == BrowseLocation(entity: "Department"))
        #expect(context.shownPredicate == nil)
        context.shutDown()
    }

    @Test func saysWhatTheModelNoLongerHas() async throws {
        let (context, _) = try await context()
        let fine = SavedPredicate(name: "Fine", entity: "Department", predicate: PredicateSource(format: "name != nil"))
        let stale = SavedPredicate(
            name: "Stale", entity: "Department", predicate: PredicateSource(format: "budget > 3"),
            sort: [SortKey(keyPath: "founded", ascending: true)])
        let gone = SavedPredicate(name: "Gone", entity: "Project", predicate: nil)
        #expect(context.check(fine).isUsable)
        #expect(context.check(stale).missingKeyPaths == ["budget", "founded"])
        #expect(!context.check(stale).isMissingEntity)
        #expect(context.check(gone).isMissingEntity)
        context.shutDown()
    }

    @Test func thePredicateBarHoldsTheShownPredicatesText() async throws {
        let (context, _) = try await context()
        let bar = PredicateBarModel(context: context)
        context.setFilter(PredicateSource(format: "name != nil"), of: "Department")
        let saved = try #require(context.saveShownPredicate())
        bar.follow()
        #expect(bar.text == "name != nil")
        #expect(bar.savedPredicate == saved.id)

        // Applying writes to the predicate, not the entity.
        bar.text = #"name == "Department 2""#
        bar.apply()
        #expect(context.savedPredicate(saved.id)?.predicate?.format == #"name == "Department 2""#)
        #expect(context.layout(of: "Department").filter == nil)

        // The entity itself is unfiltered, and the field says so.
        context.select(entity: "Department")
        bar.follow()
        #expect(bar.text.isEmpty)
        #expect(bar.savedPredicate == nil)
        context.shutDown()
    }

    @Test func aNewPredicateStartsOnTheNameFieldWithNothingApplied() async throws {
        let (context, _) = try await context()
        let saved = try #require(context.saveShownPredicate())
        let bar = PredicateBarModel(context: context)
        bar.follow()
        #expect(bar.savedPredicate == saved.id)

        #expect(bar.startNewPredicate())
        // From a saved predicate, a new one starts from the entity's own rows.
        #expect(context.navigation.current == BrowseLocation(entity: "Department"))
        #expect(bar.text == #"name CONTAINS[cd] """#)
        #expect(bar.isShowingBuilder)
        #expect(!bar.isFiltering)
        guard case .rows = bar.builderContent else {
            Issue.record("expected rows, found \(String(describing: bar.builderContent))")
            context.shutDown()
            return
        }
        context.shutDown()
    }
}

/// The sidebar's section and the menu commands (PRD-3, PRD-5, BRW-1).
@MainActor
@Suite struct SavedPredicateWindowTests {
    private func window(with predicates: [SavedPredicate] = []) async throws -> (ProjectDocument, NSWindow) {
        let document = try ProjectDocument(type: ProjectPackage.typeIdentifier)
        document.context.workingCopiesDirectory = try AppFixtures.scratchFolder("copies")
        document.context.adoptStore(at: try AppFixtures.location(.company).storeURL)
        var package = document.context.package
        package.predicates = predicates
        document.context.replace(package)
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

    @Test func listsSavedPredicatesAfterTheModelsOwnAndBadgesTheOnesThatNoLongerFit() async throws {
        let fine = SavedPredicate(
            name: "Big departments", entity: "Department", predicate: PredicateSource(format: "employees.@count > 1"))
        let stale = SavedPredicate(
            name: "Old budget", entity: "Department", predicate: PredicateSource(format: "budget > 3"))
        let gone = SavedPredicate(name: "Projects", entity: "Project", predicate: nil)
        let (document, window) = try await window(with: [stale, gone, fine])
        let sidebar = try #require(window.firstController(of: SidebarViewController.self))
        let outline = sidebar.outlineView

        #expect(
            Array(sidebar.rowTitles.suffix(4)) == ["Saved Predicates", "Big departments", "Old budget", "Projects"])
        func cell(_ title: String) throws -> SidebarCellView {
            let row = try #require(sidebar.rowTitles.firstIndex(of: title))
            return try #require(outline.view(atColumn: 0, row: row, makeIfNecessary: true) as? SidebarCellView)
        }
        #expect(try cell("Big departments").warning.isHidden)
        let badge = try cell("Old budget").warning
        #expect(!badge.isHidden)
        #expect(badge.accessibilityLabel() == "Missing budget")
        #expect(badge.toolTip?.contains("budget") == true)
        #expect(try !cell("Projects").warning.isHidden)

        // One whose entity is gone has nothing to show; one that merely does not fit still opens, and the
        // predicate bar says what is wrong with it.
        let item = { (title: String) in outline.item(atRow: sidebar.rowTitles.firstIndex(of: title) ?? -1) as Any }
        #expect(!sidebar.outlineView(outline, shouldSelectItem: item("Projects")))
        #expect(sidebar.outlineView(outline, shouldSelectItem: item("Old budget")))
        document.close()
    }

    @Test func clickingOneShowsItsRowsAndItsName() async throws {
        let saved = SavedPredicate(
            name: "Department 2", entity: "Department", predicate: PredicateSource(format: #"name == "Department 2""#),
            columns: [ColumnLayout(property: "head", isHidden: true)])
        let (document, window) = try await window(with: [saved])
        let sidebar = try #require(window.firstController(of: SidebarViewController.self))
        let grid = try #require(window.firstController(of: GridViewController.self))
        let bar = try #require(window.firstController(of: PredicateBarViewController.self))
        let outline = sidebar.outlineView

        let row = try #require(sidebar.rowTitles.firstIndex(of: "Department 2"))
        outline.selectRowIndexes([row], byExtendingSelection: false)
        try await settle(grid)

        #expect(document.context.navigation.current?.savedPredicate == saved.id)
        #expect(window.subtitle == "Department 2")
        #expect(grid.tableView.numberOfRows == 1)
        // Its own columns: the one it hides is not there, though the entity shows it.
        #expect(!grid.tableView.tableColumns.contains { $0.identifier.rawValue == "head" })
        #expect(bar.field.stringValue == #"name == "Department 2""#)

        // Back to the entity: all of its rows and all of its columns.
        let entityRow = try #require(sidebar.rowTitles.firstIndex(of: "Department"))
        outline.selectRowIndexes([entityRow], byExtendingSelection: false)
        try await settle(grid)
        #expect(document.context.navigation.current == BrowseLocation(entity: "Department"))
        #expect(grid.tableView.numberOfRows == 4)
        #expect(grid.tableView.tableColumns.contains { $0.identifier.rawValue == "head" })
        #expect(bar.field.stringValue.isEmpty)
        #expect(window.subtitle == "Department")
        document.close()
    }

    @Test func savingPutsTheNewPredicatesNameIntoEditing() async throws {
        let (document, window) = try await window()
        let controller = try #require(document.windowControllers.first as? ProjectWindowController)
        let sidebar = try #require(window.firstController(of: SidebarViewController.self))
        let grid = try #require(window.firstController(of: GridViewController.self))
        document.context.setFilter(PredicateSource(format: #"name == "Department 1""#), of: "Department")
        try await settle(grid)

        let item = NSMenuItem(
            title: "", action: #selector(ProjectWindowController.savePredicate(_:)), keyEquivalent: "")
        #expect(controller.validateMenuItem(item))
        controller.savePredicate(nil)
        try await settle(grid)

        let saved = try #require(document.context.savedPredicates.first)
        #expect(saved.name == #"name == "Department 1""#)
        let row = try #require(sidebar.rowTitles.firstIndex(of: saved.name))
        #expect(sidebar.outlineView.selectedRow == row)
        let cell = try #require(
            sidebar.outlineView.view(atColumn: 0, row: row, makeIfNecessary: false) as? SidebarCellView)
        #expect(cell.isEditingName)
        cell.commitEditing(as: "First department")
        try await settle(grid)

        #expect(document.context.savedPredicate(saved.id)?.name == "First department")
        #expect(sidebar.rowTitles.contains("First department"))
        #expect(window.subtitle == "First department")
        #expect(grid.tableView.numberOfRows == 1)
        // Already saved: there is nothing to save again until the entity is shown.
        #expect(!controller.validateMenuItem(item))
        try await WindowSnapshot.write(window, named: "saved-predicate")
        document.close()
    }

    @Test func aNewPredicatePutsTheKeyboardInTheBuildersValue() async throws {
        let (document, window) = try await window()
        let controller = try #require(document.windowControllers.first as? ProjectWindowController)
        let bar = try #require(window.firstController(of: PredicateBarViewController.self))
        controller.newPredicate(nil)
        try await settle()

        #expect(bar.model.isShowingBuilder)
        #expect(bar.model.text == #"name CONTAINS[cd] """#)
        // Nothing is applied until there is a value to filter by.
        #expect(document.context.layout(of: "Department").filter == nil)
        let editor = bar.builder.editor
        let responder = window.firstResponder as? NSView
        // The field editor of the row's value field, which sits inside the field it edits.
        #expect(responder?.isDescendant(of: editor) == true)
        document.close()
    }
}
