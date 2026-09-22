import DabbiBase
import DabbiTestSupport
import FixtureKit
import Foundation
import Testing

@testable import DabbiLocator

@Suite struct SimulatorIndexTests {
    static let group = TestBinaries.groups[0]

    /// One device with: a Core Data app (ships a model) with a store in its data container and one in its App
    /// Group; a SwiftData app (no model) with `default.store`; an app without databases; an app that never ran;
    /// a shared container nobody claims.
    struct World {
        let set: SyntheticDeviceSet
        let device: SyntheticDeviceSet.Device
        let notes: SyntheticDeviceSet.App
        let swifty: SyntheticDeviceSet.App
        let groupContainer: URL

        init() throws {
            set = try SyntheticDeviceSet()
            device = try set.addDevice(udid: "DEVICE-1", booted: true)

            notes = try set.install(
                "org.example.notes", name: "Notes", on: device, executable: try TestBinaries.withSection.get())
            let model = try #require(try TestFixtures.location(.noModelCache).modelURL)
            try FileManager.default.copyItem(
                at: model, to: notes.bundle.appendingPathComponent(model.lastPathComponent))
            let data = try #require(notes.dataContainer)
            try SyntheticDeviceSet.place(.company, at: "Library/Application Support/Notes.sqlite", in: data)
            try SyntheticDeviceSet.place(.notCoreData, at: "Library/Caches/cache.db", in: data)
            groupContainer = try set.addGroup(SimulatorIndexTests.group, on: device)
            try SyntheticDeviceSet.place(.basic, at: "Shared.sqlite", in: groupContainer)

            swifty = try set.install("org.example.swifty", name: "Swifty", on: device)
            try SyntheticDeviceSet.place(
                .basic, at: "Library/Application Support/default.store", in: try #require(swifty.dataContainer))

            try set.install("org.example.empty", name: "Empty", on: device)
            try set.install("org.example.neverran", name: "NeverRan", on: device, hasData: false)

            let orphan = try set.addGroup("group.org.example.orphan", on: device)
            try SyntheticDeviceSet.place(.walOnly, at: "Orphan.sqlite", in: orphan)
        }
    }

    @Test func mapsContainersToApps() throws {
        let world = try World()
        let map = ContainerMap(deviceData: world.device.data)
        #expect(
            Set(map.bundles.keys) == [
                "org.example.notes", "org.example.swifty", "org.example.empty", "org.example.neverran",
            ])
        #expect(map.dataContainers["org.example.notes"]?.path == world.notes.dataContainer?.path)
        #expect(map.dataContainers["org.example.neverran"] == nil)
        #expect(Set(map.groupContainers.keys) == [Self.group, "group.org.example.orphan"])

        let apps = map.apps()
        #expect(apps.map(\.name) == ["Empty", "NeverRan", "Notes", "Swifty"])
        let notes = try #require(apps.first { $0.bundleID == "org.example.notes" })
        #expect(notes.version == "1.2")
        // Entitled to two groups; only one has a container.
        #expect(Array(notes.groupContainers.keys) == [Self.group])
        #expect(notes.containers.map(\.container) == [.data, .group(Self.group)])
        #expect(Array(map.unclaimedGroups(by: apps).keys) == ["group.org.example.orphan"])
    }

    @Test func aBundleContainerWithoutMetadataIsKnownByItsInfoPlist() throws {
        let set = try SyntheticDeviceSet()
        let device = try set.addDevice()
        try set.install("org.example.bare", name: "Bare", on: device, writesMetadata: false)
        let map = ContainerMap(deviceData: device.data)
        #expect(Array(map.bundles.keys) == ["org.example.bare"])
        #expect(map.dataContainers["org.example.bare"] != nil)
    }

    @Test func afterAReinstallTheNewerContainerWins() throws {
        let set = try SyntheticDeviceSet()
        let device = try set.addDevice()
        let old = try set.install("org.example.app", name: "App", on: device)
        let new = try set.install("org.example.app", name: "App", on: device)
        let past = Date(timeIntervalSinceNow: -86_400)
        for url in [old.bundle, try #require(old.dataContainer)] {
            try FileManager.default.setAttributes([.modificationDate: past], ofItemAtPath: url.path)
        }
        let map = ContainerMap(deviceData: device.data)
        #expect(map.bundles["org.example.app"]?.path == new.bundle.path)
        #expect(map.dataContainers["org.example.app"]?.path == new.dataContainer?.path)
    }

    @Test func scansADevice() throws {
        let world = try World()
        let contents = SimulatorIndex.scan(world.device.simulatorDevice)
        #expect(contents.udid == "DEVICE-1")
        #expect(contents.installedAppCount == 4)
        #expect(contents.isComplete)
        #expect(contents.apps.map(\.app.name) == ["Notes", "Swifty"])

        let notes = try #require(contents.apps.first)
        #expect(!notes.usesSwiftData)
        #expect(notes.stores.map(\.kind) == [.coreData, .plainSQLite, .coreData])
        #expect(
            notes.stores.map(\.location) == [
                .simulator(
                    udid: "DEVICE-1", bundleID: "org.example.notes", container: .data,
                    relativePath: "Library/Application Support/Notes.sqlite"),
                .simulator(
                    udid: "DEVICE-1", bundleID: "org.example.notes", container: .data,
                    relativePath: "Library/Caches/cache.db"),
                .simulator(
                    udid: "DEVICE-1", bundleID: "org.example.notes", container: .group(Self.group),
                    relativePath: "Shared.sqlite"),
            ])
        #expect(notes.stores.allSatisfy { $0.byteCount > 0 && $0.modifiedAt != nil })

        let swifty = try #require(contents.apps.last)
        #expect(swifty.usesSwiftData)
        #expect(swifty.stores.map(\.kind) == [.swiftData])

        #expect(contents.sharedStores.map(\.kind) == [.coreData])
        #expect(
            contents.sharedStores.map(\.location) == [
                .simulator(
                    udid: "DEVICE-1", bundleID: "", container: .group("group.org.example.orphan"),
                    relativePath: "Orphan.sqlite")
            ])
        #expect(contents.storeCount == 4)
    }

    @Test func everyLocationItHandsOutResolvesBackToTheFile() throws {
        let world = try World()
        let index = SimulatorIndex(source: SimulatorDeviceSource(devicesDirectory: world.set.root, runner: nil))
        let contents = SimulatorIndex.scan(world.device.simulatorDevice)
        let stores = contents.apps.flatMap(\.stores) + contents.sharedStores
        #expect(stores.count == 5)
        for store in stores {
            #expect(try index.resolve(store.location).path == store.url.path)
        }
    }

    @Test func remembersWhatItScannedUntilAskedAgain() async throws {
        let world = try World()
        let index = SimulatorIndex(source: SimulatorDeviceSource(devicesDirectory: world.set.root, runner: nil))
        let device = try #require(await index.devices().devices.first)
        #expect(device.udid == "DEVICE-1")
        #expect(device.state == .booted)

        let first = await index.contents(of: device)
        try SyntheticDeviceSet.place(
            .basic, at: "Documents/Second.sqlite", in: try #require(world.swifty.dataContainer))
        #expect(await index.contents(of: device) == first)
        let again = await index.contents(of: device, refresh: true)
        #expect(again.apps.last?.stores.count == 2)
    }

    @Test func scansEveryDeviceBootedFirst() async throws {
        let set = try SyntheticDeviceSet()
        for number in 1...5 {
            let device = try set.addDevice(udid: "OFF-\(number)", name: "Phone \(number)")
            let app = try set.install("org.example.app", name: "App", on: device)
            try SyntheticDeviceSet.place(.basic, at: "Documents/Model.sqlite", in: try #require(app.dataContainer))
        }
        try set.addDevice(udid: "ON", name: "Zebra", booted: true)

        let index = SimulatorIndex(source: SimulatorDeviceSource(devicesDirectory: set.root, runner: nil))
        var seen: [SimulatorContents] = []
        for await contents in await index.scanAll(maxConcurrent: 1) { seen.append(contents) }
        #expect(seen.count == 6)
        #expect(seen.first?.udid == "ON")
        #expect(seen.map(\.storeCount).reduce(0, +) == 5)
    }

    @Test func attributesChangesToDevices() {
        let root = URL(fileURLWithPath: "/Devices", isDirectory: true)
        func udids(_ paths: String...) -> Set<String>? {
            SimulatorIndex.udids(of: paths.map { URL(fileURLWithPath: $0, isDirectory: true) }, under: root)
        }
        #expect(udids("/Devices/A/data/Containers/Data/Application/X/Library") == ["A"])
        #expect(udids("/Devices/A/data/Containers", "/Devices/B/data/Containers/Shared/AppGroup/Y") == ["A", "B"])
        // The system's own churn in a booted device is not news.
        #expect(udids("/Devices/A/data/Library/Preferences", "/Devices/A/data/var/db") == [])
        #expect(udids("/Elsewhere/A/data/Containers/Data") == [])
        // The root itself: events were dropped, or the set changed. Everything is stale.
        #expect(udids("/Devices/A/data/Containers/Data", "/Devices") == nil)
    }

    @Test func saysWhenAContainerChanges() async throws {
        let world = try World()
        let index = SimulatorIndex(source: SimulatorDeviceSource(devicesDirectory: world.set.root, runner: nil))
        let device = world.device.simulatorDevice
        _ = await index.contents(of: device)

        let changes = await index.changes()
        let waiting = Task { () -> Set<String>? in
            for await udids in changes { return udids }
            return nil
        }
        // FSEvents needs a moment to start; keep writing until it notices.
        let writing = Task {
            var number = 0
            while !Task.isCancelled {
                number += 1
                try SyntheticDeviceSet.place(
                    .basic, at: "Documents/New-\(number).sqlite", in: try #require(world.swifty.dataContainer))
                try await Task.sleep(for: .milliseconds(300))
            }
        }
        let timeout = Task {
            try await Task.sleep(for: .seconds(30))
            waiting.cancel()
        }
        let changed = await waiting.value
        writing.cancel()
        timeout.cancel()
        #expect(changed == ["DEVICE-1"])
        // What it knew is forgotten: the next question is answered by looking.
        let fresh = await index.contents(of: device)
        #expect((fresh.apps.last?.stores.count ?? 0) >= 2)
    }
}
