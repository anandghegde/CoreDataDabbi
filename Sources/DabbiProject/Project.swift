import DabbiBase
import Foundation

/// The shareable part of a `.dabbi` project: `project.json` (PRJ-1, ARCHITECTURE.md §6.9).
///
/// Everything here makes sense on somebody else's machine. What does not — bookmarks, window and selection
/// state — is `LocalState`.
///
/// Every member decodes with a default when it is absent, so a project written by an older version of the app
/// opens without a migration; a key this version does not know is kept and written back (`ProjectPackage`).
public struct Project: Sendable, Hashable {
    /// The schema this version of the app writes. It changes only when the meaning of an existing key does;
    /// adding keys needs no new version.
    public static let currentSchemaVersion = 1

    public var schemaVersion: Int
    /// Stable for the life of the project. Names the project's folder when local state lives outside the package.
    public var id: UUID
    public var store: StoreLocation?
    public var model: ModelReference
    public var accessMode: AccessMode
    public var localStatePlacement: LocalStatePlacement
    public var display: DisplayPreferences

    public init(
        id: UUID = UUID(),
        store: StoreLocation? = nil,
        model: ModelReference = .storeCache,
        accessMode: AccessMode = .readOnly,
        localStatePlacement: LocalStatePlacement = .inPackage,
        display: DisplayPreferences = DisplayPreferences()
    ) {
        self.schemaVersion = Self.currentSchemaVersion
        self.id = id
        self.store = store
        self.model = model
        self.accessMode = accessMode
        self.localStatePlacement = localStatePlacement
        self.display = display
    }
}

/// Which model the store is browsed with (PRJ-3, PRJ-7).
public enum ModelReference: Sendable, Hashable {
    /// The copy of the model Core Data caches inside the store.
    case storeCache
    /// A `.mom`, a `.momd` or an app bundle to find the model in.
    case file(FileReference)
}

/// Where the machine-specific half of a project is kept.
public enum LocalStatePlacement: String, Sendable, Hashable, Codable {
    /// In the package's `local/` folder — the project is one self-contained item.
    case inPackage
    /// Under `~/Library/Application Support`, keyed by the project's ID — the package holds nothing
    /// machine-specific and can be committed to a repository (PRD §9.6).
    case applicationSupport
}

// MARK: - Display preferences

public struct DisplayPreferences: Sendable, Hashable {
    /// The time zone dates are rendered in (BRW-4).
    public var timeZone: TimeZoneChoice
    /// Grid layout per entity name (BRW-3). An entity without an entry shows the default layout.
    public var entities: [String: EntityLayout]

    public init(timeZone: TimeZoneChoice = .utc, entities: [String: EntityLayout] = [:]) {
        self.timeZone = timeZone
        self.entities = entities
    }
}

public enum TimeZoneChoice: Sendable, Hashable {
    case utc
    /// Whatever the machine is set to when the project is open.
    case local
    /// An IANA identifier such as `Europe/Amsterdam`.
    case custom(String)

    /// An identifier that names no zone falls back to UTC rather than to a zone nobody asked for.
    public var timeZone: TimeZone {
        switch self {
        case .utc: .gmt
        case .local: .autoupdatingCurrent
        case .custom(let identifier): TimeZone(identifier: identifier) ?? .gmt
        }
    }
}

/// How one entity's grid is laid out and ordered.
public struct EntityLayout: Sendable, Hashable {
    /// Columns in display order. A property the list does not mention is shown after these, in model order, so
    /// an attribute added to the model later is never silently invisible.
    public var columns: [ColumnLayout]
    public var sort: [SortKey]
    /// The predicate the grid is filtered by, as the user wrote it (§7.1). Kept with the layout because it is
    /// part of what the project is showing, and readable in the file for the same reason the sort is.
    public var filter: PredicateSource?
    /// The attribute that labels an object of this entity wherever a to-one points at it; `nil` = the engine's
    /// heuristic (BRW-2).
    public var displayAttribute: String?

    public init(
        columns: [ColumnLayout] = [], sort: [SortKey] = [], filter: PredicateSource? = nil,
        displayAttribute: String? = nil
    ) {
        self.columns = columns
        self.sort = sort
        self.filter = filter
        self.displayAttribute = displayAttribute
    }
}

public struct ColumnLayout: Sendable, Hashable {
    /// The column that shows the object's ID rather than a property.
    public static let objectIDColumn = "$objectID"
    /// The column that names each row's own entity when sub-entities are shown together (BRW-6).
    public static let entityColumn = "$entity"

    /// A property name, or one of the `$` columns above.
    public var property: String
    /// Points; `nil` = sized automatically.
    public var width: Double?
    public var isHidden: Bool

    public init(property: String, width: Double? = nil, isHidden: Bool = false) {
        self.property = property
        self.width = width
        self.isHidden = isHidden
    }
}

// MARK: - Coding

extension Project: Codable {
    private enum CodingKeys: String, CodingKey {
        case schemaVersion, id, store, model, accessMode, localStatePlacement = "localState", display
    }

    public init(from decoder: any Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        schemaVersion = try values.decodeIfPresent(Int.self, forKey: .schemaVersion) ?? Self.currentSchemaVersion
        id = try values.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        store = try values.decodeIfPresent(StoreLocation.self, forKey: .store)
        model = try values.decodeIfPresent(ModelReference.self, forKey: .model) ?? .storeCache
        accessMode = try values.decodeIfPresent(AccessMode.self, forKey: .accessMode) ?? .readOnly
        localStatePlacement =
            try values.decodeIfPresent(LocalStatePlacement.self, forKey: .localStatePlacement) ?? .inPackage
        display = try values.decodeIfPresent(DisplayPreferences.self, forKey: .display) ?? DisplayPreferences()
    }

    public func encode(to encoder: any Encoder) throws {
        var values = encoder.container(keyedBy: CodingKeys.self)
        try values.encode(schemaVersion, forKey: .schemaVersion)
        try values.encode(id, forKey: .id)
        try values.encodeIfPresent(store, forKey: .store)
        try values.encode(model, forKey: .model)
        try values.encode(accessMode, forKey: .accessMode)
        try values.encode(localStatePlacement, forKey: .localStatePlacement)
        try values.encode(display, forKey: .display)
    }
}

extension ModelReference: Codable {
    private enum CodingKeys: String, CodingKey { case kind, file }
    private enum Kind: String, Codable { case storeCache, file }

    public init(from decoder: any Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        switch try values.decode(Kind.self, forKey: .kind) {
        case .storeCache: self = .storeCache
        case .file: self = .file(try values.decode(FileReference.self, forKey: .file))
        }
    }

    public func encode(to encoder: any Encoder) throws {
        var values = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .storeCache:
            try values.encode(Kind.storeCache, forKey: .kind)
        case .file(let reference):
            try values.encode(Kind.file, forKey: .kind)
            try values.encode(reference, forKey: .file)
        }
    }
}

extension TimeZoneChoice: Codable {
    public init(from decoder: any Decoder) throws {
        switch try decoder.singleValueContainer().decode(String.self) {
        case "utc": self = .utc
        case "local": self = .local
        case let identifier: self = .custom(identifier)
        }
    }

    public func encode(to encoder: any Encoder) throws {
        var value = encoder.singleValueContainer()
        switch self {
        case .utc: try value.encode("utc")
        case .local: try value.encode("local")
        case .custom(let identifier): try value.encode(identifier)
        }
    }
}

extension DisplayPreferences: Codable {
    private enum CodingKeys: String, CodingKey { case timeZone, entities }

    public init(from decoder: any Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        timeZone = try values.decodeIfPresent(TimeZoneChoice.self, forKey: .timeZone) ?? .utc
        entities = try values.decodeIfPresent([String: EntityLayout].self, forKey: .entities) ?? [:]
    }
}

extension EntityLayout: Codable {
    private enum CodingKeys: String, CodingKey { case columns, sort, filter, displayAttribute }

    public init(from decoder: any Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        columns = try values.decodeIfPresent([ColumnLayout].self, forKey: .columns) ?? []
        sort = try values.decodeIfPresent([SortKey].self, forKey: .sort) ?? []
        filter = try values.decodeIfPresent(PredicateSource.self, forKey: .filter)
        displayAttribute = try values.decodeIfPresent(String.self, forKey: .displayAttribute)
    }
}

extension ColumnLayout: Codable {
    private enum CodingKeys: String, CodingKey { case property, width, isHidden = "hidden" }

    public init(from decoder: any Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        property = try values.decode(String.self, forKey: .property)
        width = try values.decodeIfPresent(Double.self, forKey: .width)
        isHidden = try values.decodeIfPresent(Bool.self, forKey: .isHidden) ?? false
    }
}
