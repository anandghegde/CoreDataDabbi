import DabbiBase
import Foundation

/// The backup taken before the first commit of an editing session (EDT-9, ARCHITECTURE.md §6.4).
///
/// One per editable session. The commit pipeline (M3-07) calls `ensure()` before every save: the first call copies
/// the store into the library, verifies the copy and applies the retention; later calls return that same backup.
/// A call that fails leaves no backup behind, and the next one tries again — a commit never goes ahead on the
/// strength of a copy that did not hold up.
public actor PreCommitBackup {
    public nonisolated let store: URL
    public nonisolated let library: SnapshotLibrary
    public nonisolated let retention: SnapshotLibrary.Retention
    private let name: String

    /// The backup of this session, once there is one.
    public private(set) var backup: SnapshotManifest?
    private var inFlight: Task<SnapshotManifest, any Error>?

    /// - Parameter name: What the backup is called in lists. The app passes a localised one.
    public init(
        store: URL, library: SnapshotLibrary, retention: SnapshotLibrary.Retention = .default,
        name: String = "Before editing"
    ) {
        self.store = store
        self.library = library
        self.retention = retention
        self.name = name
    }

    /// The session's backup, taken and verified now if this is the first time it is asked for.
    public func ensure() async throws -> SnapshotManifest {
        if let backup { return backup }
        // Two commits racing for the first backup wait for the same copy.
        if let inFlight { return try await inFlight.value }
        let task = Task { [store, library, name] in
            try await Snapshotter.take(of: store, into: library, kind: .backup, name: name)
        }
        inFlight = task
        defer { inFlight = nil }
        let manifest = try await task.value
        backup = manifest
        library.prune(retention)
        return manifest
    }

    /// Where a store's backups go under `root`: one library per store, by `NSStoreUUID` when it has one — which
    /// follows the store through a reinstall that moves its container — or else by its path.
    public static func library(forStoreUUID storeUUID: String?, at storeURL: URL, under root: URL) -> SnapshotLibrary {
        let key: String
        if let storeUUID, !storeUUID.isEmpty, !storeUUID.contains("/") {
            key = storeUUID
        } else {
            key = "path-" + String(storeURL.standardizedFileURL.path.hashValueStable, radix: 16)
        }
        return SnapshotLibrary(root: root.appendingPathComponent(key, isDirectory: true))
    }
}

extension String {
    /// FNV-1a over the UTF-8 bytes: the same on every launch, unlike `hashValue`.
    fileprivate var hashValueStable: UInt64 {
        utf8.reduce(0xcbf2_9ce4_8422_2325) { ($0 ^ UInt64($1)) &* 0x100_0000_01b3 }
    }
}
