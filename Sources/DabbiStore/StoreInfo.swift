import DabbiBase
import DabbiModel
import Foundation

/// How a store is opened. Only read-only exists so far; editable arrives with staged edits (M3).
public enum AccessMode: String, Sendable, Hashable, Codable {
    case readOnly
}

/// Everything a front end shows about an open store that is not row data.
public struct StoreInfo: Sendable, Hashable, Codable {
    public let url: URL
    public let accessMode: AccessMode
    /// The model as the app defined it — including the class and transformer names the sanitiser replaced.
    public let model: ModelDescription
    public let modelSource: ModelSource
    public let metadata: StoreMetadata
    public let probe: FormatProbe
    public let schemaMap: SchemaMap
}

/// Row counts of one entity.
public struct EntityCount: Sendable, Hashable, Codable {
    public let entity: String
    /// Rows whose entity is exactly this one. Always 0 for an abstract entity.
    public let own: Int
    /// Rows of this entity and of all its descendants.
    public let total: Int
}

/// A fixed, ordered list of objects that pages are cut from. Value type; the list itself stays in the session.
public struct PagerHandle: Sendable, Hashable, Codable {
    public let id: UUID
    public let spec: FetchSpec
    /// The number of objects in the list when it was opened.
    public let count: Int
    /// What `page` returns for this pager: the entity's stored properties, then those its descendants add.
    public let columns: ColumnSet
    /// The session generation the pager belongs to. A pager from an older generation is stale.
    public let generation: Int
}
