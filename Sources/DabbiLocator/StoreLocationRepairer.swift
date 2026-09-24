import DabbiBase
import Foundation

/// Somewhere a store that is not where its project says may be now (PRJ-12).
public struct StoreRepair: Sendable, Hashable, Identifiable {
    public enum Reason: Sendable, Hashable {
        /// The same app's store, at the same path, on another simulator. The one the project names is gone, or
        /// the app is no longer on it: a new simulator, or the store of the same app on a sibling device.
        case otherDevice
        /// The same app on the same simulator has a store at another path in its container: the app renamed or
        /// moved it.
        case elsewhereInContainer
        /// A store in the folder the project's file used to be in.
        case sameFolder
    }

    /// What the project should point at from now on. `nil` for a plain file, which the project remembers by
    /// bookmark: whoever keeps the bookmarks adopts `url`.
    public var location: StoreLocation?
    /// The store file, today.
    public var url: URL
    public var reason: Reason
    /// The simulator the store is on, for a simulator location.
    public var device: SimulatorDevice?
    public var modifiedAt: Date?

    public var id: URL { url }

    public init(
        location: StoreLocation?, url: URL, reason: Reason, device: SimulatorDevice? = nil, modifiedAt: Date? = nil
    ) {
        self.location = location
        self.url = url
        self.reason = reason
        self.device = device
        self.modifiedAt = modifiedAt
    }
}

/// Looks for a store its project has lost (PRJ-12).
///
/// A simulator location already survives a reinstall — the resolver looks its container up by bundle ID every
/// time — so what is left to repair is what the resolver cannot know: the simulator was deleted and the app
/// runs on another one now, or the app keeps its store under another name. Nothing here changes a project; the
/// suggestions are for the user to pick from, because a store on another device is another store.
///
/// Blocking file work: call it off the main thread.
public struct StoreLocationRepairer: Sendable {
    public var devicesDirectory: URL
    public var sniffer: StoreSniffer

    public init(devicesDirectory: URL? = nil, sniffer: StoreSniffer = StoreSniffer()) {
        self.devicesDirectory = devicesDirectory ?? SimulatorDeviceSource.defaultDevicesDirectory
        self.sniffer = sniffer
    }

    /// The likeliest first: the same device before another one, the same file name before another, the most
    /// recently written before the rest. Empty when there is nothing to suggest — or nothing to repair.
    public func suggestions(for location: StoreLocation) -> [StoreRepair] {
        let found: [(rank: Int, repair: StoreRepair)]
        switch location {
        case .simulator(let udid, let bundleID, let container, let relativePath):
            found = simulatorSuggestions(
                udid: udid, bundleID: bundleID, container: container, relativePath: relativePath)
        case .file(let reference):
            found = folderSuggestions(for: reference.lastKnownURL)
        case .macApp, .container, .devicePull:
            found = []
        }
        return found.sorted {
            if $0.rank != $1.rank { return $0.rank < $1.rank }
            return ($0.repair.modifiedAt ?? .distantPast) > ($1.repair.modifiedAt ?? .distantPast)
        }
        .map(\.repair)
    }

    // MARK: Simulators

    private func simulatorSuggestions(
        udid: String, bundleID: String, container: AppContainer, relativePath: String
    ) -> [(rank: Int, repair: StoreRepair)] {
        let fileName = (relativePath as NSString).lastPathComponent
        let devices = SimulatorDeviceSource(devicesDirectory: devicesDirectory).devicesFromFiles()
        var found: [(rank: Int, repair: StoreRepair)] = []

        for device in devices {
            let map = ContainerMap(deviceData: device.dataURL)
            let root: URL?
            switch container {
            case .data: root = map.dataContainers[bundleID]
            case .group(let group): root = map.groupContainers[group]
            }
            guard let root else { continue }

            func suggest(_ url: URL, at path: String, reason: StoreRepair.Reason, rank: Int) {
                let location = StoreLocation.simulator(
                    udid: device.udid, bundleID: bundleID, container: container, relativePath: path)
                let repair = StoreRepair(
                    location: location, url: url, reason: reason, device: device,
                    modifiedAt: StoreSniffer.footprint(of: url).modifiedAt)
                found.append((rank, repair))
            }

            if device.udid == udid {
                // The container is there and the store is not: whatever else the app keeps in it.
                let original = (try? StoreLocationResolver.descend(from: root, along: relativePath))?
                    .standardizedFileURL
                for url in sniffer.databases(under: root).databases where url.standardizedFileURL != original {
                    guard let path = SimulatorIndex.path(of: url, relativeTo: root) else { continue }
                    let rank = url.lastPathComponent == fileName ? 0 : 2
                    suggest(url, at: path, reason: .elsewhereInContainer, rank: rank)
                }
            } else if let url = try? StoreLocationResolver.descend(from: root, along: relativePath),
                FileManager.default.fileExists(atPath: url.path)
            {
                suggest(url, at: relativePath, reason: .otherDevice, rank: 1)
            }
        }
        return found
    }

    // MARK: Files

    /// Stores next to where the file was — only there: a folder's subfolders are somebody else's business.
    private func folderSuggestions(for lastKnown: URL) -> [(rank: Int, repair: StoreRepair)] {
        let folder = lastKnown.deletingLastPathComponent()
        var shallow = sniffer
        shallow.maxDepth = 1
        return shallow.databases(under: folder).databases
            .filter { $0.standardizedFileURL != lastKnown.standardizedFileURL }
            .map { url in
                let repair = StoreRepair(
                    location: nil, url: url, reason: .sameFolder, modifiedAt: StoreSniffer.footprint(of: url).modifiedAt
                )
                return (url.pathExtension == lastKnown.pathExtension ? 3 : 4, repair)
            }
    }
}
