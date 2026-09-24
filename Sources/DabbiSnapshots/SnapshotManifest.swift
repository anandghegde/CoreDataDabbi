import DabbiBase
import Foundation

/// What a snapshot is a copy of, and what it held when it was taken (§7.3, EDT-9).
///
/// Written as `manifest.json` next to the copy. It carries names, sizes and counts — never row values — so it can
/// be read, listed and shared without opening the store.
public struct SnapshotManifest: Sendable, Hashable, Codable, Identifiable {
    /// Why the snapshot exists. Retention only ever removes backups; a snapshot someone took stays until they
    /// delete it.
    public enum Kind: String, Sendable, Hashable, Codable {
        /// Taken by the user, with a name and a note.
        case snapshot
        /// Taken before the first commit of an editing session (EDT-9).
        case backup
    }

    /// One table's row count in the copy.
    public struct TableCount: Sendable, Hashable, Codable {
        public let table: String
        public let rows: Int
    }

    /// What was checked before the snapshot was kept.
    public struct Verification: Sendable, Hashable, Codable {
        public let verifiedAt: Date
        /// The copy's row counts were compared with the store's, read with no commit in between. `false` when the
        /// app kept saving while the copy was made; then the copy is checked against itself only.
        public let comparedWithStore: Bool

        public init(verifiedAt: Date, comparedWithStore: Bool) {
            self.verifiedAt = verifiedAt
            self.comparedWithStore = comparedWithStore
        }
    }

    /// The manifest's own format. A newer one is refused rather than guessed at.
    public static let currentFormat = 1

    public let format: Int
    public let id: UUID
    public let kind: Kind
    public var name: String
    public var note: String
    public let createdAt: Date

    /// Where the store was when the copy was made.
    public let sourceURL: URL
    /// The store's file name, which is also the copy's.
    public let storeFileName: String
    /// `NSStoreUUID`: which store this is a copy of, whatever its path.
    public let storeUUID: String?
    /// Entity name → version hash of the model the store was last saved with.
    public let entityVersionHashes: [String: Data]

    /// Every table of the copy, in name order.
    public let tables: [TableCount]
    public let databaseBytes: Int64
    /// Files in the copy's support folder (external binary data), and their total size.
    public let externalFileCount: Int
    public let externalBytes: Int64
    public let verification: Verification

    public init(
        id: UUID = UUID(), kind: Kind, name: String, note: String = "", createdAt: Date, sourceURL: URL,
        storeFileName: String, storeUUID: String?, entityVersionHashes: [String: Data], tables: [TableCount],
        databaseBytes: Int64, externalFileCount: Int, externalBytes: Int64, verification: Verification
    ) {
        self.format = Self.currentFormat
        self.id = id
        self.kind = kind
        self.name = name
        self.note = note
        self.createdAt = createdAt
        self.sourceURL = sourceURL
        self.storeFileName = storeFileName
        self.storeUUID = storeUUID
        self.entityVersionHashes = entityVersionHashes
        self.tables = tables
        self.databaseBytes = databaseBytes
        self.externalFileCount = externalFileCount
        self.externalBytes = externalBytes
        self.verification = verification
    }

    public var totalBytes: Int64 { databaseBytes + externalBytes }

    // MARK: Reading and writing

    static let fileName = "manifest.json"
    /// ISO 8601 with milliseconds: two backups a second apart must still sort, and a manifest read back must be
    /// the one that was written.
    private static let dateFormat = Date.ISO8601FormatStyle(includingFractionalSeconds: true)

    static func read(from folder: URL) throws -> SnapshotManifest {
        let url = folder.appendingPathComponent(fileName)
        let manifest: SnapshotManifest
        do {
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .custom { decoder in
                let text = try decoder.singleValueContainer().decode(String.self)
                guard let date = try? Date(text, strategy: dateFormat) else {
                    throw DecodingError.dataCorrupted(
                        .init(codingPath: decoder.codingPath, debugDescription: "Not an ISO 8601 date: \(text)"))
                }
                return date
            }
            manifest = try decoder.decode(SnapshotManifest.self, from: Data(contentsOf: url))
        } catch {
            throw DabbiError(
                .snapshotNotFound, "The snapshot’s manifest could not be read.", arguments: ["path": url.path],
                underlying: error)
        }
        guard manifest.format <= currentFormat else {
            throw DabbiError(
                .snapshotNotFound, "The snapshot was made by a newer version of CoreDataDabbi.",
                arguments: ["path": url.path, "format": String(manifest.format)])
        }
        return manifest
    }

    func write(to folder: URL) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .custom { date, encoder in
            var container = encoder.singleValueContainer()
            try container.encode(date.formatted(Self.dateFormat))
        }
        try encoder.encode(self).write(to: folder.appendingPathComponent(Self.fileName), options: .atomic)
    }
}
