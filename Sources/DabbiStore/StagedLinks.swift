@preconcurrency import CoreData
import DabbiBase
import DabbiModel
import Foundation

/// Staged relationship edits (EDT-3, EDT-8): linking objects, unlinking them, and making a new object already
/// linked. Each call is one undoable edit, like the value edits in `StagedEdits.swift`, and returns the whole of
/// what is staged afterwards. Core Data keeps the inverse, so linking from either end reads the same from both.
///
/// Objects on either side may be ones only inserted, named by the identity they were staged under.
extension StoreSession {
    /// Links `objects` to `object` through its relationship `name`: added to a to-many (at the end of an ordered
    /// one), or set as a to-one, replacing what it held. A to-one takes exactly one object.
    ///
    /// Objects already linked are left where they are, and an edit that links nothing new stages nothing. Throws
    /// `.unknownProperty` for a name the entity has no relationship by, and `.invalidValue` for an object the
    /// relationship cannot lead to.
    @discardableResult
    public func link(
        _ objects: [PendingObjectID], to object: PendingObjectID, through name: String, actionName: String? = nil
    ) async throws -> PendingChanges {
        let relationship = try editableRelationship(name, of: object)
        if !relationship.isToMany, objects.count != 1 {
            throw DabbiError(
                .invalidValue, "\(object.entity).\(name) is a to-one relationship; link one object to it.",
                arguments: ["entity": object.entity, "property": name])
        }
        let target = try editableObjectID(for: object)
        let destinations = try destinationIDs(of: objects, through: relationship, of: object)
        return try await stack.edit(actionName: actionName ?? "Link \(name)") { context in
            let source = try Self.existingObject(target, object: object, in: context)
            let linked = try destinations.map { try Self.existingObject($0.id, object: $0.object, in: context) }
            Self.connect(linked, to: source, through: relationship)
        }.1
    }

    /// Unlinks `objects` from `object`'s relationship `name`: removed from a to-many, or, for a to-one that holds
    /// one of them, emptied. The objects themselves stay; no delete rule is involved. An object that was not
    /// linked is passed over, and an edit that unlinks nothing stages nothing.
    @discardableResult
    public func unlink(
        _ objects: [PendingObjectID], from object: PendingObjectID, through name: String, actionName: String? = nil
    ) async throws -> PendingChanges {
        let relationship = try editableRelationship(name, of: object)
        let target = try editableObjectID(for: object)
        let destinations = try destinationIDs(of: objects, through: relationship, of: object)
        return try await stack.edit(actionName: actionName ?? "Unlink \(name)") { context in
            let source = try Self.existingObject(target, object: object, in: context)
            let unlinked = try destinations.map { try Self.existingObject($0.id, object: $0.object, in: context) }
            if relationship.isOrdered {
                let set = source.mutableOrderedSetValue(forKey: relationship.name)
                for destination in unlinked where set.contains(destination) { set.remove(destination) }
            } else if relationship.isToMany {
                let set = source.mutableSetValue(forKey: relationship.name)
                for destination in unlinked where set.contains(destination) { set.remove(destination) }
            } else if let current = source.value(forKey: relationship.name) as? NSManagedObject,
                unlinked.contains(current)
            {
                source.setValue(nil, forKey: relationship.name)
            }
        }.1
    }

    /// Stages a new object at the far end of `object`'s relationship `name`, linked to it, as one edit: undoing
    /// it takes both back. The new object is of the relationship's destination entity, or of `entity` when given,
    /// which has to be that entity or one of its sub-entities. Abstract entities are refused, as by
    /// `insertObject(entity:)`.
    public func insertRelatedObject(
        to object: PendingObjectID, through name: String, entity: String? = nil, actionName: String? = nil
    ) async throws -> (object: PendingObjectID, changes: PendingChanges) {
        let relationship = try editableRelationship(name, of: object)
        let entityName = entity ?? relationship.destinationEntity
        let allowed = Set(info.model.entityAndDescendants(of: relationship.destinationEntity).map(\.name))
        guard allowed.contains(entityName) else {
            throw DabbiError(
                .invalidValue,
                "\(object.entity).\(name) leads to \(relationship.destinationEntity), not \(entityName).",
                arguments: ["entity": object.entity, "property": name])
        }
        let description = try entityDescription(entityName)
        guard !description.isAbstract else {
            throw DabbiError(
                .invalidValue, "\(entityName) is abstract and cannot have objects of its own.",
                arguments: ["entity": entityName],
                recovery: ["Make one of its sub-entities: " + description.subentities.joined(separator: ", ")])
        }
        let target = try editableObjectID(for: object)
        let converter = stack.converter
        let undoName = actionName ?? "New \(entityName)"
        let ((id, inserted), changes) = try await stack.edit(actionName: undoName) { context in
            let source = try Self.existingObject(target, object: object, in: context)
            let created = NSEntityDescription.insertNewObject(forEntityName: entityName, into: context)
            Self.connect([created], to: source, through: relationship)
            return (created.objectID, converter.pendingID(of: created))
        }
        insertedObjectIDs[inserted.uri] = id
        return (inserted, changes)
    }

    // MARK: Helpers

    /// The relationship `name` of `object`'s own entity, in a session open for editing.
    private func editableRelationship(_ name: String, of object: PendingObjectID) throws -> RelationshipDescription {
        try ensureOpen()
        guard stack.isEditable else { throw CoreDataStack.notEditable }
        let entity = try entityDescription(object.entity)
        guard let relationship = entity.relationship(named: name), !relationship.isTransient else {
            throw DabbiError(
                .unknownProperty, "\(entity.name) has no relationship named “\(name)”.",
                arguments: ["entity": entity.name, "property": name])
        }
        return relationship
    }

    /// The objects `relationship` is to lead to, each checked against its destination entity.
    private func destinationIDs(
        of objects: [PendingObjectID], through relationship: RelationshipDescription, of object: PendingObjectID
    ) throws -> [(id: NSManagedObjectID, object: PendingObjectID)] {
        let allowed = Set(info.model.entityAndDescendants(of: relationship.destinationEntity).map(\.name))
        return try objects.map { destination in
            guard allowed.contains(destination.entity) else {
                throw DabbiError(
                    .invalidValue,
                    "\(object.entity).\(relationship.name) leads to \(relationship.destinationEntity), "
                        + "not \(destination.entity).",
                    arguments: ["entity": object.entity, "property": relationship.name])
            }
            return (try editableObjectID(for: destination), destination)
        }
    }

    /// Links on the context's queue. What is already linked stays where it is, so that linking it again changes
    /// nothing and leaves no edit behind.
    private static func connect(
        _ destinations: [NSManagedObject], to source: NSManagedObject, through relationship: RelationshipDescription
    ) {
        if relationship.isOrdered {
            let set = source.mutableOrderedSetValue(forKey: relationship.name)
            for destination in destinations where !set.contains(destination) { set.add(destination) }
        } else if relationship.isToMany {
            let set = source.mutableSetValue(forKey: relationship.name)
            for destination in destinations where !set.contains(destination) { set.add(destination) }
        } else if let destination = destinations.first,
            (source.value(forKey: relationship.name) as? NSManagedObject) != destination
        {
            source.setValue(destination, forKey: relationship.name)
        }
    }
}
