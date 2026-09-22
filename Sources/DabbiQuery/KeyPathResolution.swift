import DabbiModel
import Foundation

/// Resolves a predicate key path against the model, one component at a time.
///
/// Every key path in a predicate goes through here before the predicate is executed: unknown paths become
/// diagnostics rather than the exception Core Data would raise mid-fetch (ARCHITECTURE.md §6.5). The same walk
/// backs autocomplete (M2-02), which asks what a *partial* path could continue with.
public struct KeyPathResolver: Sendable {
    public let model: ModelDescription

    public init(model: ModelDescription) {
        self.model = model
    }

    /// Resolves `keyPath` starting at `entity`.
    public func resolve(_ keyPath: String, in entity: String) -> Result<ResolvedKeyPath, KeyPathFailure> {
        guard model.entity(named: entity) != nil else {
            return .failure(
                KeyPathFailure(resolvedPrefix: "", component: entity, reason: .unknownEntity, candidates: []))
        }
        return resolve(keyPath, from: ResolvedKeyPath(target: .object(entity: entity), isCollection: false))
    }

    /// Resolves `keyPath` relative to somewhere a previous resolution ended — the entity a `SUBQUERY` iterator
    /// is bound to, or the object on the left of `$item.price`.
    public func resolve(_ keyPath: String, from start: ResolvedKeyPath) -> Result<ResolvedKeyPath, KeyPathFailure> {
        var current = start
        var resolved: [String] = []

        for component in keyPath.split(separator: ".", omittingEmptySubsequences: false).map(String.init) {
            let failure = { (reason: KeyPathFailure.Reason, candidates: [String]) in
                Result<ResolvedKeyPath, KeyPathFailure>.failure(
                    KeyPathFailure(
                        resolvedPrefix: resolved.joined(separator: "."), component: component, reason: reason,
                        candidates: candidates))
            }
            guard !component.isEmpty else { return failure(.emptyComponent, []) }

            if component == "SELF" {
                guard resolved.isEmpty else { return failure(.selfNotFirst, []) }
                resolved.append(component)
                continue
            }
            if component.hasPrefix("@") {
                guard let op = CollectionOperator(rawValue: component) else {
                    return failure(.unknownCollectionOperator, CollectionOperator.allCases.map(\.rawValue))
                }
                current = ResolvedKeyPath(
                    target: .collectionOperator(op, over: current.target), isCollection: op.producesCollection)
                resolved.append(component)
                continue
            }
            switch step(from: current.target, through: component) {
            case .moved(let next):
                // Anything read through a to-many names many values, however far the path goes on: the `title`
                // in `books.title` is as much a collection as `books` is.
                current = ResolvedKeyPath(
                    target: next, isCollection: current.isCollection || next.isToManyRelationship)
                resolved.append(component)
            case .failed(let reason):
                return failure(reason, candidates(after: current))
            }
        }
        return .success(current)
    }

    /// What a key path standing at `resolved` can continue with: property names, and the collection operators
    /// when it names many values. Feeds autocomplete and "did you mean".
    public func candidates(after resolved: ResolvedKeyPath) -> [String] {
        let properties: [String]
        switch resolved.target {
        case .object(let entity):
            properties = model.entity(named: entity)?.propertyNames ?? []
        case .toOne(let relationship), .toMany(let relationship):
            properties = model.entity(named: relationship.destinationEntity)?.propertyNames ?? []
        case .attribute(let attribute, _):
            properties = attribute.compositeElements?.map(\.name) ?? []
        case .collectionOperator, .fetchedProperty:
            properties = []
        }
        guard resolved.isCollection else { return properties }
        return properties + CollectionOperator.allCases.map(\.rawValue)
    }

    private enum Step {
        case moved(KeyPathTarget)
        case failed(KeyPathFailure.Reason)
    }

    private func step(from target: KeyPathTarget, through name: String) -> Step {
        switch target {
        case .object(let entity):
            return property(named: name, of: entity)
        case .toOne(let relationship), .toMany(let relationship):
            return property(named: name, of: relationship.destinationEntity)
        case .attribute(let attribute, let entity):
            // A composite attribute's elements are addressable: `place.latitude` (S3).
            guard let elements = attribute.compositeElements else {
                return .failed(.notTraversable(kind: attribute.type.displayName))
            }
            guard let element = elements.first(where: { $0.name == name }) else {
                return .failed(.unknownCompositeElement(attribute: attribute.name))
            }
            return .moved(.attribute(element, entity: entity))
        case .collectionOperator(let op, _):
            return .failed(.notTraversable(kind: op.rawValue))
        case .fetchedProperty:
            return .failed(.notTraversable(kind: "fetched property"))
        }
    }

    private func property(named name: String, of entity: String) -> Step {
        guard let description = model.entity(named: entity) else { return .failed(.unknownEntity) }
        if let attribute = description.attribute(named: name) {
            return .moved(.attribute(attribute, entity: entity))
        }
        if let relationship = description.relationship(named: name) {
            return .moved(relationship.isToMany ? .toMany(relationship) : .toOne(relationship))
        }
        if description.fetchedProperties.contains(name) {
            return .moved(.fetchedProperty(name: name, entity: entity))
        }
        return .failed(.unknownProperty(entity: entity))
    }
}

/// Where a key path ends, and whether it got there through a to-many.
public struct ResolvedKeyPath: Sendable, Hashable {
    public var target: KeyPathTarget
    /// Whether the key path names many values rather than one — what decides whether `ANY`/`ALL` belongs.
    /// True as soon as the path crosses a to-many, and false again after `@count` and the other reducers.
    public var isCollection: Bool

    public init(target: KeyPathTarget, isCollection: Bool) {
        self.target = target
        self.isCollection = isCollection
    }

    /// What kind of constant the key path can be compared with.
    public var typeGroup: AttributeTypeGroup { target.typeGroup }
    /// The entity a key path standing here continues from, when there is one.
    public var entityName: String? { target.entityName }
}

/// Where a key path ends.
public indirect enum KeyPathTarget: Sendable, Hashable {
    /// `SELF`, or the start of every key path.
    case object(entity: String)
    /// `entity` is the entity the key path arrived at, not the one that declares the attribute.
    case attribute(AttributeDescription, entity: String)
    case toOne(RelationshipDescription)
    case toMany(RelationshipDescription)
    case collectionOperator(CollectionOperator, over: KeyPathTarget)
    /// A fetched property. Part of the model, but not something a predicate can compare against.
    case fetchedProperty(name: String, entity: String)

    var isToManyRelationship: Bool {
        if case .toMany = self { return true }
        return false
    }

    /// What kind of constant the key path can be compared with.
    public var typeGroup: AttributeTypeGroup {
        switch self {
        case .object, .toOne, .toMany, .fetchedProperty: .object
        case .attribute(let attribute, _): AttributeTypeGroup(attribute.type)
        case .collectionOperator(let op, let inner): op.resultType(over: inner)
        }
    }

    /// The entity a key path standing here continues from, when there is one.
    public var entityName: String? {
        switch self {
        case .object(let entity), .fetchedProperty(_, let entity): entity
        case .toOne(let relationship), .toMany(let relationship): relationship.destinationEntity
        case .attribute: nil
        case .collectionOperator(_, let inner): inner.entityName
        }
    }
}

public enum CollectionOperator: String, Sendable, Hashable, Codable, CaseIterable {
    case count = "@count"
    case sum = "@sum"
    case avg = "@avg"
    case min = "@min"
    case max = "@max"
    case unionOfObjects = "@unionOfObjects"
    case distinctUnionOfObjects = "@distinctUnionOfObjects"
    case unionOfArrays = "@unionOfArrays"
    case distinctUnionOfArrays = "@distinctUnionOfArrays"
    case unionOfSets = "@unionOfSets"
    case distinctUnionOfSets = "@distinctUnionOfSets"

    /// Whether the operator yields many values rather than one.
    public var producesCollection: Bool {
        switch self {
        case .count, .sum, .avg, .min, .max: false
        default: true
        }
    }

    /// `@count` is the only one Core Data's SQLite store can turn into SQL; the rest raise at fetch time, so a
    /// predicate that uses them is flagged before it runs.
    public var isSupportedBySQLiteStore: Bool { self == .count }

    func resultType(over inner: KeyPathTarget) -> AttributeTypeGroup {
        switch self {
        case .count: .number
        case .sum, .avg: .number
        case .min, .max: inner.typeGroup
        default: inner.typeGroup
        }
    }
}

public struct KeyPathFailure: Error, Sendable, Hashable, Codable {
    public enum Reason: Sendable, Hashable, Codable {
        case unknownEntity
        case unknownProperty(entity: String)
        /// The path continues past something that has no properties — an attribute, a `@count`.
        case notTraversable(kind: String)
        case unknownCompositeElement(attribute: String)
        case unknownCollectionOperator
        case selfNotFirst
        case emptyComponent
    }

    /// The part of the key path that did resolve, e.g. `author.address`.
    public var resolvedPrefix: String
    /// The component that did not.
    public var component: String
    public var reason: Reason
    /// What the component could have been, for "did you mean" and autocomplete.
    public var candidates: [String]

    /// The whole key path up to and including the component that failed.
    public var keyPath: String {
        resolvedPrefix.isEmpty ? component : "\(resolvedPrefix).\(component)"
    }

    public var message: String {
        switch reason {
        case .unknownEntity:
            "There is no entity named “\(component)” in the model."
        case .unknownProperty(let entity):
            "\(entity) has no property named “\(component)”."
        case .notTraversable(let kind):
            "“\(resolvedPrefix)” is \(kind), so “\(component)” cannot follow it."
        case .unknownCompositeElement(let attribute):
            "The composite attribute “\(attribute)” has no element named “\(component)”."
        case .unknownCollectionOperator:
            "“\(component)” is not a collection operator."
        case .selfNotFirst:
            "SELF can only be the first part of a key path."
        case .emptyComponent:
            "The key path “\(resolvedPrefix).” is missing a part after the dot."
        }
    }

    /// The closest candidates by edit distance, for a "did you mean" line. At most three, and only ones that are
    /// actually close — an unrelated name is worse than no suggestion.
    public var suggestions: [String] {
        let target = component.lowercased()
        let budget = max(2, target.count / 3)
        return
            candidates
            .map { ($0, editDistance($0.lowercased(), target)) }
            .filter { $0.1 <= budget }
            .sorted { ($0.1, $0.0) < ($1.1, $1.0) }
            .prefix(3)
            .map(\.0)
    }
}

/// Levenshtein distance, two rows at a time.
private func editDistance(_ lhs: String, _ rhs: String) -> Int {
    let a = Array(lhs), b = Array(rhs)
    if a.isEmpty { return b.count }
    if b.isEmpty { return a.count }
    var previous = Array(0...b.count)
    var current = previous
    for i in 1...a.count {
        current[0] = i
        for j in 1...b.count {
            let substitution = previous[j - 1] + (a[i - 1] == b[j - 1] ? 0 : 1)
            current[j] = Swift.min(previous[j] + 1, current[j - 1] + 1, substitution)
        }
        swap(&previous, &current)
    }
    return previous[b.count]
}

extension AttributeTypeGroup {
    public init(_ type: AttributeType) {
        switch type {
        case .integer16, .integer32, .integer64, .decimal, .double, .float: self = .number
        case .string: self = .string
        case .boolean: self = .boolean
        case .date: self = .date
        case .binaryData: self = .binary
        case .uuid: self = .uuid
        case .uri: self = .uri
        case .transformable: self = .transformable
        case .objectID: self = .object
        case .composite: self = .composite
        case .undefined: self = .unknown
        }
    }

    /// Whether a constant of `other`'s group can sensibly be compared with a value of this one. Deliberately
    /// forgiving: a warning is for a comparison that is certainly wrong, not one that is merely unusual.
    public func accepts(_ other: AttributeTypeGroup) -> Bool {
        if self == other || self == .unknown || other == .unknown { return true }
        switch self {
        // Core Data stores booleans as numbers, and `flag == 1` is how plenty of predicates are written.
        case .number, .boolean: return other == .number || other == .boolean
        // A UUID or a URI written as text is the usual way to type one.
        case .uuid, .uri: return other == .string
        // Transformable and binary values have no comparable SQL form; nothing about them is certainly wrong.
        case .transformable, .binary, .composite: return true
        case .object: return other == .object || other == .string
        case .string, .date: return false
        case .unknown: return true
        }
    }
}
