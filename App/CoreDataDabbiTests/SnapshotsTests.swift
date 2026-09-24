import AppKit
import DabbiKit
import FixtureKit
import Foundation
import Testing

@testable import CoreDataDabbi

/// Snapshots in a window (§7.3): taken, named and noted, listed with the backups, and put back — never over a
/// store another process has open, never without a backup, and never past staged edits without asking.
@MainActor
@Suite struct SnapshotsTests {
    final class Recorder {
        var errors: [DabbiError] = []
        var holders: [[LiveProcess]] = []
        var canQuit: [Bool] = []
        var asked = 0
    }

    private func context(
        _ recorder: Recorder, access: AccessMode = .readOnly
    ) async throws -> (ProjectContext, URL) {
        let folder = try AppFixtures.scratchFolder()
        let store = try ProjectRepairTests.copyStore(to: folder)
        var package = ProjectPackage()
        package.project.accessMode = access
        let context = ProjectContext(package: package)
        context.workingCopiesDirectory = try AppFixtures.scratchFolder("copies")
        context.backupsDirectory = folder.appendingPathComponent("Backups", isDirectory: true)
        context.simulators = nil
        context.adoptStore(at: store)
        context.snapshots.onError = { recorder.errors.append($0) }
        context.editing.onError = { recorder.errors.append($0) }
        context.openStoreIfNeeded()
        await context.whenSettled()
        #expect(context.snapshots.isAttached)
        return (context, store)
    }

    private func count(_ context: ProjectContext) async throws -> Int {
        try await #require(context.session).count(FetchSpec(entity: "Sample"))
    }

    private func take(_ name: String, in context: ProjectContext) async throws -> SnapshotManifest {
        let task = try #require(context.takeSnapshot(name: name, note: "Forty samples"))
        let manifest = try #require(await task.value)
        await context.whenSettled()
        return manifest
    }

    /// Deletes two samples and commits: the store has 38 then, and a backup of it at 40.
    private func deleteTwo(in context: ProjectContext) async throws {
        let refs = try await #require(context.session).references(FetchSpec(entity: "Sample"), limit: 2)
        context.editing.delete(refs.map(PendingObjectID.init))
        await context.whenSettled()
        #expect(await context.editing.commit().value)
        await context.whenSettled()
        #expect(try await count(context) == 38)
    }

    @Test func aSnapshotIsTakenNamedNotedAndDeleted() async throws {
        let recorder = Recorder()
        let (context, _) = try await context(recorder)
        #expect(context.snapshots.snapshots.isEmpty)

        let manifest = try await take("Seeded", in: context)
        #expect(manifest.kind == .snapshot && manifest.note == "Forty samples")
        #expect(context.snapshots.snapshots.map(\.id) == [manifest.id])
        let library = try #require(context.snapshots.library)
        try Snapshotter.verify(manifest, in: library)

        context.snapshots.rename(manifest.id, to: "  Before the demo ")
        context.snapshots.rename(manifest.id, to: "   ")
        context.snapshots.setNote("Forty samples, none edited", of: manifest.id)
        #expect(context.snapshots.snapshots.first?.name == "Before the demo")
        #expect(library.list().first?.name == "Before the demo")
        #expect(library.list().first?.note == "Forty samples, none edited")

        // Reopening the store keeps its library, and reads it again.
        context.reloadStore()
        await context.whenSettled()
        #expect(context.snapshots.snapshots.map(\.name) == ["Before the demo"])

        context.snapshots.delete(manifest.id)
        #expect(context.snapshots.snapshots.isEmpty)
        #expect(library.list().isEmpty)
        #expect(recorder.errors.isEmpty)
        context.shutDown()
    }

    @Test func anUnnamedSnapshotIsNamedForWhenItWasTaken() async throws {
        let recorder = Recorder()
        let (context, _) = try await context(recorder)
        let manifest = try await take("", in: context)
        #expect(manifest.name.hasPrefix("Snapshot "))
        context.shutDown()
    }

    @Test func restoringPutsTheSnapshotBackAndBacksTheStoreUpFirst() async throws {
        let recorder = Recorder()
        let (context, _) = try await context(recorder, access: .editable)
        let snapshot = try await take("Forty", in: context)
        try await deleteTwo(in: context)
        // The commit's backup is listed with the snapshots.
        #expect(context.snapshots.snapshots.map(\.kind) == [.backup, .snapshot])

        #expect(context.canRestore)
        context.restore(snapshot)
        #expect(context.snapshots.activity == .restoring)
        await context.whenSettled()
        #expect(context.snapshots.activity == nil)
        #expect(recorder.errors.isEmpty)
        #expect(try await count(context) == 40)
        #expect(context.accessMode == .editable, "the store comes back as it was opened")

        let names = context.snapshots.snapshots.map(\.name)
        #expect(names.first == "Before restoring “Forty”")
        #expect(context.snapshots.snapshots.map(\.kind) == [.backup, .backup, .snapshot])

        // The backup is the store as it was: restoring it undoes the restore.
        let backup = try #require(context.snapshots.snapshots.first)
        context.restore(backup)
        await context.whenSettled()
        #expect(try await count(context) == 38)
        #expect(recorder.errors.isEmpty)
        context.shutDown()
    }

    @Test func stagedEditsAreAskedAboutBeforeARestore() async throws {
        let recorder = Recorder()
        let (context, _) = try await context(recorder, access: .editable)
        let snapshot = try await take("Forty", in: context)
        let refs = try await #require(context.session).references(FetchSpec(entity: "Sample"), limit: 1)
        context.editing.delete(refs.map(PendingObjectID.init))
        await context.whenSettled()

        var answer = LeavingChanges.cancel
        context.onLeavingChanges = { decide in
            recorder.asked += 1
            decide(answer)
        }
        context.restore(snapshot)
        await context.whenSettled()
        #expect(recorder.asked == 1)
        #expect(context.editing.hasChanges, "Cancel leaves the edits staged and the store alone")
        #expect(context.snapshots.snapshots.count == 1)

        answer = .discard
        context.restore(snapshot)
        await context.whenSettled()
        #expect(recorder.asked == 2)
        #expect(!context.editing.hasChanges)
        #expect(try await count(context) == 40)
        #expect(context.snapshots.snapshots.count == 2)
        context.shutDown()
    }

    @Test func aStoreAnotherProcessHasOpenIsOnlyRestoredOnceItLetsGo() async throws {
        let recorder = Recorder()
        let (context, store) = try await context(recorder, access: .editable)
        let snapshot = try await take("Forty", in: context)
        try await deleteTwo(in: context)
        let backupsBefore = context.snapshots.snapshots.count

        let holder = Process()
        holder.executableURL = URL(fileURLWithPath: "/usr/bin/tail")
        holder.arguments = ["-f", store.path]
        holder.standardOutput = FileHandle.nullDevice
        try holder.run()
        defer { holder.terminate() }
        for _ in 0..<50 {
            if !LiveProcesses.holding(store).isEmpty { break }
            try await Task.sleep(for: .milliseconds(20))
        }

        var quit = false
        context.onStoreInUse = { holders, canQuit, decide in
            recorder.holders.append(holders)
            recorder.canQuit.append(canQuit)
            decide(quit)
        }
        context.quitHolders = { holders, store in
            #expect(holders.map(\.pid) == [holder.processIdentifier])
            holder.terminate()
            try await StoreHolders.waitUntilFree(store)
        }

        context.restore(snapshot)
        await context.whenSettled()
        #expect(recorder.holders.map { $0.map(\.name) } == [["tail"]])
        // A command-line tool is not an app that can be asked to quit, and the store is a plain file.
        #expect(recorder.canQuit == [false])
        #expect(try await count(context) == 38)
        #expect(context.snapshots.snapshots.count == backupsBefore, "no backup for a restore that did not happen")
        #expect(context.snapshots.activity == nil)

        quit = true
        context.restore(snapshot)
        await context.whenSettled()
        #expect(recorder.holders.count == 2)
        #expect(try await count(context) == 40)
        #expect(context.snapshots.snapshots.count == backupsBefore + 1)
        #expect(recorder.errors.isEmpty)
        context.shutDown()
    }

    @Test func withNobodyToAskTheRestoreIsRefusedAndSaysWhy() async throws {
        let recorder = Recorder()
        let (context, store) = try await context(recorder)
        let snapshot = try await take("Forty", in: context)
        let holder = Process()
        holder.executableURL = URL(fileURLWithPath: "/usr/bin/tail")
        holder.arguments = ["-f", store.path]
        holder.standardOutput = FileHandle.nullDevice
        try holder.run()
        defer { holder.terminate() }
        for _ in 0..<50 {
            if !LiveProcesses.holding(store).isEmpty { break }
            try await Task.sleep(for: .milliseconds(20))
        }

        context.restore(snapshot)
        await context.whenSettled()
        #expect(recorder.errors.map(\.code) == [.storeInUse])
        #expect(context.snapshots.snapshots.count == 1)
        context.shutDown()
    }

    @Test func aDamagedSnapshotIsNotRestoredAndTheStoreIsReopenedAsItWas() async throws {
        let recorder = Recorder()
        let (context, _) = try await context(recorder, access: .editable)
        let snapshot = try await take("Forty", in: context)
        try await deleteTwo(in: context)
        let library = try #require(context.snapshots.library)
        try FileManager.default.removeItem(at: library.databaseURL(of: snapshot))

        context.restore(snapshot)
        await context.whenSettled()
        #expect(recorder.errors.count == 1)
        #expect(try await count(context) == 38)
        #expect(context.snapshots.activity == nil)
        #expect(context.accessMode == .editable)
        context.shutDown()
    }
}

@MainActor
@Suite struct SnapshotsWindowTests {
    @Test func theSidebarListsSnapshotsAndTheirMenuActs() async throws {
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

        let take = NSMenuItem(
            title: "", action: #selector(ProjectWindowController.takeSnapshot(_:)), keyEquivalent: "")
        #expect(controller.validateMenuItem(take))
        let task = try #require(document.context.takeSnapshot(name: "Seeded", note: "Forty samples, as generated"))
        let manifest = try #require(await task.value)
        await settle(document)

        let sidebar = try #require(window.firstController(of: SidebarViewController.self))
        #expect(sidebar.rowTitles.suffix(2) == ["Snapshots", "Seeded"])
        let cell = try #require(sidebar.cell(forSnapshot: manifest.id))
        #expect(cell.toolTip?.contains("Forty samples, as generated") == true)
        try await WindowSnapshot.write(window, named: "snapshots")

        // Renamed in place, as a saved predicate is.
        sidebar.beginRenaming(snapshot: manifest.id)
        #expect(cell.isEditingName)
        cell.commitEditing(as: "Pristine")
        await settle(document)
        #expect(sidebar.rowTitles.last == "Pristine")

        let restore = NSMenuItem(
            title: "", action: #selector(ProjectWindowController.restoreSnapshot(_:)), keyEquivalent: "")
        restore.representedObject = manifest.id
        #expect(controller.validateMenuItem(restore))
        document.close()
    }

    private func settle(_ document: ProjectDocument) async {
        await document.context.whenSettled()
        for _ in 0..<5 { await Task.yield() }
        try? await Task.sleep(for: .milliseconds(50))
        await document.context.whenSettled()
    }
}
