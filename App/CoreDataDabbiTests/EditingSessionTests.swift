import AppKit
import DabbiKit
import FixtureKit
import Foundation
import Testing

@testable import CoreDataDabbi

/// Staged edits in a window (EDT-8): the window's undo stack mirrors the session's, Commit backs up first and
/// writes, and nothing that would lose what is staged happens without asking.
@MainActor
@Suite struct EditingSessionTests {
    final class Recorder {
        var errors: [DabbiError] = []
        var asked = 0
    }

    private func editableContext(_ recorder: Recorder) async throws -> (ProjectContext, URL) {
        let folder = try AppFixtures.scratchFolder()
        let store = try ProjectRepairTests.copyStore(to: folder)
        var package = ProjectPackage()
        package.project.accessMode = .editable
        let context = ProjectContext(package: package)
        context.workingCopiesDirectory = try AppFixtures.scratchFolder("copies")
        context.backupsDirectory = folder.appendingPathComponent("Backups", isDirectory: true)
        context.simulators = nil
        context.adoptStore(at: store)
        context.editing.onError = { recorder.errors.append($0) }
        context.openStoreIfNeeded()
        await context.whenSettled()
        #expect(context.accessMode == .editable)
        #expect(context.editing.isEditable)
        return (context, folder)
    }

    private func samples(_ context: ProjectContext) async throws -> [ObjectRef] {
        try await #require(context.session).references(FetchSpec(entity: "Sample"), limit: 2)
    }

    private func firstSample(_ context: ProjectContext) async throws -> ObjectRef {
        try #require(try await samples(context).first)
    }

    @Test func theWindowsUndoStackFollowsTheSessions() async throws {
        let recorder = Recorder()
        let (context, _) = try await editableContext(recorder)
        let ref = try await firstSample(context)
        let object = PendingObjectID(ref)
        let session = try #require(context.session)
        let original = try await session.object(ref)["int32Value"]
        let undo = context.editing.undoManager

        context.editing.setValue(.int(7), for: "int32Value", of: object)
        context.editing.setValue(.int(8), for: "int32Value", of: object)
        await context.whenSettled()
        #expect(context.editing.changes.change(for: object)?.fields.first?.after == .int(8))
        #expect(undo.canUndo && undo.undoActionName == "Edit int32Value")

        undo.undo()
        await context.whenSettled()
        #expect(try await session.object(ref)["int32Value"] == .int(7))
        #expect(undo.canRedo && undo.redoActionName == "Edit int32Value")

        undo.undo()
        await context.whenSettled()
        #expect(!context.editing.hasChanges)
        #expect(!undo.canUndo)
        #expect(try await session.object(ref)["int32Value"] == original)

        undo.redo()
        undo.redo()
        await context.whenSettled()
        #expect(try await session.object(ref)["int32Value"] == .int(8))
        #expect(undo.canUndo && !undo.canRedo)
        #expect(recorder.errors.isEmpty)
        context.shutDown()
    }

    @Test func editsThatChangeNothingOrAreRefusedLeaveNothingToUndo() async throws {
        let recorder = Recorder()
        let (context, _) = try await editableContext(recorder)
        let ref = try await firstSample(context)
        let current = try #require(try await context.session?.object(ref)["name"])

        context.editing.setValue(current, for: "name", of: PendingObjectID(ref))
        context.editing.setValue(.string("not a number"), for: "int32Value", of: PendingObjectID(ref))
        await context.whenSettled()
        #expect(!context.editing.hasChanges)
        #expect(!context.editing.undoManager.canUndo)
        #expect(recorder.errors.map(\.code) == [.invalidValue])
        context.shutDown()
    }

    @Test func commitBacksUpWritesAndEmptiesTheUndoStack() async throws {
        let recorder = Recorder()
        let (context, folder) = try await editableContext(recorder)
        let refs = try await samples(context)
        let ref = refs[0]
        context.editing.setValue(.string("Committed"), for: "name", of: PendingObjectID(ref))
        context.editing.delete([PendingObjectID(refs[1])])
        await context.whenSettled()
        #expect(context.editing.changes.changes.count == 2)

        let committed = await context.editing.commit().value
        #expect(committed)
        #expect(!context.editing.hasChanges && !context.editing.undoManager.canUndo)
        #expect(context.editing.commits == 1)
        #expect(context.editing.lastCommit?.total == 2)
        #expect(try await context.session?.object(ref)["name"] == .string("Committed"))
        #expect(try await context.session?.count(FetchSpec(entity: "Sample")) == 39)

        // The backup is the store as it was before the commit.
        let backups = try FileManager.default.subpathsOfDirectory(atPath: folder.appending(path: "Backups").path)
        #expect(backups.contains { $0.hasSuffix(".sqlite") })
        #expect(recorder.errors.isEmpty)
        context.shutDown()
    }

    @Test func lockingWithPendingChangesAsksFirst() async throws {
        let recorder = Recorder()
        let (context, _) = try await editableContext(recorder)
        let ref = try await firstSample(context)
        var answer = LeavingChanges.cancel
        context.onLeavingChanges = { decide in
            recorder.asked += 1
            decide(answer)
        }
        context.editing.setValue(.string("Staged"), for: "name", of: PendingObjectID(ref))
        await context.whenSettled()

        context.toggleAccessMode()
        await context.whenSettled()
        #expect(recorder.asked == 1)
        #expect(context.accessMode == .editable, "Cancel leaves the store as it is")
        #expect(context.editing.hasChanges)

        answer = .commit
        context.toggleAccessMode()
        await context.whenSettled()
        // The commit finishes, then the store is reopened.
        await context.whenSettled()
        #expect(recorder.asked == 2)
        #expect(context.accessMode == .readOnly)
        #expect(!context.editing.isEditable && !context.editing.hasChanges)
        #expect(try await context.session?.object(ref)["name"] == .string("Staged"))
        context.shutDown()
    }

    @Test func discardingOnReloadLosesTheEditsAndNotTheStore() async throws {
        let recorder = Recorder()
        let (context, _) = try await editableContext(recorder)
        let ref = try await firstSample(context)
        let original = try await context.session?.object(ref)["name"]
        context.onLeavingChanges = { $0(.discard) }
        context.editing.setValue(.string("Thrown away"), for: "name", of: PendingObjectID(ref))
        await context.whenSettled()
        #expect(context.editing.hasChanges)

        context.reloadStore()
        await context.whenSettled()
        #expect(context.accessMode == .editable)
        #expect(!context.editing.hasChanges && !context.editing.undoManager.canUndo)
        #expect(try await context.session?.object(ref)["name"] == original)
        context.shutDown()
    }

    @Test func withNobodyToAskNothingIsLost() async throws {
        let recorder = Recorder()
        let (context, _) = try await editableContext(recorder)
        let ref = try await firstSample(context)
        context.editing.setValue(.string("Kept"), for: "name", of: PendingObjectID(ref))
        await context.whenSettled()

        context.setAccessMode(.readOnly)
        await context.whenSettled()
        #expect(context.accessMode == .editable)
        #expect(context.editing.hasChanges)
        context.shutDown()
    }

    @Test func aReadOnlyStoreHasNothingToEdit() async throws {
        let store = try ProjectRepairTests.copyStore(to: try AppFixtures.scratchFolder())
        let context = ProjectContext()
        context.workingCopiesDirectory = try AppFixtures.scratchFolder("copies")
        context.simulators = nil
        context.adoptStore(at: store)
        context.openStoreIfNeeded()
        await context.whenSettled()
        #expect(context.accessMode == .readOnly)
        #expect(!context.editing.isEditable)
        #expect(!context.editing.commit().isCancelled)
        #expect(await context.editing.commit().value == false)
        context.shutDown()
    }

    @Test func summarisesWhatIsStaged() {
        let object = PendingObjectID(uri: URL(string: "x-coredata:///Sample/t1")!, entity: "Sample")
        let changes = PendingChanges(changes: [
            PendingChange(object: object, kind: .inserted, label: nil, fields: []),
            PendingChange(
                object: PendingObjectID(uri: URL(string: "x-coredata://A/Sample/p1")!, entity: "Sample"),
                kind: .deleted, label: nil, fields: []),
            PendingChange(
                object: PendingObjectID(uri: URL(string: "x-coredata://A/Sample/p2")!, entity: "Sample"),
                kind: .deleted, label: nil, fields: []),
        ])
        #expect(PendingChangesView.summary(of: changes) == "1 new · 2 deleted")
        #expect(object.description == "Sample#new")
    }
}

/// The same, through the window: the grid, the Pending Changes panel and the Data menu.
@MainActor
@Suite struct EditingWindowTests {
    @Test func deletingRowsStagesThemListsThemAndCommitRemovesThem() async throws {
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
        #expect(document.context.accessMode == .editable)
        #expect(window.undoManager === document.context.editing.undoManager)

        let grid = try #require(window.firstController(of: GridViewController.self))
        await grid.whenSettled()
        #expect(grid.tableView.numberOfRows == 40)
        window.makeFirstResponder(grid.tableView)
        grid.tableView.selectRowIndexes([0, 1], byExtendingSelection: false)
        let delete = NSMenuItem(
            title: "", action: #selector(ProjectWindowController.deleteObjects(_:)), keyEquivalent: "")
        #expect(controller.validateMenuItem(delete))

        controller.deleteObjects(nil)
        await settle(document)
        await grid.whenSettled()
        #expect(document.context.editing.changes.count(of: .deleted) == 2)
        #expect(window.undoManager?.undoActionName == "Delete 2 Objects")

        // The first edit opens the panel it is listed in.
        let bottom = try #require(window.firstController(of: BottomSplitViewController.self))
        #expect(bottom.item(for: Pane.changes)?.isCollapsed == false)
        try await WindowSnapshot.write(window, named: "pending-changes")

        let commit = NSMenuItem(
            title: "", action: #selector(ProjectWindowController.commitChanges(_:)), keyEquivalent: "")
        #expect(controller.validateMenuItem(commit))
        controller.commitChanges(nil)
        await settle(document)
        await grid.whenSettled()
        #expect(!document.context.editing.hasChanges)
        #expect(grid.tableView.numberOfRows == 38)
        #expect(!controller.validateMenuItem(commit))
        document.close()
    }

    private func settle(_ document: ProjectDocument) async {
        await document.context.whenSettled()
        for _ in 0..<5 { await Task.yield() }
        try? await Task.sleep(for: .milliseconds(50))
        await document.context.whenSettled()
    }
}
