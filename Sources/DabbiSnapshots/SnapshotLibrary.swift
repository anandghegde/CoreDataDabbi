import DabbiBase
import Foundation

/// A folder of snapshots: one sub-folder per snapshot, named by its ID, holding the copied store, its support
/// folder and `manifest.json`.
///
/// ```
/// <root>/
/// ├─ 6F1C…/manifest.json
/// │        Model.sqlite
/// │        .Model_SUPPORT/_EXTERNAL_DATA/…
/// └─ .staging-9A2E…/          a copy being taken; never listed, swept when found
/// ```
public struct SnapshotLibrary: Sendable, Hashable {
    public let root: URL

    public init(root: URL) {
        self.root = root
    }

    /// How many backups to keep. Snapshots someone took are never removed by retention.
    public struct Retention: Sendable, Hashable, Codable {
        /// Backups beyond this many, newest first, are removed. At least one is always kept.
        public var keepBackups: Int
        /// Backups older than this are removed, the newest one excepted. `nil` keeps them regardless of age.
        public var maxBackupAge: TimeInterval?

        public init(keepBackups: Int = 10, maxBackupAge: TimeInterval? = nil) {
            self.keepBackups = keepBackups
            self.maxBackupAge = maxBackupAge
        }

        public static let `default` = Retention()
    }

    private static let stagingPrefix = ".staging-"
    private static let log = DabbiLog.logger(.snapshots)

    func folder(for id: UUID) -> URL {
        root.appendingPathComponent(id.uuidString, isDirectory: true)
    }

    func stagingFolder(for id: UUID) -> URL {
        root.appendingPathComponent(Self.stagingPrefix + id.uuidString, isDirectory: true)
    }

    /// The copied database of a snapshot in this library.
    public func databaseURL(of manifest: SnapshotManifest) -> URL {
        folder(for: manifest.id).appendingPathComponent(manifest.storeFileName)
    }

    // MARK: Reading

    /// Every snapshot in the library, newest first. A folder whose manifest cannot be read is skipped.
    public func list() -> [SnapshotManifest] {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: root.path)) ?? []
        return names.compactMap { name -> SnapshotManifest? in
            guard let id = UUID(uuidString: name) else { return nil }
            do {
                return try SnapshotManifest.read(from: folder(for: id))
            } catch {
                Self.log.error("Skipped a snapshot whose manifest could not be read.")
                return nil
            }
        }
        .sorted { ($0.createdAt, $0.id.uuidString) > ($1.createdAt, $1.id.uuidString) }
    }

    public func manifest(_ id: UUID) throws -> SnapshotManifest {
        let folder = folder(for: id)
        guard FileManager.default.fileExists(atPath: folder.path) else {
            throw DabbiError(
                .snapshotNotFound, "The snapshot is no longer there.", arguments: ["path": folder.path],
                recovery: ["It may have been deleted, or its folder moved."])
        }
        return try SnapshotManifest.read(from: folder)
    }

    // MARK: Changing

    /// Renames a snapshot and replaces its note. The copy itself is not touched.
    @discardableResult
    public func update(_ id: UUID, name: String? = nil, note: String? = nil) throws -> SnapshotManifest {
        var manifest = try manifest(id)
        if let name { manifest.name = name }
        if let note { manifest.note = note }
        do {
            try manifest.write(to: folder(for: id))
        } catch {
            throw DabbiError(
                .snapshotFailed, "The snapshot could not be renamed.", arguments: ["path": folder(for: id).path],
                underlying: error)
        }
        return try SnapshotManifest.read(from: folder(for: id))
    }

    public func delete(_ id: UUID) throws {
        do {
            try FileManager.default.removeItem(at: folder(for: id))
        } catch {
            throw DabbiError(
                .snapshotFailed, "The snapshot could not be deleted.", arguments: ["path": folder(for: id).path],
                underlying: error)
        }
    }

    /// Removes the backups `retention` does not keep, and returns them. Snapshots are left alone.
    @discardableResult
    public func prune(_ retention: Retention, now: Date = Date()) -> [SnapshotManifest] {
        let backups = list().filter { $0.kind == .backup }
        let keep = max(retention.keepBackups, 1)
        let removed = backups.enumerated().filter { index, backup in
            guard index > 0 else { return false }
            if index >= keep { return true }
            if let age = retention.maxBackupAge, now.timeIntervalSince(backup.createdAt) > age { return true }
            return false
        }
        .map(\.element)
        for backup in removed { try? delete(backup.id) }
        return removed
    }

    /// Removes copies a crash left half-taken. Call it when nothing can be taking a snapshot into this library —
    /// at launch — since a copy in progress looks exactly like one abandoned.
    public func sweepStaging() {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: root.path)) ?? []
        for name in names where name.hasPrefix(Self.stagingPrefix) {
            try? FileManager.default.removeItem(at: root.appendingPathComponent(name))
        }
    }
}
