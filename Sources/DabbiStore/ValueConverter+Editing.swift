@preconcurrency import CoreData
import DabbiBase
import DabbiModel
import Foundation

/// The other direction: `Value`s into what Core Data stores, and the edit context's state out as
/// `PendingChange`s (EDT-8). Called inside `context.perform` only, like the rest of the converter.
extension ValueConverter {
    // MARK: Values in

    /// What to hand `setValue(_:forKey:)` for `value` on `attribute`; `nil` for `.null`.
    ///
    /// Numbers are checked against their type's range here, because Core Data does not: an Integer 16 given
    /// 70 000 is truncated on save without a word. Everything else the model says — optionality, minimum and
    /// maximum, patterns — is Core Data's validation, which the commit runs (and M3-05 explains).
    ///
    /// Errors name the attribute and its type, never the value (privacy, ARCHITECTURE.md §9).
    func raw(_ value: Value, for attribute: AttributeDescription, of entity: String) throws -> Any? {
        func refused(_ reason: String) -> DabbiError {
            DabbiError(
                .invalidValue, "\(entity).\(attribute.name) cannot hold this value: \(reason)",
                arguments: ["entity": entity, "property": attribute.name, "type": attribute.type.displayName])
        }
        let expected = "it is a \(attribute.type.displayName) attribute."
        if attribute.isTransient || attribute.isDerived {
            throw refused("it is \(attribute.isTransient ? "transient" : "derived") and not set directly.")
        }
        if case .null = value { return nil }

        switch attribute.type {
        case .integer16, .integer32, .integer64:
            let integer: Int64
            switch value {
            case .int(let number): integer = number
            case .double(let number) where number.rounded() == number && abs(number) < 9.2e18: integer = Int64(number)
            case .decimal(let number) where Decimal(NSDecimalNumber(decimal: number).int64Value) == number:
                integer = NSDecimalNumber(decimal: number).int64Value
            default: throw refused(expected)
            }
            let range: ClosedRange<Int64> =
                switch attribute.type {
                case .integer16: Int64(Int16.min)...Int64(Int16.max)
                case .integer32: Int64(Int32.min)...Int64(Int32.max)
                default: Int64.min...Int64.max
                }
            guard range.contains(integer) else {
                throw refused("it is out of the range of \(attribute.type.displayName).")
            }
            return NSNumber(value: integer)
        case .double, .float:
            switch value {
            case .double(let number): return NSNumber(value: number)
            case .int(let number): return NSNumber(value: Double(number))
            case .decimal(let number): return NSNumber(value: NSDecimalNumber(decimal: number).doubleValue)
            default: throw refused(expected)
            }
        case .decimal:
            switch value {
            case .decimal(let number): return NSDecimalNumber(decimal: number)
            case .int(let number): return NSDecimalNumber(value: number)
            case .double(let number) where number.isFinite: return NSDecimalNumber(value: number)
            default: throw refused(expected)
            }
        case .boolean:
            switch value {
            case .bool(let flag): return NSNumber(value: flag)
            case .int(let number) where number == 0 || number == 1: return NSNumber(value: number == 1)
            default: throw refused(expected)
            }
        case .string:
            guard case .string(let string) = value else { throw refused(expected) }
            return string
        case .date:
            guard case .date(let date) = value else { throw refused(expected) }
            return date
        case .uuid:
            switch value {
            case .uuid(let uuid): return uuid
            case .string(let string):
                guard let uuid = UUID(uuidString: string) else { throw refused("the text is not a UUID.") }
                return uuid
            default: throw refused(expected)
            }
        case .uri:
            switch value {
            case .url(let url): return url
            case .string(let string):
                guard let url = URL(string: string) else { throw refused("the text is not a URL.") }
                return url
            default: throw refused(expected)
            }
        case .binaryData, .transformable, .composite, .objectID, .undefined:
            // Binary content, composites and object IDs have editors of their own (M3-10).
            throw refused("\(attribute.type.displayName) attributes are not edited as a single value.")
        }
    }

    // MARK: Pending changes out

    /// Everything staged in `context`: inserted, then updated, then deleted objects.
    ///
    /// An updated object lists only what differs from the file, compared as the grid shows it; an object whose
    /// changes cancel out — a to-many that lost one member and gained another is still the same count — is
    /// listed with its to-many fields all the same, so that nothing staged is ever invisible.
    func pendingChanges(in context: NSManagedObjectContext) -> [PendingChange] {
        func sorted(_ objects: Set<NSManagedObject>) -> [NSManagedObject] {
            objects.sorted {
                ($0.entity.name ?? "", $0.objectID.uriRepresentation().absoluteString)
                    < ($1.entity.name ?? "", $1.objectID.uriRepresentation().absoluteString)
            }
        }
        var changes: [PendingChange] = []
        for object in sorted(context.insertedObjects) {
            changes.append(inserted(object))
        }
        for object in sorted(context.updatedObjects) {
            if let change = updated(object, in: context) { changes.append(change) }
        }
        for object in sorted(context.deletedObjects) {
            changes.append(deleted(object, in: context))
        }
        return changes
    }

    func pendingID(of object: NSManagedObject) -> PendingObjectID {
        PendingObjectID(uri: object.objectID.uriRepresentation(), entity: object.entity.name ?? "")
    }

    private func inserted(_ object: NSManagedObject) -> PendingChange {
        let layout = object.entity.name.flatMap { layouts[$0] }
        let fields = storedProperties(of: object).compactMap { name -> PendingChange.Field? in
            let after = current(name, of: object, layout: layout)
            switch after {
            case .null, .toOne(nil, _), .toMany(count: 0): return nil
            default: return PendingChange.Field(property: name, before: nil, after: after)
            }
        }
        return PendingChange(object: pendingID(of: object), kind: .inserted, label: label(of: object), fields: fields)
    }

    private func updated(_ object: NSManagedObject, in context: NSManagedObjectContext) -> PendingChange? {
        let layout = object.entity.name.flatMap { layouts[$0] }
        let changed = Set(object.changedValues().keys)
        let keys = storedProperties(of: object).filter(changed.contains)
        guard !keys.isEmpty else { return nil }
        let committed = object.committedValues(forKeys: keys)
        let fields = keys.map { name in
            PendingChange.Field(
                property: name, before: converted(committed[name], name, layout: layout, in: context),
                after: current(name, of: object, layout: layout))
        }
        let differing = fields.filter { $0.before != $0.after }
        return PendingChange(
            object: pendingID(of: object), kind: .updated, label: label(of: object),
            fields: differing.isEmpty ? fields : differing)
    }

    private func deleted(_ object: NSManagedObject, in context: NSManagedObjectContext) -> PendingChange {
        let layout = object.entity.name.flatMap { layouts[$0] }
        let names = storedProperties(of: object)
        let committed = object.committedValues(forKeys: names)
        let fields = names.map { name in
            PendingChange.Field(
                property: name, before: converted(committed[name], name, layout: layout, in: context), after: nil)
        }
        let display = layout?.displayAttribute.flatMap { committed[$0] as? String }
        return PendingChange(
            object: pendingID(of: object), kind: .deleted, label: display.flatMap { $0.isEmpty ? nil : $0 },
            fields: fields)
    }

    private func storedProperties(of object: NSManagedObject) -> [String] {
        columns(for: object.entity.name ?? "", includeSubentities: false).properties
    }

    private func label(of object: NSManagedObject) -> String? {
        let display = object.entity.name.flatMap { layouts[$0]?.displayAttribute }
            .flatMap { object.value(forKey: $0) as? String }
        return display.flatMap { $0.isEmpty ? nil : $0 }
    }

    private func current(_ name: String, of object: NSManagedObject, layout: Layout?) -> Value {
        if let attribute = layout?.attributes[name] { return value(object.value(forKey: name), of: attribute) }
        guard let relationship = layout?.relationships[name] else { return .null }
        return relationship.isToMany ? toMany(object.value(forKey: name)) : toOne(object.value(forKey: name))
    }

    /// A committed value. For relationships Core Data may hand back object IDs rather than objects.
    private func converted(_ raw: Any?, _ name: String, layout: Layout?, in context: NSManagedObjectContext) -> Value {
        if let attribute = layout?.attributes[name] { return value(raw, of: attribute) }
        guard let relationship = layout?.relationships[name] else { return .null }
        if relationship.isToMany {
            switch raw {
            case let set as NSSet: return .toMany(count: set.count)
            case let set as NSOrderedSet: return .toMany(count: set.count)
            case let array as NSArray: return .toMany(count: array.count)
            default: return .toMany(count: 0)
            }
        }
        if let id = raw as? NSManagedObjectID { return toOne(try? context.existingObject(with: id)) }
        return toOne(raw)
    }
}
