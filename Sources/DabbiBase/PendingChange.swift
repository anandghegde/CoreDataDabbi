import Foundation

/// The identity of an object with staged edits (EDT-8).
///
/// Unlike an `ObjectRef` it can name an object that has only been inserted: until the commit gives it a primary
/// key, such an object has a temporary Core Data URI (`x-coredata:///Sample/t…`), and that is what `uri` holds.
public struct PendingObjectID: Sendable, Hashable, Codable {
    public let uri: URL
    /// The object's own entity.
    public let entity: String

    public init(uri: URL, entity: String) {
        self.uri = uri
        self.entity = entity
    }

    public init(_ ref: ObjectRef) {
        self.init(uri: ref.uri, entity: ref.entity)
    }

    /// The saved object's reference; `nil` while the object is only inserted.
    public var ref: ObjectRef? { ObjectRef(uri: uri) }
    public var isInserted: Bool { ref == nil }
}

extension PendingObjectID: CustomStringConvertible {
    public var description: String { ref?.description ?? "\(entity)#new" }
}

/// One object's staged edits, as the Pending Changes panel lists them.
public struct PendingChange: Sendable, Hashable, Codable, Identifiable {
    public enum Kind: String, Sendable, Hashable, Codable {
        case inserted, updated, deleted
    }

    /// One property's value in the file (`before`) and as staged (`after`). An inserted object has no `before`,
    /// a deleted one no `after`.
    public struct Field: Sendable, Hashable, Codable {
        public let property: String
        public let before: Value?
        public let after: Value?

        public init(property: String, before: Value?, after: Value?) {
            self.property = property
            self.before = before
            self.after = after
        }
    }

    public let object: PendingObjectID
    public let kind: Kind
    /// The object's display attribute, when it has one.
    public let label: String?
    /// For an update, the properties that changed; for an insert, those set to something; for a delete, every
    /// stored property as it was.
    public let fields: [Field]

    public var id: PendingObjectID { object }

    public init(object: PendingObjectID, kind: Kind, label: String?, fields: [Field]) {
        self.object = object
        self.kind = kind
        self.label = label
        self.fields = fields
    }
}

/// Everything staged in an editable session, and where its undo stack stands.
public struct PendingChanges: Sendable, Hashable, Codable {
    /// Inserted, then updated, then deleted; by entity and identity within each.
    public var changes: [PendingChange]
    public var canUndo: Bool
    public var canRedo: Bool
    /// The name of the edit `undo()` would take back; empty when it has none.
    public var undoActionName: String
    public var redoActionName: String
    /// How many edits `undo()` can take back, one at a time. A front end mirroring the undo stack in its own
    /// compares it before and after a call to tell an edit from one that changed nothing.
    public var undoDepth: Int

    public init(
        changes: [PendingChange], canUndo: Bool = false, canRedo: Bool = false, undoActionName: String = "",
        redoActionName: String = "", undoDepth: Int = 0
    ) {
        self.changes = changes
        self.canUndo = canUndo
        self.canRedo = canRedo
        self.undoActionName = undoActionName
        self.redoActionName = redoActionName
        self.undoDepth = undoDepth
    }

    public static let none = PendingChanges(changes: [])

    public var isEmpty: Bool { changes.isEmpty }

    public func count(of kind: PendingChange.Kind) -> Int {
        changes.count { $0.kind == kind }
    }

    public func change(for object: PendingObjectID) -> PendingChange? {
        changes.first { $0.object == object }
    }
}

/// What a commit wrote.
public struct CommitSummary: Sendable, Hashable, Codable {
    public let inserted: Int
    public let updated: Int
    public let deleted: Int
    /// The session generation after the commit; pages and pagers from before it are stale.
    public let generation: Int

    public init(inserted: Int, updated: Int, deleted: Int, generation: Int) {
        self.inserted = inserted
        self.updated = updated
        self.deleted = deleted
        self.generation = generation
    }

    public var total: Int { inserted + updated + deleted }
}
