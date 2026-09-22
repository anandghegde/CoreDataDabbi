import Foundation

/// How a store is opened (EDT-1). Projects remember it; sessions report it.
///
/// Read-only is the default everywhere. `StoreSession` cannot open a store editable yet — that arrives with
/// staged edits (M3) — so until then a project that asks for it is opened read-only and says so.
public enum AccessMode: String, Sendable, Hashable, Codable {
    case readOnly
    case editable
}
