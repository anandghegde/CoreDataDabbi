import DabbiBase
import DabbiTestSupport
import FixtureKit
import Foundation
import Testing

@testable import DabbiLocator

@Suite struct StoreLocationResolverTests {
    private func simulator(
        _ udid: String, _ bundleID: String, _ container: AppContainer = .data, _ path: String = "Documents/Model.sqlite"
    ) -> StoreLocation {
        .simulator(udid: udid, bundleID: bundleID, container: container, relativePath: path)
    }

    @Test func findsTheStoreAgainAfterAReinstallMovedTheContainer() throws {
        let set = try SyntheticDeviceSet()
        let device = try set.addDevice(udid: "DEVICE")
        let resolver = StoreLocationResolver(devicesDirectory: set.root)
        let location = simulator("DEVICE", "org.example.app")

        let first = try set.install("org.example.app", name: "App", on: device)
        let firstStore = try SyntheticDeviceSet.place(
            .basic, at: "Documents/Model.sqlite", in: try #require(first.dataContainer))
        #expect(try resolver.resolve(location).path == firstStore.path)

        // Deleting and installing again gives the app new containers under new UUIDs.
        try FileManager.default.removeItem(at: try #require(first.dataContainer))
        try FileManager.default.removeItem(at: first.bundle.deletingLastPathComponent())
        let second = try set.install("org.example.app", name: "App", on: device)
        let secondStore = try SyntheticDeviceSet.place(
            .basic, at: "Documents/Model.sqlite", in: try #require(second.dataContainer))
        #expect(secondStore.path != firstStore.path)
        #expect(try resolver.resolve(location).path == secondStore.path)
    }

    /// PRJ-12: the error says how far the lookup got.
    @Test func saysWhatIsMissing() throws {
        let set = try SyntheticDeviceSet()
        let device = try set.addDevice(udid: "DEVICE")
        try set.install("org.example.neverran", name: "NeverRan", on: device, hasData: false)
        try set.install("org.example.app", name: "App", on: device)
        let resolver = StoreLocationResolver(devicesDirectory: set.root)

        func failure(_ location: StoreLocation) throws -> DabbiError {
            try #require(#expect(throws: DabbiError.self) { try resolver.resolve(location) })
        }
        let noDevice = try failure(simulator("OTHER", "org.example.app"))
        #expect(noDevice.code == .locationUnresolved)
        #expect(noDevice.message.contains("simulator"))

        #expect(try failure(simulator("DEVICE", "org.example.gone")).message.contains("not installed"))
        #expect(try failure(simulator("DEVICE", "org.example.neverran")).message.contains("no data yet"))
        #expect(try failure(simulator("DEVICE", "org.example.app", .group("group.none"))).message.contains("App Group"))

        let noFile = try failure(simulator("DEVICE", "org.example.app"))
        #expect(noFile.message.contains("Model.sqlite"))
        #expect(noFile.diagnosis.contains { $0.contains("container was found") })
    }

    @Test func aPathFromAProjectFileCannotLeadOutOfTheContainer() throws {
        let set = try SyntheticDeviceSet()
        let device = try set.addDevice(udid: "DEVICE")
        try set.install("org.example.app", name: "App", on: device)
        let resolver = StoreLocationResolver(devicesDirectory: set.root)
        for path in ["../../../../device.plist", "Documents/../../x", "", "/", "./Model.sqlite"] {
            #expect(throws: DabbiError.self, "\(path)") {
                try resolver.resolve(simulator("DEVICE", "org.example.app", .data, path))
            }
        }
        for udid in ["", "..", "../DEVICE", "a/b"] {
            #expect(throws: DabbiError.self, "\(udid)") { try resolver.resolve(simulator(udid, "org.example.app")) }
        }
    }

    @Test func resolvesMacAppContainers() throws {
        let home = TestFixtures.root.appendingPathComponent("home-\(UUID().uuidString)", isDirectory: true)
        let sandboxed = home.appendingPathComponent("Library/Containers/org.example.mac/Data")
        let group = home.appendingPathComponent("Library/Group Containers/TEAM.org.example")
        let storeInSandbox = try SyntheticDeviceSet.place(
            .basic, at: "Library/Application Support/Mac/Model.sqlite", in: sandboxed)
        let storeInGroup = try SyntheticDeviceSet.place(.basic, at: "Shared.sqlite", in: group)
        let storeInHome = try SyntheticDeviceSet.place(
            .basic, at: "Library/Application Support/Plain/Model.sqlite", in: home)

        let resolver = StoreLocationResolver(homeDirectory: home)
        #expect(
            try resolver.resolve(
                .macApp(
                    bundleID: "org.example.mac", container: .data,
                    relativePath: "Library/Application Support/Mac/Model.sqlite")
            ).path == storeInSandbox.path)
        #expect(
            try resolver.resolve(
                .macApp(
                    bundleID: "org.example.mac", container: .group("TEAM.org.example"), relativePath: "Shared.sqlite")
            ).path == storeInGroup.path)
        // No sandbox: the path is relative to the home folder.
        #expect(
            try resolver.resolve(
                .macApp(
                    bundleID: "org.example.plain", container: .data,
                    relativePath: "Library/Application Support/Plain/Model.sqlite")
            ).path == storeInHome.path)
    }

    @Test func filesGoThroughWhoeverHoldsTheBookmarks() throws {
        let store = try TestFixtures.location(.basic).storeURL
        let moved = FileReference(bookmarkID: UUID(), lastKnownPath: "/nonexistent/Old.sqlite")
        #expect(throws: DabbiError.self) { try StoreLocationResolver().resolve(.file(moved)) }
        let resolver = StoreLocationResolver(fileResolver: { $0.bookmarkID == moved.bookmarkID ? store : nil })
        #expect(try resolver.resolve(.file(moved)).path == store.path)

        let pulled = StoreLocation.devicePull(deviceID: "D", bundleID: "org.example.app", relativePath: "Model.sqlite")
        #expect(throws: DabbiError.self) { try resolver.resolve(pulled) }
    }

    @Test func looksInsideAnXcappdata() throws {
        let package = TestFixtures.root.appendingPathComponent("pulled-\(UUID().uuidString).xcappdata")
        let store = try SyntheticDeviceSet.place(
            .basic, at: "AppData/Library/Application Support/Model.sqlite", in: package)
        let reference = FileReference(bookmarkID: UUID(), lastKnownPath: package.path)
        let location = StoreLocation.container(reference, relativePath: "Library/Application Support/Model.sqlite")
        #expect(try StoreLocationResolver().resolve(location).path == store.path)
    }
}
