import Foundation

/// The one error type at the engine's API boundary.
///
/// Besides a machine-readable `code` it carries what a front end needs for an *instructive* error state
/// (PRD §8.1): what was looked for and where (`diagnosis`) and what the user can do next (`recovery`).
///
/// `message` is the English fallback. Localised front ends look up `code.rawValue` in their string catalog and
/// substitute `arguments`.
///
/// Privacy: a `DabbiError` may contain paths, entity names and property names — never row values.
public struct DabbiError: Error, Sendable, Hashable, Codable {
    public struct Code: RawRepresentable, Sendable, Hashable, Codable, ExpressibleByStringLiteral {
        public let rawValue: String
        public init(rawValue: String) { self.rawValue = rawValue }
        public init(stringLiteral value: String) { self.rawValue = value }
    }

    public var code: Code
    public var message: String
    public var arguments: [String: String]
    public var diagnosis: [String]
    public var recovery: [String]
    /// A description of the lower-level error, when there was one.
    public var underlying: String?

    public init(
        _ code: Code,
        _ message: String,
        arguments: [String: String] = [:],
        diagnosis: [String] = [],
        recovery: [String] = [],
        underlying: (any Error)? = nil
    ) {
        self.code = code
        self.message = message
        self.arguments = arguments
        self.diagnosis = diagnosis
        self.recovery = recovery
        self.underlying = underlying.map { Self.describe($0) }
    }

    private static func describe(_ error: any Error) -> String {
        if let error = error as? DabbiError { return error.message }
        let nsError = error as NSError
        return "\(nsError.domain) \(nsError.code): \(nsError.localizedDescription)"
    }
}

extension DabbiError.Code {
    // Files and SQLite
    public static let fileNotFound: Self = "file.notFound"
    public static let fileUnreadable: Self = "file.unreadable"
    /// The file does not start with the SQLite header: encrypted (e.g. SQLCipher) or not a database at all.
    public static let notSQLite: Self = "sqlite.notSQLite"
    /// A valid SQLite database without Core Data's metadata table. Raw mode can still show it.
    public static let notCoreData: Self = "sqlite.notCoreData"
    public static let sqlite: Self = "sqlite.error"
    /// The statement was refused by the read-only authorizer.
    public static let sqliteDenied: Self = "sqlite.denied"
    /// A WAL database in a location where neither `-shm` exists nor the directory is writable.
    public static let readOnlyLocation: Self = "sqlite.readOnlyLocation"
    public static let cancelled: Self = "cancelled"
    public static let timeout: Self = "timeout"

    // Models
    public static let modelNotFound: Self = "model.notFound"
    public static let modelUnreadable: Self = "model.unreadable"
    public static let modelCacheMissing: Self = "model.cacheMissing"
    public static let modelIncompatible: Self = "model.incompatible"
    /// Sanitising changed the entity version hashes. This must never happen; it guards ADR-09.
    public static let modelSanitiserChangedHashes: Self = "model.sanitiserChangedHashes"

    // Store session
    public static let storeOpenFailed: Self = "store.openFailed"
    public static let storeClosed: Self = "store.closed"
    public static let unknownEntity: Self = "store.unknownEntity"
    public static let unknownProperty: Self = "store.unknownProperty"
    public static let invalidPredicate: Self = "store.invalidPredicate"
    /// The predicate parsed but uses constructs that could run arbitrary code (custom `FUNCTION`, blocks).
    public static let unsafePredicate: Self = "store.unsafePredicate"
    public static let invalidSort: Self = "store.invalidSort"
    public static let fetchFailed: Self = "store.fetchFailed"
    public static let objectNotFound: Self = "store.objectNotFound"
    /// The pager belongs to an older session generation, or was closed.
    public static let stalePager: Self = "store.stalePager"
    /// Persistent history was asked for on a store that does not record any.
    public static let historyUnavailable: Self = "store.historyUnavailable"

    // Projects
    public static let projectUnreadable: Self = "project.unreadable"
    /// The project was written by a newer version of the app, with a schema this one does not know.
    public static let projectTooNew: Self = "project.tooNew"
    public static let projectWriteFailed: Self = "project.writeFailed"

    // Locating stores
    /// A developer tool (`xcrun`, `simctl`) is not installed or could not be started.
    public static let toolUnavailable: Self = "locator.toolUnavailable"
    /// A tool ran and answered with something that cannot be read.
    public static let toolOutputUnreadable: Self = "locator.toolOutputUnreadable"
    /// A store location no longer leads to a file: the device, the app or the file is gone (PRJ-12).
    public static let locationUnresolved: Self = "locator.unresolved"

    // Decoding
    public static let decompressionFailed: Self = "decode.decompressionFailed"
    /// A safety limit (inflated size, recursion depth, row cap) was hit.
    public static let limitExceeded: Self = "decode.limitExceeded"
    /// Field content that claims a format (by its magic bytes) and does not follow it.
    public static let contentMalformed: Self = "decode.malformed"
    /// "Decode as" named a content type nobody registered a decoder for.
    public static let noDecoder: Self = "decode.noDecoder"

    public static let objcException: Self = "internal.objcException"
    public static let `internal`: Self = "internal.error"
}

extension DabbiError: LocalizedError, CustomStringConvertible {
    public var errorDescription: String? { message }
    public var failureReason: String? { diagnosis.isEmpty ? nil : diagnosis.joined(separator: "\n") }
    public var recoverySuggestion: String? { recovery.isEmpty ? nil : recovery.joined(separator: "\n") }

    /// A multi-line rendering for terminals: message, then diagnosis and recovery as bullet lists.
    public var description: String {
        var lines = ["\(message) [\(code.rawValue)]"]
        lines += diagnosis.map { "  · \($0)" }
        if let underlying { lines.append("  · underlying: \(underlying)") }
        lines += recovery.map { "  → \($0)" }
        return lines.joined(separator: "\n")
    }
}
