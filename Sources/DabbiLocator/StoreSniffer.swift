import DabbiBase
import DabbiSQLite
import Foundation

/// Finds the databases in a container and says which of them are Core Data's (PRJ-8, §6.7).
///
/// Two steps, the cheap one first: a bounded walk that reads sixteen bytes of every file whose name could be a
/// database's, then — only for those with SQLite's header — a read-only open to look for Core Data's
/// bookkeeping tables. Nothing is decided by file name alone: stores are called `Model.sqlite`, `default.store`,
/// `data`, or whatever the developer liked.
public struct StoreSniffer: Sendable {
    /// Lower-case extensions worth a look; the empty one stands for files without any (PRJ-15).
    public var extensions: Set<String> = ["sqlite", "sqlite3", "db", "store", "storedata", "coredata", "data", ""]
    /// Folders that hold the system's databases, never the app's: web views, URL caches, snapshots.
    public var excludedFolderNames: Set<String> = [
        "WebKit", "HTTPStorages", "Cookies", "SplashBoard", "Saved Application State", "SystemData",
        "com.apple.nsurlsessiond",
    ]
    public var maxDepth = 8
    /// Entries looked at per container before the walk gives up: a container with a million cached images must
    /// not hold up the browser.
    public var maxEntries = 50_000

    public init() {}

    /// What a walk found, and whether it saw everything.
    public struct Walk: Sendable, Hashable {
        public var databases: [URL]
        public var isComplete: Bool
    }

    /// Files under `root` that start with SQLite's header, in path order.
    public func databases(under root: URL) -> Walk {
        let keys: [URLResourceKey] = [.isDirectoryKey, .isRegularFileKey]
        // Package contents are walked too: a store may well sit inside a document package.
        guard let enumerator = FileManager.default.enumerator(at: root, includingPropertiesForKeys: keys, options: [])
        else { return Walk(databases: [], isComplete: true) }

        var found: [URL] = []
        var seen = 0
        while let url = enumerator.nextObject() as? URL {
            seen += 1
            guard seen <= maxEntries else {
                return Walk(databases: found.sorted { $0.path < $1.path }, isComplete: false)
            }
            let values = try? url.resourceValues(forKeys: Set(keys))
            if values?.isDirectory == true {
                if enumerator.level >= maxDepth || excludedFolderNames.contains(url.lastPathComponent) {
                    enumerator.skipDescendants()
                }
                continue
            }
            guard values?.isRegularFile == true, extensions.contains(url.pathExtension.lowercased()),
                !Self.isSidecar(url), Self.hasSQLiteHeader(url)
            else { continue }
            found.append(url)
        }
        return Walk(databases: found.sorted { $0.path < $1.path }, isComplete: true)
    }

    /// `nil` when the file cannot be opened as a database at all (encrypted, locked, gone in the meantime).
    public static func kind(of database: URL) -> StoreCandidate.Kind? {
        var options = SQLiteConnection.Options()
        // The browser never waits for an app that is writing.
        options.busyTimeoutMilliseconds = 50
        guard let connection = try? SQLiteConnection(readOnly: database, options: options) else { return nil }
        defer { connection.close() }
        guard let tables = try? connection.tableNames() else { return nil }
        guard tables.contains("Z_METADATA"), tables.contains("Z_PRIMARYKEY") else { return .plainSQLite }
        let writtenBySwiftData = SwiftDataConventions.looksWrittenBySwiftData(
            modelVersionIdentifiers: modelVersionIdentifiers(connection),
            tracksHistory: tables.contains("ATRANSACTION"))
        return writtenBySwiftData ? .swiftData : .coreData
    }

    /// `NSStoreModelVersionIdentifiers` of the store's metadata, which Core Data keeps as a property list in the
    /// one row of `Z_METADATA`. Empty when there is none or it cannot be read; the browser does not care why.
    private static func modelVersionIdentifiers(_ connection: SQLiteConnection) -> [String] {
        guard let data = try? connection.scalar("SELECT Z_PLIST FROM Z_METADATA LIMIT 1")?.data,
            data.count <= 1024 * 1024,
            let plist = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any]
        else { return [] }
        return (plist["NSStoreModelVersionIdentifiers"] as? [Any] ?? []).map { String(describing: $0) }
    }

    /// For a database that cannot be opened where it is (a write-ahead log without its `-shm`, §6.2): whether
    /// Core Data's table names occur in the first megabytes of the file or of its log. The schema is stored as
    /// the text of its `CREATE TABLE` statements, and Core Data writes it before anything else.
    public static func kindByContent(of database: URL) -> StoreCandidate.Kind {
        let needle = Data("CREATE TABLE Z_METADATA".utf8)
        for path in [database.path, database.path + "-wal"] {
            guard let handle = FileHandle(forReadingAtPath: path) else { continue }
            defer { try? handle.close() }
            if let head = try? handle.read(upToCount: 4 * 1024 * 1024), head.range(of: needle) != nil {
                return .coreData
            }
        }
        return .plainSQLite
    }

    /// The main file plus its write-ahead log and shared memory, and the newest change to any of them.
    public static func footprint(of database: URL) -> (byteCount: Int64, modifiedAt: Date?) {
        var byteCount: Int64 = 0
        var modifiedAt: Date?
        for suffix in ["", "-wal", "-shm"] {
            let url = URL(fileURLWithPath: database.path + suffix)
            guard let values = try? url.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey]) else {
                continue
            }
            byteCount += Int64(values.fileSize ?? 0)
            if let date = values.contentModificationDate, date > modifiedAt ?? .distantPast { modifiedAt = date }
        }
        return (byteCount, modifiedAt)
    }

    static func isSidecar(_ url: URL) -> Bool {
        let name = url.lastPathComponent
        return name.hasSuffix("-wal") || name.hasSuffix("-shm") || name.hasSuffix("-journal")
    }

    static func hasSQLiteHeader(_ url: URL) -> Bool {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return false }
        defer { try? handle.close() }
        guard let head = try? handle.read(upToCount: SQLiteHeader.magic.count) else { return false }
        return SQLiteHeader.hasMagic(head)
    }
}
