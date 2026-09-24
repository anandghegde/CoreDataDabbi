@preconcurrency import CoreData
import DabbiBase
import DabbiModel
import Foundation

/// Staged edits (EDT-8, ARCHITECTURE.md §6.4).
///
/// An editable session stages every change in its edit context and writes nothing until `commit`. Each call
/// here is one undoable edit, and each returns the whole of what is staged afterwards, so a front end never has
/// to ask twice. Browsing the same session shows the staged values; objects that are only inserted are not in
/// pagers — they have no reference until the commit gives them a primary key — and are listed in
/// `PendingChanges` instead.
///
/// Action names are the undo menu's (“Undo Edit name”). Pass them localised; the defaults are English.
extension StoreSession {
    /// What is staged, and what undo and redo would do.
    public func pendingChanges() async throws -> PendingChanges {
        try ensureOpen()
        guard stack.isEditable else { return .none }
        let converter = stack.converter
        return try await stack.performEditing { context, _ in
            CoreDataStack.pendingChanges(in: context, converter: converter)
        }
    }

    /// Stages a new value for one attribute or to-one relationship.
    ///
    /// For a to-one, `value` is `.toOne(ref, display:)` — the display is ignored — or `.null` to clear it.
    /// To-many relationships are changed by linking and unlinking (M3-06), not by value.
    @discardableResult
    public func setValue(
        _ value: Value, for property: String, of object: PendingObjectID, actionName: String? = nil
    ) async throws -> PendingChanges {
        let id = try editableObjectID(for: object)
        let entity = try entityDescription(object.entity)
        let raw: RawValue
        if let attribute = entity.attribute(named: property) {
            raw = .attribute(try stack.converter.raw(value, for: attribute, of: entity.name))
        } else if let relationship = entity.relationship(named: property) {
            raw = .toOne(try destinationID(of: value, for: relationship, in: entity))
        } else {
            throw DabbiError(
                .unknownProperty, "\(entity.name) has no property “\(property)”.",
                arguments: ["entity": entity.name, "property": property])
        }
        let name = actionName ?? "Edit \(property)"
        return try await stack.edit(actionName: name) { context in
            let target = try Self.existingObject(id, object: object, in: context)
            // Core Data counts setting the same value as a change; an edit that changes nothing is not one.
            switch raw {
            case .attribute(let value):
                let current = target.value(forKey: property) as? NSObject
                guard current != value as? NSObject else { return }
                target.setValue(value, forKey: property)
            case .toOne(let destinationID):
                let current = (target.value(forKey: property) as? NSManagedObject)?.objectID
                guard current != destinationID else { return }
                let destination = try destinationID.map { try Self.existingObject($0, object: nil, in: context) }
                target.setValue(destination, forKey: property)
            }
        }.1
    }

    /// Stages a new object of `entity`, with the model's default values. Abstract entities are refused.
    public func insertObject(
        entity name: String, actionName: String? = nil
    ) async throws -> (object: PendingObjectID, changes: PendingChanges) {
        try ensureOpen()
        let entity = try entityDescription(name)
        guard !entity.isAbstract else {
            throw DabbiError(
                .invalidValue, "\(name) is abstract and cannot have objects of its own.",
                arguments: ["entity": name],
                recovery: ["Insert one of its sub-entities: " + entity.subentities.joined(separator: ", ")])
        }
        let converter = stack.converter
        let ((id, object), changes) = try await stack.edit(actionName: actionName ?? "New \(name)") { context in
            let inserted = NSEntityDescription.insertNewObject(forEntityName: name, into: context)
            return (inserted.objectID, converter.pendingID(of: inserted))
        }
        insertedObjectIDs[object.uri] = id
        return (object, changes)
    }

    /// Stages the deletion of `objects`, with their delete rules: what a cascade takes along is staged too.
    /// A Deny rule is enforced by the commit, which is refused while the denying relationship is not empty.
    @discardableResult
    public func delete(_ objects: [PendingObjectID], actionName: String? = nil) async throws -> PendingChanges {
        let ids = try objects.map { (id: try editableObjectID(for: $0), object: $0) }
        let name =
            actionName ?? (objects.count == 1 ? "Delete \(objects[0].entity)" : "Delete \(objects.count) Objects")
        return try await stack.edit(actionName: name) { context in
            // Every object is found before any is deleted, so that a missing one deletes nothing.
            let targets = try ids.map { try Self.existingObject($0.id, object: $0.object, in: context) }
            for target in targets { context.delete(target) }
        }.1
    }

    /// Takes back the last staged edit. Does nothing when there is none.
    @discardableResult
    public func undo() async throws -> PendingChanges {
        try await stepUndo(CoreDataStack.undoLastEdit(in:))
    }

    /// Puts back the last edit `undo()` took back. Does nothing when there is none.
    @discardableResult
    public func redo() async throws -> PendingChanges {
        try await stepUndo(CoreDataStack.redoLastEdit(in:))
    }

    private func stepUndo(
        _ step: @escaping @Sendable (NSManagedObjectContext) -> Void
    ) async throws -> PendingChanges {
        try ensureOpen()
        let converter = stack.converter
        return try await stack.performEditing { context, _ in
            try objcGuarded("The edit could not be undone.", code: .internal) { step(context) }
            return CoreDataStack.pendingChanges(in: context, converter: converter)
        }
    }

    /// Throws away everything staged, and the undo stack with it. The file is not touched.
    @discardableResult
    public func discardChanges() async throws -> PendingChanges {
        try ensureOpen()
        guard stack.isEditable else { return .none }
        try await stack.performEditing { context, _ in
            context.rollback()
            CoreDataStack.clearUndo(of: context)
            context.refreshAllObjects()
        }
        insertedObjectIDs.removeAll()
        return .none
    }

    /// Writes everything staged to the store, in one save.
    ///
    /// `prepare` runs first, and nothing is written unless it returns: it is where the pre-commit backup is
    /// taken and verified (EDT-9) — `DabbiKit` passes it — and where the commit guards go (M3-07). A commit with
    /// nothing staged writes nothing and does not call it.
    ///
    /// Afterwards the undo stack is empty, a new generation has begun — every pager is stale and objects that
    /// were inserted have their primary keys — and the history of a store that records it names this session's
    /// author (EDT-5).
    ///
    /// Throws `.validationFailed`, `.commitConflict` or `.commitFailed`, with everything still staged: nothing
    /// was written.
    public func commit(prepare: @Sendable () async throws -> Void = {}) async throws -> CommitSummary {
        try ensureOpen()
        guard stack.isEditable else { throw CoreDataStack.notEditable }
        let hasChanges = try await stack.performEditing { context, _ in context.hasChanges }
        guard hasChanges else { return CommitSummary(inserted: 0, updated: 0, deleted: 0, generation: generation) }
        do {
            try await prepare()
        } catch {
            let cause = error as? DabbiError
            throw DabbiError(
                .commitPreparationFailed, "Nothing was committed: \(cause?.message ?? "the commit could not begin.")",
                diagnosis: cause?.diagnosis ?? [], recovery: cause?.recovery ?? [], underlying: error)
        }
        try ensureOpen()
        let counts = try await stack.performEditing { context, _ in
            let counts = (
                inserted: context.insertedObjects.count, updated: context.updatedObjects.count,
                deleted: context.deletedObjects.count
            )
            do {
                try objcGuarded("The store refused the commit.", code: .commitFailed) { try context.save() }
            } catch let error as DabbiError {
                throw error
            } catch {
                throw Self.commitError(error)
            }
            CoreDataStack.clearUndo(of: context)
            return counts
        }
        insertedObjectIDs.removeAll()
        invalidate()
        return CommitSummary(
            inserted: counts.inserted, updated: counts.updated, deleted: counts.deleted, generation: generation)
    }

    // MARK: Helpers

    /// What `setValue` stages, resolved on the actor before the edit runs.
    private enum RawValue: @unchecked Sendable {
        case attribute(Any?)
        case toOne(NSManagedObjectID?)
    }

    private func entityDescription(_ name: String) throws -> EntityDescription {
        guard let entity = info.model.entity(named: name) else {
            throw DabbiError(
                .unknownEntity, "The model has no entity named “\(name)”.", arguments: ["entity": name])
        }
        return entity
    }

    private func editableObjectID(for object: PendingObjectID) throws -> NSManagedObjectID {
        try ensureOpen()
        guard stack.isEditable else { throw CoreDataStack.notEditable }
        if let ref = object.ref { return try objectID(for: ref) }
        guard let id = insertedObjectIDs[object.uri] else {
            throw DabbiError(.objectNotFound, "\(object) is not staged in this session.")
        }
        return id
    }

    private func destinationID(
        of value: Value, for relationship: RelationshipDescription, in entity: EntityDescription
    ) throws -> NSManagedObjectID? {
        guard !relationship.isToMany else {
            throw DabbiError(
                .invalidValue, "\(entity.name).\(relationship.name) is a to-many relationship.",
                arguments: ["entity": entity.name, "property": relationship.name],
                recovery: ["Link and unlink its objects instead of setting a value."])
        }
        switch value {
        case .null, .toOne(nil, _):
            return nil
        case .toOne(let ref?, _):
            let allowed = Set(info.model.entityAndDescendants(of: relationship.destinationEntity).map(\.name))
            guard allowed.contains(ref.entity) else {
                throw DabbiError(
                    .invalidValue,
                    "\(entity.name).\(relationship.name) leads to \(relationship.destinationEntity), not \(ref.entity).",
                    arguments: ["entity": entity.name, "property": relationship.name])
            }
            return try objectID(for: ref)
        default:
            throw DabbiError(
                .invalidValue, "\(entity.name).\(relationship.name) is a relationship; give it an object.",
                arguments: ["entity": entity.name, "property": relationship.name])
        }
    }

    private static func existingObject(
        _ id: NSManagedObjectID, object: PendingObjectID?, in context: NSManagedObjectContext
    ) throws -> NSManagedObject {
        guard let found = try? context.existingObject(with: id), !found.isDeleted else {
            throw DabbiError(.objectNotFound, "\(object?.description ?? "The object") no longer exists.")
        }
        return found
    }

    /// A failed save, as the error a front end explains. Row values never go into it, only which object and
    /// which property (privacy).
    static func commitError(_ error: any Error) -> DabbiError {
        let nsError = error as NSError
        guard nsError.domain == NSCocoaErrorDomain else {
            return DabbiError(.commitFailed, "The store refused the commit. Nothing was written.", underlying: error)
        }
        switch nsError.code {
        case NSManagedObjectMergeError, NSPersistentStoreSaveConflictsError, NSManagedObjectConstraintMergeError:
            let isConstraint = nsError.code == NSManagedObjectConstraintMergeError
            return DabbiError(
                .commitConflict,
                isConstraint
                    ? "The commit would break a uniqueness constraint. Nothing was written."
                    : "The store changed underneath these edits. Nothing was written.",
                diagnosis: isConstraint
                    ? ["Another object already has the same value for a property that must be unique."]
                    : ["Rows edited here were changed or deleted by somebody else since they were read."],
                recovery: [
                    "Review the pending changes, then commit again.",
                    "Discard the changes to start again from what is in the store.",
                ],
                underlying: error)
        case NSValidationMultipleErrorsError, NSManagedObjectValidationError...NSValidationStringPatternMatchingError:
            let details = (nsError.userInfo[NSDetailedErrorsKey] as? [NSError]) ?? [nsError]
            return DabbiError(
                .validationFailed,
                details.count == 1
                    ? "One value does not pass the model's validation. Nothing was written."
                    : "\(details.count) values do not pass the model's validation. Nothing was written.",
                arguments: ["count": String(details.count)],
                diagnosis: details.map(validationDiagnosis),
                recovery: ["Correct the values, or undo the edits that set them, then commit again."],
                underlying: error)
        default:
            return DabbiError(.commitFailed, "The store refused the commit. Nothing was written.", underlying: error)
        }
    }

    /// “Sample#3 · name: is required.” — the object, the property and the rule, never the value.
    private static func validationDiagnosis(_ error: NSError) -> String {
        let object = error.userInfo[NSValidationObjectErrorKey] as? NSManagedObject
        let who =
            object.map { object in
                ObjectRef(uri: object.objectID.uriRepresentation())?.description
                    ?? "new \(object.entity.name ?? "object")"
            } ?? "An object"
        let key = error.userInfo[NSValidationKeyErrorKey] as? String
        let rule: String =
            switch error.code {
            case NSValidationMissingMandatoryPropertyError: "is required"
            case NSValidationRelationshipLacksMinimumCountError: "has too few objects"
            case NSValidationRelationshipExceedsMaximumCountError: "has too many objects"
            case NSValidationRelationshipDeniedDeleteError: "still has objects, and its delete rule is Deny"
            case NSValidationNumberTooLargeError: "is above the model's maximum"
            case NSValidationNumberTooSmallError: "is below the model's minimum"
            case NSValidationDateTooLateError: "is later than the model allows"
            case NSValidationDateTooSoonError: "is earlier than the model allows"
            case NSValidationInvalidDateError: "is not a valid date"
            case NSValidationStringTooLongError: "is longer than the model allows"
            case NSValidationStringTooShortError: "is shorter than the model allows"
            case NSValidationStringPatternMatchingError: "does not match the model's pattern"
            default: "does not pass the model's validation"
            }
        return key.map { "\(who) · \($0): \(rule)." } ?? "\(who): \(rule)."
    }
}
