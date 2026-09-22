import DabbiKit
import Foundation
import Observation

/// The simulator browser's state: which devices this Mac has, what they hold, and what the filters leave of it
/// (PRJ-8).
///
/// Devices arrive first and stores afterwards, one device at a time, because a scan walks containers: the list
/// is usable while the slowest device is still being looked at.
@MainActor
@Observable
final class SimulatorBrowserModel {
    /// Devices that share a runtime — "iOS 17.5", the browser's sections.
    struct RuntimeGroup: Identifiable {
        var runtimeID: String
        var name: String
        var devices: [SimulatorDevice]

        var id: String { runtimeID }
    }

    /// One app of the selected device, with the stores of it the filters let through. An app group container
    /// that no installed app claims has no `app`: the group ID is all that is known of it.
    struct AppRow: Identifiable {
        var app: SimulatorApp?
        var usesSwiftData: Bool
        var stores: [StoreCandidate]

        var id: String { app?.bundleID ?? "" }
        var name: String { app?.name ?? String(localized: "Shared App Groups") }
        var bundleID: String? { app?.bundleID }
    }

    /// How many devices are scanned at once. Walking a container is mostly waiting on the file system, and six
    /// keeps a Mac with thirty devices busy without drowning it.
    static let maxConcurrentScans = 6

    private let source: any SimulatorBrowsing
    /// What opening a store does. The window controller makes it a project; the tests just remember it.
    @ObservationIgnored var openStore: (StoreLocation) -> Void

    private(set) var devices: [SimulatorDevice] = []
    private(set) var origin: SimulatorDeviceSource.Origin?
    /// Why the device list is the folders' word rather than `simctl`'s, when it is.
    private(set) var listingIssue: DabbiError?
    private(set) var contents: [String: SimulatorContents] = [:]
    /// Devices being walked right now, so that a device says "Looking…" rather than "No stores".
    private(set) var scanning: Set<String> = []
    private(set) var isLoadingDevices = false

    var search = "" {
        didSet { if search != oldValue { keepSelectionVisible() } }
    }
    var bootedOnly = false {
        didSet { if bootedOnly != oldValue { keepSelectionVisible() } }
    }
    /// SQLite databases that are not Core Data's — caches, third-party libraries. Off by default: the browser is
    /// for stores, and raw mode (PRJ-13) is what the rest are for.
    var showsOtherDatabases = false
    var selectedDevice: String?

    @ObservationIgnored private var loadTask: Task<Void, Never>?
    @ObservationIgnored private var scanTask: Task<Void, Never>?
    @ObservationIgnored private var watchTask: Task<Void, Never>?

    init(source: any SimulatorBrowsing, open: @escaping (StoreLocation) -> Void) {
        self.source = source
        self.openStore = open
    }

    // MARK: Reading

    /// Lists the devices, then looks inside them. `refresh` asks both again; otherwise the index answers from
    /// what it knows, which is what makes reopening the window instant.
    func load(refresh: Bool = false) {
        loadTask?.cancel()
        scanTask?.cancel()
        isLoadingDevices = true
        loadTask = Task { [weak self] in
            guard let self else { return }
            let listing = await self.source.devices(refresh: refresh)
            guard !Task.isCancelled else { return }
            self.devices = listing.devices.sorted(by: Self.precedes)
            self.origin = listing.origin
            self.listingIssue = listing.issue
            self.isLoadingDevices = false
            if refresh { self.contents = [:] }
            self.keepSelectionVisible()
            self.scan(self.devices, refresh: refresh)
        }
    }

    /// Watches for containers changing — the app under test saving, or being reinstalled — and looks at those
    /// devices again (§6.7). Started by the window, so that a closed browser watches nothing.
    func watchForChanges() {
        guard watchTask == nil else { return }
        watchTask = Task { [weak self] in
            guard let stream = await self?.source.changes() else { return }
            for await changed in stream {
                guard let self else { return }
                let devices = self.devices.filter { changed.contains($0.udid) }
                self.scan(devices, refresh: true)
            }
        }
    }

    func stopWatching() {
        watchTask?.cancel()
        watchTask = nil
    }

    private func scan(_ devices: [SimulatorDevice], refresh: Bool) {
        guard !devices.isEmpty else { return }
        // Booted first: that is the device the developer is working on.
        let ordered = devices.sorted { ($0.state == .booted ? 0 : 1) < ($1.state == .booted ? 0 : 1) }
        for device in ordered where contents[device.udid] == nil || refresh {
            scanning.insert(device.udid)
        }
        let previous = scanTask
        scanTask = Task { [weak self] in
            // One scan pass at a time, so that a refresh arriving mid-walk does not double the work.
            await previous?.value
            guard let self, !Task.isCancelled else { return }
            await withTaskGroup(of: (String, SimulatorContents).self) { group in
                var running = 0
                for device in ordered {
                    if running >= Self.maxConcurrentScans {
                        if let (udid, found) = await group.next() {
                            self.received(found, for: udid)
                        }
                        running -= 1
                    }
                    running += 1
                    group.addTask { [source = self.source] in
                        (device.udid, await source.contents(of: device, refresh: refresh))
                    }
                }
                for await (udid, found) in group {
                    self.received(found, for: udid)
                }
            }
        }
    }

    private func received(_ found: SimulatorContents, for udid: String) {
        contents[udid] = found
        scanning.remove(udid)
        keepSelectionVisible()
    }

    /// Returns once the devices are listed and every scan in flight has landed. For the tests.
    func whenSettled() async {
        await loadTask?.value
        await scanTask?.value
    }

    // MARK: What the browser shows

    /// The devices the filters leave, grouped by runtime, newest runtime first.
    var groups: [RuntimeGroup] {
        let visible = devices.filter(matches)
        let byRuntime = Dictionary(grouping: visible, by: \.runtimeID)
        return byRuntime.keys.sorted(by: SimulatorRuntime.precedes).map { runtimeID in
            RuntimeGroup(
                runtimeID: runtimeID, name: SimulatorRuntime.displayName(of: runtimeID),
                devices: (byRuntime[runtimeID] ?? []).sorted(by: Self.precedes))
        }
    }

    var visibleDevices: [SimulatorDevice] { groups.flatMap(\.devices) }

    var device: SimulatorDevice? { devices.first { $0.udid == selectedDevice } }

    /// The apps of the selected device that have stores the filters let through, and the shared containers after
    /// them.
    var appRows: [AppRow] {
        guard let device, let found = contents[device.udid] else { return [] }
        var rows = found.apps.compactMap { entry -> AppRow? in
            let stores = entry.stores.filter { self.shows($0, of: entry.app) }
            guard !stores.isEmpty else { return nil }
            return AppRow(app: entry.app, usesSwiftData: entry.usesSwiftData, stores: stores)
        }
        let shared = found.sharedStores.filter { self.shows($0, of: nil) }
        if !shared.isEmpty { rows.append(AppRow(app: nil, usesSwiftData: false, stores: shared)) }
        return rows
    }

    func isScanning(_ device: SimulatorDevice) -> Bool { scanning.contains(device.udid) }

    /// How many stores a device has, as the sidebar counts them: `nil` while it has not been looked at.
    func storeCount(of device: SimulatorDevice) -> Int? {
        guard let found = contents[device.udid] else { return nil }
        return found.apps.reduce(0) { $0 + $1.stores.filter { store in self.shows(store, of: nil) }.count }
            + found.sharedStores.filter { self.shows($0, of: nil) }.count
    }

    /// Apps installed on a device, stores or no stores: what says "four apps, none of them saves anything".
    func installedAppCount(of device: SimulatorDevice) -> Int? { contents[device.udid]?.installedAppCount }

    /// `true` when a container was too large to walk to the end: there may be stores the browser is not showing.
    func isComplete(_ device: SimulatorDevice) -> Bool { contents[device.udid]?.isComplete ?? true }

    // MARK: Filtering

    private func shows(_ store: StoreCandidate, of app: SimulatorApp?) -> Bool {
        guard showsOtherDatabases || store.kind != .plainSQLite else { return false }
        guard !query.isEmpty else { return true }
        if store.url.lastPathComponent.localizedCaseInsensitiveContains(query) { return true }
        // A search for an app shows all of its stores; searching for a device shows everything on it.
        return app.map(matches) ?? false
    }

    private func matches(_ app: SimulatorApp) -> Bool {
        query.isEmpty || app.name.localizedCaseInsensitiveContains(query)
            || app.bundleID.localizedCaseInsensitiveContains(query)
    }

    /// A device is shown when it is the kind asked for and something about it matches the search: its own name,
    /// or an app or a store it holds. A device not yet looked at stays until its scan says otherwise.
    private func matches(_ device: SimulatorDevice) -> Bool {
        guard !bootedOnly || device.state == .booted else { return false }
        guard !query.isEmpty else { return true }
        if device.name.localizedCaseInsensitiveContains(query) { return true }
        if device.runtimeName.localizedCaseInsensitiveContains(query) { return true }
        guard let found = contents[device.udid] else { return true }
        return found.apps.contains { entry in
            matches(entry.app) || entry.stores.contains { shows($0, of: entry.app) }
        } || found.sharedStores.contains { shows($0, of: nil) }
    }

    private var query: String { search.trimmingCharacters(in: .whitespaces) }

    /// Keeps a device selected where the filters leave one, and lets go of one they hide.
    private func keepSelectionVisible() {
        let visible = visibleDevices
        if let selectedDevice, visible.contains(where: { $0.udid == selectedDevice }) { return }
        selectedDevice = visible.first?.udid
    }

    /// Booted devices first — then the most recently used, and names for the rest.
    private static func precedes(_ lhs: SimulatorDevice, _ rhs: SimulatorDevice) -> Bool {
        if (lhs.state == .booted) != (rhs.state == .booted) { return lhs.state == .booted }
        switch (lhs.lastBootedAt, rhs.lastBootedAt) {
        case (let left?, let right?) where left != right: return left > right
        case (nil, .some): return false
        case (.some, nil): return true
        default: return lhs.name.localizedStandardCompare(rhs.name) == .orderedAscending
        }
    }

    // MARK: What the user does

    func open(_ store: StoreCandidate) {
        openStore(store.location)
    }
}
