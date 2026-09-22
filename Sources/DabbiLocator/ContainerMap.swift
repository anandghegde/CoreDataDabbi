import DabbiBase
import Foundation

/// Which folder under a simulator's `data/Containers` belongs to whom (§6.7).
///
/// Containers are named by UUIDs that change on every reinstall; what ties one to an app is the metadata file
/// the container manager writes into each: `MCMMetadataIdentifier` is the bundle ID (bundle and data
/// containers) or the group ID (shared ones). That file is CoreSimulator's, not API — when it cannot be read a
/// bundle container still identifies itself through the app's `Info.plist`, and the rest is simply not mapped.
public struct ContainerMap: Sendable, Hashable {
    static let metadataFileName = ".com.apple.mobile_container_manager.metadata.plist"

    /// The `.app` of every installed app, by bundle ID.
    public var bundles: [String: URL] = [:]
    /// Data containers by bundle ID.
    public var dataContainers: [String: URL] = [:]
    /// App Group containers by group ID.
    public var groupContainers: [String: URL] = [:]

    public init() {}

    /// Reads the three container folders of the device whose file system starts at `dataURL`.
    public init(deviceData dataURL: URL) {
        let containers = dataURL.appendingPathComponent("Containers", isDirectory: true)

        for folder in Self.folders(in: containers.appendingPathComponent("Bundle/Application")) {
            guard let app = Self.folders(in: folder).first(where: { $0.pathExtension == "app" }) else { continue }
            guard let bundleID = Self.identifier(of: folder) ?? BundleInfo(bundle: app)?.bundleID else { continue }
            bundles[bundleID] = Self.newer(app, than: bundles[bundleID])
        }
        for folder in Self.folders(in: containers.appendingPathComponent("Data/Application")) {
            guard let bundleID = Self.identifier(of: folder) else { continue }
            dataContainers[bundleID] = Self.newer(folder, than: dataContainers[bundleID])
        }
        for folder in Self.folders(in: containers.appendingPathComponent("Shared/AppGroup")) {
            guard let groupID = Self.identifier(of: folder) else { continue }
            groupContainers[groupID] = Self.newer(folder, than: groupContainers[groupID])
        }
    }

    /// The installed apps, by name. `entitlements` is asked once per app; it is a parameter so that the index
    /// can cache what it read from a binary that has not changed.
    public func apps(entitlements: (URL) -> AppEntitlements? = MachOEntitlements.read(appBundle:)) -> [SimulatorApp] {
        bundles.compactMap { bundleID, bundleURL -> SimulatorApp? in
            let info = BundleInfo(bundle: bundleURL)
            let groups = entitlements(bundleURL)?.applicationGroups ?? []
            return SimulatorApp(
                bundleID: bundleID, name: info?.displayName ?? bundleURL.deletingPathExtension().lastPathComponent,
                version: info?.version, bundleURL: bundleURL, dataContainerURL: dataContainers[bundleID],
                groupContainers: Dictionary(
                    groups.compactMap { group in groupContainers[group].map { (group, $0) } },
                    uniquingKeysWith: { first, _ in first }),
                iconURL: info?.iconURL)
        }
        .sorted {
            let order = $0.name.localizedStandardCompare($1.name)
            return order == .orderedSame ? $0.bundleID < $1.bundleID : order == .orderedAscending
        }
    }

    /// Group containers no installed app claims: the app was built without readable entitlements, or is gone.
    public func unclaimedGroups(by apps: [SimulatorApp]) -> [String: URL] {
        let claimed = Set(apps.flatMap { $0.groupContainers.keys })
        return groupContainers.filter { !claimed.contains($0.key) }
    }

    // MARK: Reading

    static func identifier(of container: URL) -> String? {
        guard let data = try? Data(contentsOf: container.appendingPathComponent(metadataFileName)),
            let plist = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any],
            let identifier = plist["MCMMetadataIdentifier"] as? String, !identifier.isEmpty
        else { return nil }
        return identifier
    }

    private static func folders(in url: URL) -> [URL] {
        let contents =
            (try? FileManager.default.contentsOfDirectory(
                at: url, includingPropertiesForKeys: [.isDirectoryKey], options: [])) ?? []
        return contents.filter { (try? $0.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true }
    }

    /// A reinstall can leave the old container behind for a while; the one changed last is the live one.
    private static func newer(_ candidate: URL, than current: URL?) -> URL {
        guard let current else { return candidate }
        func modified(_ url: URL) -> Date {
            (try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
        }
        return modified(candidate) > modified(current) ? candidate : current
    }
}
