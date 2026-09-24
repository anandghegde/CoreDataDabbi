import Foundation

/// The files a Core Data SQLite store is made of, besides the database itself.
public enum StoreFiles {
    /// Suffixes of the files SQLite keeps next to a database in write-ahead-log mode.
    public static let sideFileSuffixes = ["-wal", "-shm"]

    /// `.Model_SUPPORT` beside `Model.sqlite`. Attributes with "Allows External Storage" keep their large values
    /// in its `_EXTERNAL_DATA` folder, one file per value, named by a UUID the row holds.
    public static func supportFolder(of store: URL) -> URL {
        let name = store.deletingPathExtension().lastPathComponent
        return store.deletingLastPathComponent().appendingPathComponent(".\(name)_SUPPORT", isDirectory: true)
    }
}
