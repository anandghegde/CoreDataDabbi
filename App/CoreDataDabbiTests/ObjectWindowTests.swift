import AppKit
import DabbiKit
import Foundation
import Testing

@testable import CoreDataDabbi

/// Inserted rows in the grid, the keyboard way into a cell, and detail windows (EDT-3, BRW-9).
@MainActor
@Suite struct ObjectWindowTests {
    @Test func anInsertedObjectIsListedSelectedAndDeletableBeforeItIsCommitted() async throws {
        let (document, controller, window) = try await openEditable()
        let grid = try #require(window.firstController(of: GridViewController.self))
        await grid.whenSettled()
        #expect(grid.tableView.numberOfRows == 40)

        document.context.insertObject()
        await settle(document)
        await grid.whenSettled()
        await settle(document)
        #expect(grid.tableView.numberOfRows == 41)
        let inserted = try #require(document.context.inspectedObject)
        #expect(inserted.isInserted)
        // The grid selects the row the inspector is showing.
        #expect(grid.selectedPendingObjects == [inserted])
        let row = grid.tableView.selectedRow
        let objectID = try #require(grid.columns.first { $0.property == ColumnLayout.objectIDColumn })
        #expect(grid.value(at: row, column: objectID)?.text == String(localized: "New"))

        // Deleting it is taking the insert back.
        window.makeFirstResponder(grid.tableView)
        let delete = NSMenuItem(
            title: "", action: #selector(ProjectWindowController.deleteObjects(_:)), keyEquivalent: "")
        #expect(controller.validateMenuItem(delete))
        controller.deleteObjects(nil)
        await settle(document)
        await grid.whenSettled()
        await settle(document)
        #expect(document.context.editing.changes.count(of: .inserted) == 0)
        #expect(grid.tableView.numberOfRows == 40)
        document.close()
    }

    @Test func returnOpensTheSelectedRowsCellEditor() async throws {
        let (document, _, window) = try await openEditable()
        let grid = try #require(window.firstController(of: GridViewController.self))
        await grid.whenSettled()
        // Nothing selected, nothing to edit.
        grid.tableView.deselectAll(nil)
        #expect(!grid.editSelectedCell())

        grid.tableView.selectRowIndexes([3], byExtendingSelection: false)
        await settle(document)
        window.makeFirstResponder(grid.tableView)
        let event = try #require(
            NSEvent.keyEvent(
                with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0,
                windowNumber: window.windowNumber, context: nil, characters: "\r",
                charactersIgnoringModifiers: "\r", isARepeat: false, keyCode: 36))
        grid.tableView.keyDown(with: event)
        let cell = try #require(grid.editedCell)
        cell.popover.close()

        // Two rows are not one cell.
        grid.tableView.selectRowIndexes([3, 4], byExtendingSelection: false)
        #expect(!grid.editSelectedCell())
        document.close()
    }

    @Test func aDetailWindowEditsItsObjectAndFollowsItThroughTheCommit() async throws {
        let (document, controller, window) = try await openEditable()
        let grid = try #require(window.firstController(of: GridViewController.self))
        await grid.whenSettled()
        grid.tableView.selectRowIndexes([0], byExtendingSelection: false)
        await settle(document)
        let open = NSMenuItem(
            title: "", action: #selector(ProjectWindowController.openObjectWindows(_:)), keyEquivalent: "")
        #expect(controller.validateMenuItem(open))
        let first = try #require(grid.selectedPendingObjects.first)

        controller.openObjectWindows(nil)
        controller.openObjectWindows(nil)
        // One window per object: asking again brings it forward.
        let windows = document.windowControllers.compactMap { $0 as? ObjectWindowController }
        try #require(windows.count == 1)
        let detail = windows[0]
        #expect(detail.object == first)
        #expect(detail.window?.undoManager === document.context.editing.undoManager)
        detail.window?.setFrame(NSRect(x: 0, y: 0, width: 760, height: 520), display: false)
        await detail.model.whenSettled()
        await settle(document)
        await detail.model.whenSettled()
        guard case .object(let shown, _) = detail.model.details.details else {
            Issue.record("the window did not read its object")
            return
        }
        #expect(shown == first)
        guard case .ready(let source, _) = detail.model.relationships.state else {
            Issue.record("the window did not read its object's relationships")
            return
        }
        #expect(PendingObjectID(source) == first)

        // Selecting another row leaves the window where it is.
        grid.tableView.selectRowIndexes([5], byExtendingSelection: false)
        await settle(document)
        #expect(detail.object == first)
        #expect(detail.model.details.focusedObject == first)

        document.context.editing.setValue(.string("From its own window"), for: "name", of: first)
        await settle(document)
        await detail.model.whenSettled()
        guard case .object(_, let staged) = detail.model.details.details else {
            Issue.record("the window lost its object")
            return
        }
        #expect(staged["name"] == .string("From its own window"))
        if let detailWindow = detail.window { try await WindowSnapshot.write(detailWindow, named: "object-window") }
        document.close()
    }

    @Test func aDetailWindowOfAnInsertedObjectFollowsItToItsReference() async throws {
        let (document, controller, window) = try await openEditable()
        let grid = try #require(window.firstController(of: GridViewController.self))
        await grid.whenSettled()
        document.context.insertObject()
        await settle(document)
        await grid.whenSettled()
        await settle(document)
        let inserted = try #require(document.context.inspectedObject)
        controller.openWindow(for: inserted)
        let detail = try #require(document.windowControllers.compactMap { $0 as? ObjectWindowController }.first)
        #expect(!detail.model.hasRelationships)
        #expect(detail.model.title == String(localized: "New \(inserted.entity)"))
        document.context.editing.setValue(.string("Brand new"), for: "name", of: inserted)
        await settle(document)

        controller.commitChanges(nil)
        await settle(document)
        await settle(document)
        let ref = try #require(detail.object.ref)
        #expect(ref.entity == inserted.entity)
        #expect(detail.model.hasRelationships)
        #expect(detail.model.relationships.source == ref)
        await detail.model.whenSettled()
        guard case .object(_, let staged) = detail.model.details.details else {
            Issue.record("the window lost its object")
            return
        }
        #expect(staged["name"] == .string("Brand new"))
        document.close()
    }

    // MARK: -

    private func openEditable() async throws -> (ProjectDocument, ProjectWindowController, NSWindow) {
        let folder = try AppFixtures.scratchFolder()
        let store = try ProjectRepairTests.copyStore(to: folder)
        let document = try ProjectDocument(type: ProjectPackage.typeIdentifier)
        document.context.workingCopiesDirectory = try AppFixtures.scratchFolder("copies")
        document.context.backupsDirectory = folder.appendingPathComponent("Backups", isDirectory: true)
        document.context.simulators = nil
        document.context.adoptStore(at: store)
        document.makeWindowControllers()
        let controller = try #require(document.windowControllers.first as? ProjectWindowController)
        let window = try #require(controller.window)
        window.setFrame(NSRect(x: 0, y: 0, width: 1320, height: 820), display: false)
        window.orderFront(nil)
        await settle(document)
        document.context.setAccessMode(.editable)
        await settle(document)
        return (document, controller, window)
    }

    private func settle(_ document: ProjectDocument) async {
        await document.context.whenSettled()
        for _ in 0..<5 { await Task.yield() }
        try? await Task.sleep(for: .milliseconds(50))
        await document.context.whenSettled()
    }
}
