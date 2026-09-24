@preconcurrency import CoreData
import DabbiBase
import DabbiModel
import Foundation

/// The model's delete rules, followed through the object graph without deleting anything (EDT-2).
///
/// Staging the delete is what decides — Core Data applies the rules and validation says what they broke — but
/// staging only to find out would change the undo stack, and a preview the user cancels must leave nothing
/// behind, a redo included. So this applies the same rules by reading: `value(forKey:)` on relationships fires
/// faults and registers nothing.
///
/// Two readings are its own. A Deny rule counts only the objects that stay, since the ones the delete takes along
/// leave with it; Core Data may be stricter, and the staged delete's validation says so if it is. And a
/// relationship without an inverse is invisible to Core Data from its destination's side: deleting that
/// destination changes nothing on the side that points at it, so those objects are found by a fetch.
///
/// Inside `context.perform` only.
struct DeleteRules: Sendable {
    let converter: ValueConverter

    func preview(
        of targets: [NSManagedObject], sampleSize: Int, in context: NSManagedObjectContext
    ) -> DeletePreview {
        let translator = ValidationTranslator(converter: converter)

        // Everything the delete removes: the targets, then whatever Cascade rules reach from them, transitively.
        // The targets come first, so that what follows them is what was taken along.
        var doomed: [NSManagedObject] = []
        var isDoomed: Set<NSManagedObjectID> = []
        func doom(_ object: NSManagedObject) {
            guard !object.isDeleted, isDoomed.insert(object.objectID).inserted else { return }
            doomed.append(object)
        }
        for target in targets { doom(target) }
        let requested = doomed.count
        var next = 0
        while next < doomed.count {
            let object = doomed[next]
            next += 1
            for relationship in relationships(of: object) where relationship.deleteRule == .cascade {
                for destination in related(object, relationship.name) { doom(destination) }
            }
        }

        // What becomes of the objects that stay.
        var nullified: [NSManagedObjectID: NSManagedObject] = [:]
        var dangling: [NSManagedObjectID: NSManagedObject] = [:]
        var losses: [Link: Int] = [:]
        var issues: [ValidationIssue] = []
        for object in doomed {
            for relationship in relationships(of: object) {
                let staying = related(object, relationship.name).filter {
                    !$0.isDeleted && !isDoomed.contains($0.objectID)
                }
                guard !staying.isEmpty else { continue }
                switch relationship.deleteRule {
                case .deny:
                    issues.append(
                        translator.issue(
                            object, property: relationship.name, rule: .deleteDenied, count: staying.count))
                case .nullify:
                    // Without an inverse there is nothing on the far side to unlink.
                    guard let inverse = relationship.inverseName else { continue }
                    for survivor in staying {
                        nullified[survivor.objectID] = survivor
                        losses[Link(object: survivor.objectID, relationship: inverse), default: 0] += 1
                    }
                case .noAction:
                    guard relationship.inverseName != nil else { continue }
                    for survivor in staying { dangling[survivor.objectID] = survivor }
                case .cascade:
                    // Everything it leads to is doomed already.
                    break
                }
            }
        }
        issues += brokenByUnlinking(losses, in: nullified, translator: translator)
        for survivor in pointingOneWay(at: doomed, isDoomed: isDoomed, in: context) {
            dangling[survivor.objectID] = survivor
        }

        return DeletePreview(
            requested: requested,
            cascaded: groups(Array(doomed.dropFirst(requested)), sampleSize: sampleSize),
            nullified: groups(Array(nullified.values), sampleSize: sampleSize),
            dangling: groups(Array(dangling.values), sampleSize: sampleSize),
            issues: ValidationTranslator.sorted(issues))
    }

    /// One relationship of one object that stays.
    private struct Link: Hashable {
        let object: NSManagedObjectID
        let relationship: String
    }

    /// The rules of the objects that stay which losing their links would break: a to-one that must be set, or a
    /// to-many left with fewer objects than its minimum.
    private func brokenByUnlinking(
        _ losses: [Link: Int], in survivors: [NSManagedObjectID: NSManagedObject], translator: ValidationTranslator
    ) -> [ValidationIssue] {
        losses.compactMap { link, lost in
            guard let survivor = survivors[link.object],
                let relationship = layout(of: survivor)?.relationships[link.relationship]
            else { return nil }
            guard relationship.isToMany else {
                return relationship.isOptional
                    ? nil : translator.issue(survivor, property: relationship.name, rule: .required)
            }
            // A to-many that is not optional needs one object even when its minimum says nothing.
            let minimum = max(relationship.minCount, relationship.isOptional ? 0 : 1)
            let remaining = (ValidationTranslator.count(of: survivor.value(forKey: relationship.name)) ?? 0) - lost
            guard remaining < minimum else { return nil }
            return translator.issue(
                survivor, property: relationship.name, rule: .tooFewObjects, limit: String(minimum),
                count: max(remaining, 0))
        }
    }

    /// Objects that stay and point at a doomed one through a relationship that has no inverse. Core Data cannot
    /// follow such a relationship back from its destination, so no delete rule reaches them.
    ///
    /// Best effort: a fetch Core Data refuses leaves its objects unreported, as not asking would.
    private func pointingOneWay(
        at doomed: [NSManagedObject], isDoomed: Set<NSManagedObjectID>, in context: NSManagedObjectContext
    ) -> [NSManagedObject] {
        let model = converter.model
        var found: [NSManagedObject] = []
        for entity in model.entities {
            // Each relationship once, where it is declared: a fetch on that entity covers its sub-entities.
            for relationship in entity.relationships
            where relationship.declaredIn == entity.name && relationship.inverseName == nil
                && !relationship.isTransient
            {
                let reachable = Set(model.entityAndDescendants(of: relationship.destinationEntity).map(\.name))
                let targets = doomed.filter { $0.entity.name.map(reachable.contains) ?? false }
                for start in stride(from: 0, to: targets.count, by: Self.batchSize) {
                    let batch = Array(targets[start..<min(start + Self.batchSize, targets.count)])
                    let request = NSFetchRequest<NSManagedObject>(entityName: entity.name)
                    request.predicate = NSPredicate(
                        format: relationship.isToMany ? "ANY %K IN %@" : "%K IN %@", relationship.name, batch)
                    let sources = (try? CoreDataStack.fetch(request, in: context)) ?? []
                    found += sources.filter { !$0.isDeleted && !isDoomed.contains($0.objectID) }
                }
            }
        }
        return found
    }

    /// Objects per `IN` list, well inside SQLite's limit on bound variables.
    private static let batchSize = 500

    // MARK: Reading the graph

    private func layout(of object: NSManagedObject) -> ValueConverter.Layout? {
        object.entity.name.flatMap { converter.layouts[$0] }
    }

    /// The relationships an object has — its own entity's, inherited ones included — that are stored.
    private func relationships(of object: NSManagedObject) -> [RelationshipDescription] {
        layout(of: object).map { $0.relationships.values.filter { !$0.isTransient } } ?? []
    }

    private func related(_ object: NSManagedObject, _ name: String) -> [NSManagedObject] {
        switch object.value(forKey: name) {
        case let destination as NSManagedObject: [destination]
        case let set as NSSet: set.compactMap { $0 as? NSManagedObject }
        case let set as NSOrderedSet: set.compactMap { $0 as? NSManagedObject }
        default: []
        }
    }

    /// By entity; within one, the first few in object-ID order — inserted objects, which have no key yet, last.
    private func groups(_ objects: [NSManagedObject], sampleSize: Int) -> [DeletePreview.Group] {
        Dictionary(grouping: objects) { $0.entity.name ?? "" }
            .map { entity, members in
                let ordered = members.map { converter.pendingID(of: $0) }.sorted(by: Self.precedes)
                return DeletePreview.Group(
                    entity: entity, count: members.count, sample: Array(ordered.prefix(sampleSize)))
            }
            .sorted { $0.entity < $1.entity }
    }

    private static func precedes(_ left: PendingObjectID, _ right: PendingObjectID) -> Bool {
        switch (left.ref, right.ref) {
        case (let left?, let right?): left < right
        case (nil, nil): left.uri.absoluteString < right.uri.absoluteString
        case (.some, nil): true
        case (nil, .some): false
        }
    }
}
