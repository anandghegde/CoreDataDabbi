import AppKit
import DabbiKit
import FixtureKit
import Foundation
import Testing

@testable import CoreDataDabbi

/// Data › Import from the window (IMX-2 – IMX-4): the file's columns mapped by name, a dry run that stages
/// nothing, and an import that is one undoable edit. Parsing, coercion and staging are the engine's, and tested
/// there.
@MainActor
@Suite(.serialized) struct ImportSheetTests {
    private func settle(_ document: ProjectDocument) async {
        await document.context.whenSettled()
        for _ in 0..<5 { await Task.yield() }
        try? await Task.sleep(for: .milliseconds(50))
        await document.context.whenSettled()
    }

    /// A window on a copy of the basic store, which shows its samples; read-only until the test says otherwise.
    private func window() async throws -> (ProjectDocument, ProjectWindowController, NSWindow) {
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
        let grid = try #require(window.firstController(of: GridViewController.self))
        await grid.whenSettled()
        return (document, controller, window)
    }

    private func file(_ name: String, _ text: String) throws -> URL {
        let url = try AppFixtures.scratchFolder("import").appendingPathComponent(name)
        try text.write(to: url, atomically: true, encoding: .utf8)
        return url
    }

    private func sheet(of window: NSWindow) -> ImportSheetController? {
        window.contentViewController?.presentedViewControllers?.compactMap { $0 as? ImportSheetController }.first
    }

    private let importItem = NSMenuItem(
        title: "", action: #selector(ProjectWindowController.importFile(_:)), keyEquivalent: "")

    @Test func importsAFileAsOneEditAfterADryRun() async throws {
        let (document, controller, window) = try await window()
        let editing = document.context.editing
        // A read-only store takes no import.
        #expect(!controller.validateMenuItem(importItem))
        document.context.setAccessMode(.editable)
        await settle(document)
        #expect(controller.validateMenuItem(importItem))

        let url = try file(
            "Samples.csv",
            "name,int16Value,uuidValue,note\nImported,12,\(UUID().uuidString),x\nBad,twelve,\(UUID().uuidString),y\n")
        controller.showImport(of: url)
        let model = try #require(sheet(of: window)?.model)
        #expect(model.entity.name == "Sample")
        #expect(
            model.mapping.columns.map(\.target) == [
                .attribute(["name"]), .attribute(["int16Value"]), .attribute(["uuidValue"]), .ignored,
            ])
        #expect(model.preview(ofColumn: 0) == ("Imported", true))
        #expect(model.preview(ofColumn: 3).text == "—")

        // A dry run reports every row and stages nothing.
        model.dryRun()
        await model.work?.value
        let report = try #require(model.report)
        #expect(report.rows.map(\.outcome) == [.inserted, .failed])
        #expect(report.rows[1].issues.map(\.property) == ["int16Value"])
        #expect(model.summary?.contains("Failed: 1") == true)
        #expect(model.reportNote != nil)
        #expect(!editing.hasChanges && !editing.undoManager.canUndo)
        try await WindowSnapshot.write(try #require(window.attachedSheet), named: "import-sheet")
        try await WindowSnapshot.write(
            try #require(window.attachedSheet), named: "import-sheet-dark", appearance: .darkAqua)

        // All or nothing, with a row that fails: nothing, and the sheet stays to say why.
        model.importRows()
        await model.work?.value
        await settle(document)
        #expect(model.report?.isApplied == false)
        #expect(sheet(of: window) != nil)
        #expect(!editing.hasChanges)

        // Changing the options drops the stale report; skipping the row that fails imports the other.
        model.mode = .skipInvalid
        #expect(model.report == nil)
        model.importRows()
        await model.work?.value
        await settle(document)
        #expect(sheet(of: window) == nil)
        #expect(editing.changes.count(of: .inserted) == 1)
        #expect(editing.undoManager.undoActionName == "Import Sample")

        editing.undoManager.undo()
        await settle(document)
        #expect(!editing.hasChanges)
        document.close()
    }

    @Test func aFileThatCannotBeReadIsExplained() async throws {
        let (document, controller, window) = try await window()
        document.context.setAccessMode(.editable)
        await settle(document)
        controller.showImport(of: try file("Broken.csv", "name\n\"never closed"))
        #expect(sheet(of: window) == nil)
        let alert = try #require(window.attachedSheet)
        window.endSheet(alert)
        controller.showImport(of: try file("Empty.json", "[]"))
        #expect(sheet(of: window) == nil)
        if let alert = window.attachedSheet { window.endSheet(alert) }
        document.close()
    }

    @Test func columnsCanBeRemappedByHand() async throws {
        let (document, controller, window) = try await window()
        document.context.setAccessMode(.editable)
        await settle(document)
        controller.showImport(of: try file("Renamed.json", #"[{"title": "From JSON", "count": 3}]"#))
        let model = try #require(sheet(of: window)?.model)
        #expect(model.mapping.columns.map(\.target) == [.ignored, .ignored])
        #expect(!model.canRun)
        model.setTarget(.attribute(["name"]), ofColumn: 0)
        model.setTarget(.attribute(["int16Value"]), ofColumn: 1)
        #expect(model.canRun)
        #expect(model.preview(ofColumn: 1) == ("3", true))
        model.setTarget(.attribute(["int16Value"]), ofColumn: 0)
        #expect(model.preview(ofColumn: 0) == ("This is not a whole number.", false))

        #expect(ImportSheetModel.name(of: .ignored) == "Do Not Import")
        #expect(ImportSheetModel.name(of: .relationshipKey("tags", key: "label")) == "tags by label")
        #expect(ImportSheetModel.name(of: .id) == "$id")
        model.cancel()
        await settle(document)
        #expect(sheet(of: window) == nil)
        document.close()
    }

    @Test func theDataMenuOffersImport() throws {
        let data = try #require(MainMenu.make().items.first { $0.submenu?.title == "Data" }?.submenu)
        #expect(data.items.contains { $0.action == #selector(ProjectWindowController.importFile(_:)) })
    }
}
