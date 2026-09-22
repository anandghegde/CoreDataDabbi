import DabbiKit
import Foundation
import Observation

/// The welcome window's state (PRJ-16): the ways into a store, what was opened recently, and what a dropped
/// file turns out to hold.
@MainActor
@Observable
final class WelcomeModel {
    /// Something opened before, as the list shows it. A recent that is no longer where it was stays on the
    /// list — the File menu keeps it too — and says so rather than disappearing.
    struct Recent: Identifiable, Equatable {
        var url: URL
        var isProject: Bool
        var isMissing: Bool

        var id: URL { url }
        /// Projects are named by their file; a store keeps its extension, because `Model.sqlite` and `data` are
        /// both names a store really has (PRJ-15).
        var name: String {
            isProject ? url.deletingPathExtension().lastPathComponent : url.lastPathComponent
        }
        var folder: String {
            (url.deletingLastPathComponent().path as NSString).abbreviatingWithTildeInPath
        }
    }

    /// What the window can ask the app to do. The window controller fills these in; the tests watch them.
    struct Actions {
        var open: (URL) -> Void = { _ in }
        var openDatabase: () -> Void = {}
        var openProject: () -> Void = {}
        var browseSimulators: () -> Void = {}
    }

    /// How deep a dropped folder is searched, and how many stores are opened from one drop. A drop is one
    /// gesture, and a gesture that opens a dozen windows is not what anyone meant by it.
    static let maxStoresPerDrop = 8

    private(set) var recents: [Recent] = []
    /// What went wrong with the last drop, shown under the drop zone until the next one.
    private(set) var problem: DabbiError?
    /// Set while a dropped folder is being searched: an app bundle takes a moment.
    private(set) var isSearching = false

    /// Whether the window shows itself when the app opens with nothing else to show.
    var showsAtLaunch: Bool {
        didSet { defaults.set(showsAtLaunch, forKey: Self.showsAtLaunchKey) }
    }

    @ObservationIgnored var actions: Actions
    @ObservationIgnored private let recentURLs: () -> [URL]
    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private var dropTask: Task<Void, Never>?

    static let showsAtLaunchKey = "ShowsWelcomeWindowAtLaunch"

    init(
        recents: @escaping () -> [URL] = { DocumentController.current?.recentDocumentURLs ?? [] },
        defaults: UserDefaults = .standard,
        actions: Actions = Actions()
    ) {
        self.recentURLs = recents
        self.defaults = defaults
        self.actions = actions
        // Shown unless the user has said otherwise: an app opened from the Dock with no window is a blank stare.
        self.showsAtLaunch = defaults.object(forKey: Self.showsAtLaunchKey) as? Bool ?? true
        refresh()
    }

    // MARK: Reading

    func refresh() {
        let manager = FileManager.default
        recents = recentURLs().map { url in
            Recent(
                url: url, isProject: url.pathExtension.lowercased() == ProjectPackage.fileExtension,
                isMissing: !manager.fileExists(atPath: url.path))
        }
    }

    // MARK: What the user does

    func open(_ recent: Recent) {
        actions.open(recent.url)
    }

    func openDatabase() { actions.openDatabase() }
    func openProject() { actions.openProject() }
    func browseSimulators() { actions.browseSimulators() }

    /// Takes what was dropped (PRJ-16). A file is opened as it is, whatever it is called (PRJ-15); a folder —
    /// an app bundle, an exported `.xcappdata` container, a folder of stores — is searched for the stores in it.
    func accept(_ urls: [URL]) {
        problem = nil
        dropTask?.cancel()
        let folders = urls.filter(Self.isFolder)
        for url in urls where !folders.contains(url) { actions.open(url) }
        guard !folders.isEmpty else { return }

        isSearching = true
        dropTask = Task { [weak self] in
            let found = await Self.stores(in: folders)
            guard let self, !Task.isCancelled else { return }
            self.isSearching = false
            guard !found.stores.isEmpty else {
                self.problem = Self.nothingFound(in: folders, searchedFully: found.isComplete)
                return
            }
            for url in found.stores.prefix(Self.maxStoresPerDrop) { self.actions.open(url) }
            if found.stores.count > Self.maxStoresPerDrop {
                self.problem = Self.tooMany(found.stores.count, in: folders)
            }
        }
    }

    /// Waits for a drop to have been made sense of. For the tests; nothing in the window waits.
    func whenSettled() async {
        await dropTask?.value
    }

    // MARK: Searching what was dropped

    /// The Core Data and SwiftData stores inside the folders, off the main actor: walking an app bundle is file
    /// system work, and plain SQLite databases are left out because the browser is not what raw mode is for.
    private static func stores(in folders: [URL]) async -> (stores: [URL], isComplete: Bool) {
        await Task.detached {
            var found: [URL] = []
            var isComplete = true
            for folder in folders {
                let walk = StoreSniffer().databases(under: folder)
                isComplete = isComplete && walk.isComplete
                // A store that cannot be opened where it is — a log without its shared memory (§6.2) — is read
                // by its schema instead, because that is precisely the store worth opening with a copy.
                found += walk.databases.filter { database in
                    (StoreSniffer.kind(of: database) ?? StoreSniffer.kindByContent(of: database)) != .plainSQLite
                }
            }
            return (found, isComplete)
        }.value
    }

    private static func isFolder(_ url: URL) -> Bool {
        (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true
    }

    private static func nothingFound(in folders: [URL], searchedFully: Bool) -> DabbiError {
        let name = folders.count == 1 ? folders[0].lastPathComponent : "\(folders.count) folders"
        return DabbiError(
            .notCoreData, "No Core Data or SwiftData store was found in \(name).",
            arguments: ["name": name],
            diagnosis: searchedFully
                ? ["Every database inside it was read, and none of them is a Core Data store."]
                : ["It was too large to search to the end."],
            recovery: ["Open Database… opens any file, if you know which one holds the data."])
    }

    private static func tooMany(_ count: Int, in folders: [URL]) -> DabbiError {
        let name = folders.count == 1 ? folders[0].lastPathComponent : "\(folders.count) folders"
        return DabbiError(
            .limitExceeded, "\(name) holds \(count) stores; the first \(maxStoresPerDrop) were opened.",
            arguments: ["name": name, "count": String(count)],
            recovery: ["Open Database… opens the rest, one at a time."])
    }
}
