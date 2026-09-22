import DabbiLocator
import FixtureKit
import Foundation

/// A CoreSimulator device set made of nothing but folders and property lists, laid out like the real thing.
///
/// No simulator has to be installed — CI has none with apps in them — and a test can put a device into any
/// state it likes: an app without data, a container whose metadata is gone, a store without its `-shm`.
public struct SyntheticDeviceSet {
    public let root: URL

    public init() throws {
        let folder = TestFixtures.root.appendingPathComponent("devices-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        // The temporary directory is behind a symlink (/var → /private/var), and listing a folder gives real
        // paths: start from the real one, so that what goes in compares equal to what comes out.
        root = URL(fileURLWithPath: try Self.realPath(of: folder), isDirectory: true)
    }

    public struct Device {
        public let udid: String
        public let folder: URL
        public var data: URL { folder.appendingPathComponent("data", isDirectory: true) }
        public var containers: URL { data.appendingPathComponent("Containers", isDirectory: true) }

        public var simulatorDevice: SimulatorDevice {
            SimulatorDevice(udid: udid, name: "Synthetic", runtimeID: SyntheticDeviceSet.iOS17, dataURL: data)
        }
    }

    public static let iOS17 = "com.apple.CoreSimulator.SimRuntime.iOS-17-5"
    public static let iOS18 = "com.apple.CoreSimulator.SimRuntime.iOS-18-2"

    @discardableResult
    public func addDevice(
        udid: String = UUID().uuidString, name: String = "iPhone 15", runtime: String = iOS17, booted: Bool = false,
        isDeleted: Bool = false
    ) throws -> Device {
        let device = Device(udid: udid, folder: root.appendingPathComponent(udid, isDirectory: true))
        try FileManager.default.createDirectory(at: device.containers, withIntermediateDirectories: true)
        var plist: [String: Any] = [
            "UDID": udid, "name": name, "runtime": runtime, "state": booted ? 3 : 1,
            "deviceType": "com.apple.CoreSimulator.SimDeviceType.iPhone-15",
        ]
        if isDeleted { plist["isDeleted"] = true }
        try Self.write(plist, to: device.folder.appendingPathComponent("device.plist"))
        return device
    }

    public struct App {
        public let bundleID: String
        public let bundle: URL
        public let dataContainer: URL?
    }

    /// Installs a fake app: a bundle container with an `Info.plist`, and — unless the app "never ran" — a data
    /// container. `executable` is copied in as the app's binary, for the entitlements.
    @discardableResult
    public func install(
        _ bundleID: String, name: String, on device: Device, executable: URL? = nil, hasData: Bool = true,
        writesMetadata: Bool = true
    ) throws -> App {
        let files = FileManager.default
        let bundleContainer = device.containers.appendingPathComponent("Bundle/Application/\(UUID().uuidString)")
        let bundle = bundleContainer.appendingPathComponent("\(name).app", isDirectory: true)
        try files.createDirectory(at: bundle, withIntermediateDirectories: true)
        try Self.write(
            [
                "CFBundleIdentifier": bundleID, "CFBundleName": name, "CFBundleExecutable": name,
                "CFBundleShortVersionString": "1.2",
            ], to: bundle.appendingPathComponent("Info.plist"))
        if let executable {
            try files.copyItem(at: executable, to: bundle.appendingPathComponent(name))
        } else {
            try Data("#!/bin/sh\n".utf8).write(to: bundle.appendingPathComponent(name))
        }
        if writesMetadata { try Self.writeMetadata(bundleID, in: bundleContainer) }

        var dataContainer: URL?
        if hasData {
            let container = device.containers.appendingPathComponent("Data/Application/\(UUID().uuidString)")
            try files.createDirectory(
                at: container.appendingPathComponent("Library/Application Support"), withIntermediateDirectories: true)
            try Self.writeMetadata(bundleID, in: container)
            dataContainer = container
        }
        return App(bundleID: bundleID, bundle: bundle, dataContainer: dataContainer)
    }

    @discardableResult
    public func addGroup(_ groupID: String, on device: Device) throws -> URL {
        let container = device.containers.appendingPathComponent("Shared/AppGroup/\(UUID().uuidString)")
        try FileManager.default.createDirectory(
            at: container.appendingPathComponent("Library/Application Support"), withIntermediateDirectories: true)
        try Self.writeMetadata(groupID, in: container)
        return container
    }

    /// Puts a fixture's store (and whatever side files it has) at `relativePath` of a container.
    @discardableResult
    public static func place(_ fixture: Fixture, at relativePath: String, in container: URL) throws -> URL {
        let source = try TestFixtures.location(fixture).storeURL
        let destination = container.appendingPathComponent(relativePath)
        try FileManager.default.createDirectory(
            at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
        for suffix in ["", "-wal", "-shm"] where FileManager.default.fileExists(atPath: source.path + suffix) {
            try FileManager.default.copyItem(atPath: source.path + suffix, toPath: destination.path + suffix)
        }
        return destination
    }

    public static func realPath(of url: URL) throws -> String {
        guard let resolved = realpath(url.path, nil) else { throw CocoaError(.fileNoSuchFile) }
        defer { free(resolved) }
        return String(cString: resolved)
    }

    public static func writeMetadata(_ identifier: String, in container: URL) throws {
        try write(
            ["MCMMetadataIdentifier": identifier, "MCMMetadataContentClass": 2],
            to: container.appendingPathComponent(".com.apple.mobile_container_manager.metadata.plist"))
    }

    public static func write(_ plist: [String: Any], to url: URL) throws {
        try PropertyListSerialization.data(fromPropertyList: plist, format: .binary, options: 0).write(to: url)
    }
}
