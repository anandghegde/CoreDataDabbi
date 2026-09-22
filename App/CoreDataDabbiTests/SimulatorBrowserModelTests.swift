import AppKit
import DabbiKit
import Foundation
import Testing

@testable import CoreDataDabbi

@MainActor
@Suite struct SimulatorBrowserModelTests {
    /// A Mac's worth of simulators, made up: this machine's own are nobody's to predict, and a test that scanned
    /// them would say something different on every developer's desk.
    private actor FakeSimulators: SimulatorBrowsing {
        var listing: SimulatorDeviceSource.Listing
        var contents: [String: SimulatorContents]
        private(set) var scans: [String: Int] = [:]
        private var continuation: AsyncStream<Set<String>>.Continuation?

        init(listing: SimulatorDeviceSource.Listing, contents: [String: SimulatorContents]) {
            self.listing = listing
            self.contents = contents
        }

        func devices(refresh: Bool) async -> SimulatorDeviceSource.Listing { listing }

        func contents(of device: SimulatorDevice, refresh: Bool) async -> SimulatorContents {
            scans[device.udid, default: 0] += 1
            return contents[device.udid] ?? SimulatorContents(udid: device.udid)
        }

        func changes() async -> AsyncStream<Set<String>> {
            let (stream, continuation) = AsyncStream<Set<String>>.makeStream()
            self.continuation = continuation
            return stream
        }

        /// Something happened in these devices' containers.
        func announce(_ udids: Set<String>) { continuation?.yield(udids) }

        func replace(_ found: SimulatorContents) { contents[found.udid] = found }
    }

    // MARK: A world to browse

    private static let iOS18 = "com.apple.CoreSimulator.SimRuntime.iOS-18-2"
    private static let iOS17 = "com.apple.CoreSimulator.SimRuntime.iOS-17-5"
    private static let watchOS = "com.apple.CoreSimulator.SimRuntime.watchOS-11-0"

    private static func device(
        _ udid: String, _ name: String, runtime: String, booted: Bool = false
    ) -> SimulatorDevice {
        SimulatorDevice(
            udid: udid, name: name, runtimeID: runtime, state: booted ? .booted : .shutdown,
            dataURL: URL(fileURLWithPath: "/Devices/\(udid)/data"))
    }

    private static func app(_ bundleID: String, _ name: String) -> SimulatorApp {
        SimulatorApp(
            bundleID: bundleID, name: name, version: "1.0",
            bundleURL: URL(fileURLWithPath: "/Devices/Bundle/\(name).app"), dataContainerURL: nil,
            groupContainers: [:], iconURL: nil)
    }

    private static func store(
        _ fileName: String, on udid: String, of bundleID: String, container: AppContainer = .data,
        kind: StoreCandidate.Kind = .coreData
    ) -> StoreCandidate {
        let path = "Library/Application Support/\(fileName)"
        return StoreCandidate(
            url: URL(fileURLWithPath: "/Devices/\(udid)/\(bundleID)/\(path)"),
            location: .simulator(udid: udid, bundleID: bundleID, container: container, relativePath: path),
            kind: kind, byteCount: 40_960, modifiedAt: Date(timeIntervalSince1970: 1_700_000_000))
    }

    /// A booted iPhone with a Core Data app, a SwiftData app and a cache nobody asked for; an iPad on an older
    /// runtime with nothing installed; a watch with a store in an app group no app claims.
    private static func world() -> FakeSimulators {
        let phone = device("PHONE", "iPhone 16", runtime: iOS18, booted: true)
        let pad = device("PAD", "iPad Pro", runtime: iOS17)
        let watch = device("WATCH", "Apple Watch Series 10", runtime: watchOS)
        let notes = SimulatorContents.AppStores(
            app: app("org.example.notes", "Notes"),
            stores: [
                store("Notes.sqlite", on: "PHONE", of: "org.example.notes"),
                store("Cache.db", on: "PHONE", of: "org.example.notes", kind: .plainSQLite),
            ],
            usesSwiftData: false)
        let swifty = SimulatorContents.AppStores(
            app: app("org.example.swifty", "Swifty"),
            stores: [store("default.store", on: "PHONE", of: "org.example.swifty", kind: .swiftData)],
            usesSwiftData: true)
        return FakeSimulators(
            listing: SimulatorDeviceSource.Listing(devices: [pad, watch, phone], origin: .simctl),
            contents: [
                "PHONE": SimulatorContents(udid: "PHONE", apps: [notes, swifty], installedAppCount: 4),
                "PAD": SimulatorContents(udid: "PAD", installedAppCount: 1),
                "WATCH": SimulatorContents(
                    udid: "WATCH",
                    sharedStores: [
                        store("Shared.sqlite", on: "WATCH", of: "", container: .group("group.org.example"))
                    ],
                    installedAppCount: 2),
            ])
    }

    /// A loaded browser over that world, and whatever it was asked to open.
    private func browser(
        _ source: FakeSimulators = SimulatorBrowserModelTests.world()
    ) async -> (SimulatorBrowserModel, Opened) {
        let opened = Opened()
        let model = SimulatorBrowserModel(source: source) { opened.locations.append($0) }
        model.load()
        await model.whenSettled()
        return (model, opened)
    }

    @MainActor final class Opened {
        var locations: [StoreLocation] = []
    }

    // MARK: Tests

    @Test func groupsDevicesByRuntimeWithTheNewestFirst() async {
        let (model, _) = await browser()

        #expect(model.groups.map(\.name) == ["iOS 18.2", "iOS 17.5", "watchOS 11.0"])
        #expect(model.groups.first?.devices.map(\.name) == ["iPhone 16"])
        // The booted device is where the developer is working: the browser opens on it.
        #expect(model.selectedDevice == "PHONE")
    }

    @Test func countsTheStoresOfEachDeviceOnceItHasLookedInside() async {
        let (model, _) = await browser()
        let devices = Dictionary(uniqueKeysWithValues: model.devices.map { ($0.udid, $0) })

        // The cache is a plain SQLite database, and not what the browser is for.
        #expect(model.storeCount(of: devices["PHONE"]!) == 2)
        #expect(model.storeCount(of: devices["PAD"]!) == 0)
        #expect(model.storeCount(of: devices["WATCH"]!) == 1)
        #expect(model.isScanning(devices["PHONE"]!) == false)
    }

    @Test func showsTheAppsOfTheSelectedDeviceWithTheirStores() async {
        let (model, _) = await browser()

        let rows = model.appRows
        #expect(rows.map(\.name) == ["Notes", "Swifty"])
        #expect(rows.first?.bundleID == "org.example.notes")
        #expect(rows.first?.stores.map { $0.url.lastPathComponent } == ["Notes.sqlite"])
        // PRJ-11: the badge that says the model comes from the store itself.
        #expect(rows.last?.usesSwiftData == true)
    }

    @Test func showsOtherDatabasesOnlyWhenAsked() async {
        let (model, _) = await browser()

        model.showsOtherDatabases = true
        #expect(model.appRows.first?.stores.map { $0.url.lastPathComponent } == ["Notes.sqlite", "Cache.db"])
        model.showsOtherDatabases = false
        #expect(model.appRows.first?.stores.count == 1)
    }

    @Test func listsStoresInAppGroupsNoAppClaims() async {
        let (model, _) = await browser()

        model.selectedDevice = "WATCH"
        let row = model.appRows.first
        #expect(row?.bundleID == nil)
        #expect(row?.stores.first?.url.lastPathComponent == "Shared.sqlite")
    }

    @Test func bootedOnlyLeavesTheRunningSimulators() async {
        let (model, _) = await browser()

        model.bootedOnly = true
        #expect(model.visibleDevices.map(\.udid) == ["PHONE"])
        model.bootedOnly = false
        #expect(model.visibleDevices.count == 3)
    }

    @Test func searchesDevicesAppsAndStores() async {
        let (model, _) = await browser()

        model.search = "ipad"
        #expect(model.visibleDevices.map(\.udid) == ["PAD"])

        // An app's name, and its bundle ID: both find the device that has it, and it alone.
        model.search = "swifty"
        #expect(model.visibleDevices.map(\.udid) == ["PHONE"])
        #expect(model.appRows.map(\.name) == ["Swifty"])
        model.search = "org.example.notes"
        #expect(model.appRows.map(\.name) == ["Notes"])

        // And a store by its file name, which is often all a developer remembers.
        model.search = "shared.sqlite"
        #expect(model.visibleDevices.map(\.udid) == ["WATCH"])
        #expect(model.appRows.first?.stores.count == 1)

        model.search = "nothing here"
        #expect(model.visibleDevices.isEmpty)
        #expect(model.selectedDevice == nil)
    }

    @Test func keepsADeviceSelectedWhileTheFiltersAllowIt() async {
        let (model, _) = await browser()

        model.selectedDevice = "WATCH"
        model.search = "watch"
        #expect(model.selectedDevice == "WATCH")
        // Filtered out: the selection moves to what is left rather than leaving an empty pane behind.
        model.search = "notes"
        #expect(model.selectedDevice == "PHONE")
    }

    @Test func opensAStoreByItsIdentityNotItsPath() async throws {
        let (model, opened) = await browser()

        let store = try #require(model.appRows.first?.stores.first)
        model.open(store)
        #expect(opened.locations == [store.location])
        if case .simulator(let udid, let bundleID, let container, _) = opened.locations.first {
            #expect(udid == "PHONE")
            #expect(bundleID == "org.example.notes")
            #expect(container == .data)
        } else {
            Issue.record("a simulator store was not remembered as one: \(opened.locations)")
        }
    }

    @Test func looksAgainAtADeviceWhoseContainersChanged() async {
        let source = Self.world()
        let (model, _) = await browser(source)
        model.watchForChanges()

        // The app under test saved something new, and the watcher says which device it was.
        await source.replace(
            SimulatorContents(
                udid: "PAD",
                apps: [
                    SimulatorContents.AppStores(
                        app: Self.app("org.example.late", "Late"),
                        stores: [Self.store("Late.sqlite", on: "PAD", of: "org.example.late")],
                        usesSwiftData: false)
                ], installedAppCount: 1))
        await source.announce(["PAD"])

        let pad = model.devices.first { $0.udid == "PAD" }!
        await Self.until { model.storeCount(of: pad) == 1 }
        #expect(await source.scans["PAD"] == 2)
        #expect(await source.scans["PHONE"] == 1)
        model.stopWatching()
    }

    @Test func saysWhenTheDeviceListDidNotComeFromSimctl() async {
        let issue = DabbiError(.toolUnavailable, "xcrun simctl could not be run.")
        let source = FakeSimulators(
            listing: SimulatorDeviceSource.Listing(
                devices: [Self.device("PAD", "iPad Pro", runtime: Self.iOS17)], origin: .deviceFiles,
                issue: issue),
            contents: [:])
        let (model, _) = await browser(source)

        #expect(model.origin == .deviceFiles)
        #expect(model.listingIssue?.code == .toolUnavailable)
    }

    @Test func showsTheDevicesAndTheirStoresInAWindow() async throws {
        let controller = SimulatorBrowserWindowController(source: Self.world())
        let window = try #require(controller.window)
        window.setFrame(NSRect(x: 0, y: 0, width: 900, height: 560), display: false)
        window.orderFront(nil)

        // The window loads what it shows when it appears; nothing is asked of the index before that.
        await Self.until { !controller.model.appRows.isEmpty }
        for _ in 0..<5 { await Task.yield() }
        #expect(controller.model.selectedDevice == "PHONE")
        #expect(window.title == "Simulators")
        try await WindowSnapshot.write(window, named: "simulators")
        try await WindowSnapshot.write(window, named: "simulators-dark", appearance: .darkAqua)
        controller.close()
    }

    /// Waits for something the watcher will bring, rather than for a length of time.
    private static func until(
        _ condition: @MainActor () -> Bool, within seconds: Double = 2
    ) async {
        let deadline = Date().addingTimeInterval(seconds)
        while !condition(), Date() < deadline {
            await Task.yield()
            try? await Task.sleep(for: .milliseconds(5))
        }
    }
}
