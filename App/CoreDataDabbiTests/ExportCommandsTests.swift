import AppKit
import DabbiKit
import FixtureKit
import Foundation
import Testing

@testable import CoreDataDabbi

/// Export and Copy As from the window (IMX-1, BRW-12, TRK-5): which rows, which columns, and what reaches the
/// file or the pasteboard. The formats themselves are the engine's, and tested there.
@MainActor
@Suite(.serialized) struct ExportCommandsTests {
    private func window(showing fixture: Fixture) async throws -> (ProjectDocument, NSWindow, GridViewController) {
        let document = try ProjectDocument(type: ProjectPackage.typeIdentifier)
        document.context.workingCopiesDirectory = try AppFixtures.scratchFolder("copies")
        document.context.adoptStore(at: try AppFixtures.location(fixture).storeURL)
        document.makeWindowControllers()
        let window = try #require(document.windowControllers.first?.window)
        window.setFrame(NSRect(x: 0, y: 0, width: 1320, height: 820), display: false)
        window.orderFront(nil)
        await document.context.whenSettled()
        for _ in 0..<5 { await Task.yield() }
        try await Task.sleep(for: .milliseconds(50))
        let grid = try #require(window.firstController(of: GridViewController.self))
        await grid.whenSettled()
        for _ in 0..<5 { await Task.yield() }
        return (document, window, grid)
    }

    private func controller(of document: ProjectDocument) throws -> ProjectWindowController {
        try #require(document.windowControllers.first as? ProjectWindowController)
    }

    private func menuItem(_ action: Selector, _ represented: String? = nil) -> NSMenuItem {
        let item = NSMenuItem(title: "", action: action, keyEquivalent: "")
        item.representedObject = represented
        return item
    }

    // MARK: What is read

    @Test func readsTheSelectionTheViewOrTheWholeEntity() async throws {
        let (document, _, grid) = try await window(showing: .company)
        let context = document.context
        #expect(ExportCommands.source(for: .selection, context: context, selection: []) == nil)

        grid.tableView.selectRowIndexes([2, 0], byExtendingSelection: false)
        let picked = grid.selectedObjects
        #expect(picked.count == 2)
        #expect(
            ExportCommands.source(for: .selection, context: context, selection: picked)
                == .objects(picked, entity: "Department"))

        // The view is the grid's fetch: its filter and sort. The whole entity has neither.
        context.updateShownLayout { $0.sort = [SortKey(keyPath: "name", ascending: false)] }
        guard case .fetch(let view) = ExportCommands.source(for: .view, context: context, selection: picked) else {
            Issue.record("the view is a fetch")
            return
        }
        #expect(view.entity == "Department")
        #expect(view.sort == [SortKey(keyPath: "name", ascending: false)])
        #expect(
            ExportCommands.source(for: .entity, context: context, selection: [])
                == .fetch(FetchSpec(entity: "Department")))
        document.close()
    }

    @Test func writesTheGridsColumnsInTheGridsOrder() async throws {
        let (document, _, grid) = try await window(showing: .company)
        // The grid shows the object ID, then name, employees, head, organisation.
        #expect(ExportCommands.properties(of: grid.columns) == ["name", "employees", "head", "organisation"])
        let hidden = grid.columns.map { column in
            var column = column
            if column.property == "employees" { column.isHidden = true }
            return column
        }
        #expect(ExportCommands.properties(of: hidden) == ["name", "head", "organisation"])

        let settings = ExportSettings(relationships: .counts, includesBinaryData: false)
        let view = ExportCommands.options(for: .view, settings: settings, columns: hidden)
        #expect(view.properties == ["name", "head", "organisation"])
        #expect(view.relationships == .counts)
        #expect(!view.includesBinaryData)
        #expect(ExportCommands.options(for: .entity, settings: settings, columns: hidden).properties == nil)
        document.close()
    }

    @Test func exportsTheCurrentViewToAFile() async throws {
        let (document, _, grid) = try await window(showing: .company)
        let context = document.context
        let session = try #require(context.session)
        context.updateShownLayout { $0.sort = [SortKey(keyPath: "name", ascending: true)] }
        let source = try #require(ExportCommands.source(for: .view, context: context, selection: []))
        let settings = ExportSettings(separator: .semicolon, relationships: .omitted)
        let reader = ExportReader(
            session: session, options: ExportCommands.options(for: .view, settings: settings, columns: grid.columns))
        let url = try AppFixtures.scratchFolder("export").appendingPathComponent("Department.csv")
        let count = try await reader.write(
            source, as: settings.exporter(for: .csv, timeZone: context.timeZone), to: url)
        #expect(count == 4)
        let lines = try String(contentsOf: url, encoding: .utf8).components(separatedBy: "\r\n")
        #expect(lines[0] == "$id;$entity;name")
        #expect(
            lines.dropFirst().prefix(4).map { $0.split(separator: ";").last.map(String.init) } == [
                "Department 0", "Department 1", "Department 2", "Department 3",
            ])
        document.close()
    }

    @Test func namesTheFileAfterTheEntity() {
        #expect(ExportCommands.fileName(entity: "Person", scope: .entity, format: .json) == "Person.json")
        #expect(ExportCommands.fileName(entity: "Person", scope: .selection, format: .csv) == "Person Selection.csv")
    }

    @Test func offersEmbeddingOnlyForJSON() {
        #expect(!ExportSettings.relationshipChoices(for: .csv).contains(.embedded(depth: 1)))
        #expect(ExportSettings.relationshipChoices(for: .json).contains(.embedded(depth: 2)))
        let accessory = ExportAccessory(format: .json, relationships: true)
        accessory.select(relationships: .embedded(depth: 2))
        #expect(accessory.settings.relationships == .embedded(depth: 2))
        let csv = ExportAccessory(format: .csv, relationships: true)
        csv.select(separator: .tab)
        #expect(csv.settings.separator == .tab)
        #expect(csv.settings.includesHeader)
    }

    @Test func showsTheOptionsUnderTheSavePanel() async throws {
        let accessory = ExportAccessory(format: .csv, relationships: true)
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 480, height: 150), styleMask: [.titled], backing: .buffered,
            defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = accessory.view
        window.orderFront(nil)
        try await WindowSnapshot.write(window, named: "export-options")
        try await WindowSnapshot.write(window, named: "export-options-dark", appearance: .darkAqua)
        window.close()
    }

    // MARK: Copy As (BRW-12)

    @Test func copiesTheSelectedRowsAsTextJSONAndMarkdown() async throws {
        let (document, _, grid) = try await window(showing: .company)
        let session = try #require(document.context.session)
        grid.tableView.selectRowIndexes([0, 1], byExtendingSelection: false)
        let picked = grid.selectedObjects
        let first = try await session.object(picked[0])["name"].map { ValueText.text(for: $0) }

        let tsv = try await ExportCommands.copyText(
            .tsv, of: picked, entity: "Department", columns: grid.columns, session: session, timeZone: .gmt)
        let lines = tsv.split(separator: "\n").map(String.init)
        #expect(lines.first == "$id\t$entity\tname\temployees\thead\torganisation")
        #expect(lines.count == 3)
        #expect(lines[1].hasPrefix(picked[0].uri.absoluteString + "\tDepartment\t" + (first ?? "")))

        let json = try await ExportCommands.copyText(
            .json, of: picked, entity: "Department", columns: grid.columns, session: session, timeZone: .gmt)
        let items = try #require(try JSONSerialization.jsonObject(with: Data(json.utf8)) as? [[String: Any]])
        #expect(items.map { $0["$id"] as? String } == picked.map(\.uri.absoluteString))
        // A to-many is copied as the grid shows it: a count.
        #expect((items[0]["employees"] as? [String: Any])?["$count"] != nil)

        let markdown = try await ExportCommands.copyText(
            .markdown, of: picked, entity: "Department", columns: grid.columns, session: session, timeZone: .gmt)
        #expect(markdown.hasPrefix("| $id | $entity | name |"))
        #expect(markdown.split(separator: "\n").count == 4)
        document.close()
    }

    @Test func copiesObjectURIsFromTheWindow() async throws {
        let (document, window, grid) = try await window(showing: .company)
        let controller = try controller(of: document)
        #expect(controller.validateMenuItem(menuItem(#selector(ProjectWindowController.copyObjectURI(_:)))) == false)

        grid.tableView.selectRowIndexes([1, 3], byExtendingSelection: false)
        let picked = grid.selectedObjects
        #expect(controller.validateMenuItem(menuItem(#selector(ProjectWindowController.copyObjectURI(_:)))))
        controller.copyObjectURI(nil)
        #expect(
            NSPasteboard.general.string(forType: .string) == picked.map(\.uri.absoluteString).joined(separator: "\n"))

        controller.copyRowsAs(menuItem(#selector(ProjectWindowController.copyRowsAs(_:)), CopyFormat.tsv.rawValue))
        for _ in 0..<50 where NSPasteboard.general.string(forType: .string)?.hasPrefix("$id") != true {
            try await Task.sleep(for: .milliseconds(20))
        }
        #expect(NSPasteboard.general.string(forType: .string)?.hasPrefix("$id\t$entity\tname") == true)
        _ = window
        document.close()
    }

    @Test func enablesEachExportWhenThereIsSomethingToWrite() async throws {
        let (document, _, grid) = try await window(showing: .company)
        let controller = try controller(of: document)
        let menu = MainMenu.make()
        let data = try #require(menu.items.first { $0.submenu?.title == "Data" }?.submenu)
        let export = try #require(data.items.first { $0.submenu?.title == "Export" }?.submenu)
        let items = export.items.filter { !$0.isSeparatorItem }
        #expect(items.count == 8)
        func enabled() -> [String] {
            items.filter { controller.validateMenuItem($0) }.compactMap { $0.representedObject as? String }
        }
        // Nothing is selected and nothing tracked: the view and the entity.
        #expect(enabled() == ["view.csv", "view.json", "entity.csv", "entity.json"])
        grid.tableView.selectRowIndexes([0], byExtendingSelection: false)
        #expect(enabled() == ["selection.csv", "selection.json", "view.csv", "view.json", "entity.csv", "entity.json"])

        let edit = try #require(menu.items.first { $0.submenu?.title == "Edit" }?.submenu)
        let copyAs = try #require(edit.items.first { $0.submenu?.title == "Copy As" }?.submenu)
        #expect(copyAs.items.compactMap { $0.representedObject as? String } == ["tsv", "json", "markdown"])
        #expect(copyAs.items.allSatisfy { controller.validateMenuItem($0) })
        document.close()
    }

    // MARK: Tracked session (TRK-5)

    @Test func exportsTheTrackedSessionOldestFirst() async throws {
        var log = TrackingLog()
        let ada = try #require(ObjectRef(storeUUID: "F1D0", entity: "Person", pk: 1))
        let grace = try #require(ObjectRef(storeUUID: "F1D0", entity: "Person", pk: 2))
        let columns = ColumnSet(["name"])
        func values(_ name: String, _ ref: ObjectRef) -> ObjectSnapshot {
            ObjectSnapshot(row: RowSnapshot(ref: ref, values: [.string(name)]), columns: columns, generation: 1)
        }
        log.append(
            ChangeEvent(object: ada, kind: .inserted, after: values("Ada", ada), at: .init(timeIntervalSince1970: 0)))
        log.append(
            ChangeEvent(
                object: grace, kind: .inserted, after: values("Grace", grace), at: .init(timeIntervalSince1970: 1)))
        log.append(
            ChangeEvent(
                object: ada, kind: .updated, before: values("Ada", ada), after: values("Ada L", ada),
                changedKeys: ["name"], at: .init(timeIntervalSince1970: 2)))

        let export = ExportCommands.trackedSession(log)
        let text = try await export.text(as: JSONExporter())
        let items = try #require(try JSONSerialization.jsonObject(with: Data(text.utf8)) as? [[String: Any]])
        #expect(items.map { $0["sequence"] as? Int } == [1, 2, 3])
        #expect(items.map { $0["kind"] as? String } == ["inserted", "inserted", "updated"])
        #expect((items[2]["after"] as? [String: Any])?["name"] as? String == "Ada L")
    }
}
