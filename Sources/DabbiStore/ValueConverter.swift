@preconcurrency import CoreData
import DabbiBase
import DabbiModel
import Foundation

/// Converts managed objects to `Value`s. Only ever called inside `context.perform`; what comes out is `Sendable`
/// and is the only thing that leaves the closure (ADR-02).
struct ValueConverter: Sendable {
    struct Layout: Sendable {
        var attributes: [String: AttributeDescription] = [:]
        var relationships: [String: RelationshipDescription] = [:]
        /// The attribute a to-one pointing at this entity is labelled with.
        var displayAttribute: String?
    }

    let model: ModelDescription
    let layouts: [String: Layout]

    init(model: ModelDescription) {
        self.model = model
        var layouts: [String: Layout] = [:]
        for entity in model.entities {
            var layout = Layout()
            for attribute in entity.attributes { layout.attributes[attribute.name] = attribute }
            for relationship in entity.relationships { layout.relationships[relationship.name] = relationship }
            layout.displayAttribute = entity.displayAttributeName
            layouts[entity.name] = layout
        }
        self.layouts = layouts
    }

    // MARK: Columns

    /// The stored properties of `entity` — attributes, then relationships — followed, when sub-entities are
    /// included, by what its descendants add. Transient properties have nothing stored and are left out.
    func columns(for entity: String, includeSubentities: Bool) -> ColumnSet {
        let entities =
            includeSubentities
            ? model.entityAndDescendants(of: entity) : model.entity(named: entity).map { [$0] } ?? []
        var seen: Set<String> = []
        var names: [String] = []
        for entity in entities {
            let stored =
                entity.attributes.filter { !$0.isTransient }.map(\.name)
                + entity.relationships.filter { !$0.isTransient }.map(\.name)
            for name in stored where seen.insert(name).inserted { names.append(name) }
        }
        return ColumnSet(names)
    }

    func toOneRelationships(in columns: ColumnSet, of entity: String) -> [String] {
        guard let layout = layouts[entity] else { return [] }
        return columns.properties.filter { layout.relationships[$0]?.isToMany == false }
    }

    /// What to name in `propertiesToFetch` to read only `columns`: their attributes and to-ones. `nil` when a
    /// partial fetch cannot serve them — a column only a sub-entity has cannot be named on the parent's request,
    /// and would cost one fault per row instead.
    func partialFetchProperties(for columns: ColumnSet, of entity: String) -> [String]? {
        guard let layout = layouts[entity] else { return nil }
        var properties: [String] = []
        for name in columns.properties {
            if let attribute = layout.attributes[name] {
                // A composite is several columns under one name; leave those to the full fetch.
                guard attribute.type != .composite else { return nil }
                properties.append(name)
            } else if let relationship = layout.relationships[name] {
                if !relationship.isToMany { properties.append(name) }
            } else {
                return nil
            }
        }
        return properties
    }

    /// The to-many relationships among `columns` that can be counted for a whole page in one grouped fetch:
    /// those whose inverse is to-one, and which mean the same thing in every entity of the fetched hierarchy.
    func batchCountableRelationships(
        in columns: ColumnSet, of entity: String, includeSubentities: Bool
    ) -> [RelationshipDescription] {
        let entities = includeSubentities ? model.entityAndDescendants(of: entity).map(\.name) : [entity]
        return columns.properties.compactMap { name in
            let declared = Set(entities.compactMap { layouts[$0]?.relationships[name] })
            guard declared.count == 1, let relationship = declared.first, relationship.isToMany,
                let inverseName = relationship.inverseName,
                let inverse = layouts[relationship.destinationEntity]?.relationships[inverseName],
                !inverse.isToMany
            else { return nil }
            return relationship
        }
    }

    // MARK: Rows

    typealias ToManyCounts = [String: [NSManagedObjectID: Int]]

    func row(_ object: NSManagedObject, columns: ColumnSet, counts: ToManyCounts = [:]) -> RowSnapshot? {
        guard let ref = ObjectRef(uri: object.objectID.uriRepresentation()),
            let layout = object.entity.name.flatMap({ layouts[$0] })
        else { return nil }
        let values = columns.properties.map { name -> Value in
            if let attribute = layout.attributes[name] {
                return value(object.value(forKey: name), of: attribute)
            }
            guard let relationship = layout.relationships[name] else { return .null }
            guard relationship.isToMany else { return toOne(object.value(forKey: name)) }
            if let counted = counts[name] { return .toMany(count: counted[object.objectID] ?? 0) }
            return toMany(object.value(forKey: name))
        }
        return RowSnapshot(ref: ref, values: values)
    }

    /// One object as the relationships panel lists it: its identity, and the label a to-one would carry (REL-1).
    ///
    /// Reading the identity does not fire the object's fault; reading the label does, which is why this is
    /// only ever called for the objects actually shown.
    func item(of object: NSManagedObject) -> RelatedObjects.Item? {
        guard let ref = ObjectRef(uri: object.objectID.uriRepresentation()) else { return nil }
        let display = object.entity.name.flatMap { layouts[$0]?.displayAttribute }
            .flatMap { object.value(forKey: $0) as? String }
        return RelatedObjects.Item(ref: ref, display: display.flatMap { $0.isEmpty ? nil : $0 })
    }

    func toOne(_ raw: Any?) -> Value {
        guard let destination = raw as? NSManagedObject,
            let ref = ObjectRef(uri: destination.objectID.uriRepresentation())
        else { return .toOne(nil, display: nil) }
        let display = destination.entity.name.flatMap { layouts[$0]?.displayAttribute }
            .flatMap { destination.value(forKey: $0) as? String }
        return .toOne(ref, display: display.flatMap { $0.isEmpty ? nil : $0 })
    }

    func toMany(_ raw: Any?) -> Value {
        switch raw {
        case let set as NSSet: .toMany(count: set.count)
        case let set as NSOrderedSet: .toMany(count: set.count)
        default: .toMany(count: 0)
        }
    }

    // MARK: Attribute values

    func value(_ raw: Any?, of attribute: AttributeDescription) -> Value {
        guard let raw, !(raw is NSNull) else { return .null }
        switch attribute.type {
        case .integer16, .integer32, .integer64:
            return (raw as? NSNumber).map { .int($0.int64Value) } ?? unexpected(raw)
        case .double, .float:
            return (raw as? NSNumber).map { .double($0.doubleValue) } ?? unexpected(raw)
        case .decimal:
            return (raw as? NSNumber).map { .decimal(($0 as? NSDecimalNumber)?.decimalValue ?? $0.decimalValue) }
                ?? unexpected(raw)
        case .boolean:
            return (raw as? NSNumber).map { .bool($0.boolValue) } ?? unexpected(raw)
        case .string:
            return (raw as? String).map(Value.string) ?? unexpected(raw)
        case .date:
            return (raw as? Date).map(Value.date) ?? unexpected(raw)
        case .uuid:
            return (raw as? UUID).map(Value.uuid) ?? unexpected(raw)
        case .uri:
            return (raw as? URL).map(Value.url) ?? unexpected(raw)
        case .objectID:
            return (raw as? NSManagedObjectID).map { .url($0.uriRepresentation()) } ?? unexpected(raw)
        case .binaryData, .transformable:
            // With the pass-through transformer a transformable's value is its stored bytes.
            guard let data = raw as? Data else { return unexpected(raw) }
            return .blob(
                BlobSummary(
                    byteCount: data.count,
                    sniffedType: MagicSniffer.sniff(data.prefix(MagicSniffer.prefixLength)),
                    isExternal: attribute.allowsExternalBinaryDataStorage))
        case .composite:
            guard let dictionary = raw as? [String: Any] else { return unexpected(raw) }
            var elements: [String: Value] = [:]
            for element in attribute.compositeElements ?? [] {
                elements[element.name] = value(dictionary[element.name], of: element)
            }
            return .composite(elements)
        case .undefined:
            return unexpected(raw)
        }
    }

    /// A value of a class the attribute's type does not predict. Its content is not rendered — only what it is.
    private func unexpected(_ raw: Any) -> Value {
        .string("<\(String(describing: type(of: raw)))>")
    }

    /// The bytes of a binary or transformable attribute; `path` may descend into composites (`a.b.c`).
    func data(of object: NSManagedObject, path: String) throws -> Data? {
        let components = path.split(separator: ".").map(String.init)
        guard let first = components.first,
            var attribute = object.entity.name.flatMap({ layouts[$0]?.attributes[first] })
        else {
            throw DabbiError(
                .unknownProperty, "There is no attribute “\(path)” on \(object.entity.name ?? "this entity").")
        }
        var raw = object.value(forKey: first)
        for component in components.dropFirst() {
            guard let element = attribute.compositeElements?.first(where: { $0.name == component }) else {
                throw DabbiError(.unknownProperty, "“\(path)” does not lead to an attribute.")
            }
            raw = (raw as? [String: Any])?[component]
            attribute = element
        }
        guard attribute.type == .binaryData || attribute.type == .transformable else {
            throw DabbiError(.unknownProperty, "“\(path)” is not a binary or transformable attribute.")
        }
        return raw as? Data
    }

    // MARK: Sorting

    /// Checks that every key leads, through to-one relationships and composites, to a stored attribute of a
    /// sortable type — so that a typo is an explained error rather than an Objective-C exception.
    func sortDescriptors(for keys: [SortKey], entity: String) throws -> [NSSortDescriptor] {
        try keys.map { key in
            try validateSortKeyPath(key.keyPath, entity: entity)
            return NSSortDescriptor(key: key.keyPath, ascending: key.ascending)
        }
    }

    private func validateSortKeyPath(_ keyPath: String, entity: String) throws {
        func invalid(_ reason: String) -> DabbiError {
            DabbiError(
                .invalidSort, "Cannot sort \(entity) by “\(keyPath)”: \(reason)",
                arguments: ["entity": entity, "keyPath": keyPath])
        }
        var current = entity
        var composite: [AttributeDescription]?
        let components = keyPath.split(separator: ".", omittingEmptySubsequences: false).map(String.init)
        for (index, component) in components.enumerated() {
            let isLast = index == components.count - 1
            let attribute =
                composite?.first { $0.name == component }
                ?? (composite == nil
                    ? layouts[current]?.attributes[component] : nil)
            if let attribute {
                guard !attribute.isTransient else { throw invalid("“\(component)” is transient and not stored.") }
                if attribute.type == .composite, !isLast {
                    composite = attribute.compositeElements ?? []
                    continue
                }
                guard isLast else { throw invalid("“\(component)” is an attribute, not a relationship.") }
                guard ![.binaryData, .transformable, .composite, .undefined].contains(attribute.type) else {
                    throw invalid("\(attribute.type.displayName) attributes have no order.")
                }
                return
            }
            guard composite == nil, let relationship = layouts[current]?.relationships[component] else {
                let known = (layouts[current]?.attributes.keys.sorted() ?? []).joined(separator: ", ")
                throw invalid("\(current) has no property “\(component)”. Attributes: \(known).")
            }
            guard !relationship.isToMany else { throw invalid("“\(component)” is a to-many relationship.") }
            guard !isLast else { throw invalid("“\(component)” is a relationship; add one of its attributes.") }
            current = relationship.destinationEntity
        }
    }
}
