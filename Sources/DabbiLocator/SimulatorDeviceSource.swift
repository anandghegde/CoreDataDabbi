import DabbiBase
import Foundation

/// Where the list of simulators comes from: `simctl`, and the device folders themselves when `simctl` cannot be
/// asked — no Xcode selected, a beta that answers differently, a sandbox that does not let it run.
///
/// `simctl list -j devices` is the supported way to ask. The folders are an implementation detail of
/// CoreSimulator, stable for a decade; every device has a `device.plist` beside its `data` folder.
public struct SimulatorDeviceSource: Sendable {
    public enum Origin: String, Sendable, Hashable, Codable {
        case simctl
        /// `device.plist` files. The booted state in them can lag behind.
        case deviceFiles
    }

    public struct Listing: Sendable {
        public var devices: [SimulatorDevice]
        public var origin: Origin
        /// Why `simctl` was not the origin, when it was not.
        public var issue: DabbiError?

        public init(devices: [SimulatorDevice], origin: Origin, issue: DabbiError? = nil) {
            self.devices = devices
            self.origin = origin
            self.issue = issue
        }
    }

    public static var defaultDevicesDirectory: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Developer/CoreSimulator/Devices", isDirectory: true)
    }

    public var devicesDirectory: URL
    /// `nil` = never run a tool; read the folders.
    public var runner: (any ProcessRunning)?
    public var timeout: TimeInterval = 20

    public init(devicesDirectory: URL? = nil, runner: (any ProcessRunning)? = ProcessRunner()) {
        self.devicesDirectory = devicesDirectory ?? Self.defaultDevicesDirectory
        self.runner = runner
    }

    public func listing() async -> Listing {
        guard let runner else { return Listing(devices: devicesFromFiles(), origin: .deviceFiles, issue: nil) }
        do {
            return Listing(devices: try await devicesFromSimctl(runner), origin: .simctl, issue: nil)
        } catch {
            let issue = error as? DabbiError ?? DabbiError(.internal, "simctl failed.", underlying: error)
            DabbiLog.logger(.locator).notice("simctl unavailable (\(issue.code.rawValue)); reading device folders")
            return Listing(devices: devicesFromFiles(), origin: .deviceFiles, issue: issue)
        }
    }

    // MARK: simctl

    func devicesFromSimctl(_ runner: any ProcessRunning) async throws -> [SimulatorDevice] {
        var arguments = ["simctl"]
        // The default set needs no naming, and naming it would make simctl treat it as a custom one.
        if devicesDirectory.standardizedFileURL != Self.defaultDevicesDirectory.standardizedFileURL {
            arguments += ["--set", devicesDirectory.path]
        }
        arguments += ["list", "-j", "devices"]
        let result = try await runner.run(ProcessRunner.xcrun, arguments: arguments, timeout: timeout)
        guard result.succeeded else {
            throw DabbiError(
                .toolUnavailable, "simctl could not list the simulators.",
                arguments: ["status": String(result.status)], diagnosis: [result.errorSummary].filter { !$0.isEmpty },
                recovery: ["Check that Xcode is installed and selected: `xcode-select -p`."])
        }
        return try Self.parseSimctl(result.standardOutput, devicesDirectory: devicesDirectory)
    }

    static func parseSimctl(_ json: Data, devicesDirectory: URL) throws -> [SimulatorDevice] {
        struct Output: Decodable {
            struct Device: Decodable {
                var udid: String
                var name: String
                var state: String?
                var isAvailable: Bool?
                var dataPath: String?
                var deviceTypeIdentifier: String?
                var lastBootedAt: String?
            }
            var devices: [String: [Device]]
        }
        let output: Output
        do {
            output = try JSONDecoder().decode(Output.self, from: json)
        } catch {
            throw DabbiError(
                .toolOutputUnreadable, "simctl answered with something that is not its usual JSON.",
                underlying: error)
        }
        let dates = ISO8601DateFormatter()
        return output.devices.flatMap { runtime, devices in
            devices.map { device in
                SimulatorDevice(
                    udid: device.udid, name: device.name, runtimeID: runtime,
                    deviceTypeID: device.deviceTypeIdentifier, state: .init(simctl: device.state ?? ""),
                    isAvailable: device.isAvailable ?? true,
                    dataURL: device.dataPath.map { URL(fileURLWithPath: $0, isDirectory: true) }
                        ?? devicesDirectory.appendingPathComponent("\(device.udid)/data", isDirectory: true),
                    lastBootedAt: device.lastBootedAt.flatMap(dates.date))
            }
        }
        .sorted(by: Self.browserOrder)
    }

    // MARK: Device folders

    func devicesFromFiles() -> [SimulatorDevice] {
        let folders =
            (try? FileManager.default.contentsOfDirectory(
                at: devicesDirectory, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles])) ?? []
        return folders.compactMap { folder -> SimulatorDevice? in
            guard let data = try? Data(contentsOf: folder.appendingPathComponent("device.plist")),
                let plist = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any],
                let udid = plist["UDID"] as? String, let name = plist["name"] as? String,
                plist["isDeleted"] as? Bool != true
            else { return nil }
            return SimulatorDevice(
                udid: udid, name: name, runtimeID: plist["runtime"] as? String ?? "",
                deviceTypeID: plist["deviceType"] as? String,
                state: .init(devicePlist: plist["state"] as? Int ?? 0),
                // Whether the runtime is still installed is simctl's to know.
                isAvailable: true,
                dataURL: folder.appendingPathComponent("data", isDirectory: true),
                lastBootedAt: plist["lastBootedAt"] as? Date)
        }
        .sorted(by: Self.browserOrder)
    }

    /// Runtimes newest first, then booted devices, then by name.
    static func browserOrder(_ lhs: SimulatorDevice, _ rhs: SimulatorDevice) -> Bool {
        if lhs.runtimeID != rhs.runtimeID { return SimulatorRuntime.precedes(lhs.runtimeID, rhs.runtimeID) }
        if (lhs.state == .booted) != (rhs.state == .booted) { return lhs.state == .booted }
        let order = lhs.name.localizedStandardCompare(rhs.name)
        return order == .orderedSame ? lhs.udid < rhs.udid : order == .orderedAscending
    }
}
