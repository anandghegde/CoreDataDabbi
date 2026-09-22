import DabbiBase
import DabbiModel
import Foundation

/// What one simulator holds that the browser shows (PRJ-8): apps with stores, and stores in shared containers
/// that no app claims.
public struct SimulatorContents: Sendable, Hashable, Codable {
    public struct AppStores: Sendable, Hashable, Identifiable, Codable {
        public var app: SimulatorApp
        public var stores: [StoreCandidate]
        /// The app ships no compiled model: its stores are SwiftData's, and only their cached model can describe
        /// them (PRJ-11).
        public var usesSwiftData: Bool

        public var id: String { app.bundleID }

        public init(app: SimulatorApp, stores: [StoreCandidate], usesSwiftData: Bool) {
            self.app = app
            self.stores = stores
            self.usesSwiftData = usesSwiftData
        }
    }

    public var udid: String
    /// Apps that have at least one database, by name.
    public var apps: [AppStores]
    /// Databases in App Group containers no installed app is entitled to — or whose app's entitlements could
    /// not be read. They are remembered with an empty bundle ID; the group ID is what finds them again.
    public var sharedStores: [StoreCandidate]
    /// Apps installed, with or without databases.
    public var installedAppCount: Int
    /// `false` when a container was too large to walk to the end; there may be more stores than listed.
    public var isComplete: Bool
    public var scannedAt: Date

    public init(
        udid: String, apps: [AppStores] = [], sharedStores: [StoreCandidate] = [], installedAppCount: Int = 0,
        isComplete: Bool = true, scannedAt: Date = Date()
    ) {
        self.udid = udid
        self.apps = apps
        self.sharedStores = sharedStores
        self.installedAppCount = installedAppCount
        self.isComplete = isComplete
        self.scannedAt = scannedAt
    }

    /// Core Data and SwiftData stores only — what the browser lists unless asked for every database.
    public var storeCount: Int {
        (apps.flatMap(\.stores) + sharedStores).filter { $0.kind != .plainSQLite }.count
    }
}

/// The simulators on this Mac, their apps and their stores (§6.7).
///
/// The index is the memory; the looking is done off the actor, one device per task, so that thirty devices take
/// as long as the slowest of them and a caller asking for the device list never waits for a scan.
public actor SimulatorIndex {
    public let source: SimulatorDeviceSource
    public let sniffer: StoreSniffer

    private var listing: SimulatorDeviceSource.Listing?
    private var contents: [String: SimulatorContents] = [:]
    private var watcher: DirectoryWatcher?
    private var changeContinuations: [UUID: AsyncStream<Set<String>>.Continuation] = [:]

    public init(source: SimulatorDeviceSource = SimulatorDeviceSource(), sniffer: StoreSniffer = StoreSniffer()) {
        self.source = source
        self.sniffer = sniffer
    }

    // MARK: Devices

    /// The simulators, in the browser's order. Asked once, then remembered until `refresh`.
    public func devices(refresh: Bool = false) async -> SimulatorDeviceSource.Listing {
        if let listing, !refresh { return listing }
        let fresh = await source.listing()
        listing = fresh
        return fresh
    }

    // MARK: Contents

    /// The apps and stores of one device.
    public func contents(of device: SimulatorDevice, refresh: Bool = false) async -> SimulatorContents {
        if let known = contents[device.udid], !refresh { return known }
        let sniffer = sniffer
        let fresh = await Task.detached(priority: .userInitiated) { Self.scan(device, sniffer: sniffer) }.value
        contents[device.udid] = fresh
        return fresh
    }

    /// Every device's contents, each as soon as it is known. Booted devices go first: that is where the
    /// developer is working.
    public func scanAll(refresh: Bool = false, maxConcurrent: Int = 6) -> AsyncStream<SimulatorContents> {
        AsyncStream { continuation in
            let task = Task {
                let devices = await self.devices(refresh: refresh).devices
                    .sorted { ($0.state == .booted ? 0 : 1) < ($1.state == .booted ? 0 : 1) }
                await withTaskGroup(of: Void.self) { group in
                    var running = 0
                    for device in devices {
                        if running >= maxConcurrent {
                            await group.next()
                            running -= 1
                        }
                        running += 1
                        group.addTask {
                            guard !Task.isCancelled else { return }
                            continuation.yield(await self.contents(of: device, refresh: refresh))
                        }
                    }
                }
                continuation.finish()
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    /// Looks at one device. Blocking file work: call it off the main thread.
    public static func scan(_ device: SimulatorDevice, sniffer: StoreSniffer = StoreSniffer()) -> SimulatorContents {
        let map = ContainerMap(deviceData: device.dataURL)
        let apps = map.apps()
        var isComplete = true

        func stores(in root: URL, bundleID: String, container: AppContainer, swiftData: Bool) -> [StoreCandidate] {
            let walk = sniffer.databases(under: root)
            isComplete = isComplete && walk.isComplete
            return walk.databases.compactMap { url in
                guard let relativePath = Self.path(of: url, relativeTo: root) else { return nil }
                var kind = StoreSniffer.kind(of: url) ?? StoreSniffer.kindByContent(of: url)
                if kind == .coreData, swiftData { kind = .swiftData }
                let footprint = StoreSniffer.footprint(of: url)
                return StoreCandidate(
                    url: url,
                    location: .simulator(
                        udid: device.udid, bundleID: bundleID, container: container, relativePath: relativePath),
                    kind: kind, byteCount: footprint.byteCount, modifiedAt: footprint.modifiedAt)
            }
        }

        let appStores = apps.compactMap { app -> SimulatorContents.AppStores? in
            let usesSwiftData = SwiftDataConventions.shipsNoModel(app.bundleURL)
            let found = app.containers.flatMap {
                stores(in: $0.url, bundleID: app.bundleID, container: $0.container, swiftData: usesSwiftData)
            }
            guard !found.isEmpty else { return nil }
            return .init(app: app, stores: found, usesSwiftData: usesSwiftData)
        }
        let shared = map.unclaimedGroups(by: apps).sorted { $0.key < $1.key }.flatMap {
            stores(in: $0.value, bundleID: "", container: .group($0.key), swiftData: false)
        }
        return SimulatorContents(
            udid: device.udid, apps: appStores, sharedStores: shared, installedAppCount: apps.count,
            isComplete: isComplete, scannedAt: Date())
    }

    /// `url` below `root`, as the path a `StoreLocation` remembers.
    static func path(of url: URL, relativeTo root: URL) -> String? {
        let rootParts = root.resolvingSymlinksInPath().standardizedFileURL.pathComponents
        let parts = url.resolvingSymlinksInPath().standardizedFileURL.pathComponents
        guard parts.count > rootParts.count, Array(parts.prefix(rootParts.count)) == rootParts else { return nil }
        return parts.dropFirst(rootParts.count).joined(separator: "/")
    }

    // MARK: Resolving (PRJ-2, PRJ-12)

    /// The file a simulator location stands for today. The container's path is looked up anew every time: it
    /// changes whenever the app is reinstalled.
    public nonisolated func resolve(_ location: StoreLocation) throws -> URL {
        try StoreLocationResolver(devicesDirectory: source.devicesDirectory).resolve(location)
    }

    // MARK: Changes

    /// UDIDs of devices in whose containers something changed. The index has already forgotten what it knew
    /// about them; ask `contents(of:)` again. The first subscriber starts the watching.
    public func changes() -> AsyncStream<Set<String>> {
        let id = UUID()
        let (stream, continuation) = AsyncStream<Set<String>>.makeStream()
        changeContinuations[id] = continuation
        continuation.onTermination = { [weak self] _ in Task { await self?.unsubscribe(id) } }
        startWatching()
        return stream
    }

    private func unsubscribe(_ id: UUID) {
        changeContinuations[id] = nil
        if changeContinuations.isEmpty {
            watcher?.stop()
            watcher = nil
        }
    }

    private func startWatching() {
        guard watcher == nil else { return }
        let root = source.devicesDirectory.resolvingSymlinksInPath().standardizedFileURL
        watcher = DirectoryWatcher(root: root) { [weak self] folders in
            let udids = Self.udids(of: folders, under: root)
            Task { await self?.containersChanged(udids) }
        }
    }

    private func containersChanged(_ udids: Set<String>?) {
        // `nil`: events were dropped, or the device set itself changed.
        let affected = udids ?? Set(contents.keys)
        if udids == nil { listing = nil }
        guard !affected.isEmpty else { return }
        for udid in affected { contents[udid] = nil }
        for continuation in changeContinuations.values { continuation.yield(affected) }
    }

    /// The devices whose `data/Containers` the changed folders are in; `nil` when the root itself is among them.
    static func udids(of folders: [URL], under root: URL) -> Set<String>? {
        let rootParts = root.pathComponents
        var udids: Set<String> = []
        for folder in folders {
            let parts = folder.resolvingSymlinksInPath().standardizedFileURL.pathComponents
            if parts.count <= rootParts.count { return nil }
            guard Array(parts.prefix(rootParts.count)) == rootParts else { continue }
            let inside = parts.dropFirst(rootParts.count)
            // Devices/<udid>/data/Containers/…: the rest of a device is the system's business.
            if inside.count >= 3, Array(inside.dropFirst().prefix(2)) == ["data", "Containers"] {
                udids.insert(inside[inside.startIndex])
            }
        }
        return udids
    }
}
