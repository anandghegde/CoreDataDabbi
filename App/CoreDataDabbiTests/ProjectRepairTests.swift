import AppKit
import DabbiKit
import FixtureKit
import Foundation
import Testing

@testable import CoreDataDabbi

/// Auto-repair (PRJ-12): a store that moves or goes away is noticed when the window comes back, a store that
/// comes back is opened, and a lost one is looked for.
@MainActor
@Suite struct ProjectRepairTests {
    /// A copy of the basic fixture's store, with its side files, at `name` in `folder`.
    @discardableResult
    static func copyStore(to folder: URL, as name: String = "Model.sqlite") throws -> URL {
        let source = try AppFixtures.location(.basic).storeURL
        let destination = folder.appendingPathComponent(name)
        try FileManager.default.createDirectory(
            at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
        for suffix in ["", "-wal", "-shm"] where FileManager.default.fileExists(atPath: source.path + suffix) {
            try FileManager.default.copyItem(atPath: source.path + suffix, toPath: destination.path + suffix)
        }
        return destination
    }

    static func removeStore(at url: URL) throws {
        for suffix in ["", "-wal", "-shm"] where FileManager.default.fileExists(atPath: url.path + suffix) {
            try FileManager.default.removeItem(atPath: url.path + suffix)
        }
    }

    private func context(on store: URL, devices: URL? = nil) async -> ProjectContext {
        let context = ProjectContext()
        context.workingCopiesDirectory = try? AppFixtures.scratchFolder("copies")
        context.devicesDirectory = devices
        context.simulators = nil
        context.adoptStore(at: store)
        context.openStoreIfNeeded()
        await context.whenSettled()
        return context
    }

    private func failure(of context: ProjectContext) -> DabbiError? {
        if case .failed(let error) = context.storeState { error } else { nil }
    }

    final class Count {
        var value = 0
    }

    @Test func aStoreThatGoesAwayIsNoticedAndLookedFor() async throws {
        let folder = try AppFixtures.scratchFolder()
        let store = try Self.copyStore(to: folder)
        let context = await context(on: store)
        let lost = Count()
        context.onStoreLost = { lost.value += 1 }
        #expect(context.session != nil)

        context.checkReachability()
        await context.whenSettled()
        #expect(context.session != nil, "nothing moved, so nothing was reopened")
        #expect(lost.value == 0)

        try Self.removeStore(at: store)
        let renamed = try Self.copyStore(to: folder, as: "Renamed.sqlite")
        context.checkReachability()
        await context.whenSettled()
        #expect(failure(of: context)?.code == .locationUnresolved)
        #expect(lost.value == 1)
        #expect(context.repairs.map(\.url.lastPathComponent) == [renamed.lastPathComponent])

        context.checkReachability()
        await context.whenSettled()
        #expect(lost.value == 1, "Project Settings is shown once for each time the store goes missing")

        context.apply(try #require(context.repairs.first))
        await context.whenSettled()
        #expect(context.storeURL?.lastPathComponent == "Renamed.sqlite")
        #expect(context.repairs.isEmpty)
        context.shutDown()
    }

    @Test func aStoreThatMovedIsFollowed() async throws {
        let folder = try AppFixtures.scratchFolder()
        let store = try Self.copyStore(to: folder)
        let context = await context(on: store)
        let entity = context.selectedEntity

        // The bookmark follows the folder.
        let moved = try AppFixtures.scratchFolder().appendingPathComponent("moved", isDirectory: true)
        try FileManager.default.moveItem(at: folder, to: moved)
        context.checkReachability()
        await context.whenSettled()
        #expect(context.storeURL?.deletingLastPathComponent().lastPathComponent == "moved")
        #expect(context.selectedEntity == entity, "the place is kept")
        guard case .file(let reference) = context.project.store else { throw CocoaError(.fileNoSuchFile) }
        #expect(reference.lastKnownURL.deletingLastPathComponent().lastPathComponent == "moved")
        context.shutDown()
    }

    @Test func aStoreThatComesBackIsOpened() async throws {
        let folder = try AppFixtures.scratchFolder()
        let store = try Self.copyStore(to: folder)
        let context = await context(on: store)
        let lost = Count()
        context.onStoreLost = { lost.value += 1 }

        try Self.removeStore(at: store)
        context.checkReachability()
        await context.whenSettled()
        #expect(failure(of: context) != nil)

        // The app wrote it again.
        try Self.copyStore(to: folder)
        context.checkReachability()
        await context.whenSettled()
        #expect(context.session != nil)

        try Self.removeStore(at: store)
        context.checkReachability()
        await context.whenSettled()
        #expect(lost.value == 2, "gone, back, and gone again is two losses")
        context.shutDown()
    }

    @Test func aSimulatorStoreIsFoundOnAnotherDevice() async throws {
        let devices = try AppFixtures.scratchFolder("devices")
        let path = "Library/Application Support/Model.sqlite"
        let container = try Self.installApp("org.example.app", on: "PHONE", named: "iPhone 16", in: devices)
        try Self.copyStore(to: container, as: path)
        let lost = StoreLocation.simulator(
            udid: "ERASED", bundleID: "org.example.app", container: .data, relativePath: path)

        let context = ProjectContext()
        context.devicesDirectory = devices
        context.simulators = nil
        context.adopt(lost)
        let reported = Count()
        context.onStoreLost = { reported.value += 1 }
        context.openStoreIfNeeded()
        await context.whenSettled()
        #expect(failure(of: context)?.message.contains("simulator") == true)
        #expect(reported.value == 1)
        let repair = try #require(context.repairs.first)
        #expect(repair.reason == .otherDevice)
        #expect(ProjectSettingsView.title(of: repair).contains("iPhone 16"))

        let changes = Count()
        context.onChange = { if $0 == .project { changes.value += 1 } }
        context.apply(repair)
        await context.whenSettled()
        #expect(context.session != nil)
        #expect(changes.value == 1)
        #expect(
            context.project.store
                == .simulator(udid: "PHONE", bundleID: "org.example.app", container: .data, relativePath: path))
        context.shutDown()
    }

    @Test func settingsChangeTheProject() async throws {
        let context = try await TestProject.context(on: .basic)
        let changes = Count()
        context.onChange = { if $0 == .project { changes.value += 1 } }

        context.setTimeZone(.custom("Europe/Amsterdam"))
        #expect(context.timeZone.identifier == "Europe/Amsterdam")
        context.setTimeZone(.custom("Europe/Amsterdam"))
        #expect(changes.value == 1, "choosing what is already chosen changes nothing")

        let missing = try AppFixtures.scratchFolder().appendingPathComponent("Gone.momd")
        context.chooseModel(at: missing)
        await context.whenSettled()
        #expect(failure(of: context)?.code == .modelNotFound)
        context.useCachedModel()
        await context.whenSettled()
        #expect(context.session != nil)
        #expect(context.project.model == .storeCache)
        #expect(changes.value == 3)
        context.shutDown()
    }

    @Test func aLostStoreOpensProjectSettingsOnItsWindow() async throws {
        let folder = try AppFixtures.scratchFolder()
        let store = try Self.copyStore(to: folder)
        try Self.copyStore(to: folder, as: "Other.sqlite")
        try Self.removeStore(at: store)

        let document = try ProjectDocument(type: ProjectPackage.typeIdentifier)
        document.context.workingCopiesDirectory = try AppFixtures.scratchFolder("copies")
        document.context.simulators = nil
        document.context.adoptStore(at: store)
        document.makeWindowControllers()
        let window = try #require(document.windowControllers.first?.window)
        window.orderFront(nil)
        await document.context.whenSettled()
        for _ in 0..<5 { await Task.yield() }
        (window.windowController as? ProjectWindowController)?.windowDidBecomeKey(
            Notification(name: NSWindow.didBecomeKeyNotification, object: window))
        await document.context.whenSettled()
        try await Task.sleep(for: .milliseconds(100))

        let presented = window.contentViewController?.presentedViewControllers ?? []
        let settings = try #require(presented.first as? ProjectSettingsController)
        #expect(document.context.repairs.map(\.url.lastPathComponent) == ["Other.sqlite"])
        #expect(settings.title == String(localized: "Project Settings"))
        settings.dismiss(nil)
        document.close()
    }

    // MARK: A simulator, as folders

    /// A device folder with one app's data container in it, laid out as CoreSimulator does; the container.
    static func installApp(_ bundleID: String, on udid: String, named name: String, in devices: URL) throws -> URL {
        let device = devices.appendingPathComponent(udid, isDirectory: true)
        let container = device.appendingPathComponent("data/Containers/Data/Application/\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: container, withIntermediateDirectories: true)
        try write(
            ["UDID": udid, "name": name, "runtime": "com.apple.CoreSimulator.SimRuntime.iOS-18-2", "state": 1],
            to: device.appendingPathComponent("device.plist"))
        try write(
            ["MCMMetadataIdentifier": bundleID, "MCMMetadataContentClass": 2],
            to: container.appendingPathComponent(".com.apple.mobile_container_manager.metadata.plist"))
        return container
    }

    private static func write(_ plist: [String: Any], to url: URL) throws {
        try PropertyListSerialization.data(fromPropertyList: plist, format: .binary, options: 0).write(to: url)
    }
}
