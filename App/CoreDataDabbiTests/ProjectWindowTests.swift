import AppKit
import DabbiKit
import FixtureKit
import Testing

@testable import CoreDataDabbi

@MainActor
@Suite struct ProjectWindowTests {
    private func window(showing fixture: Fixture?) async throws -> (ProjectDocument, NSWindow) {
        let document = try ProjectDocument(type: ProjectPackage.typeIdentifier)
        document.context.workingCopiesDirectory = try AppFixtures.scratchFolder("copies")
        if let fixture { document.context.adoptStore(at: try AppFixtures.location(fixture).storeURL) }
        document.makeWindowControllers()
        let window = try #require(document.windowControllers.first?.window)
        window.setFrame(NSRect(x: 0, y: 0, width: 1320, height: 820), display: false)
        window.orderFront(nil)
        await document.context.whenSettled()
        // Observation reaches the views a turn of the main actor later.
        for _ in 0..<5 { await Task.yield() }
        try await Task.sleep(for: .milliseconds(50))
        return (document, window)
    }

    @Test func showsAStore() async throws {
        let (document, window) = try await window(showing: .company)
        #expect(window.title == "Company.sqlite")
        #expect(window.subtitle == "Department")
        #expect(window.toolbar?.items.contains { $0.itemIdentifier.rawValue == "org.coredatadabbi.status" } == true)
        try await WindowSnapshot.write(window, named: "project-company")
        try await WindowSnapshot.write(window, named: "project-company-dark", appearance: .darkAqua)
        document.close()
    }

    @Test func saysWhatIsWrongInsteadOfShowingAnEmptyWindow() async throws {
        let (document, window) = try await window(showing: .encrypted)
        try await WindowSnapshot.write(window, named: "project-failed")
        document.close()
    }

    @Test func offersToChooseAStoreWhenTheProjectHasNone() async throws {
        let (document, window) = try await window(showing: nil)
        try await WindowSnapshot.write(window, named: "project-empty")
        document.close()
    }

    @Test func showsTheEntityTreeInTheSidebar() async throws {
        let (document, window) = try await window(showing: .company)
        let sidebar = try #require(window.firstController(of: SidebarViewController.self))
        // The sidebar is behind a vibrancy view, which a layer snapshot does not render; what it shows has to
        // be read off the outline view instead.
        let outline = sidebar.outlineView
        #expect(outline.numberOfRows == 8)  // "Entities" and the seven entities, all expanded.
        #expect(
            sidebar.rowTitles == [
                "Entities", "Department", "Party", "Organisation", "Person", "Employee",
                "Manager", "Tag",
            ])
        #expect(outline.level(forRow: 6) == 4)  // Manager, under Employee, Person, Party, Entities.

        // It starts on the first entity that has rows, and the grid agrees.
        #expect(outline.item(atRow: outline.selectedRow).flatMap { ($0 as? SidebarNode)?.title } == "Department")

        sidebar.filter(by: "man")
        #expect(sidebar.rowTitles == ["Entities", "Party", "Person", "Employee", "Manager"])
        sidebar.filter(by: "")
        #expect(outline.numberOfRows == 8)
        document.close()
    }

    @Test func fillsTheGridWithTheEntitysRows() async throws {
        let (document, window) = try await window(showing: .company)
        let grid = try #require(window.firstController(of: GridViewController.self))
        await grid.whenSettled()
        for _ in 0..<5 { await Task.yield() }

        // Department: four rows, its own attributes and its relationships.
        #expect(grid.tableView.numberOfRows == 4)
        #expect(grid.columns.map(\.property) == ["$objectID", "name", "employees", "head", "organisation"])
        #expect(grid.footer.state == .rows(count: 4, hasMore: false))

        // Without a sort the store hands rows over in object-ID order, which is not the order they were
        // written in; what matters is that every one of them is there, once, against its own object ID.
        let name = try #require(grid.columns.first { $0.property == "name" })
        let names = (0..<4).compactMap { grid.value(at: $0, column: name)?.text }
        #expect(Set(names) == ["Department 0", "Department 1", "Department 2", "Department 3"])
        let ids = (0..<4).compactMap { grid.value(at: $0, column: grid.columns[0])?.text }.compactMap(Int.init)
        #expect(ids == ids.sorted())
        let employees = try #require(grid.columns.first { $0.property == "employees" })
        #expect(grid.value(at: 0, column: employees)?.emphasis == .reference)

        try await WindowSnapshot.write(window, named: "grid-department")
        document.close()
    }

    @Test func followsTheSidebarToAnotherEntity() async throws {
        let (document, window) = try await window(showing: .company)
        let grid = try #require(window.firstController(of: GridViewController.self))
        await grid.whenSettled()

        document.context.select(entity: "Manager")
        for _ in 0..<5 { await Task.yield() }
        await grid.whenSettled()
        for _ in 0..<5 { await Task.yield() }

        #expect(grid.tableView.numberOfRows == 5)
        #expect(window.subtitle == "Manager")
        // Manager has no subentities, so nothing needs a column saying what each row is.
        #expect(!grid.columns.contains { $0.property == ColumnLayout.entityColumn })
        // Everything a Manager inherits is there to see.
        #expect(
            Set(grid.columns.map(\.property)).isSuperset(of: [
                "name", "createdAt", "email", "age", "title", "salary", "level",
            ]))

        try await WindowSnapshot.write(window, named: "grid-manager")
        document.close()
    }

    @Test func showsTheWholeInheritanceTreeUnderAnAbstractEntity() async throws {
        let (document, window) = try await window(showing: .company)
        let grid = try #require(window.firstController(of: GridViewController.self))
        await grid.whenSettled()

        document.context.select(entity: "Party")
        for _ in 0..<5 { await Task.yield() }
        await grid.whenSettled()
        for _ in 0..<5 { await Task.yield() }

        // 3 organisations + 35 people + 20 employees + 5 managers.
        #expect(grid.tableView.numberOfRows == 63)
        let entityColumn = try #require(grid.columns.first { $0.property == ColumnLayout.entityColumn })
        let kinds = Set((0..<grid.tableView.numberOfRows).compactMap { grid.value(at: $0, column: entityColumn)?.text })
        #expect(kinds == ["Organisation", "Person", "Employee", "Manager"])

        try await WindowSnapshot.write(window, named: "grid-party")
        document.close()
    }

    @Test func filtersTheGridFromThePredicateBar() async throws {
        let (document, window) = try await window(showing: .company)
        let controller = try #require(window.windowController as? ProjectWindowController)
        let grid = try #require(window.firstController(of: GridViewController.self))
        let bar = try #require(window.firstController(of: PredicateBarViewController.self))
        await grid.whenSettled()
        for _ in 0..<5 { await Task.yield() }
        #expect(grid.tableView.numberOfRows == 4)

        // ⌥⌘F puts the keyboard in the field from wherever the window is, once there is an entity to filter
        // (§8.3). The field edits through its own field editor, which is what makes completion work.
        let command = NSMenuItem(
            title: "", action: #selector(ProjectWindowController.focusFilter(_:)), keyEquivalent: "")
        #expect(controller.validateMenuItem(command))
        controller.focusFilter(nil)
        let editor = try #require(window.firstResponder as? PredicateFieldEditor)
        #expect(editor.delegate === bar.field)

        // What is typed is completed against the entity on screen, over the range the completer asked for and
        // not the one a field editor would guess at.
        editor.insertText("na", replacementRange: NSRange(location: 0, length: 0))
        #expect(bar.model.text == "na")
        #expect(editor.rangeForUserCompletion == NSRange(location: 0, length: 2))
        var index = 0
        let items = withUnsafeMutablePointer(to: &index) {
            bar.control(
                bar.field, textView: editor, completions: [], forPartialWordRange: editor.rangeForUserCompletion,
                indexOfSelectedItem: $0)
        }
        #expect(items == ["name"])
        #expect(index == -1)  // Nothing is picked until the user says so: Return applies the predicate.

        // Typing a predicate and pressing Return. Nothing here may be improved into something else: a curly
        // quote would change what the predicate says.
        let format = #"name == "Department 1""#
        editor.setSelectedRange(NSRange(location: 0, length: (editor.string as NSString).length))
        editor.insertText(format, replacementRange: editor.selectedRange())
        #expect(editor.string == format)
        #expect(bar.model.status == .valid([]))
        #expect(bar.control(bar.field, textView: editor, doCommandBy: #selector(NSResponder.insertNewline(_:))))

        for _ in 0..<5 { await Task.yield() }
        await grid.whenSettled()
        for _ in 0..<5 { await Task.yield() }
        #expect(grid.tableView.numberOfRows == 1)
        #expect(grid.footer.state == .rows(count: 1, hasMore: false))
        let name = try #require(grid.columns.first { $0.property == "name" })
        #expect(grid.value(at: 0, column: name)?.text == "Department 1")
        // The filter is the entity's, and is written down with its columns and its sort (§7.1, M2-04).
        #expect(document.context.layout(of: "Department").filter?.format == format)
        try await WindowSnapshot.write(window, named: "grid-filtered")

        // Escape with nothing to give up hands the keyboard back to the rows (§8.4).
        #expect(bar.control(bar.field, textView: editor, doCommandBy: #selector(NSResponder.cancelOperation(_:))))
        #expect(window.firstResponder === grid.tableView)

        bar.model.clear()
        for _ in 0..<5 { await Task.yield() }
        await grid.whenSettled()
        for _ in 0..<5 { await Task.yield() }
        #expect(grid.tableView.numberOfRows == 4)
        #expect(document.context.layout(of: "Department").filter == nil)
        document.close()
    }

    @Test func showsTheSelectedRowInTheInspector() async throws {
        let (document, window) = try await window(showing: .company)
        let grid = try #require(window.firstController(of: GridViewController.self))
        let inspector = try #require(window.firstController(of: InspectorViewController.self))
        await grid.whenSettled()
        for _ in 0..<5 { await Task.yield() }

        grid.tableView.selectRowIndexes([0], byExtendingSelection: false)
        let focus = try #require(document.context.navigation.current?.focus)
        #expect(focus.entity == "Department")

        // The hosted view starts the read; nothing in the app waits for it, so the test has to.
        let model = inspector.model
        for _ in 0..<10 {
            if case .object = model.details { break }
            try await Task.sleep(for: .milliseconds(20))
        }
        await model.whenSettled()
        guard case .object(let ref, let snapshot) = model.details else {
            Issue.record("the inspector did not read the selected row: \(model.details)")
            document.close()
            return
        }
        #expect(ref == focus)
        #expect(snapshot.columns.properties.contains("name"))
        #expect(snapshot["name"]?.displayString(timeZone: .gmt).hasPrefix("Department") == true)
        // A Department has a head and an organisation whether or not this one uses them.
        #expect(snapshot.columns.properties.contains("organisation"))
        document.close()
    }

    @Test func showsTheClickedCellInTheContentViewer() async throws {
        let (document, window) = try await window(showing: .basic)
        let grid = try #require(window.firstController(of: GridViewController.self))
        let content = try #require(window.firstController(of: ContentViewController.self))
        await grid.whenSettled()
        for _ in 0..<5 { await Task.yield() }

        // Every fifth row of the fixture leaves its optional attributes unset; this one has something in it.
        let name = try #require(grid.columns.first { $0.property == "name" })
        let row = try #require(
            (0..<grid.tableView.numberOfRows).first {
                grid.value(at: $0, column: name)?.text.hasPrefix("sample-") == true
            })
        grid.tableView.selectRowIndexes([row], byExtendingSelection: false)

        let column = grid.tableView.column(withIdentifier: NSUserInterfaceItemIdentifier("keywords"))
        #expect(column >= 0)
        grid.focus(onColumnAt: column)
        #expect(document.context.focusedProperty == "keywords")

        let model = content.model
        for _ in 0..<15 {
            if case .ready = model.state { break }
            try await Task.sleep(for: .milliseconds(20))
        }
        await model.whenSettled()
        guard case .ready(let field, let report) = model.state else {
            Issue.record("the content viewer read nothing: \(model.state)")
            document.close()
            return
        }
        #expect(field.property == "keywords")
        // A transformable written by Core Data's default transformer: an archive, read as a description.
        #expect(report.type == .keyedArchive)
        document.close()
    }

    @Test func readsTheTableWhenTheStructureTabIsAskedFor() async throws {
        let (document, window) = try await window(showing: .company)
        let inspector = try #require(window.firstController(of: InspectorViewController.self))
        let model = inspector.model
        model.tab = .structure
        for _ in 0..<10 where model.structure == nil { try await Task.sleep(for: .milliseconds(20)) }
        await model.whenSettled()

        let structure = try #require(model.structure, "the Structure tab read nothing")
        #expect(structure.entity == "Department")
        #expect(structure.table == "ZDEPARTMENT")
        #expect(structure.columns.map(\.name).contains("ZNAME"))
        #expect(model.structureError == nil)
        // The tab is part of the project's local state, so a reopened window lands where it was left.
        #expect(document.context.local.selection.inspectorTab == "structure")
        document.close()
    }

    @Test func followsARelationshipOutOfTheSelectedRow() async throws {
        let (document, window) = try await window(showing: .company)
        let grid = try #require(window.firstController(of: GridViewController.self))
        let panel = try #require(window.firstController(of: RelationshipsViewController.self))
        let inspector = try #require(window.firstController(of: InspectorViewController.self))
        await grid.whenSettled()
        for _ in 0..<5 { await Task.yield() }

        grid.tableView.selectRowIndexes([0], byExtendingSelection: false)
        let department = try #require(document.context.navigation.current?.focus)

        // The hosted view starts the read; nothing in the app waits for it, so the test has to.
        let model = panel.model
        for _ in 0..<15 {
            if model.related != nil { break }
            try await Task.sleep(for: .milliseconds(20))
        }
        await model.whenSettled()
        guard case .ready(let ref, let rows) = model.state else {
            Issue.record("the relationships panel read nothing: \(model.state)")
            document.close()
            return
        }
        #expect(ref == department)
        #expect(rows.map(\.id) == ["employees", "head", "organisation"])
        let related = try #require(model.related)
        #expect(related.relationship == "employees")
        let employee = try #require(related.items.first)

        // Nothing on the far side is picked yet, so there is nothing to reveal.
        #expect(!model.canReveal)

        // Picking one shows it in the inspector without moving the grid (REL-1).
        model.selectItem(employee.ref)
        for _ in 0..<15 {
            if case .object(let shown, _) = inspector.model.details, shown == employee.ref { break }
            try await Task.sleep(for: .milliseconds(20))
        }
        await inspector.model.whenSettled()
        guard case .object(let shown, _) = inspector.model.details else {
            Issue.record("the inspector did not follow the panel: \(inspector.model.details)")
            document.close()
            return
        }
        #expect(shown == employee.ref)
        #expect(grid.tableView.selectedRow == 0)
        #expect(document.context.navigation.current?.entity == "Department")

        // Revealing it is what moves the grid, and leaves a trail behind (REL-3). The menu item is the
        // keyboard's way to it, and it is live only while something is picked (§8.4).
        let controller = try #require(window.windowController as? ProjectWindowController)
        let reveal = NSMenuItem(
            title: "", action: #selector(ProjectWindowController.revealInEntity(_:)), keyEquivalent: "")
        #expect(model.canReveal)
        #expect(controller.validateMenuItem(reveal))
        controller.revealInEntity(nil)
        for _ in 0..<5 { await Task.yield() }
        await grid.whenSettled()
        for _ in 0..<5 { await Task.yield() }
        #expect(document.context.navigation.current?.entity == employee.ref.entity)
        #expect(window.subtitle == employee.ref.entity)
        #expect(document.context.navigation.current?.trail.count == 2)
        // The grid found the row it was sent to and highlighted it.
        #expect(grid.tableView.selectedRow >= 0)

        let browse = try #require(window.firstController(of: BrowseViewController.self))
        #expect(browse.breadcrumb.fittingSize.height > 0)
        try await WindowSnapshot.write(window, named: "relationships-employees")
        document.close()
    }

    @Test func sendsTheKeyboardToAPaneByName() async throws {
        let (document, window) = try await window(showing: .company)
        let controller = try #require(window.windowController as? ProjectWindowController)
        let grid = try #require(window.firstController(of: GridViewController.self))
        let sidebar = try #require(window.firstController(of: SidebarViewController.self))
        // The rows are what a project window is for, so that is where the keyboard starts (§8.4).
        #expect(window.initialFirstResponder === grid.tableView)

        // Asking for the entities means the list of them, not the filter field above it.
        #expect(controller.focus(pane: Pane.sidebar) === sidebar.outlineView)
        #expect(window.firstResponder === sidebar.outlineView)
        #expect(controller.focus(pane: Pane.rows) === grid.tableView)
        #expect(window.firstResponder === grid.tableView)

        // A pane that is shut is opened before the keyboard is sent there, or there would be nothing to send
        // it to.
        let centre = try #require(window.firstController(of: CentreSplitViewController.self))
        controller.toggleBottomPanel(nil)
        try await Task.sleep(for: .milliseconds(400))
        #expect(centre.item(for: Pane.bottom)?.isCollapsed == true)
        let content = try #require(window.firstController(of: ContentViewController.self))
        let inside = controller.focus(pane: Pane.content).map { ($0 as? NSView)?.isDescendant(of: content.view) }
        #expect(inside == true)
        #expect(centre.item(for: Pane.bottom)?.isCollapsed == false)

        // Every pane the menu offers can be reached, and nothing else can.
        for pane in Pane.focusable {
            #expect(controller.focus(pane: pane) != nil, "\(pane) took no keyboard")
        }
        #expect(controller.focus(pane: "no such pane") == nil)
        document.close()
    }

    @Test func remembersWhichPanesAreHidden() async throws {
        let (document, window) = try await window(showing: .basic)
        let controller = try #require(window.windowController as? ProjectWindowController)
        controller.toggleBottomPanel(nil)
        try await Task.sleep(for: .milliseconds(400))
        #expect(document.context.local.window.collapsedPanes.contains(Pane.bottom))
        #expect(!document.isDocumentEdited)
        document.close()
    }
}
