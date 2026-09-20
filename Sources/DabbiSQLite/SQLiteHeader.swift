import DabbiBase
import Foundation

/// The fixed 100-byte header of a SQLite database file, read without opening the database.
///
/// This is the first check on any file a user hands us: it tells a real database from an encrypted one
/// (SQLCipher encrypts the header too) or from something that is not a database at all.
public struct SQLiteHeader: Sendable, Hashable {
    public static let magic = Array("SQLite format 3\0".utf8)
    public static let length = 100

    public let pageSize: Int
    /// `true` when the file-format version bytes say write-ahead logging.
    public let isWAL: Bool
    public let userVersion: Int32
    public let applicationID: Int32
    /// `SQLITE_VERSION_NUMBER` of the library that last wrote the file.
    public let writerLibraryVersion: Int32

    /// Whether `data` begins with the SQLite magic string.
    public static func hasMagic(_ data: Data) -> Bool {
        data.count >= magic.count && Array(data.prefix(magic.count)) == magic
    }

    /// Reads and validates the header.
    ///
    /// - Throws: `.fileNotFound`, `.fileUnreadable`, or `.notSQLite` with an explanation that covers encryption.
    public static func read(from url: URL) throws -> SQLiteHeader {
        guard FileManager.default.fileExists(atPath: url.path) else {
            throw DabbiError(
                .fileNotFound,
                "The database file does not exist.",
                arguments: ["path": url.path],
                diagnosis: ["Looked for \(url.path)."],
                recovery: ["If the app was reinstalled, its container moved. Re-select the app or the store."]
            )
        }

        let head: Data
        do {
            let handle = try FileHandle(forReadingFrom: url)
            defer { try? handle.close() }
            head = try handle.read(upToCount: length) ?? Data()
        } catch {
            throw DabbiError(
                .fileUnreadable,
                "The database file cannot be read.",
                arguments: ["path": url.path],
                diagnosis: ["Reading \(url.path) failed."],
                recovery: ["Check the file's permissions. macOS may also ask for consent to read another app's data."],
                underlying: error
            )
        }

        guard hasMagic(head), head.count >= length else {
            let detail =
                head.isEmpty
                ? "The file is empty."
                : "The file does not start with the SQLite header (\"SQLite format 3\")."
            throw DabbiError(
                .notSQLite,
                "This file is not a SQLite database, or it is encrypted.",
                arguments: ["path": url.path],
                diagnosis: [detail, "Encrypted stores (for example SQLCipher) look exactly like this."],
                recovery: ["Open an unencrypted copy of the store. CoreDataDabbi never asks for encryption keys."]
            )
        }

        func bigEndian32(at offset: Int) -> Int32 {
            Int32(bitPattern: head[offset..<offset + 4].reduce(UInt32(0)) { $0 << 8 | UInt32($1) })
        }
        let rawPageSize = Int(head[16]) << 8 | Int(head[17])
        return SQLiteHeader(
            pageSize: rawPageSize == 1 ? 65536 : rawPageSize,
            isWAL: head[18] == 2 || head[19] == 2,
            userVersion: bigEndian32(at: 60),
            applicationID: bigEndian32(at: 68),
            writerLibraryVersion: bigEndian32(at: 96)
        )
    }
}
