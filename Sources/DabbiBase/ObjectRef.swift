import Foundation

/// The identity of one managed object, as a value that can cross any isolation boundary.
///
/// An `ObjectRef` is derived from the object's permanent Core Data URI
/// (`x-coredata://<store-uuid>/<Entity>/p42`). Temporary (unsaved) object IDs have no `ObjectRef`.
public struct ObjectRef: Sendable, Hashable, Codable {
    /// The name of the object's own entity — for a sub-entity row this is the sub-entity, not the fetched parent.
    public let entity: String
    /// The row's primary key (`Z_PK`), taken from the last URI component (`p42` → 42).
    public let pk: Int64
    /// The permanent object URI.
    public let uri: URL

    public init(entity: String, pk: Int64, uri: URL) {
        self.entity = entity
        self.pk = pk
        self.uri = uri
    }

    /// Parses a permanent Core Data object URI. Returns `nil` for anything else, including temporary IDs.
    public init?(uri: URL) {
        guard uri.scheme == "x-coredata" else { return nil }
        let parts = uri.pathComponents.filter { $0 != "/" }
        guard parts.count == 2, let last = parts.last, last.hasPrefix("p"), let pk = Int64(last.dropFirst()) else {
            return nil
        }
        self.init(entity: parts[0], pk: pk, uri: uri)
    }

    /// The UUID of the persistent store the object lives in, when the URI carries one.
    public var storeIdentifier: String? { uri.host }
}

extension ObjectRef: CustomStringConvertible {
    /// A short, log-safe form such as `Person#42`. Identity is not row data, so this may be logged.
    public var description: String { "\(entity)#\(pk)" }
}

extension ObjectRef: Comparable {
    public static func < (lhs: ObjectRef, rhs: ObjectRef) -> Bool {
        (lhs.entity, lhs.pk) < (rhs.entity, rhs.pk)
    }
}
