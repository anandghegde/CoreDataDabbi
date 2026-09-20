@preconcurrency import CoreData
import DabbiBase
import Foundation

extension ModelDescription {
    /// Mirrors `model`. Pass the model as loaded, *before* sanitising, so the app's class and transformer names
    /// are what is described.
    public init(_ model: NSManagedObjectModel) {
        let entities = model.entities.map(EntityDescription.init)
        let templates = model.fetchRequestTemplatesByName.map { name, request in
            FetchRequestTemplate(name: name, request: request)
        }
        var configurations: [String: [String]] = [:]
        for configuration in model.configurations {
            configurations[configuration] = (model.entities(forConfigurationName: configuration) ?? [])
                .compactMap(\.name).sorted()
        }
        self.init(
            entities: entities,
            versionIdentifiers: model.versionIdentifiers.map { String(describing: $0) }.sorted(),
            fetchRequestTemplates: templates,
            configurations: configurations
        )
    }
}

extension EntityDescription {
    init(_ entity: NSEntityDescription) {
        let entityName = entity.name ?? ""
        var attributes: [AttributeDescription] = []
        var relationships: [RelationshipDescription] = []
        var fetchedProperties: [String] = []
        for property in entity.properties {
            let declaredIn = Self.declaringEntity(of: property.name, in: entity)
            switch property {
            case let attribute as NSAttributeDescription:
                attributes.append(AttributeDescription(attribute, declaredIn: declaredIn))
            case let relationship as NSRelationshipDescription:
                relationships.append(RelationshipDescription(relationship, declaredIn: declaredIn))
            case is NSFetchedPropertyDescription:
                fetchedProperties.append(property.name)
            default:
                break
            }
        }
        self.init(
            name: entityName,
            managedObjectClassName: entity.managedObjectClassName,
            isAbstract: entity.isAbstract,
            superentity: entity.superentity?.name,
            subentities: entity.subentities.compactMap(\.name).sorted(),
            // `properties` comes back in hash order; by name is what the model editor shows, and it is stable.
            attributes: attributes.sorted { $0.name < $1.name },
            relationships: relationships.sorted { $0.name < $1.name },
            fetchedProperties: fetchedProperties.sorted(),
            indexes: entity.indexes.map(IndexDescription.init),
            uniquenessConstraints: entity.uniquenessConstraints.map { constraint in
                constraint.map { ($0 as? NSPropertyDescription)?.name ?? String(describing: $0) }
            },
            userInfo: stringDictionary(entity.userInfo),
            renamingIdentifier: entity.renamingIdentifier,
            versionHash: entity.versionHash,
            versionHashModifier: entity.versionHashModifier
        )
    }

    /// The topmost ancestor that has a property called `name`.
    private static func declaringEntity(of name: String, in entity: NSEntityDescription) -> String {
        var declaring = entity
        while let parent = declaring.superentity, parent.propertiesByName[name] != nil { declaring = parent }
        return declaring.name ?? ""
    }
}

extension AttributeType {
    init(_ type: NSAttributeType) {
        switch type {
        case .integer16AttributeType: self = .integer16
        case .integer32AttributeType: self = .integer32
        case .integer64AttributeType: self = .integer64
        case .decimalAttributeType: self = .decimal
        case .doubleAttributeType: self = .double
        case .floatAttributeType: self = .float
        case .stringAttributeType: self = .string
        case .booleanAttributeType: self = .boolean
        case .dateAttributeType: self = .date
        case .binaryDataAttributeType: self = .binaryData
        case .UUIDAttributeType: self = .uuid
        case .URIAttributeType: self = .uri
        case .transformableAttributeType: self = .transformable
        case .objectIDAttributeType: self = .objectID
        case .compositeAttributeType: self = .composite
        case .undefinedAttributeType: self = .undefined
        @unknown default: self = .undefined
        }
    }
}

extension AttributeDescription {
    init(_ attribute: NSAttributeDescription, declaredIn: String) {
        let composite = attribute as? NSCompositeAttributeDescription
        let derived = attribute as? NSDerivedAttributeDescription
        self.init(
            name: attribute.name,
            type: AttributeType(attribute.attributeType),
            isOptional: attribute.isOptional,
            isTransient: attribute.isTransient,
            declaredIn: declaredIn,
            defaultValue: attribute.defaultValue.map(Self.renderDefault),
            validation: ValidationFacets(attribute.validationPredicates),
            valueTransformerName: attribute.valueTransformerName,
            attributeValueClassName: attribute.attributeValueClassName,
            allowsExternalBinaryDataStorage: attribute.allowsExternalBinaryDataStorage,
            preservesValueInHistoryOnDeletion: attribute.preservesValueInHistoryOnDeletion,
            derivationExpression: derived?.derivationExpression.map { String(describing: $0) },
            compositeElements: composite?.elements.map { AttributeDescription($0, declaredIn: declaredIn) },
            compositeName: nil,
            userInfo: stringDictionary(attribute.userInfo),
            renamingIdentifier: attribute.renamingIdentifier,
            versionHash: attribute.versionHash
        )
    }

    private static func renderDefault(_ value: Any) -> String {
        switch value {
        case let date as Date: date.formatted(.iso8601)
        case let data as Data: "\(data.count) bytes"
        default: String(describing: value)
        }
    }
}

extension ValidationFacets {
    /// Recognises the rule shapes the model editor writes — `SELF >= min`, `SELF <= max`, `length >= n`,
    /// `length <= n`, `SELF MATCHES regex` — and keeps every rule verbatim in `predicates`.
    init(_ predicates: [NSPredicate]) {
        self.init(predicates: predicates.map(\.predicateFormat))
        for case let comparison as NSComparisonPredicate in predicates {
            let left = comparison.leftExpression
            let right = comparison.rightExpression
            guard right.expressionType == .constantValue, let constant = right.constantValue else { continue }
            let text = String(describing: constant)
            switch (left.expressionType, comparison.predicateOperatorType) {
            case (.evaluatedObject, .greaterThanOrEqualTo): minimum = text
            case (.evaluatedObject, .lessThanOrEqualTo): maximum = text
            case (.evaluatedObject, .matches): regularExpression = text
            case (.keyPath, .greaterThanOrEqualTo) where left.keyPath == "length":
                minimumLength = (constant as? NSNumber)?.intValue
            case (.keyPath, .lessThanOrEqualTo) where left.keyPath == "length":
                maximumLength = (constant as? NSNumber)?.intValue
            default: break
            }
        }
    }
}

extension DeleteRule {
    init(_ rule: NSDeleteRule) {
        switch rule {
        case .noActionDeleteRule: self = .noAction
        case .nullifyDeleteRule: self = .nullify
        case .cascadeDeleteRule: self = .cascade
        case .denyDeleteRule: self = .deny
        @unknown default: self = .noAction
        }
    }
}

extension RelationshipDescription {
    init(_ relationship: NSRelationshipDescription, declaredIn: String) {
        self.init(
            name: relationship.name,
            destinationEntity: relationship.destinationEntity?.name ?? "",
            inverseName: relationship.inverseRelationship?.name,
            isToMany: relationship.isToMany,
            isOrdered: relationship.isOrdered,
            isOptional: relationship.isOptional,
            isTransient: relationship.isTransient,
            deleteRule: DeleteRule(relationship.deleteRule),
            minCount: relationship.minCount,
            maxCount: relationship.maxCount,
            declaredIn: declaredIn,
            userInfo: stringDictionary(relationship.userInfo),
            renamingIdentifier: relationship.renamingIdentifier,
            versionHash: relationship.versionHash
        )
    }
}

extension IndexDescription {
    init(_ index: NSFetchIndexDescription) {
        self.init(
            name: index.name,
            elements: index.elements.map { element in
                Element(
                    property: element.propertyName ?? element.property?.name ?? "<expression>",
                    isAscending: element.isAscending,
                    collation: element.collationType == .rTree ? .rTree : .binary
                )
            },
            partialIndexPredicate: index.partialIndexPredicate?.predicateFormat
        )
    }
}

extension FetchRequestTemplate {
    init(name: String, request: NSFetchRequest<any NSFetchRequestResult>) {
        let format = request.predicate?.predicateFormat
        self.init(
            name: name,
            entity: request.entityName,
            predicateFormat: format,
            sort: (request.sortDescriptors ?? []).compactMap { descriptor in
                descriptor.key.map { SortKey(keyPath: $0, ascending: descriptor.ascending) }
            },
            fetchLimit: request.fetchLimit,
            substitutionVariables: format.map(Self.variables(in:)) ?? []
        )
    }

    /// `$NAME` tokens of a predicate format string. The AST walk of `DabbiQuery` refines this later (M2-01).
    static func variables(in format: String) -> [String] {
        let pattern = /\$([A-Za-z_][A-Za-z0-9_]*)/
        return Set(format.matches(of: pattern).map { String($0.output.1) }).sorted()
    }
}

private func stringDictionary(_ dictionary: [AnyHashable: Any]?) -> [String: String] {
    var result: [String: String] = [:]
    for (key, value) in dictionary ?? [:] {
        result[String(describing: key)] = String(describing: value)
    }
    return result
}
