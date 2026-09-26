import AppKit
import DabbiKit
import Foundation
import Testing

@testable import CoreDataDabbi

/// A commit's questions (EDT-10, EDT-11): the guards are put to the user once, the processes that hold the store
/// can be quit first, and a store that changed underneath the edits is settled object by object before anything
/// is written.
@MainActor
@Suite struct CommitConfirmationTests {
    final class Recorder {
        var errors: [DabbiError] = []
        var guards: [CommitGuards] = []
        var canQuit: [Bool] = []
        var conflicts: [[CommitConflict]] = []
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
        #expect(context.editing.isEditable)
        return (context, store)
    }

    private func firstSample(_ context: ProjectContext) async throws -> ObjectRef {
        let session = try #require(context.session)
        return try #require(try await session.references(FetchSpec(entity: "Sample"), limit: 1).first)
    }

    /// `tail -f` on the store: a process that has it open, and that is no app to be asked to quit.
    private func holder(of store: URL) async throws -> Process {
        let holder = Process()
        holder.executableURL = URL(fileURLWithPath: "/usr/bin/tail")
        holder.arguments = ["-f", store.path]
        holder.standardOutput = FileHandle.nullDevice
        try holder.run()
        for _ in 0..<100 where LiveProcesses.holding(store).isEmpty {
            try await Task.sleep(for: .milliseconds(20))
        }
        return holder
    }

    /// Somebody else — the store's own app — saves `name` for `ref`.
    private func saveElsewhere(_ name: String, for ref: ObjectRef, in store: URL) async throws {
        let other = try await StoreSession.open(
            storeURL: store, modelURL: nil, access: .editable(.app))
        try await other.setValue(.string(name), for: "name", of: PendingObjectID(ref))
        _ = try await other.commit()
        await other.close()
    }

    private func name(of ref: ObjectRef, in store: URL) async throws -> Value? {
        let reader = try await StoreSession.open(storeURL: store, modelURL: nil)
        defer { Task { await reader.close() } }
        return try await reader.object(ref)["name"]
    }

    @Test func aStoreOpenElsewhereIsAskedAboutOnceASession() async throws {
        let recorder = Recorder()
        let (context, store) = try await editableContext(recorder)
        let holder = try await holder(of: store)
        defer { holder.terminate() }
        var answer = CommitGuardAnswer.cancel
        context.onCommitGuards = { guards, canQuit, decide in
            recorder.guards.append(guards)
            recorder.canQuit.append(canQuit)
            decide(answer)
        }
        let ref = try await firstSample(context)

        context.editing.setValue(.string("Declined"), for: "name", of: PendingObjectID(ref))
        #expect(await context.editing.commit().value == false)
        #expect(recorder.guards.map { $0.holders.map(\.name) } == [["tail"]])
        #expect(recorder.canQuit == [false], "a command-line tool is no app to quit")
        #expect(context.editing.hasChanges && !context.editing.isCommitting)
        #expect(recorder.errors.isEmpty, "declining is not an error")
        #expect(try await name(of: ref, in: store) != .string("Declined"))

        answer = .commit
        #expect(await context.editing.commit().value)
        #expect(try await name(of: ref, in: store) == .string("Declined"))

        // Asked about once: the same process is not put to the user again.
        context.editing.setValue(.string("Again"), for: "name", of: PendingObjectID(ref))
        #expect(await context.editing.commit().value)
        #expect(recorder.guards.count == 2)
        #expect(recorder.errors.isEmpty)
        context.shutDown()
    }

    @Test func quitAndCommitQuitsTheHoldersFirst() async throws {
        let recorder = Recorder()
        let (context, store) = try await editableContext(recorder)
        let holder = try await holder(of: store)
        defer { holder.terminate() }
        context.onCommitGuards = { _, _, decide in decide(.quitAndCommit) }
        var quit: [[Int32]] = []
        context.quitHolders = { holders, store in
            quit.append(holders.map(\.pid))
            holder.terminate()
            try await StoreHolders.waitUntilFree(store)
        }
        let ref = try await firstSample(context)

        context.editing.setValue(.string("After quitting"), for: "name", of: PendingObjectID(ref))
        #expect(await context.editing.commit().value)
        #expect(quit == [[holder.processIdentifier]])
        #expect(try await name(of: ref, in: store) == .string("After quitting"))
        #expect(recorder.errors.isEmpty)
        context.shutDown()
    }

    @Test func aConflictIsSettledAsChosenAndCommitted() async throws {
        let recorder = Recorder()
        let (context, store) = try await editableContext(recorder)
        var answer: [PendingObjectID: CommitConflict.Choice]?
        context.onCommitConflicts = { conflicts, decide in
            recorder.conflicts.append(conflicts)
            decide(answer)
        }
        let ref = try await firstSample(context)
        let object = PendingObjectID(ref)
        context.editing.setValue(.string("Mine"), for: "name", of: object)
        await context.whenSettled()
        try await saveElsewhere("Theirs", for: ref, in: store)

        // Cancelled: nothing written, everything still staged, and nothing to explain.
        #expect(await context.editing.commit().value == false)
        #expect(recorder.conflicts.map { $0.map(\.object) } == [[object]])
        #expect(recorder.conflicts.first?.first?.fields.first?.isClash == true)
        #expect(context.editing.hasChanges && context.editing.undoManager.canUndo)
        #expect(recorder.errors.isEmpty)
        #expect(try await name(of: ref, in: store) == .string("Theirs"))

        answer = [object: .mine]
        #expect(await context.editing.commit().value)
        #expect(recorder.conflicts.count == 2)
        #expect(!context.editing.hasChanges && !context.editing.undoManager.canUndo)
        #expect(try await name(of: ref, in: store) == .string("Mine"))
        #expect(recorder.errors.isEmpty)
        context.shutDown()
    }

    @Test func theirsLetsTheEditGoAndCommitsTheRest() async throws {
        let recorder = Recorder()
        let (context, store) = try await editableContext(recorder)
        context.onCommitConflicts = { conflicts, decide in
            decide(Dictionary(uniqueKeysWithValues: conflicts.map { ($0.object, .theirs) }))
        }
        let refs = try await #require(context.session).references(FetchSpec(entity: "Sample"), limit: 2)
        context.editing.setValue(.string("Mine"), for: "name", of: PendingObjectID(refs[0]))
        context.editing.setValue(.string("Untouched elsewhere"), for: "name", of: PendingObjectID(refs[1]))
        await context.whenSettled()
        try await saveElsewhere("Theirs", for: refs[0], in: store)

        #expect(await context.editing.commit().value)
        #expect(context.editing.lastCommit?.updated == 1)
        #expect(try await name(of: refs[0], in: store) == .string("Theirs"))
        #expect(try await name(of: refs[1], in: store) == .string("Untouched elsewhere"))
        context.shutDown()
    }

    @Test func withNobodyToAskAConflictIsNotCommitted() async throws {
        let recorder = Recorder()
        let (context, store) = try await editableContext(recorder)
        let ref = try await firstSample(context)
        context.editing.setValue(.string("Mine"), for: "name", of: PendingObjectID(ref))
        await context.whenSettled()
        try await saveElsewhere("Theirs", for: ref, in: store)

        #expect(await context.editing.commit().value == false)
        #expect(context.editing.hasChanges)
        #expect(try await name(of: ref, in: store) == .string("Theirs"))
        context.shutDown()
    }

    @Test func theGuardsAreExplained() {
        let tail = LiveProcess(pid: 42, name: "tail")
        let cloud = CommitGuards(mirroredToCloudKit: true)
        let both = CommitGuards(mirroredToCloudKit: true, holders: [tail])
        let held = CommitGuards(holders: [tail])
        #expect(ProjectWindowController.guardsTitle(cloud) == "This store is synced with iCloud")
        #expect(ProjectWindowController.guardsTitle(both) == "This store is synced with iCloud and open in tail")
        #expect(ProjectWindowController.guardsTitle(held) == "The store is open in tail")
        #expect(ProjectWindowController.guardsExplanation(cloud, canQuit: false).contains("iCloud"))
        #expect(!ProjectWindowController.guardsExplanation(held, canQuit: false).contains("Quit it first"))
        #expect(ProjectWindowController.guardsExplanation(held, canQuit: true).contains("Quit it first"))
    }

    @Test func theConflictsSheetOffersMineOnlyWhereThereIsARow() throws {
        let changed = CommitConflict(
            object: PendingObjectID(try #require(ObjectRef(storeUUID: "S", entity: "Sample", pk: 1))), kind: .changed,
            staged: .updated, label: "one",
            fields: [.init(property: "name", original: .string("a"), mine: .string("b"), theirs: .string("c"))])
        let gone = CommitConflict(
            object: PendingObjectID(try #require(ObjectRef(storeUUID: "S", entity: "Sample", pk: 2))), kind: .deleted,
            staged: .updated, label: nil,
            fields: [.init(property: "name", original: .string("a"), mine: .string("b"), theirs: nil)])
        let model = CommitConflictsView.Model(conflicts: [changed, gone], timeZone: .gmt)
        let theirs: [PendingObjectID: CommitConflict.Choice] = [changed.object: .theirs, gone.object: .theirs]
        #expect(model.choices == theirs, "nothing is written over unasked")
        model.chooseAll(.mine)
        #expect(model.choices == [changed.object: CommitConflict.Choice.mine, gone.object: .theirs])
        model.chooseAll(.theirs)
        #expect(model.choices == theirs)
        #expect(CommitConflictsView.title(1) == "1 object changed in the store since it was edited")
        #expect(CommitConflictsView.title(2) == "2 objects changed in the store since they were edited")
    }

    @Test func theWindowAsksMineOrTheirsInASheet() async throws {
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

        let ref = try await firstSample(document.context)
        document.context.editing.setValue(.string("Mine"), for: "name", of: PendingObjectID(ref))
        await settle(document)
        try await saveElsewhere("Theirs", for: ref, in: store)

        controller.commitChanges(nil)
        var sheet: CommitConflictsController?
        for _ in 0..<200 where sheet == nil {
            try await Task.sleep(for: .milliseconds(25))
            sheet = window.attachedSheet?.contentViewController as? CommitConflictsController
        }
        let conflicts = try #require(sheet)
        #expect(conflicts.model.conflicts.map(\.object) == [PendingObjectID(ref)])
        let sheetWindow = try #require(conflicts.view.window)
        try await WindowSnapshot.write(sheetWindow, named: "commit-conflicts")

        conflicts.model.chooseAll(.mine)
        conflicts.model.onFinish(conflicts.model.choices)
        await settle(document)
        await document.context.editing.whenSettled()
        #expect(window.attachedSheet == nil)
        #expect(!document.context.editing.hasChanges)
        #expect(try await name(of: ref, in: store) == .string("Mine"))
        document.close()
    }

    private func settle(_ document: ProjectDocument) async {
        await document.context.whenSettled()
        for _ in 0..<5 { await Task.yield() }
        try? await Task.sleep(for: .milliseconds(50))
        await document.context.whenSettled()
    }
}
