import DabbiKit
import Foundation
import Testing

@testable import CoreDataDabbi

@MainActor
@Suite struct StoreStatusTests {
    /// Knows which simulators a Mac has and nothing else: naming a device asks no more than that.
    private actor DeviceList: SimulatorBrowsing {
        let devices: [SimulatorDevice]

        init(_ devices: [SimulatorDevice]) { self.devices = devices }

        func devices(refresh: Bool) async -> SimulatorDeviceSource.Listing {
            SimulatorDeviceSource.Listing(devices: devices, origin: .simctl)
        }

        func contents(of device: SimulatorDevice, refresh: Bool) async -> SimulatorContents {
            SimulatorContents(udid: device.udid)
        }

        func changes() async -> AsyncStream<Set<String>> { AsyncStream { _ in } }
    }

    private static let phone = SimulatorDevice(
        udid: "4E9B0C11-0000-0000-0000-000000000000", name: "iPhone 16",
        runtimeID: "com.apple.CoreSimulator.SimRuntime.iOS-18-2", state: .booted,
        dataURL: URL(fileURLWithPath: "/Devices/PHONE/data"))

    private static func simulatorStore(
        on udid: String = phone.udid, of bundleID: String = "org.example.notes",
        in container: AppContainer = .data
    ) -> StoreLocation {
        .simulator(
            udid: udid, bundleID: bundleID, container: container,
            relativePath: "Library/Application Support/Notes.sqlite")
    }

    @Test func aStorePickedAsAFileSaysNothingBeyondItsPath() {
        let location = StoreLocation.file(FileReference(lastKnownPath: "/Users/someone/Notes.sqlite"))
        #expect(StoreStatus.origin(of: location, devices: []) == nil)
    }

    @Test func namesTheDeviceAndTheAppASimulatorStoreBelongsTo() {
        #expect(
            StoreStatus.origin(of: Self.simulatorStore(), devices: [Self.phone])
                == "iPhone 16 · org.example.notes")
    }

    @Test func namesADeviceThisMacNoLongerHasByItsUDID() {
        // Deleted, or another Mac's: the start of the UDID is what simctl would have printed.
        #expect(
            StoreStatus.origin(of: Self.simulatorStore(), devices: []) == "4E9B0C11 · org.example.notes")
    }

    @Test func namesTheGroupContainerWhenNoAppClaimsTheStore() {
        let location = Self.simulatorStore(of: "", in: .group("group.org.example"))
        #expect(
            StoreStatus.origin(of: location, devices: [Self.phone]) == "iPhone 16 · group.org.example")
    }

    @Test func namesTheAppOfAMacStore() {
        let location = StoreLocation.macApp(
            bundleID: "org.example.desktop", container: .data, relativePath: "Library/Notes.sqlite")
        #expect(StoreStatus.origin(of: location, devices: []) == "This Mac · org.example.desktop")
    }

    @Test func namesAnExportedContainerByItsOwnName() {
        let location = StoreLocation.container(
            FileReference(lastKnownPath: "/Users/someone/Bug 42.xcappdata"),
            relativePath: "AppData/Library/Notes.sqlite")
        #expect(StoreStatus.origin(of: location, devices: []) == "Bug 42")
    }

    @Test func theCapsuleNamesTheDeviceOfASimulatorStore() async {
        let context = ProjectContext()
        context.simulators = DeviceList([Self.phone])
        context.adopt(Self.simulatorStore())
        context.openStoreIfNeeded()

        // Said before the device list is back, so that the capsule is never blank about it…
        #expect(context.locationOrigin == "4E9B0C11 · org.example.notes")
        await context.whenSettled()
        // …and said properly once it is. The store itself is not there to open; the capsule still knows whose.
        #expect(context.locationOrigin == "iPhone 16 · org.example.notes")
        let status = StoreStatus(context: context)
        #expect(status.origin == "iPhone 16 · org.example.notes")
        #expect(status.line.first == "iPhone 16 · org.example.notes")
        context.shutDown()
    }

    @Test func aFileProjectAsksNothingOfTheSimulators() async throws {
        let context = ProjectContext()
        context.workingCopiesDirectory = try AppFixtures.scratchFolder("status-copies")
        context.adoptStore(at: try AppFixtures.location(.company).storeURL)
        context.openStoreIfNeeded()
        await context.whenSettled()

        #expect(context.locationOrigin == nil)
        #expect(StoreStatus(context: context).line == ["Cached model", "Read-only"])
        context.shutDown()
    }
}
