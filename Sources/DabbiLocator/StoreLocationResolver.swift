import DabbiBase
import Foundation

/// Turns a `StoreLocation` — what a project remembers — into the file it stands for today (PRJ-2, PRJ-12).
///
/// Simulator and Mac-app locations are identities, so resolving them is a lookup that succeeds again after a
/// reinstall moved the container. When it fails the error says how far the lookup got — device, app, container,
/// file — because that is exactly what Project Settings has to show.
public struct StoreLocationResolver: Sendable {
    public var devicesDirectory: URL
    public var homeDirectory: URL
    /// Bookmarks are the project's machine-local state; whoever holds it resolves them. Without one the last
    /// known path has to do.
    public var fileResolver: @Sendable (FileReference) -> URL?

    public init(
        devicesDirectory: URL? = nil, homeDirectory: URL? = nil,
        fileResolver: @escaping @Sendable (FileReference) -> URL? = { $0.lastKnownURL }
    ) {
        self.devicesDirectory = devicesDirectory ?? SimulatorDeviceSource.defaultDevicesDirectory
        self.homeDirectory = homeDirectory ?? FileManager.default.homeDirectoryForCurrentUser
        self.fileResolver = fileResolver
    }

    public func resolve(_ location: StoreLocation) throws -> URL {
        switch location {
        case .file(let reference):
            guard let url = fileResolver(reference) else {
                throw Self.unresolved(
                    "The store file cannot be found.", ["It was last seen at \(reference.lastKnownPath)."],
                    recovery: ["Choose the file again in Project Settings."])
            }
            return try existing(url, saying: "It was last seen at \(reference.lastKnownPath).")

        case .container(let reference, let relativePath):
            guard let root = fileResolver(reference) else {
                throw Self.unresolved(
                    "The app container cannot be found.", ["It was last seen at \(reference.lastKnownPath)."],
                    recovery: ["Choose the .xcappdata again in Project Settings."])
            }
            // An .xcappdata keeps the data container under AppData.
            let appData = root.appendingPathComponent("AppData", isDirectory: true)
            let base = FileManager.default.fileExists(atPath: appData.path) ? appData : root
            return try existing(
                try Self.descend(from: base, along: relativePath), saying: "Looked inside \(root.lastPathComponent).")

        case .simulator(let udid, let bundleID, let container, let relativePath):
            return try simulatorStore(udid: udid, bundleID: bundleID, container: container, relativePath: relativePath)

        case .macApp(let bundleID, let container, let relativePath):
            let library = homeDirectory.appendingPathComponent("Library", isDirectory: true)
            let root: URL
            switch container {
            case .group(let group):
                root = library.appendingPathComponent("Group Containers/\(group)", isDirectory: true)
            case .data:
                let sandbox = library.appendingPathComponent("Containers/\(bundleID)/Data", isDirectory: true)
                // An app without a sandbox keeps its files in the home folder itself.
                root = FileManager.default.fileExists(atPath: sandbox.path) ? sandbox : homeDirectory
            }
            return try existing(try Self.descend(from: root, along: relativePath), saying: "Looked in \(root.path).")

        case .devicePull(let deviceID, let bundleID, _):
            throw Self.unresolved(
                "Stores pulled from a device are not kept between sessions yet.",
                ["Device \(deviceID), app \(bundleID)."], recovery: ["Pull the app's container again."])
        }
    }

    // MARK: Simulators

    private func simulatorStore(
        udid: String, bundleID: String, container: AppContainer, relativePath: String
    ) throws -> URL {
        // A UDID is a folder name here; one with a slash in it is not a UDID.
        guard !udid.isEmpty, !udid.contains("/"), udid != "..", udid != "." else {
            throw Self.unresolved("“\(udid)” is not a simulator identifier.", [])
        }
        let data = devicesDirectory.appendingPathComponent("\(udid)/data", isDirectory: true)
        guard FileManager.default.fileExists(atPath: data.path) else {
            throw Self.unresolved(
                "The simulator this store was in does not exist any more.",
                ["Looked for simulator \(udid) in \(devicesDirectory.path)."],
                recovery: ["Pick the app again from the simulator browser."])
        }

        let map = ContainerMap(deviceData: data)
        let root: URL
        switch container {
        case .data:
            guard let found = map.dataContainers[bundleID] else {
                let installed = map.bundles[bundleID] != nil
                throw Self.unresolved(
                    installed
                        ? "\(bundleID) is installed in the simulator, but has no data yet."
                        : "\(bundleID) is not installed in the simulator any more.",
                    ["Simulator \(udid) has no data container for \(bundleID)."],
                    recovery: [
                        installed ? "Run the app once, so that it creates its store." : "Install and run the app again."
                    ])
            }
            root = found
        case .group(let group):
            guard let found = map.groupContainers[group] else {
                throw Self.unresolved(
                    "The App Group \(group) has no container in the simulator.",
                    ["Simulator \(udid) has no shared container for \(group)."],
                    recovery: ["Run the app once, so that it creates its store."])
            }
            root = found
        }
        return try existing(
            try Self.descend(from: root, along: relativePath),
            saying: "The app's container was found at \(root.path), but the store is not in it.",
            recovery: ["Run the app once, so that it creates its store."])
    }

    // MARK: Paths

    /// `root` + `relativePath`, which comes from a project file and must not lead out of `root`.
    static func descend(from root: URL, along relativePath: String) throws -> URL {
        let parts = relativePath.split(separator: "/", omittingEmptySubsequences: true).map(String.init)
        guard !parts.isEmpty, !parts.contains(".."), !parts.contains(".") else {
            throw unresolved("“\(relativePath)” is not a path inside a container.", [])
        }
        return parts.reduce(root) { $0.appendingPathComponent($1) }
    }

    private func existing(_ url: URL, saying detail: String, recovery: [String] = []) throws -> URL {
        guard FileManager.default.fileExists(atPath: url.path) else {
            throw Self.unresolved(
                "\(url.lastPathComponent) is not where it was.", [detail, "Looked for \(url.path)."],
                recovery: recovery)
        }
        return url
    }

    static func unresolved(_ message: String, _ diagnosis: [String], recovery: [String] = []) -> DabbiError {
        DabbiError(.locationUnresolved, message, diagnosis: diagnosis, recovery: recovery)
    }
}
