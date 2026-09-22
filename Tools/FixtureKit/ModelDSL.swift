@preconcurrency import CoreData
import Foundation

// A small vocabulary for building models in code. Fixtures are generated, never checked in, so every model the
// tests need is described here rather than in an .xcdatamodeld.

func entity(
    _ name: String,
    className: String? = nil,
    abstract: Bool = false,
    parent: NSEntityDescription? = nil,
    _ properties: [NSPropertyDescription]
) -> NSEntityDescription {
    let entity = NSEntityDescription()
    entity.name = name
    // A class name the inspecting process cannot resolve — exactly what a real app's store looks like.
    entity.managedObjectClassName = className ?? "FixtureApp.\(name)"
    entity.isAbstract = abstract
    entity.properties = properties
    if let parent { parent.subentities.append(entity) }
    return entity
}

func attribute(
    _ name: String,
    _ type: NSAttributeType,
    optional: Bool = true,
    defaultValue: Any? = nil,
    transformer: String? = nil,
    externalStorage: Bool = false,
    preserved: Bool = false,
    validation: [String] = [],
    userInfo: [String: String] = [:]
) -> NSAttributeDescription {
    let attribute = NSAttributeDescription()
    attribute.name = name
    attribute.attributeType = type
    attribute.isOptional = optional
    attribute.defaultValue = defaultValue
    attribute.allowsExternalBinaryDataStorage = externalStorage
    // What persistent history keeps of the value after the row is deleted — the only prior value a tombstone has.
    attribute.preservesValueInHistoryOnDeletion = preserved
    if type == .transformableAttributeType { attribute.valueTransformerName = transformer }
    if !validation.isEmpty {
        attribute.setValidationPredicates(
            validation.map { NSPredicate(format: $0) },
            withValidationWarnings: validation.map { "Fails: \($0)" })
    }
    if !userInfo.isEmpty { attribute.userInfo = userInfo }
    return attribute
}

func derived(_ name: String, _ type: NSAttributeType, _ expression: String) -> NSDerivedAttributeDescription {
    let attribute = NSDerivedAttributeDescription()
    attribute.name = name
    attribute.attributeType = type
    attribute.isOptional = true
    attribute.derivationExpression = NSExpression(format: expression)
    return attribute
}

func composite(_ name: String, _ elements: [NSAttributeDescription]) -> NSCompositeAttributeDescription {
    let attribute = NSCompositeAttributeDescription()
    attribute.name = name
    attribute.isOptional = true
    attribute.elements = elements
    return attribute
}

enum Cardinality {
    case toOne
    case toMany
    case orderedToMany
}

/// Adds a relationship and its inverse. Call after both entities exist.
func relate(
    _ source: NSEntityDescription, _ name: String, _ cardinality: Cardinality,
    _ destination: NSEntityDescription, inverse inverseName: String, _ inverseCardinality: Cardinality,
    deleteRule: NSDeleteRule = .nullifyDeleteRule,
    inverseDeleteRule: NSDeleteRule = .nullifyDeleteRule
) {
    let forward = relationship(name, cardinality, to: destination, deleteRule: deleteRule)
    let backward = relationship(inverseName, inverseCardinality, to: source, deleteRule: inverseDeleteRule)
    forward.inverseRelationship = backward
    backward.inverseRelationship = forward
    source.properties.append(forward)
    // A self-relationship's two ends live on the same entity.
    destination.properties.append(backward)
}

/// Adds a relationship without an inverse.
func relateOneWay(
    _ source: NSEntityDescription, _ name: String, _ cardinality: Cardinality, _ destination: NSEntityDescription
) {
    source.properties.append(relationship(name, cardinality, to: destination, deleteRule: .nullifyDeleteRule))
}

private func relationship(
    _ name: String, _ cardinality: Cardinality, to destination: NSEntityDescription, deleteRule: NSDeleteRule
) -> NSRelationshipDescription {
    let relationship = NSRelationshipDescription()
    relationship.name = name
    relationship.destinationEntity = destination
    relationship.isOptional = true
    relationship.deleteRule = deleteRule
    relationship.minCount = 0
    switch cardinality {
    case .toOne:
        relationship.maxCount = 1
    case .toMany:
        relationship.maxCount = 0
    case .orderedToMany:
        relationship.maxCount = 0
        relationship.isOrdered = true
    }
    return relationship
}

func model(_ entities: [NSEntityDescription], identifier: String? = nil) -> NSManagedObjectModel {
    let model = NSManagedObjectModel()
    model.entities = entities
    if let identifier { model.versionIdentifiers = [identifier] }
    return model
}

// MARK: - Compiled model files

enum ModelFiles {
    /// Writes `model` as a compiled model. A `.mom` is a keyed archive of the `NSManagedObjectModel`.
    static func writeMOM(_ model: NSManagedObjectModel, to url: URL) throws {
        let data = try NSKeyedArchiver.archivedData(withRootObject: model, requiringSecureCoding: true)
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: url)
    }

    /// Writes a versioned model bundle: one `.mom` per version plus `VersionInfo.plist`.
    static func writeMOMD(
        versions: [(name: String, model: NSManagedObjectModel)], current: String, to url: URL
    ) throws {
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        var hashes: [String: [String: Data]] = [:]
        for (name, model) in versions {
            try writeMOM(model, to: url.appendingPathComponent("\(name).mom"))
            hashes[name] = model.entityVersionHashesByName
        }
        let info: [String: Any] = [
            "NSManagedObjectModel_CurrentVersionName": current,
            "NSManagedObjectModel_VersionHashes": hashes,
        ]
        let plist = try PropertyListSerialization.data(fromPropertyList: info, format: .binary, options: 0)
        try plist.write(to: url.appendingPathComponent("VersionInfo.plist"))
    }
}
