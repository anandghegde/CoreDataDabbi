import AppKit
import DabbiKit
import FixtureKit
import Foundation
import Testing

@testable import CoreDataDabbi

/// The quick filter (PRD-6) over the basic fixture's forty `Sample`s. Their strings are `name` (`sample-<i>`, or
/// `sparse-<i>` for every fifth row, whose other attributes are unset) and `stringValue`, which cycles through
/// six values — `"naïve café"` among them — and the URL of each row mentions `dabbi`, which is not a string.
@MainActor
@Suite struct QuickFilterContextTests {
    private func rowCount(of context: ProjectContext) async throws -> Int {
        let location = try #require(context.navigation.current)
        let session = try #require(context.session)
        return try await session.count(FetchSpec(entity: location.entity, predicate: context.fetchFilter(at: location)))
    }

    @Test func aTermIsLookedForInEveryStringAttribute() async throws {
        let context = try await TestProject.context(on: .basic)
        #expect(context.shownQuickFilter?.keyPaths == ["name", "stringValue"])

        context.setQuickFilter("CAFE")
        // "naïve café" is every sixth row from the third, less the sparse ones: 2, 8, 20, 26, 32, 38.
        #expect(try await rowCount(of: context) == 6)
        context.setQuickFilter("sparse")
        #expect(try await rowCount(of: context) == 8)
        context.setQuickFilter("example.org")
        #expect(try await rowCount(of: context) == 0, "a URL is not text to search")
        context.setQuickFilter("  ")
        #expect(context.shownFetchFilter == nil)
        #expect(try await rowCount(of: context) == 40)
        context.shutDown()
    }

    @Test func itNarrowsTheFilterWithoutEditingIt() async throws {
        let context = try await TestProject.context(on: .basic)
        let changes = Changes()
        context.onChange = { changes.all.append($0) }
        context.setShownFilter(PredicateSource(format: "int16Value > 500"))
        changes.all.removeAll()

        context.setQuickFilter("café")
        #expect(try await rowCount(of: context) == 3, "26, 32 and 38")
        #expect(context.shownLayout.filter == PredicateSource(format: "int16Value > 500"))
        #expect(context.layout(of: "Sample").filter == PredicateSource(format: "int16Value > 500"))
        #expect(changes.all.isEmpty, "a search is not something the project keeps")
        context.shutDown()
    }

    @Test func aSearchBelongsToItsPlace() async throws {
        let context = try await TestProject.context(on: .basic)
        context.setQuickFilter("sparse")
        let saved = try #require(context.saveShownPredicate())
        #expect(context.navigation.current?.quickFilter == "", "somewhere new starts with nothing searched")
        #expect(saved.predicate == nil, "the search is not kept with the predicate")

        context.goBack()
        #expect(context.navigation.current?.quickFilter == "sparse")
        #expect(try await rowCount(of: context) == 8)
        context.goForward()
        #expect(try await rowCount(of: context) == 40)
        context.shutDown()
    }

    final class Changes {
        var all: [ProjectContext.Change] = []
    }
}

@MainActor
@Suite struct QuickFilterWindowTests {
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

    private func search(_ term: String, in bar: PredicateBarViewController) {
        bar.searchField.stringValue = term
        bar.searchField.sendAction(bar.searchField.action, to: bar.searchField.target)
    }

    @Test func commandFSearchesTheRowsAndEscapeGoesBackToThem() async throws {
        let (document, window) = try await window()
        let controller = try #require(window.windowController as? ProjectWindowController)
        let bar = try #require(window.firstController(of: PredicateBarViewController.self))
        let grid = try #require(window.firstController(of: GridViewController.self))
        #expect(grid.tableView.numberOfRows == 40)
        #expect(bar.searchField.isEnabled)
        #expect(bar.searchField.accessibilityLabel() == String(localized: "Search Rows"))

        controller.focusQuickFilter(nil)
        let editor = try #require(window.firstResponder as? NSTextView)
        #expect(editor.delegate === bar.searchField)

        search("sample-1", in: bar)
        try await settle(grid)
        // sample-1, and sample-10 to sample-18 but for the sparse 14.
        #expect(grid.tableView.numberOfRows == 9)
        #expect(bar.field.stringValue.isEmpty, "the predicate field still says what the filter is")

        let escape = #selector(NSResponder.cancelOperation(_:))
        #expect(bar.control(bar.searchField, textView: editor, doCommandBy: escape))
        try await settle(grid)
        #expect(bar.searchField.stringValue.isEmpty)
        #expect(grid.tableView.numberOfRows == 40)

        #expect(bar.control(bar.searchField, textView: editor, doCommandBy: escape))
        #expect(window.firstResponder === grid.tableView)
        document.close()
    }

    @Test func goingBackBringsTheSearchBackIntoTheField() async throws {
        let (document, window) = try await window()
        let bar = try #require(window.firstController(of: PredicateBarViewController.self))
        let grid = try #require(window.firstController(of: GridViewController.self))
        search("café", in: bar)
        try await settle(grid)
        #expect(grid.tableView.numberOfRows == 6)

        document.context.select(entity: "Sample")
        try await settle(grid)
        #expect(bar.searchField.stringValue.isEmpty)
        #expect(grid.tableView.numberOfRows == 40)

        document.context.goBack()
        try await settle(grid)
        #expect(bar.searchField.stringValue == "café")
        #expect(grid.tableView.numberOfRows == 6)
        document.close()
    }

    @Test func trackingIsScopedByTheSearch() async throws {
        let (document, window) = try await window()
        let controller = try #require(window.windowController as? ProjectWindowController)
        let bar = try #require(window.firstController(of: PredicateBarViewController.self))
        let context = document.context
        controller.toggleTracking(nil)
        await context.tracking.whenSettled()
        #expect(context.tracking.filter == nil)

        search("sparse", in: bar)
        try await settle()
        await context.tracking.whenSettled()
        #expect(context.tracking.isRunning)
        #expect(context.tracking.filter == context.shownFetchFilter)
        #expect(context.tracking.filter?.format.contains("sparse") == true)
        context.tracking.stop()
        document.close()
    }
}
