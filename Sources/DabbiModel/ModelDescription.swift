import DabbiBase
import Foundation

/// A complete value-type mirror of an `NSManagedObjectModel`.
///
/// One source feeds the sidebar, the entity inspector, predicate autocomplete, diagrams, model diff,
/// `dabbi describe` and the MCP `describe_model` tool. It is built from the model *before* sanitising, so class
/// and transformer names are the app's own.
public struct ModelDescription: Sendable, Hashable, Codable {
    /// Sorted by name.
    public var entities: [EntityDescription]
    public var versionIdentifiers: [String]
    /// Sorted by name. A cached model can lack these even when the app's bundled model has them (PRJ-3).
    public var fetchRequestTemplates: [FetchRequestTemplate]
    /// Configuration name → entity names.
    public var configurations: [String: [String]]

    public init(
        entities: [EntityDescription],
        versionIdentifiers: [String] = [],
        fetchRequestTemplates: [FetchRequestTemplate] = [],
        configurations: [String: [String]] = [:]
    ) {
        self.entities = entities.sorted { $0.name < $1.name }
        self.versionIdentifiers = versionIdentifiers
        self.fetchRequestTemplates = fetchRequestTemplates.sorted { $0.name < $1.name }
        self.configurations = configurations
    }

    public func entity(named name: String) -> EntityDescription? {
        entities.first { $0.name == name }
    }

    /// Entities without a parent, sorted by name.
    public var rootEntities: [EntityDescription] {
        entities.filter { $0.superentity == nil }
    }

    /// The top of `entity`'s inheritance chain — the entity whose table its rows live in.
    public func rootEntity(of entity: String) -> EntityDescription? {
        var current = self.entity(named: entity)
        while let parent = current?.superentity, let next = self.entity(named: parent) { current = next }
        return current
    }

    /// `entity` followed by all of its descendants, depth first.
    public func entityAndDescendants(of entity: String) -> [EntityDescription] {
        guard let start = self.entity(named: entity) else { return [] }
        return [start] + start.subentities.sorted().flatMap { entityAndDescendants(of: $0) }
    }

    public var entityVersionHashes: [String: Data] {
        Dictionary(uniqueKeysWithValues: entities.map { ($0.name, $0.versionHash) })
    }
}

public struct EntityDescription: Sendable, Hashable, Codable {
    public var name: String
    /// The app's class name. The engine itself always instantiates plain `NSManagedObject`s.
    public var managedObjectClassName: String?
    public var isAbstract: Bool
    public var superentity: String?
    /// Direct children only.
    public var subentities: [String]
    /// Own and inherited attributes, in the model's order.
    public var attributes: [AttributeDescription]
    /// Own and inherited relationships, in the model's order.
    public var relationships: [RelationshipDescription]
    public var fetchedProperties: [String]
    public var indexes: [IndexDescription]
    public var uniquenessConstraints: [[String]]
    public var userInfo: [String: String]
    public var renamingIdentifier: String?
    public var versionHash: Data
    public var versionHashModifier: String?

    public func attribute(named name: String) -> AttributeDescription? { attributes.first { $0.name == name } }
    public func relationship(named name: String) -> RelationshipDescription? {
        relationships.first { $0.name == name }
    }

    /// Attribute names followed by relationship names: the default column order of a grid.
    public var propertyNames: [String] { attributes.map(\.name) + relationships.map(\.name) }

    /// Attribute names tried first, in order, as the label of an object of this entity (BRW-2, REL-1).
    public static let displayNameCandidates = ["name", "title", "label", "identifier"]

    /// The attribute that labels an object of this entity wherever there is no room for all of it — a to-one in
    /// the grid, a related object in the relationships panel: the first of the conventional names the entity
    /// has, or failing that its first string attribute.
    ///
    /// A project can override the choice per entity (`EntityLayout.displayAttribute`); this is what it overrides.
    public var displayAttributeName: String? {
        let strings = attributes.filter { $0.type == .string && !$0.isTransient }.map(\.name)
        return Self.displayNameCandidates.first(where: strings.contains) ?? strings.first
    }
}

public enum AttributeType: String, Sendable, Hashable, Codable, CaseIterable {
    case integer16, integer32, integer64, decimal, double, float, string, boolean, date, binaryData
    case uuid, uri, transformable, objectID, composite, undefined

    /// The label used by Xcode's model editor.
    public var displayName: String {
        switch self {
        case .integer16: "Integer 16"
        case .integer32: "Integer 32"
        case .integer64: "Integer 64"
        case .decimal: "Decimal"
        case .double: "Double"
        case .float: "Float"
        case .string: "String"
        case .boolean: "Boolean"
        case .date: "Date"
        case .binaryData: "Binary Data"
        case .uuid: "UUID"
        case .uri: "URI"
        case .transformable: "Transformable"
        case .objectID: "Object ID"
        case .composite: "Composite"
        case .undefined: "Undefined"
        }
    }
}

public struct AttributeDescription: Sendable, Hashable, Codable {
    public var name: String
    public var type: AttributeType
    public var isOptional: Bool
    public var isTransient: Bool
    /// The entity that declares the attribute — an ancestor when it is inherited.
    public var declaredIn: String
    /// The default value, rendered as text. Defaults are part of the model, not row data.
    public var defaultValue: String?
    public var validation: ValidationFacets
    /// The app's transformer name. `nil` on a transformable means Core Data's secure-unarchive default.
    public var valueTransformerName: String?
    public var attributeValueClassName: String?
    public var allowsExternalBinaryDataStorage: Bool
    public var preservesValueInHistoryOnDeletion: Bool
    /// The derivation expression of a derived attribute, e.g. `items.@count`.
    public var derivationExpression: String?
    /// Element attributes of a composite attribute, possibly nested.
    public var compositeElements: [AttributeDescription]?
    public var compositeName: String?
    public var userInfo: [String: String]
    public var renamingIdentifier: String?
    public var versionHash: Data

    public var isDerived: Bool { derivationExpression != nil }
}

/// Validation rules of an attribute, extracted from its validation predicates where they have the shapes the
/// model editor produces. `predicates` always holds every rule verbatim.
public struct ValidationFacets: Sendable, Hashable, Codable {
    public var minimum: String?
    public var maximum: String?
    public var minimumLength: Int?
    public var maximumLength: Int?
    public var regularExpression: String?
    /// Predicate format strings, one per rule.
    public var predicates: [String]

    public init(
        minimum: String? = nil,
        maximum: String? = nil,
        minimumLength: Int? = nil,
        maximumLength: Int? = nil,
        regularExpression: String? = nil,
        predicates: [String] = []
    ) {
        self.minimum = minimum
        self.maximum = maximum
        self.minimumLength = minimumLength
        self.maximumLength = maximumLength
        self.regularExpression = regularExpression
        self.predicates = predicates
    }

    public var isEmpty: Bool { predicates.isEmpty }
}

public enum DeleteRule: String, Sendable, Hashable, Codable {
    case noAction, nullify, cascade, deny
}

public struct RelationshipDescription: Sendable, Hashable, Codable {
    public var name: String
    public var destinationEntity: String
    /// `nil` for a one-directional relationship.
    public var inverseName: String?
    public var isToMany: Bool
    public var isOrdered: Bool
    public var isOptional: Bool
    public var isTransient: Bool
    public var deleteRule: DeleteRule
    public var minCount: Int
    /// 0 means unbounded for a to-many relationship.
    public var maxCount: Int
    public var declaredIn: String
    public var userInfo: [String: String]
    public var renamingIdentifier: String?
    public var versionHash: Data
}

public struct IndexDescription: Sendable, Hashable, Codable {
    public struct Element: Sendable, Hashable, Codable {
        public enum Collation: String, Sendable, Hashable, Codable { case binary, rTree }
        /// A property name, or an expression's text for expression-based elements.
        public var property: String
        public var isAscending: Bool
        public var collation: Collation
    }

    public var name: String
    public var elements: [Element]
    public var partialIndexPredicate: String?
}

public struct FetchRequestTemplate: Sendable, Hashable, Codable {
    public var name: String
    public var entity: String?
    public var predicateFormat: String?
    public var sort: [SortKey]
    public var fetchLimit: Int
    /// `$VARIABLE` names the predicate expects, without the `$`, sorted.
    public var substitutionVariables: [String]

    public init(
        name: String, entity: String?, predicateFormat: String?, sort: [SortKey] = [], fetchLimit: Int = 0,
        substitutionVariables: [String] = []
    ) {
        self.name = name
        self.entity = entity
        self.predicateFormat = predicateFormat
        self.sort = sort
        self.fetchLimit = fetchLimit
        self.substitutionVariables = substitutionVariables
    }
}

extension Data {
    /// Lower-case hexadecimal — how version hashes are shown.
    public var hexString: String { map { String(format: "%02x", $0) }.joined() }
}
