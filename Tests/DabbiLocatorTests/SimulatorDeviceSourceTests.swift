import DabbiBase
import DabbiTestSupport
import Foundation
import Testing

@testable import DabbiLocator

@Suite struct SimulatorDeviceSourceTests {
    static let simctlJSON = """
        {
          "devices" : {
            "com.apple.CoreSimulator.SimRuntime.iOS-17-5" : [
              { "udid" : "AAAA", "name" : "iPhone 15", "state" : "Shutdown", "isAvailable" : true,
                "dataPath" : "/somewhere/AAAA/data", "deviceTypeIdentifier" : "com.apple.CoreSimulator.SimDeviceType.iPhone-15",
                "lastBootedAt" : "2026-05-01T10:00:00Z", "logPath" : "/ignored", "dataPathSize" : 12 },
              { "udid" : "BBBB", "name" : "iPad Air", "state" : "Booted", "isAvailable" : true }
            ],
            "com.apple.CoreSimulator.SimRuntime.iOS-18-2" : [
              { "udid" : "CCCC", "name" : "iPhone 16", "state" : "Shutdown", "isAvailable" : false,
                "availabilityError" : "runtime profile not found" }
            ],
            "com.apple.CoreSimulator.SimRuntime.xrOS-2-0" : [
              { "udid" : "DDDD", "name" : "Apple Vision Pro", "state" : "Creating" }
            ],
            "com.apple.CoreSimulator.SimRuntime.watchOS-11-0" : []
          }
        }
        """

    @Test func parsesWhatSimctlPrints() throws {
        let directory = URL(fileURLWithPath: "/devices", isDirectory: true)
        let devices = try SimulatorDeviceSource.parseSimctl(Data(Self.simctlJSON.utf8), devicesDirectory: directory)
        // iOS before visionOS; iOS 18 before 17; the booted iPad before the iPhone.
        #expect(devices.map(\.udid) == ["CCCC", "BBBB", "AAAA", "DDDD"])
        #expect(devices.map(\.runtimeName) == ["iOS 18.2", "iOS 17.5", "iOS 17.5", "visionOS 2.0"])
        #expect(devices.map(\.state) == [.shutdown, .booted, .shutdown, .other])
        #expect(devices.map(\.isAvailable) == [false, true, true, true])

        let phone = try #require(devices.first { $0.udid == "AAAA" })
        #expect(phone.dataURL.path == "/somewhere/AAAA/data")
        #expect(phone.deviceTypeID == "com.apple.CoreSimulator.SimDeviceType.iPhone-15")
        #expect(phone.lastBootedAt == ISO8601DateFormatter().date(from: "2026-05-01T10:00:00Z"))
        // Without a dataPath the device is where devices are.
        #expect(devices.first { $0.udid == "BBBB" }?.dataURL.path == "/devices/BBBB/data")
    }

    @Test func runtimeNames() {
        #expect(SimulatorRuntime.displayName(of: "com.apple.CoreSimulator.SimRuntime.tvOS-17-0") == "tvOS 17.0")
        #expect(SimulatorRuntime.displayName(of: "com.apple.CoreSimulator.SimRuntime.iOS-26-0-1") == "iOS 26.0.1")
        #expect(SimulatorRuntime.displayName(of: "com.apple.CoreSimulator.SimRuntime.Custom") == "Custom")
        #expect(SimulatorRuntime.displayName(of: "something else") == "something else")
        // 26 is newer than 9: versions compare as numbers.
        #expect(
            SimulatorRuntime.precedes(
                "com.apple.CoreSimulator.SimRuntime.iOS-26-0", "com.apple.CoreSimulator.SimRuntime.iOS-9-3"))
    }

    @Test func asksSimctlForACustomSetByName() async throws {
        let set = try SyntheticDeviceSet()
        let runner = FakeProcessRunner(output: Self.simctlJSON)
        let listing = await SimulatorDeviceSource(devicesDirectory: set.root, runner: runner).listing()
        #expect(listing.origin == .simctl)
        #expect(listing.issue == nil)
        #expect(listing.devices.count == 4)
        #expect(runner.arguments == [["simctl", "--set", set.root.path, "list", "-j", "devices"]])
    }

    @Test func theDefaultSetIsNotNamed() async throws {
        let runner = FakeProcessRunner(output: Self.simctlJSON)
        _ = await SimulatorDeviceSource(runner: runner).listing()
        #expect(runner.arguments == [["simctl", "list", "-j", "devices"]])
    }

    @Test func readsTheDeviceFoldersWhenSimctlFails() async throws {
        let set = try SyntheticDeviceSet()
        try set.addDevice(udid: "OLD", name: "iPhone 15", runtime: SyntheticDeviceSet.iOS17)
        try set.addDevice(udid: "NEW", name: "iPhone 16", runtime: SyntheticDeviceSet.iOS18, booted: true)
        try set.addDevice(udid: "GONE", name: "Deleted", isDeleted: true)
        try FileManager.default.createDirectory(
            at: set.root.appendingPathComponent("not-a-device"), withIntermediateDirectories: true)

        let failing = FakeProcessRunner(
            output: "", status: 72, error: "xcrun: error: unable to find utility \"simctl\"")
        let listing = await SimulatorDeviceSource(devicesDirectory: set.root, runner: failing).listing()
        #expect(listing.origin == .deviceFiles)
        #expect(listing.issue?.code == .toolUnavailable)
        #expect(listing.issue?.diagnosis.first?.contains("unable to find utility") == true)
        #expect(listing.devices.map(\.udid) == ["NEW", "OLD"])
        #expect(listing.devices.map(\.state) == [.booted, .shutdown])
        #expect(listing.devices.first?.dataURL.path == set.root.appendingPathComponent("NEW/data").path)
    }

    @Test func readsTheDeviceFoldersWhenSimctlAnswersSomethingElse() async throws {
        let set = try SyntheticDeviceSet()
        try set.addDevice(udid: "ONE")
        for output in ["", "Usage: simctl …", #"{"devices": ["unexpected"]}"#] {
            let listing = await SimulatorDeviceSource(
                devicesDirectory: set.root, runner: FakeProcessRunner(output: output)
            )
            .listing()
            #expect(listing.origin == .deviceFiles, "\(output)")
            #expect(listing.issue?.code == .toolOutputUnreadable, "\(output)")
            #expect(listing.devices.map(\.udid) == ["ONE"])
        }
    }

    @Test func readsTheDeviceFoldersWhenToldNeverToRunATool() async throws {
        let set = try SyntheticDeviceSet()
        try set.addDevice(udid: "ONE")
        let listing = await SimulatorDeviceSource(devicesDirectory: set.root, runner: nil).listing()
        #expect(listing.origin == .deviceFiles)
        #expect(listing.issue == nil)
        #expect(listing.devices.map(\.udid) == ["ONE"])
    }

    @Test func aMissingDeviceSetIsEmptyNotAnError() async throws {
        let nowhere = URL(fileURLWithPath: "/nonexistent/CoreSimulator/Devices", isDirectory: true)
        let listing = await SimulatorDeviceSource(devicesDirectory: nowhere, runner: nil).listing()
        #expect(listing.devices.isEmpty)
    }
}
