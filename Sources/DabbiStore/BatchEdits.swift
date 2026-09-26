@preconcurrency import CoreData
import DabbiBase
import DabbiModel
import Foundation

/// Batch edits (EDT-4), binary content (EDT-6) and composite elements (EDT-7): edits the single-value
/// `setValue` does not make. Each is one undoable step of the staged edits, like every other (EDT-8).
extension StoreSession {
    // MARK: Batch edits

    /// What `batchEdit` would do — how many objects it would change, and a sample of them before and after —
    /// worked out without staging anything.
    ///
    /// - Parameters:
    ///   - entity: the entity `attribute` belongs to. With a fetch that includes sub-entities, theirs too.
    ///   - sampleSize: how many changing objects to show.
    public func batchPreview(
        _ operation: BatchOperation, attribute: String, entity: String, target: BatchTarget, sampleSize: Int = 5
    ) async throws -> BatchPreview {
        let plan = try batchPlan(operation, attribute: attribute, entity: entity, target: target)
        let converter = stack.converter
        let sampleSize = max(0, sampleSize)
        return try await stack.performEditing { context, _ in
            let objects = try plan.objects(in: context)
            var changing = 0
            var samples: [BatchPreview.Sample] = []
            for object in objects {
                let current = object.value(forKey: plan.attribute.name)
                guard let new = try plan.newValue(for: current), !Self.same(current, new) else { continue }
                changing += 1
                if samples.count < sampleSize {
                    samples.append(
                        BatchPreview.Sample(
                            object: converter.pendingID(of: object), label: converter.label(of: object),
                            before: converter.value(current, of: plan.attribute),
                            after: converter.value(new.value, of: plan.attribute)))
                }
            }
            return BatchPreview(matched: objects.count, changing: changing, samples: samples)
        }
    }

    /// Stages `operation` on `attribute` of every object in `target`, as one edit. Objects that already hold
    /// the new value are left alone, and are not counted.
    ///
    /// - Returns: how many objects changed, and what is staged afterwards.
    @discardableResult
    public func batchEdit(
        _ operation: BatchOperation, attribute: String, entity: String, target: BatchTarget,
        actionName: String? = nil
    ) async throws -> (changed: Int, changes: PendingChanges) {
        let plan = try batchPlan(operation, attribute: attribute, entity: entity, target: target)
        let name: String
        switch operation {
        case .set: name = actionName ?? "Batch Update \(attribute)"
        case .replace: name = actionName ?? "Replace in \(attribute)"
        case .nullify: name = actionName ?? "Nullify \(attribute)"
        }
        return try await stack.edit(actionName: name) { context in
            // Every new value is worked out before any is set, so that a failure part-way stages nothing.
            let objects = try plan.objects(in: context)
            let edits = try objects.compactMap { object -> (NSManagedObject, Any?)? in
                let current = object.value(forKey: plan.attribute.name)
                guard let new = try plan.newValue(for: current), !Self.same(current, new) else { return nil }
                return (object, new.value)
            }
            for (object, value) in edits { object.setValue(value, forKey: plan.attribute.name) }
            return edits.count
        }
    }

    /// The attribute, the objects and the new value, checked on the actor before anything runs.
    private func batchPlan(
        _ operation: BatchOperation, attribute name: String, entity entityName: String, target: BatchTarget
    ) throws -> BatchPlan {
        try ensureOpen()
        guard stack.isEditable else { throw CoreDataStack.notEditable }
        let entity = try entityDescription(entityName)
        guard let attribute = entity.attribute(named: name) else {
            throw DabbiError(
                .unknownProperty, "\(entity.name) has no attribute “\(name)”.",
                arguments: ["entity": entity.name, "property": name])
        }
        let change: BatchPlan.Change
        switch operation {
        case .set(let value):
            change = .set(try stack.converter.raw(value, for: attribute, of: entity.name))
        case .nullify:
            guard !attribute.isTransient, !attribute.isDerived else {
                throw DabbiError(
                    .invalidValue, "\(entity.name).\(name) is not stored, so it cannot be emptied.",
                    arguments: ["entity": entity.name, "property": name])
            }
            change = .set(nil)
        case .replace(let find):
            guard attribute.type == .string, !attribute.isTransient, !attribute.isDerived else {
                throw DabbiError(
                    .invalidValue, "Find and Replace works on text; \(entity.name).\(name) is not a text attribute.",
                    arguments: ["entity": entity.name, "property": name, "type": attribute.type.displayName])
            }
            guard !find.find.isEmpty else {
                throw DabbiError(.invalidValue, "There is nothing to find.")
            }
            var expression: NSRegularExpression?
            if find.isRegularExpression {
                // Compiled here so that a bad pattern is an error of its own, not a failure inside the edit.
                do {
                    expression = try NSRegularExpression(
                        pattern: find.find, options: find.ignoresCase ? [.caseInsensitive] : [])
                } catch {
                    throw DabbiError(
                        .invalidValue, "The regular expression is not valid.",
                        recovery: ["Check the pattern, or search for plain text instead."], underlying: error)
                }
            }
            change = .replace(find, expression)
        }
        let objects: BatchPlan.Objects
        switch target {
        case .objects(let list):
            let allowed = Set(info.model.entityAndDescendants(of: entity.name).map(\.name))
            objects = .ids(
                try list.map { object in
                    guard allowed.contains(object.entity) else {
                        throw DabbiError(
                            .invalidValue, "\(object.entity) has no attribute “\(name)” of \(entity.name).",
                            arguments: ["entity": object.entity, "property": name])
                    }
                    return (id: try resolvedObjectID(for: object), object: object)
                })
        case .fetch(let spec):
            let allowed = Set(info.model.entityAndDescendants(of: entity.name).map(\.name))
            guard allowed.contains(spec.entity) else {
                throw DabbiError(
                    .invalidValue, "\(spec.entity) has no attribute “\(name)” of \(entity.name).",
                    arguments: ["entity": spec.entity, "property": name])
            }
            objects = .fetch(
                try fetchRequest(for: spec, resultType: NSManagedObjectID.self),
                failure: spec.predicate == nil ? .fetchFailed : .invalidPredicate)
        }
        return BatchPlan(attribute: attribute, change: change, objects: objects)
    }

    /// Core Data counts setting the same value as a change; an edit that changes nothing is not one.
    private static func same(_ current: Any?, _ new: BatchPlan.NewValue) -> Bool {
        (current as? NSObject) == (new.value as? NSObject)
    }

    // MARK: Binary content

    /// Stages new bytes for a binary attribute, or empties it with `nil` (EDT-6). An attribute that allows
    /// external storage keeps large content in a file of its own beside the store, as Core Data decides on commit.
    ///
    /// A transformable attribute can only be emptied: its bytes are an archive the app reads back, and bytes
    /// from anywhere else would not be one.
    @discardableResult
    public func setData(
        _ data: Data?, for attribute: String, of object: PendingObjectID, actionName: String? = nil
    ) async throws -> PendingChanges {
        let id = try editableObjectID(for: object)
        let entity = try entityDescription(object.entity)
        guard let description = entity.attribute(named: attribute),
            description.type == .binaryData || (description.type == .transformable && data == nil),
            !description.isTransient, !description.isDerived
        else {
            throw DabbiError(
                .invalidValue,
                "\(entity.name).\(attribute) is not a binary attribute\(data == nil ? "" : " that can be replaced").",
                arguments: ["entity": entity.name, "property": attribute])
        }
        let name = actionName ?? (data == nil ? "Clear \(attribute)" : "Replace \(attribute)")
        return try await stack.edit(actionName: name) { context in
            let target = try Self.existingObject(id, object: object, in: context)
            guard (target.value(forKey: attribute) as? Data) != data else { return }
            target.setValue(data, forKey: attribute)
        }.1
    }

    /// Stages the contents of the file at `url` as a binary attribute's bytes.
    @discardableResult
    public func setData(
        contentsOf url: URL, for attribute: String, of object: PendingObjectID, actionName: String? = nil
    ) async throws -> PendingChanges {
        let data: Data
        do {
            data = try Data(contentsOf: url, options: .mappedIfSafe)
        } catch {
            throw DabbiError(
                .invalidValue, "The file “\(url.lastPathComponent)” could not be read.",
                arguments: ["file": url.lastPathComponent], underlying: error)
        }
        return try await setData(data, for: attribute, of: object, actionName: actionName)
    }

    /// The bytes of a binary or transformable attribute as staged — an object only inserted included — for
    /// saving to a file (EDT-6). `attribute` may be a path into a composite.
    public func stagedData(of object: PendingObjectID, attribute: String) async throws -> Data? {
        let id = try resolvedObjectID(for: object)
        let converter = stack.converter
        return try await stack.perform { context in
            try converter.data(of: Self.existingObject(id, object: object, in: context), path: attribute)
        }
    }

    // MARK: Composite elements

    /// Stages a new value for one element of a composite attribute (EDT-7): `path` is the attribute's name and
    /// the element's, `address.city`, and may go deeper into a composite within it. The other elements keep
    /// their values; setting an element of a composite that is empty makes one whose other elements are empty.
    @discardableResult
    public func setElement(
        _ value: Value, at path: String, of object: PendingObjectID, actionName: String? = nil
    ) async throws -> PendingChanges {
        let id = try editableObjectID(for: object)
        let entity = try entityDescription(object.entity)
        let components = path.split(separator: ".").map(String.init)
        func unknown() -> DabbiError {
            DabbiError(
                .unknownProperty, "“\(path)” is not an element of a composite attribute of \(entity.name).",
                arguments: ["entity": entity.name, "property": path])
        }
        guard components.count >= 2, let attribute = entity.attribute(named: components[0]),
            attribute.type == .composite
        else { throw unknown() }
        var element = attribute
        for component in components.dropFirst() {
            guard let next = element.compositeElements?.first(where: { $0.name == component }) else {
                throw unknown()
            }
            element = next
        }
        let raw = Box(try stack.converter.raw(value, for: element, of: entity.name))
        let elementPath = Array(components.dropFirst())
        return try await stack.edit(actionName: actionName ?? "Edit \(path)") { context in
            let target = try Self.existingObject(id, object: object, in: context)
            let current = target.value(forKey: attribute.name) as? [String: Any]
            let updated = Self.setting(raw.value, at: elementPath, in: current ?? [:])
            guard (current as NSDictionary?) != (updated as NSDictionary) else { return }
            target.setValue(updated, forKey: attribute.name)
        }.1
    }

    /// `dictionary` with the value at `path` replaced, the dictionaries on the way made as needed.
    private static func setting(_ value: Any?, at path: [String], in dictionary: [String: Any]) -> [String: Any] {
        var result = dictionary
        guard let first = path.first else { return result }
        if path.count == 1 {
            result[first] = value
        } else {
            result[first] = setting(value, at: Array(path.dropFirst()), in: dictionary[first] as? [String: Any] ?? [:])
        }
        return result
    }
}

/// A converted value, carried into a `perform` block. Only ever read there.
private struct Box: @unchecked Sendable {
    let value: Any?
    init(_ value: Any?) { self.value = value }
}

/// A batch edit, resolved on the actor: everything the `perform` block needs, and nothing it would have to check.
private struct BatchPlan: @unchecked Sendable {
    enum Change {
        case set(Any?)
        /// With the compiled expression, when the text to find is one.
        case replace(FindReplace, NSRegularExpression?)
    }

    enum Objects {
        case ids([(id: NSManagedObjectID, object: PendingObjectID)])
        case fetch(StoreSession.Request<NSManagedObjectID>, failure: DabbiError.Code)
    }

    /// The value an object is to get; `value` is `nil` to empty it.
    struct NewValue {
        let value: Any?
    }

    let attribute: AttributeDescription
    let change: Change
    let objects: Objects

    func objects(in context: NSManagedObjectContext) throws -> [NSManagedObject] {
        switch objects {
        case .ids(let ids):
            return try ids.map { try StoreSession.existingObject($0.id, object: $0.object, in: context) }
        case .fetch(let request, let failure):
            let ids = try CoreDataStack.fetch(request.value, in: context, failure: failure)
            return ids.compactMap { id in
                guard let object = try? context.existingObject(with: id), !object.isDeleted else { return nil }
                return object
            }
        }
    }

    /// What `current` becomes, or `nil` when the edit leaves it alone — text with nothing to replace.
    func newValue(for current: Any?) throws -> NewValue? {
        switch change {
        case .set(let value):
            return NewValue(value: value)
        case .replace(let find, let expression):
            guard let text = current as? String else { return nil }
            let replaced: String
            if let expression {
                replaced = expression.stringByReplacingMatches(
                    in: text, range: NSRange(text.startIndex..., in: text), withTemplate: find.replacement)
            } else {
                replaced = text.replacingOccurrences(
                    of: find.find, with: find.replacement, options: find.ignoresCase ? [.caseInsensitive] : [])
            }
            return replaced == text ? nil : NewValue(value: replaced)
        }
    }
}
