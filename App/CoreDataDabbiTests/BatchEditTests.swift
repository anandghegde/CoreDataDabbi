import AppKit
import DabbiKit
import FixtureKit
import Foundation
import SwiftUI
import Testing

@testable import CoreDataDabbi

/// Batch edits from the Data menu (EDT-4), a binary field's file commands (EDT-6), a composite's elements as
/// fields (EDT-7), and deleting from the change log (TRK-6).
@MainActor
@Suite struct BatchEditTests {
    private let stringValue = "stringValue"

    // MARK: Batch edits (EDT-4)

    @Test func batchUpdateSetsTheSelectedRowsAsOneEdit() async throws {
        let (document, controller, window) = try await open()
        let grid = try #require(window.firstController(of: GridViewController.self))
        await grid.whenSettled()
        grid.tableView.selectRowIndexes([0, 1, 2], byExtendingSelection: false)
        await settle(document)
        #expect(controller.validateMenuItem(item(#selector(ProjectWindowController.batchUpdate(_:)))))

        controller.batchUpdate(nil)
        let model = try sheetModel(controller)
        #expect(model.kind == .set)
        #expect(model.scope == .selection)
        // Only what can be typed: no binary, transformable or object ID attributes.
        let names = Set(model.attributes.map(\.name))
        #expect(names.contains("int16Value") && names.contains("dateValue") && names.contains(stringValue))
        #expect(!names.contains("dataValue") && !names.contains("colour"))

        model.attribute = "int32Value"
        model.text = "not a number"
        await model.updatePreview()
        #expect(model.problem != nil)
        #expect(!model.canApply)

        model.attribute = stringValue
        model.text = "batch"
        await model.updatePreview()
        let preview = try #require(model.preview)
        #expect(preview.matched == 3)
        #expect(preview.changing == 3)
        #expect(!preview.samples.isEmpty)
        #expect(preview.samples.allSatisfy { $0.after == .string("batch") })
        // A preview stages nothing.
        #expect(document.context.editing.changes.isEmpty)

        model.apply()
        await settle(document)
        #expect(controller.batchEditSheet == nil)
        #expect(document.context.editing.changes.count(of: .updated) == 3)
        #expect(window.undoManager?.undoActionName == "Batch Update \(stringValue)")
        window.undoManager?.undo()
        await settle(document)
        #expect(document.context.editing.changes.isEmpty)
        document.close()
    }

    @Test func findAndReplaceAndNullifyWorkOnEveryRowShown() async throws {
        let (document, controller, window) = try await open()
        let grid = try #require(window.firstController(of: GridViewController.self))
        await grid.whenSettled()
        grid.tableView.deselectAll(nil)
        await settle(document)

        controller.findAndReplace(nil)
        let replace = try sheetModel(controller)
        #expect(replace.scope == .all)
        #expect(replace.attributes.allSatisfy { $0.type == .string })
        replace.attribute = stringValue
        replace.isRegularExpression = true
        replace.find = "("
        await replace.updatePreview()
        #expect(replace.problem != nil, "a pattern that does not compile says so")
        replace.find = "^.*$"
        replace.replacement = "x"
        await replace.updatePreview()
        let preview = try #require(replace.preview)
        #expect(preview.matched == 40)
        // The 8 sparse rows have no text to replace in.
        #expect(preview.changing == 32)
        replace.apply()
        await settle(document)
        #expect(document.context.editing.changes.count(of: .updated) == 32)

        controller.nullifyAttributes(nil)
        let nullify = try sheetModel(controller)
        #expect(nullify.attributes.allSatisfy { $0.isOptional })
        nullify.attribute = stringValue
        await nullify.updatePreview()
        #expect(nullify.preview?.changing == 32)
        #expect(nullify.preview?.samples.first?.before == .string("x"), "the preview sees what is staged")
        nullify.cancel()
        #expect(controller.batchEditSheet == nil)
        #expect(window.undoManager?.undoActionName == "Replace in \(stringValue)")
        document.close()
    }

    // MARK: Binary data (EDT-6)

    @Test func aBinaryFieldIsReplacedFromAFileSavedToOneAndCleared() async throws {
        let (document, _, _) = try await open(editable: false)
        let context = document.context
        let session = try #require(context.session)
        let refs = try await session.references(FetchSpec(entity: "Sample", sort: [SortKey(keyPath: "name")]), limit: 1)
        let object = PendingObjectID(try #require(refs.first))
        let value = try await session.stagedObject(object)["dataValue"] ?? .null
        #expect(!value.isNull)

        // Read-only: the bytes can be saved, not changed.
        let readOnly = try #require(context.binaryEditing("dataValue", value: value, of: object))
        #expect(readOnly.save != nil)
        #expect(readOnly.replace == nil && readOnly.clear == nil)
        #expect(context.binaryEditing(stringValue, value: .string("s"), of: object) == nil)

        context.setAccessMode(.editable)
        await settle(document)
        let editable = try #require(context.binaryEditing("dataValue", value: value, of: object))
        #expect(editable.replace != nil && editable.clear != nil)

        let folder = try AppFixtures.scratchFolder("binary")
        let source = folder.appendingPathComponent("in.bin")
        let bytes = Data((0..<2_000).map { UInt8($0 % 251) })
        try bytes.write(to: source)
        context.editing.replaceData(of: "dataValue", of: object, from: source)
        await settle(document)
        #expect(context.editing.changes.count(of: .updated) == 1)
        let saved = folder.appendingPathComponent("out.bin")
        try await context.saveData("dataValue", of: object, to: saved)
        #expect(try Data(contentsOf: saved) == bytes)

        context.editing.clearData(of: "dataValue", of: object)
        await settle(document)
        // Unlocking opened the store again.
        let editableSession = try #require(context.session)
        #expect(try await editableSession.stagedObject(object)["dataValue"] == .null)
        #expect(context.editing.undoManager.undoActionName == "Clear dataValue")
        document.close()
    }

    // MARK: Composites (EDT-7)

    @Test func aCompositesElementsAreFieldsOfTheirOwn() async throws {
        let folder = try AppFixtures.scratchFolder("composites")
        let location = try FixtureBuilder.build(.composites, in: folder)
        let (document, _, _) = try await open(store: location.storeURL)
        let context = document.context
        let session = try #require(context.session)
        let refs = try await session.references(FetchSpec(entity: "Place"), limit: 1)
        let object = PendingObjectID(try #require(refs.first))
        let value = try await session.stagedObject(object)["address"] ?? .null

        let fields = context.compositeFields("address", value: value, of: object)
        #expect(
            fields.map(\.path) == [
                "address.street", "address.city", "address.location", "address.location.latitude",
                "address.location.longitude",
            ])
        #expect(fields.map(\.depth) == [1, 1, 1, 2, 2])
        #expect(context.compositeFields("name", value: .string("x"), of: object).isEmpty)
        let location1 = try #require(fields.first { $0.path == "address.location" })
        #expect(context.fieldEditing(location1, of: object) == nil, "a nested composite is edited by its elements")

        let city = try #require(fields.first { $0.path == "address.city" })
        let editing = try #require(context.fieldEditing(city, of: object))
        let latitude = try #require(fields.first { $0.path == "address.location.latitude" })
        #expect(context.fieldEditing(latitude, of: object)?.stage("north") != nil)
        #expect(editing.stage("Lisbon") == nil)
        await settle(document)
        #expect(context.fieldEditing(latitude, of: object)?.stage("38.7") == nil)
        await settle(document)
        guard case .composite(let address) = try await session.stagedObject(object)["address"] else {
            Issue.record("the address is no longer a composite")
            return
        }
        #expect(address["city"] == .string("Lisbon"))
        if case .composite(let place)? = address["location"] {
            #expect(place["latitude"] == .double(38.7))
        } else {
            Issue.record("the location is no longer a composite")
        }
        #expect(context.editing.undoManager.undoActionName == "Edit address.location.latitude")
        document.close()
    }

    // MARK: Deleting while tracking (TRK-6)

    @Test func rowsOfTheChangeLogCanBeDeleted() async throws {
        let (document, controller, window) = try await open()
        let context = document.context
        context.tracking.options.watcher.debounce = .milliseconds(20)
        context.tracking.options.watcher.folderLatency = 0.1
        context.tracking.options.watcher.pollInterval = .milliseconds(200)
        let grid = try #require(window.firstController(of: GridViewController.self))
        await grid.whenSettled()
        controller.toggleTracking(nil)
        await context.tracking.whenSettled()
        #expect(context.tracking.isShowingLog)
        // The batch menu is the grid's; the log is not where rows are chosen for it.
        #expect(!controller.validateMenuItem(item(#selector(ProjectWindowController.batchUpdate(_:)))))

        let session = try #require(context.session)
        let refs = try await session.references(FetchSpec(entity: "Sample", sort: [SortKey(keyPath: "name")]), limit: 1)
        let object = PendingObjectID(try #require(refs.first))
        context.editing.setValue(.string("Tracked"), for: stringValue, of: object)
        await settle(document)
        controller.commitChanges(nil)
        await settle(document)
        #expect(await TrackingSessionTests.wait { !context.tracking.log.isEmpty })

        let tracking = try #require(window.firstController(of: TrackingViewController.self))
        tracking.tableView.selectRowIndexes([0], byExtendingSelection: false)
        #expect(tracking.selectedObjects == refs)
        window.makeFirstResponder(tracking.tableView)
        #expect(controller.validateMenuItem(item(#selector(ProjectWindowController.deleteObjects(_:)))))
        controller.deleteObjects(nil)
        await settle(document)
        #expect(context.editing.changes.count(of: .deleted) == 1)
        #expect(context.tracking.isRunning, "deleting does not stop the tracker")
        context.tracking.close()
        document.close()
    }

    // MARK: -

    private func item(_ action: Selector) -> NSMenuItem {
        NSMenuItem(title: "", action: action, keyEquivalent: "")
    }

    private func sheetModel(_ controller: ProjectWindowController) throws -> BatchEditModel {
        let sheet = try #require(controller.batchEditSheet as? NSHostingController<BatchEditView>)
        return sheet.rootView.model
    }

    private func open(
        store: URL? = nil, editable: Bool = true
    ) async throws -> (ProjectDocument, ProjectWindowController, NSWindow) {
        let folder = try AppFixtures.scratchFolder()
        let store = try store ?? ProjectRepairTests.copyStore(to: folder)
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
        if editable {
            document.context.setAccessMode(.editable)
            await settle(document)
        }
        return (document, controller, window)
    }

    private func settle(_ document: ProjectDocument) async {
        await document.context.whenSettled()
        for _ in 0..<5 { await Task.yield() }
        try? await Task.sleep(for: .milliseconds(50))
        await document.context.whenSettled()
    }
}
