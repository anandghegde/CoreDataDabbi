import DabbiKit
import Foundation

/// What the status capsule says (PRD §8.1): which store, read with which model, how.
struct StoreStatus: Equatable {
    enum Phase: Equatable { case none, opening, open, failed }

    var phase = Phase.none
    /// The store's name, as the project knows it.
    var title = String(localized: "No Store")
    /// Model source and access mode; empty until the store is open.
    var details: [String] = []
    /// Whose store it is, when the store is not simply a file the user picked: "iPhone 16 · org.example.notes".
    var origin: String?
    var storeURL: URL?
    /// Set when what is shown is a copy of the store (§6.2), made then.
    var workingCopyDate: Date?
    var readsCachedModel = false

    init() {}

    @MainActor
    init(context: ProjectContext) {
        if let name = context.project.store?.fileName { title = name }
        origin = context.locationOrigin
        switch context.storeState {
        case .none:
            phase = .none
        case .opening:
            phase = .opening
            details = [String(localized: "Opening…")]
        case .failed:
            phase = .failed
            details = [String(localized: "Not open")]
        case .open(let store):
            phase = .open
            storeURL = store.storeURL
            title = store.storeURL.lastPathComponent
            workingCopyDate = store.workingCopy?.createdAt
            let info = store.session.info
            readsCachedModel = info.modelSource == .storeCache
            details = [Self.label(for: info.modelSource), Self.label(for: info.accessMode)]
        }
    }

    /// What the capsule says after the store's name: where it came from first, then how it is being read.
    var line: [String] { origin.map { [$0] + details } ?? details }

    /// Whose store this is, for a store remembered by identity rather than by path (PRJ-2, PRJ-8). A simulator
    /// store's resolved path is a pair of UUIDs and says nothing; the device and the app say everything.
    ///
    /// `devices` is what this Mac has now: a device that is gone — deleted, or another Mac's — is named by the
    /// start of its UDID, which is at least what `simctl` prints.
    static func origin(of location: StoreLocation, devices: [SimulatorDevice]) -> String? {
        switch location {
        case .file:
            return nil
        case .simulator(let udid, let bundleID, let container, _):
            let device = devices.first { $0.udid == udid }?.name ?? String(udid.prefix(8))
            return [device, owner(bundleID: bundleID, container: container)].joined(separator: " · ")
        case .macApp(let bundleID, let container, _):
            return [String(localized: "This Mac"), owner(bundleID: bundleID, container: container)]
                .joined(separator: " · ")
        case .container(let reference, _):
            return reference.lastKnownURL.deletingPathExtension().lastPathComponent
        case .devicePull(let deviceID, let bundleID, _):
            let device = deviceID.isEmpty ? String(localized: "Device") : String(deviceID.prefix(8))
            return [device, bundleID].joined(separator: " · ")
        }
    }

    /// The app a store belongs to, or the group container it sits in when no app claims it.
    private static func owner(bundleID: String, container: AppContainer) -> String {
        if !bundleID.isEmpty { return bundleID }
        if case .group(let identifier) = container { return identifier }
        return String(localized: "Unknown App")
    }

    /// The short forms PRJ-3 asks for; the long one is `ModelSource.summary`.
    static func label(for source: ModelSource) -> String {
        switch source {
        case .storeCache: String(localized: "Cached model")
        case .appBundle: String(localized: "App bundle model")
        case .userSelected: String(localized: "Model file")
        }
    }

    static func label(for mode: AccessMode) -> String {
        switch mode {
        case .readOnly: String(localized: "Read-only")
        case .editable: String(localized: "Editable")
        }
    }
}
