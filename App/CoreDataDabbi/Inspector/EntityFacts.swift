import DabbiKit
import Foundation

/// The model, put into words (BRW-8).
///
/// Everything Core Data knows about an entity that is worth reading: not a re-implementation of the model
/// editor, but the answer to "what is actually allowed in this column, and what happens when I delete this row".
/// Pure, so that what the inspector says about a model can be tested without a window.
struct EntityFacts {
    /// One line of the inspector: a label, its value, and whether the value is worth pointing out.
    struct Fact: Identifiable, Hashable {
        enum Weight {
            /// An ordinary reading.
            case plain
            /// Something that constrains what the data can be: not optional, a delete rule that bites, a range.
            case notable
            /// Something the app cannot fully honour, or that will surprise: a transformer, a derivation.
            case warning
        }

        var id: String { label }
        var label: String
        var value: String
        var weight: Weight = .plain
    }

    struct Property: Identifiable, Hashable {
        enum Kind: Hashable {
            case attribute(AttributeType)
            case relationship(destination: String, isToMany: Bool)
        }

        var id: String { name }
        var name: String
        var kind: Kind
        /// The one-line summary under the name: "String · optional", "To-many · Cascade · ordered".
        var summary: String
        var facts: [Fact]
        /// Whether it is inherited rather than this entity's own.
        var declaredIn: String?

        /// True when something here is worth seeing before the row is expanded.
        var isNotable: Bool { facts.contains { $0.weight != .plain } }

        var typeName: String {
            switch kind {
            case .attribute(let type): type.displayName
            case .relationship(let destination, let isToMany):
                isToMany
                    ? String(localized: "To-many → \(destination)") : String(localized: "To-one → \(destination)")
            }
        }
    }

    struct Index: Identifiable, Hashable {
        var id: String { name }
        var name: String
        /// `"name ↑"`, `"createdAt ↓ (R-tree)"` — one per element, in the index's own order.
        var elements: [String]
        var predicate: String?
    }

    var entity: EntityDescription
    var attributes: [Property]
    var relationships: [Property]
    /// Facts about the entity itself: class, abstract, parent, version hash.
    var summary: [Fact]
    var indexes: [Index]
    var uniquenessConstraints: [[String]]
    var userInfo: [Fact]

    init(entity: EntityDescription, in model: ModelDescription) {
        self.entity = entity
        attributes =
            entity.attributes
            .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
            .map(Self.property)
        relationships =
            entity.relationships
            .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
            .map(Self.property)
        summary = Self.summary(of: entity, in: model)
        indexes = entity.indexes.map(Self.index)
        uniquenessConstraints = entity.uniquenessConstraints
        userInfo = entity.userInfo.keys.sorted().map { Fact(label: $0, value: entity.userInfo[$0] ?? "") }
    }

    // MARK: The entity

    private static func summary(of entity: EntityDescription, in model: ModelDescription) -> [Fact] {
        var facts: [Fact] = []
        if let className = entity.managedObjectClassName {
            facts.append(Fact(label: String(localized: "Class"), value: className))
        }
        if entity.isAbstract {
            facts.append(
                Fact(
                    label: String(localized: "Abstract"),
                    value: String(localized: "Yes — its rows are its subentities'"), weight: .notable))
        }
        if let superentity = entity.superentity {
            facts.append(Fact(label: String(localized: "Inherits from"), value: superentity))
        }
        if !entity.subentities.isEmpty {
            facts.append(
                Fact(
                    label: String(localized: "Subentities"),
                    value: entity.subentities.sorted().joined(separator: ", ")))
        }
        // Where the rows really are: everything in one chain shares the root's table, which explains both the
        // columns the Structure tab shows and why an abstract entity has a count at all.
        if let root = model.rootEntity(of: entity.name), root.name != entity.name {
            facts.append(Fact(label: String(localized: "Stored with"), value: root.name))
        }
        if !entity.fetchedProperties.isEmpty {
            facts.append(
                Fact(
                    label: String(localized: "Fetched properties"),
                    value: entity.fetchedProperties.sorted().joined(separator: ", ")))
        }
        if let renaming = entity.renamingIdentifier, renaming != entity.name {
            facts.append(Fact(label: String(localized: "Renaming ID"), value: renaming))
        }
        if let modifier = entity.versionHashModifier {
            facts.append(Fact(label: String(localized: "Version hash modifier"), value: modifier))
        }
        facts.append(Fact(label: String(localized: "Version hash"), value: entity.versionHash.hexString))
        return facts
    }

    private static func index(_ index: IndexDescription) -> Index {
        Index(
            name: index.name,
            elements: index.elements.map { element in
                let arrow = element.isAscending ? "↑" : "↓"
                return element.collation == .rTree
                    ? "\(element.property) \(arrow) (R-tree)" : "\(element.property) \(arrow)"
            },
            predicate: index.partialIndexPredicate)
    }

    // MARK: Attributes

    private static func property(_ attribute: AttributeDescription) -> Property {
        var facts: [Fact] = [Fact(label: String(localized: "Type"), value: attribute.type.displayName)]
        if !attribute.isOptional {
            facts.append(
                Fact(label: String(localized: "Optional"), value: String(localized: "No"), weight: .notable))
        }
        if attribute.isTransient {
            // A transient attribute is not in the file at all; a grid column of them would show nothing.
            facts.append(
                Fact(
                    label: String(localized: "Transient"),
                    value: String(localized: "Yes — not stored, and not shown in the grid"), weight: .warning))
        }
        if let expression = attribute.derivationExpression {
            facts.append(Fact(label: String(localized: "Derived from"), value: expression, weight: .warning))
        }
        if let value = attribute.defaultValue {
            facts.append(Fact(label: String(localized: "Default"), value: value))
        }
        facts += validation(attribute.validation)
        if attribute.type == .transformable {
            // The app never runs a transformer on stored bytes (ADR-08); naming it is the honest thing.
            let name = attribute.valueTransformerName ?? String(localized: "Secure unarchiving (the default)")
            facts.append(
                Fact(
                    label: String(localized: "Transformer"),
                    value: String(localized: "\(name) — not run; the bytes are shown as they are"),
                    weight: .warning))
        } else if let transformer = attribute.valueTransformerName {
            facts.append(Fact(label: String(localized: "Transformer"), value: transformer, weight: .warning))
        }
        if let className = attribute.attributeValueClassName {
            facts.append(Fact(label: String(localized: "Value class"), value: className))
        }
        if attribute.allowsExternalBinaryDataStorage {
            facts.append(
                Fact(
                    label: String(localized: "External storage"),
                    value: String(localized: "Large values are kept in files beside the store"), weight: .notable))
        }
        if attribute.preservesValueInHistoryOnDeletion {
            facts.append(Fact(label: String(localized: "Kept in history"), value: String(localized: "On deletion")))
        }
        if let elements = attribute.compositeElements, !elements.isEmpty {
            facts.append(
                Fact(
                    label: String(localized: "Elements"),
                    value: elements.map { "\($0.name): \($0.type.displayName)" }.joined(separator: ", ")))
        }
        if let composite = attribute.compositeName {
            facts.append(Fact(label: String(localized: "Composite type"), value: composite))
        }
        if let renaming = attribute.renamingIdentifier, renaming != attribute.name {
            facts.append(Fact(label: String(localized: "Renaming ID"), value: renaming))
        }
        facts += attribute.userInfo.keys.sorted().map { Fact(label: $0, value: attribute.userInfo[$0] ?? "") }

        var summary = [attribute.type.displayName]
        if attribute.isOptional { summary.append(String(localized: "optional")) }
        if attribute.isTransient { summary.append(String(localized: "transient")) }
        if attribute.isDerived { summary.append(String(localized: "derived")) }
        return Property(
            name: attribute.name, kind: .attribute(attribute.type), summary: summary.joined(separator: " · "),
            facts: facts, declaredIn: attribute.declaredIn)
    }

    /// The rules that came out of the attribute's validation predicates — and the predicates themselves when
    /// they had a shape nothing here recognises, so that a rule is never silently dropped.
    private static func validation(_ validation: ValidationFacets) -> [Fact] {
        var facts: [Fact] = []
        switch (validation.minimum, validation.maximum) {
        case (let minimum?, let maximum?):
            facts.append(
                Fact(label: String(localized: "Range"), value: "\(minimum) … \(maximum)", weight: .notable))
        case (let minimum?, nil):
            facts.append(Fact(label: String(localized: "Minimum"), value: minimum, weight: .notable))
        case (nil, let maximum?):
            facts.append(Fact(label: String(localized: "Maximum"), value: maximum, weight: .notable))
        case (nil, nil):
            break
        }
        switch (validation.minimumLength, validation.maximumLength) {
        case (let minimum?, let maximum?):
            facts.append(
                Fact(label: String(localized: "Length"), value: "\(minimum) … \(maximum)", weight: .notable))
        case (let minimum?, nil):
            facts.append(
                Fact(label: String(localized: "Minimum length"), value: "\(minimum)", weight: .notable))
        case (nil, let maximum?):
            facts.append(
                Fact(label: String(localized: "Maximum length"), value: "\(maximum)", weight: .notable))
        case (nil, nil):
            break
        }
        if let pattern = validation.regularExpression {
            facts.append(Fact(label: String(localized: "Pattern"), value: pattern, weight: .notable))
        }
        if !validation.predicates.isEmpty {
            facts.append(
                Fact(
                    label: String(localized: "Validation"),
                    value: validation.predicates.joined(separator: "\n"), weight: .notable))
        }
        return facts
    }

    // MARK: Relationships

    private static func property(_ relationship: RelationshipDescription) -> Property {
        var facts: [Fact] = [
            Fact(label: String(localized: "Destination"), value: relationship.destinationEntity),
            Fact(
                label: String(localized: "Kind"),
                value: relationship.isToMany ? String(localized: "To-many") : String(localized: "To-one")),
        ]
        if let inverse = relationship.inverseName {
            facts.append(Fact(label: String(localized: "Inverse"), value: inverse))
        } else {
            // Without an inverse Core Data keeps only one end in step; worth knowing before anything is edited.
            facts.append(Fact(label: String(localized: "Inverse"), value: String(localized: "None"), weight: .warning))
        }
        facts.append(
            Fact(
                label: String(localized: "Delete rule"), value: name(of: relationship.deleteRule),
                weight: relationship.deleteRule == .cascade || relationship.deleteRule == .deny
                    ? .notable : .plain))
        if relationship.isOrdered {
            facts.append(Fact(label: String(localized: "Ordered"), value: String(localized: "Yes")))
        }
        if !relationship.isOptional {
            facts.append(
                Fact(label: String(localized: "Optional"), value: String(localized: "No"), weight: .notable))
        }
        if relationship.isTransient {
            facts.append(
                Fact(
                    label: String(localized: "Transient"), value: String(localized: "Yes — not stored"),
                    weight: .warning))
        }
        if relationship.minCount > 0 || relationship.maxCount > 0 {
            let maximum = relationship.maxCount > 0 ? "\(relationship.maxCount)" : String(localized: "unlimited")
            facts.append(
                Fact(
                    label: String(localized: "Count"), value: "\(relationship.minCount) … \(maximum)",
                    weight: .notable))
        }
        if let renaming = relationship.renamingIdentifier, renaming != relationship.name {
            facts.append(Fact(label: String(localized: "Renaming ID"), value: renaming))
        }
        facts += relationship.userInfo.keys.sorted().map { Fact(label: $0, value: relationship.userInfo[$0] ?? "") }

        var summary = [relationship.isToMany ? String(localized: "To-many") : String(localized: "To-one")]
        summary.append(name(of: relationship.deleteRule))
        if relationship.isOrdered { summary.append(String(localized: "ordered")) }
        if relationship.inverseName == nil { summary.append(String(localized: "no inverse")) }
        return Property(
            name: relationship.name,
            kind: .relationship(destination: relationship.destinationEntity, isToMany: relationship.isToMany),
            summary: summary.joined(separator: " · "), facts: facts, declaredIn: relationship.declaredIn)
    }

    private static func name(of rule: DeleteRule) -> String {
        switch rule {
        case .noAction: String(localized: "No action")
        case .nullify: String(localized: "Nullify")
        case .cascade: String(localized: "Cascade")
        case .deny: String(localized: "Deny")
        }
    }
}
