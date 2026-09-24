import AppKit
import DabbiKit
import FixtureKit
import Foundation
import Testing

@testable import CoreDataDabbi

/// The lock (EDT-1): unlocking reopens the store editable where it is, keeping the place, and a store that
/// cannot be written stays readable and says why.
@MainActor
@Suite struct ProjectAccessModeTests {
    final class Recorder {
        var changes: [ProjectContext.Change] = []
        var refusals: [DabbiError] = []
    }

    private func context(on store: URL, _ recorder: Recorder) async -> ProjectContext {
        let context = ProjectContext()
        context.workingCopiesDirectory = try? AppFixtures.scratchFolder("copies")
        context.simulators = nil
        context.adoptStore(at: store)
        context.onChange = { recorder.changes.append($0) }
        context.onEditingRefused = { recorder.refusals.append($0) }
        context.openStoreIfNeeded()
        await context.whenSettled()
        return context
    }

    @Test func unlockingReopensTheStoreEditableAndKeepsThePlace() async throws {
        let store = try ProjectRepairTests.copyStore(to: try AppFixtures.scratchFolder())
        let recorder = Recorder()
        let context = await context(on: store, recorder)
        #expect(context.accessMode == .readOnly)
        #expect(context.project.accessMode == .readOnly)
        let entity = try #require(context.selectedEntity)

        context.toggleAccessMode()
        await context.whenSettled()
        #expect(context.accessMode == .editable)
        #expect(context.project.accessMode == .editable)
        #expect(context.selectedEntity == entity)
        #expect(recorder.changes.filter { $0 == .project }.count == 1, "the project remembers the lock")

        context.toggleAccessMode()
        await context.whenSettled()
        #expect(context.accessMode == .readOnly)
        #expect(context.project.accessMode == .readOnly)
        #expect(recorder.refusals.isEmpty)
        context.shutDown()
    }

    @Test func aStoreThatCannotBeWrittenStaysReadableAndSaysWhy() async throws {
        let store = try ProjectRepairTests.copyStore(to: try AppFixtures.scratchFolder())
        try FileManager.default.setAttributes([.posixPermissions: 0o444], ofItemAtPath: store.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: store.path) }
        let recorder = Recorder()
        let context = await context(on: store, recorder)

        context.setAccessMode(.editable)
        await context.whenSettled()
        #expect(context.session != nil)
        #expect(context.accessMode == .readOnly)
        #expect(context.project.accessMode == .readOnly, "a refused unlock leaves the project as it was")
        #expect(recorder.refusals.map(\.code) == [.storeNotWritable])
        #expect(!recorder.changes.contains(.project))
        context.shutDown()
    }

    /// A project saved unlocked opens unlocked; where its store cannot be written, it opens read-only without an
    /// alert nobody asked for, and still says unlocked in the file.
    @Test func aProjectSavedUnlockedOpensUnlocked() async throws {
        let store = try ProjectRepairTests.copyStore(to: try AppFixtures.scratchFolder())
        var package = ProjectPackage()
        package.project.accessMode = .editable
        let context = ProjectContext(package: package)
        context.workingCopiesDirectory = try AppFixtures.scratchFolder("copies")
        context.simulators = nil
        context.adoptStore(at: store)
        context.openStoreIfNeeded()
        await context.whenSettled()
        #expect(context.accessMode == .editable)

        try FileManager.default.setAttributes([.posixPermissions: 0o444], ofItemAtPath: store.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: store.path) }
        let recorder = Recorder()
        context.onEditingRefused = { recorder.refusals.append($0) }
        context.openStore()
        await context.whenSettled()
        #expect(context.accessMode == .readOnly)
        #expect(context.project.accessMode == .editable)
        #expect(recorder.refusals.isEmpty)
        context.shutDown()
    }

    @Test func theLockNeedsAnOpenStore() {
        let context = ProjectContext()
        #expect(!context.canChangeAccessMode)
        context.toggleAccessMode()
        #expect(context.accessMode == nil)
        #expect(ProjectWindowController.accessTitle(for: nil) == "Allow Editing")
        #expect(ProjectWindowController.accessTitle(for: .editable) == "Lock Store")
    }
}
