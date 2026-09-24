import Foundation

/// How a store is opened (EDT-1). Projects remember it; sessions report it.
///
/// Read-only is the default everywhere. Editable is asked for with `StoreAccess.editable`, which takes a
/// `WriteAuthorization`.
public enum AccessMode: String, Sendable, Hashable, Codable {
    case readOnly
    case editable
}

/// Permission to open a store for writing (ADR-12).
///
/// Only the engine can make one; front ends that may write get theirs from a factory in `DabbiKit`
/// (`WriteAuthorization.app`). A front end that must never write — the MCP server — is built so it has no way to
/// ask, which makes "writes are never exposed over MCP" a property of what it links rather than of its care.
public struct WriteAuthorization: Sendable, Hashable {
    /// Who the saves are by: the `transactionAuthor` persistent history records for them (EDT-5), so that the
    /// app, and our own tracker, can tell our writes from its own.
    public let author: String

    package init(author: String) {
        self.author = author
    }
}

/// How to open a store: read-only, or editable on the strength of a `WriteAuthorization`.
public enum StoreAccess: Sendable, Hashable {
    case readOnly
    case editable(WriteAuthorization)

    public var mode: AccessMode {
        switch self {
        case .readOnly: .readOnly
        case .editable: .editable
        }
    }

    public var authorization: WriteAuthorization? {
        if case .editable(let authorization) = self { authorization } else { nil }
    }
}
