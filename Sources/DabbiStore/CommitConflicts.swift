@preconcurrency import CoreData
import DabbiBase
import DabbiModel
import Foundation

/// Conflicts between staged edits and what somebody else saved meanwhile (EDT-10, ARCHITECTURE.md §6.4).
///
/// Core Data's own optimistic locking is not enough on its own here. It compares a row's version with the
/// version the context last read, and the edit context reads again after every call — browsing refreshes it
/// (`CoreDataStack.perform`), and refreshing an object with changes takes the store's values for everything that
/// was not staged and moves its snapshot on. A row the app saved while the user was scrolling would then be
/// written over at the commit without a word: staged properties win, and a staged delete goes ahead.
///
/// So every object is remembered as it was when an edit first changed it (`recordOriginals`), and the commit
/// compares that with the row as it is in the store now. Any difference in a stored attribute or to-one is a
/// conflict, and the commit is refused until each is settled — `.mine` or `.theirs`, per object. Core Data's check
/// still stands behind this one, for a save that lands between the comparison and the commit's own.
extension StoreSession {
    /// The objects with staged edits whose rows were changed or deleted in the store since they were first
    /// edited here. Inserted objects have no row to conflict with. By entity, then identity.
    public func commitConflicts() async throws -> [CommitConflict] {
        try ensureOpen()
        guard stack.isEditable else { return [] }
        let converter = stack.converter
        // Read as browsing reads, and refreshed afterwards as browsing is: every staged object then stands on its
        // row as it is now, and a save that lands after the comparison below is Core Data's to catch.
        let staged = try await stack.perform { context in
            CoreDataStack.stagedRows(in: context, converter: converter)
        }
        guard !staged.isEmpty else { return [] }
        return try await stack.performTracking { context in
            CoreDataStack.conflicts(of: staged, in: context, converter: converter)
        }
    }

    /// Settles conflicts, one choice per object, and returns what is staged afterwards. Objects not named, and
    /// objects no longer in conflict, are left as they are.
    ///
    /// `.mine` keeps the staged edits and takes the store's row as the one they were made against, so that the
    /// commit writes them; the properties nothing was staged for are the store's. `.theirs` lets the object's
    /// staged edits go — a staged delete is taken back — and the store's values stand. A row that is gone can only
    /// be let go, and `.mine` is taken as `.theirs` for it.
    ///
    /// Settling is not an edit: it cannot be undone, and it empties the undo stack, whose edits were made against
    /// rows that are not what they were.
    @discardableResult
    public func resolveConflicts(_ choices: [PendingObjectID: CommitConflict.Choice]) async throws -> PendingChanges {
        let conflicts = try await commitConflicts().filter { choices[$0.object] != nil }
        let decisions = try conflicts.map { conflict in
            let keep = choices[conflict.object] == .mine && conflict.kind == .changed
            return (id: try editableObjectID(for: conflict.object), keep: keep)
        }
        let converter = stack.converter
        return try await stack.performEditing { context, _ in
            // What the refreshes register is dropped with the rest of the undo stack below.
            let originals = CoreDataStack.originals(of: context)
            for (id, keep) in decisions {
                let object = context.object(with: id)
                try objcGuarded("The conflict could not be settled.", code: .internal) {
                    // Refreshed with its changes kept, the object reads the row as it is now: that becomes what
                    // the staged edits were made against, for this check and for Core Data's.
                    context.refresh(object, mergeChanges: keep)
                }
                originals.rows[id] = keep ? CoreDataStack.row(of: object, committed: true) : nil
            }
            context.processPendingChanges()
            CoreDataStack.clearUndo(of: context)
            return CoreDataStack.pendingChanges(in: context, converter: converter)
        }
    }

    /// The commit's refusal while `conflicts` stand.
    static func conflictError(_ conflicts: [CommitConflict]) -> DabbiError {
        let count = conflicts.count
        return DabbiError(
            .commitConflict,
            count == 1
                ? "One object was changed in the store since it was edited here. Nothing was written."
                : "\(count) objects were changed in the store since they were edited here. Nothing was written.",
            arguments: ["count": String(count)],
            diagnosis: conflicts.map {
                $0.kind == .deleted ? "\($0.object) was deleted." : "\($0.object) was saved by somebody else."
            },
            recovery: [
                "Choose, for each object, whether the staged edits or the store's values stand, then commit again.",
                "Discard the changes to start again from what is in the store.",
            ])
    }
}

/// The rows of the objects with staged edits, as they were first edited. One per edit context, in its
/// `userInfo`, and touched on its queue only.
final class OriginalRows: @unchecked Sendable {
    var rows: [NSManagedObjectID: [String: Any]] = [:]
}

/// An object with staged edits, read on the edit context's queue for the comparison on the tracking context's.
/// `@unchecked Sendable`: the raw values are Foundation values and object IDs, only read once made.
struct StagedRow: @unchecked Sendable {
    let id: NSManagedObjectID
    let object: PendingObjectID
    let kind: PendingChange.Kind
    let label: String?
    let original: [String: Any]
    /// The properties staged, with their values as staged. Empty for a delete.
    let mine: [String: Value]
}

extension CoreDataStack {
    private static let originalsKey = "org.coredatadabbi.originalRows"

    static func originals(of context: NSManagedObjectContext) -> OriginalRows {
        if let originals = context.userInfo[originalsKey] as? OriginalRows { return originals }
        let originals = OriginalRows()
        context.userInfo[originalsKey] = originals
        return originals
    }

    /// Remembers the row of every saved object an edit has changed for the first time, and forgets those no
    /// longer changed — undone. Inside `perform`, right after the edit: the snapshot is still the one the edit was
    /// made against.
    static func recordOriginals(in context: NSManagedObjectContext) {
        let originals = originals(of: context)
        let changed = context.updatedObjects.union(context.deletedObjects).filter { !$0.objectID.isTemporaryID }
        let ids = Set(changed.map(\.objectID))
        originals.rows = originals.rows.filter { ids.contains($0.key) }
        for object in changed where originals.rows[object.objectID] == nil {
            originals.rows[object.objectID] = row(of: object, committed: true)
        }
    }

    /// Forgets the rows remembered: everything staged was written, or let go.
    static func forgetOriginals(in context: NSManagedObjectContext) {
        originals(of: context).rows.removeAll()
    }

    /// What is compared: the stored attributes — not transient, not derived, which follow the others — and
    /// to-ones, which are columns of the row. A to-many is the other rows' business.
    static func comparedKeys(of entity: NSEntityDescription) -> [String] {
        let attributes = entity.attributesByName.values
            .filter { !$0.isTransient && !($0 is NSDerivedAttributeDescription) }.map(\.name)
        let toOnes = entity.relationshipsByName.values.filter { !$0.isToMany && !$0.isTransient }.map(\.name)
        return (attributes + toOnes).sorted()
    }

    /// The compared values of `object`: as last read from the store (`committed`) or as they are in the context.
    /// To-ones as object IDs; no value as `NSNull`.
    static func row(of object: NSManagedObject, committed: Bool) -> [String: Any] {
        let keys = comparedKeys(of: object.entity)
        let values = committed ? object.committedValues(forKeys: keys) : object.dictionaryWithValues(forKeys: keys)
        var row: [String: Any] = [:]
        for key in keys {
            switch values[key] {
            case let destination as NSManagedObject: row[key] = destination.objectID
            case let value?: row[key] = value
            case nil: row[key] = NSNull()
            }
        }
        return row
    }

    static func same(_ one: Any?, _ other: Any?) -> Bool {
        switch (one, other) {
        case (nil, nil), (is NSNull, nil), (nil, is NSNull), (is NSNull, is NSNull): true
        case (let one as NSObject, let other as NSObject): one.isEqual(other)
        default: false
        }
    }

    /// The saved objects with staged updates or deletes, and what they were first edited against. Inside
    /// `perform` on the edit context.
    static func stagedRows(in context: NSManagedObjectContext, converter: ValueConverter) -> [StagedRow] {
        let originals = originals(of: context).rows
        var rows: [StagedRow] = []
        let sets = [(context.updatedObjects, PendingChange.Kind.updated), (context.deletedObjects, .deleted)]
        for (objects, kind) in sets {
            for object in objects where !object.objectID.isTemporaryID {
                let original = originals[object.objectID] ?? row(of: object, committed: true)
                var mine: [String: Value] = [:]
                if kind == .updated {
                    // What was staged, not what differs from the original: a refresh has taken the store's values
                    // for everything else.
                    let staged = Set(object.changedValues().keys)
                    let current = row(of: object, committed: false)
                    for (key, raw) in current where staged.contains(key) && !same(raw, original[key]) {
                        mine[key] = shown(key, raw: raw, of: object.objectID, converter: converter, in: context)
                    }
                    // Only the other side of a relationship, or changes that cancel out: nothing to conflict with.
                    guard !mine.isEmpty else { continue }
                }
                let display = object.entity.name.flatMap { converter.layouts[$0]?.displayAttribute }
                    .flatMap { original[$0] as? String }
                rows.append(
                    StagedRow(
                        id: object.objectID, object: converter.pendingID(of: object), kind: kind,
                        label: display.flatMap { $0.isEmpty ? nil : $0 }, original: original, mine: mine))
            }
        }
        return rows
    }

    /// The staged rows the store no longer agrees with. Inside `perform` on a context that reads through to the
    /// file — the tracking one.
    static func conflicts(
        of staged: [StagedRow], in context: NSManagedObjectContext, converter: ValueConverter
    ) -> [CommitConflict] {
        var current: [NSManagedObjectID: NSManagedObject] = [:]
        for (entity, rows) in Dictionary(grouping: staged, by: { $0.id.entity }) {
            guard let name = entity.name else { continue }
            let request = NSFetchRequest<NSManagedObject>(entityName: name)
            request.predicate = NSPredicate(format: "self IN %@", rows.map(\.id))
            request.returnsObjectsAsFaults = false
            for object in (try? fetch(request, in: context)) ?? [] { current[object.objectID] = object }
        }
        var conflicts: [CommitConflict] = []
        for row in staged {
            let object = current[row.id]
            let theirs = object.map { Self.row(of: $0, committed: true) }
            let theirChanges = Set(
                row.original.keys.filter { key in theirs.map { !same($0[key], row.original[key]) } ?? false })
            guard object == nil || !theirChanges.isEmpty else { continue }
            let fields = theirChanges.union(row.mine.keys).sorted().map { key in
                CommitConflict.Field(
                    property: key,
                    original: shown(key, raw: row.original[key], of: row.id, converter: converter, in: context),
                    mine: row.mine[key],
                    theirs: theirs.map { shown(key, raw: $0[key], of: row.id, converter: converter, in: context) })
            }
            conflicts.append(
                CommitConflict(
                    object: row.object, kind: object == nil ? .deleted : .changed, staged: row.kind, label: row.label,
                    fields: fields))
        }
        return conflicts.sorted {
            ($0.object.entity, $0.object.uri.absoluteString) < ($1.object.entity, $1.object.uri.absoluteString)
        }
    }

    /// A compared value as the grid shows it.
    private static func shown(
        _ key: String, raw: Any?, of id: NSManagedObjectID, converter: ValueConverter,
        in context: NSManagedObjectContext
    ) -> Value {
        guard let layout = id.entity.name.flatMap({ converter.layouts[$0] }) else { return .null }
        if let attribute = layout.attributes[key] { return converter.value(raw is NSNull ? nil : raw, of: attribute) }
        guard let destination = raw as? NSManagedObjectID else { return .toOne(nil, display: nil) }
        return converter.toOne(try? context.existingObject(with: destination))
    }
}
