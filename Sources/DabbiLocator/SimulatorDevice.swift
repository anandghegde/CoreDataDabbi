import DabbiBase
import Foundation

/// One simulator, as the browser lists it (PRJ-8).
public struct SimulatorDevice: Sendable, Hashable, Identifiable, Codable {
    public enum State: String, Sendable, Hashable, Codable {
        case booted, shutdown, other

        /// `simctl` says “Booted”, `device.plist` says 3.
        init(simctl text: String) {
            switch text.lowercased() {
            case "booted": self = .booted
            case "shutdown": self = .shutdown
            default: self = .other
            }
        }

        init(devicePlist number: Int) {
            switch number {
            case 1: self = .shutdown
            case 3: self = .booted
            default: self = .other
            }
        }
    }

    public var udid: String
    public var name: String
    /// `com.apple.CoreSimulator.SimRuntime.iOS-17-5`.
    public var runtimeID: String
    /// `com.apple.CoreSimulator.SimDeviceType.iPhone-15`.
    public var deviceTypeID: String?
    public var state: State
    /// `false` when the runtime the device was made for is not installed any more. Its data is still there.
    public var isAvailable: Bool
    /// The device's `data` folder: the root of its file system.
    public var dataURL: URL
    public var lastBootedAt: Date?

    public var id: String { udid }

    public init(
        udid: String, name: String, runtimeID: String, deviceTypeID: String? = nil, state: State = .shutdown,
        isAvailable: Bool = true, dataURL: URL, lastBootedAt: Date? = nil
    ) {
        self.udid = udid
        self.name = name
        self.runtimeID = runtimeID
        self.deviceTypeID = deviceTypeID
        self.state = state
        self.isAvailable = isAvailable
        self.dataURL = dataURL
        self.lastBootedAt = lastBootedAt
    }

    /// What the browser groups by: “iOS 17.5”.
    public var runtimeName: String { SimulatorRuntime.displayName(of: runtimeID) }
}

public enum SimulatorRuntime {
    /// `com.apple.CoreSimulator.SimRuntime.iOS-17-5` → “iOS 17.5”; anything else is shown as it is.
    public static func displayName(of identifier: String) -> String {
        let prefix = "com.apple.CoreSimulator.SimRuntime."
        guard identifier.hasPrefix(prefix) else { return identifier }
        let parts = identifier.dropFirst(prefix.count).split(separator: "-")
        guard let platform = parts.first, parts.count > 1, parts.dropFirst().allSatisfy({ Int($0) != nil }) else {
            return String(identifier.dropFirst(prefix.count))
        }
        let name = platform == "xrOS" ? "visionOS" : String(platform)
        return "\(name) \(parts.dropFirst().joined(separator: "."))"
    }

    /// Newest first within a platform, platforms by name: the order of the browser's groups.
    public static func precedes(_ lhs: String, _ rhs: String) -> Bool {
        let (left, right) = (key(lhs), key(rhs))
        if left.platform != right.platform { return left.platform < right.platform }
        return right.version.lexicographicallyPrecedes(left.version)
    }

    private static func key(_ identifier: String) -> (platform: String, version: [Int]) {
        let name = displayName(of: identifier)
        guard let space = name.lastIndex(of: " ") else { return (name, []) }
        return (String(name[..<space]), name[name.index(after: space)...].split(separator: ".").compactMap { Int($0) })
    }
}

/// An app installed in a simulator, with the containers that belong to it.
public struct SimulatorApp: Sendable, Hashable, Identifiable, Codable {
    public var bundleID: String
    /// `CFBundleDisplayName`, else `CFBundleName`, else the bundle's file name.
    public var name: String
    public var version: String?
    /// The `.app`.
    public var bundleURL: URL
    public var dataContainerURL: URL?
    /// App Group containers the app is entitled to, by group identifier.
    public var groupContainers: [String: URL]
    /// The largest icon file the bundle names, for the browser's list.
    public var iconURL: URL?

    public var id: String { bundleID }

    public init(
        bundleID: String, name: String, version: String? = nil, bundleURL: URL, dataContainerURL: URL? = nil,
        groupContainers: [String: URL] = [:], iconURL: URL? = nil
    ) {
        self.bundleID = bundleID
        self.name = name
        self.version = version
        self.bundleURL = bundleURL
        self.dataContainerURL = dataContainerURL
        self.groupContainers = groupContainers
        self.iconURL = iconURL
    }

    /// Every container of the app, the data container first.
    public var containers: [(container: AppContainer, url: URL)] {
        var all: [(AppContainer, URL)] = []
        if let dataContainerURL { all.append((.data, dataContainerURL)) }
        all += groupContainers.sorted { $0.key < $1.key }.map { (.group($0.key), $0.value) }
        return all
    }
}

/// A database found in a container.
public struct StoreCandidate: Sendable, Hashable, Identifiable, Codable {
    public enum Kind: String, Sendable, Hashable, Codable {
        /// Has Core Data's bookkeeping tables.
        case coreData
        /// A Core Data store that SwiftData made: the app ships no compiled model (PRJ-11).
        case swiftData
        /// SQLite, but not Core Data's. Raw mode can show it.
        case plainSQLite
    }

    public var url: URL
    /// How a project remembers this store (PRJ-2).
    public var location: StoreLocation
    public var kind: Kind
    /// The main file plus `-wal` and `-shm`.
    public var byteCount: Int64
    /// The newest modification of the three files: the `-wal` is what changes while the app runs.
    public var modifiedAt: Date?

    public var id: URL { url }

    public init(url: URL, location: StoreLocation, kind: Kind, byteCount: Int64, modifiedAt: Date?) {
        self.url = url
        self.location = location
        self.kind = kind
        self.byteCount = byteCount
        self.modifiedAt = modifiedAt
    }
}
