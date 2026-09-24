import DabbiBase
import DabbiSQLite
import Foundation

/// A copy of a store that is ours to open, for stores that cannot be opened where they are (§6.2, PRJ-3).
///
/// A write-ahead-log database without its `-shm` cannot be opened read-only by anything — SQLite would have to
/// create the file, and a read-only connection never does. That is the state of a store copied without its
/// side files, of one on a read-only volume, of one inside a locked-down `.xcappdata`. The way out that writes
/// nothing next to the user's store: copy it, with whatever side files it has, and open *the copy* read-write
/// once, so that SQLite replays the log into it and it becomes one self-contained file.
public struct WorkingCopy: Sendable, Hashable, Codable {
    /// The store the copy was made of.
    public let original: URL
    /// The copy: open this.
    public let url: URL
    /// The folder made for the copy. Delete it to delete the copy.
    public let folder: URL
    public let createdAt: Date

    /// Copies `store` into a new folder under `directory`.
    ///
    /// On APFS the copy is a clone: instant, and it takes no space until one of the two changes.
    public static func make(of store: URL, in directory: URL) throws -> WorkingCopy {
        let folder = directory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        let copy = folder.appendingPathComponent(store.lastPathComponent)
        let files = FileManager.default
        do {
            try files.createDirectory(at: folder, withIntermediateDirectories: true)
            try files.copyItem(at: store, to: copy)
            for suffix in StoreFiles.sideFileSuffixes where files.fileExists(atPath: store.path + suffix) {
                try files.copyItem(atPath: store.path + suffix, toPath: copy.path + suffix)
            }
            let support = StoreFiles.supportFolder(of: store)
            if files.fileExists(atPath: support.path) {
                try files.copyItem(at: support, to: StoreFiles.supportFolder(of: copy))
            }
            try SQLiteConnection.consolidate(ownedCopyAt: copy)
        } catch {
            try? files.removeItem(at: folder)
            if let error = error as? DabbiError { throw error }
            throw DabbiError(
                .fileUnreadable, "A working copy of \(store.lastPathComponent) could not be made.",
                arguments: ["path": store.path], diagnosis: ["Copying to \(folder.path) failed."],
                recovery: ["Check the free space on the disk, and the permissions of the store."], underlying: error)
        }
        return WorkingCopy(original: store, url: copy, folder: folder, createdAt: Date())
    }

    public func remove() {
        try? FileManager.default.removeItem(at: folder)
    }

    /// Whether a failed open is one that a working copy gets around.
    public static func helps(with error: any Error) -> Bool {
        (error as? DabbiError)?.code == .readOnlyLocation
    }
}
