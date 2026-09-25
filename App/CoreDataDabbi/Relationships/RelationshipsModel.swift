import DabbiKit
import Foundation
import Observation

/// The relationships panel: what the selected object is joined to, and what lies that way (REL-1, REL-2).
///
/// Two reads, and both are bounded. The object's own row already carries a count for every relationship, so the
/// list on the left costs one fetch of the object; only the relationship actually being looked at is followed,
/// and only as far as `pageLimit`.
@MainActor
@Observable
final class RelationshipsModel {
    /// One relationship of the selected object, as the list shows it.
    struct Row: Identifiable, Equatable {
        var relationship: RelationshipDescription
        /// How many objects are on the far side. A to-one is 0 or 1.
        var count: Int
        /// What a to-one points at, named: the destination's display attribute (REL-1).
        var display: String?

        var id: String { relationship.name }
        var isEmpty: Bool { count == 0 }

        /// "To-many → Employee", and what else is worth knowing about the join itself (REL-2).
        var summary: String {
            var parts = [
                relationship.isToMany
                    ? String(localized: "To-many → \(relationship.destinationEntity)")
                    : String(localized: "To-one → \(relationship.destinationEntity)")
            ]
            if relationship.isOrdered { parts.append(String(localized: "ordered")) }
            // A one-directional relationship cannot be read from the other end; saying so here saves the trip.
            if relationship.inverseName == nil { parts.append(String(localized: "no inverse")) }
            return parts.joined(separator: " · ")
        }
    }

    enum State {
        /// Nothing is selected in the grid, or the store is not open.
        case noObject
        case loading(ObjectRef)
        case ready(ObjectRef, [Row])
        case failed(ObjectRef, DabbiError)
    }

    /// The most one relationship lists without being asked again. Reading labels for a hundred thousand rows is
    /// not what anyone clicked for; the count above the list is always the whole of it.
    static let pageLimit = 500

    private let context: ProjectContext

    private(set) var state: State = .noObject
    /// The objects on the far side of the chosen relationship, once they are in.
    private(set) var related: RelatedObjects?
    private(set) var relatedError: DabbiError?
    /// The relationship being followed. Remembered per project, and used again wherever the object has it.
    private(set) var selected: String?
    /// What names the selected object in a breadcrumb (REL-3).
    private(set) var sourceLabel: String?

    /// An object and one of its relationships, and the staged edits they were read under: what a list of related
    /// objects was read for.
    private struct Followed: Equatable {
        var object: ObjectRef
        var relationship: String
        var revision: Int
    }

    @ObservationIgnored private var rowsTask: Task<Void, Never>?
    @ObservationIgnored private var itemsTask: Task<Void, Never>?
    @ObservationIgnored private var loadedObject: ObjectRef?
    /// The staged edits the object was read under: a new revision reads it again, so that what is linked and
    /// unlinked shows here as it is staged (EDT-3, EDT-8).
    @ObservationIgnored private var loadedRevision = 0
    @ObservationIgnored private var followed: Followed?
    @ObservationIgnored private var loadedFrom: ObjectIdentifier?

    init(context: ProjectContext) {
        self.context = context
        selected = context.local.selection.relationship
    }

    /// The object whose relationships are listed: what the grid has selected, never what this panel has.
    var source: ObjectRef? { context.navigation.current?.focus }
    var sessionIdentity: ObjectIdentifier? { context.session.map(ObjectIdentifier.init) }

    /// Bumped whenever what is staged may have changed.
    var editRevision: Int { context.editing.revision }

    /// The related object being looked at (REL-1): a saved one, or one only inserted and linked here. It is not
    /// held here but read back from what the inspector and the content viewer are showing, so that a click back
    /// in the grid takes the highlight off it by itself.
    var selectedItem: PendingObjectID? {
        guard let source, let inspected = context.inspectedObject, inspected != PendingObjectID(source) else {
            return nil
        }
        return inspected
    }

    var selectedRow: Row? {
        guard case .ready(_, let rows) = state else { return nil }
        return rows.first { $0.id == selected }
    }

    // MARK: Reading

    /// Reads whatever the grid has selected. Called from the view's `task`, so that a collapsed panel follows
    /// no relationships at all.
    func refresh() {
        let session = context.session
        let identity = session.map(ObjectIdentifier.init)
        if identity != loadedFrom {
            // Another store, or the same one reopened: nothing read from the old one still applies.
            loadedFrom = identity
            loadedObject = nil
            followed = nil
            forget()
        }
        guard let session, let source else {
            rowsTask?.cancel()
            itemsTask?.cancel()
            loadedObject = nil
            followed = nil
            forget()
            return
        }
        let revision = context.editing.revision
        if source != loadedObject || revision != loadedRevision {
            // The same object read again for what is staged keeps showing what it had until the new read is in.
            loadRows(of: source, from: session, revision: revision, keepShowing: source == loadedObject)
        }
        loadItems(from: session)
    }

    private func forget() {
        state = .noObject
        related = nil
        relatedError = nil
        sourceLabel = nil
    }

    private func loadRows(of ref: ObjectRef, from session: StoreSession, revision: Int, keepShowing: Bool) {
        loadedObject = ref
        loadedRevision = revision
        rowsTask?.cancel()
        if !keepShowing {
            state = .loading(ref)
            related = nil
            relatedError = nil
        }
        rowsTask = Task { [weak self] in
            let result: Result<ObjectSnapshot, DabbiError>
            do {
                result = .success(try await session.object(ref))
            } catch let error as DabbiError {
                result = .failure(error)
            } catch {
                result = .failure(DabbiError(.internal, "The row could not be read.", underlying: error))
            }
            guard !Task.isCancelled, let self, self.loadedObject == ref else { return }
            switch result {
            case .success(let snapshot):
                let rows = self.rows(of: ref, in: snapshot)
                self.sourceLabel = self.label(of: ref, in: snapshot)
                self.state = .ready(ref, rows)
                self.choose(among: rows)
                if let session = self.context.session { self.loadItems(from: session) }
            case .failure(let error):
                self.sourceLabel = nil
                self.state = .failed(ref, error)
            }
        }
    }

    private func rows(of ref: ObjectRef, in snapshot: ObjectSnapshot) -> [Row] {
        guard let entity = context.model?.entity(named: ref.entity) else { return [] }
        return entity.relationships.filter { !$0.isTransient }.map { relationship in
            switch snapshot[relationship.name] {
            case .toMany(let count):
                Row(relationship: relationship, count: count)
            case .toOne(let destination, let display):
                Row(relationship: relationship, count: destination == nil ? 0 : 1, display: display)
            case .toOneInserted(_, let display):
                Row(relationship: relationship, count: 1, display: display)
            default:
                Row(relationship: relationship, count: 0)
            }
        }
    }

    /// What to call the selected object where there is no room for all of it, honouring the project's choice of
    /// display attribute over the model's conventions.
    private func label(of ref: ObjectRef, in snapshot: ObjectSnapshot) -> String {
        let attribute =
            context.layout(of: ref.entity).displayAttribute
            ?? context.model?.entity(named: ref.entity)?.displayAttributeName
        if case .string(let text)? = attribute.flatMap({ snapshot[$0] }), !text.isEmpty { return text }
        return ref.description
    }

    /// Keeps the relationship being followed where the new object has it, and picks a useful one where it does
    /// not: the first that has something in it, so that opening the panel shows objects rather than nothing.
    private func choose(among rows: [Row]) {
        if let selected, rows.contains(where: { $0.id == selected }) { return }
        if let remembered = context.local.selection.relationship, rows.contains(where: { $0.id == remembered }) {
            selected = remembered
            return
        }
        selected = (rows.first { !$0.isEmpty } ?? rows.first)?.id
    }

    private func loadItems(from session: StoreSession) {
        guard case .ready(let ref, let rows) = state, let name = selected,
            rows.contains(where: { $0.id == name })
        else {
            itemsTask?.cancel()
            followed = nil
            related = nil
            relatedError = nil
            return
        }
        let wanted = Followed(object: ref, relationship: name, revision: loadedRevision)
        guard wanted != followed else { return }
        // The same relationship read again for what is staged keeps its list up until the new one is in.
        let isAnotherList = followed.map { $0.object != ref || $0.relationship != name } ?? true
        followed = wanted
        itemsTask?.cancel()
        if isAnotherList {
            related = nil
            relatedError = nil
        }
        itemsTask = Task { [weak self] in
            let result: Result<RelatedObjects, DabbiError>
            do {
                result = .success(try await session.related(to: ref, through: name, limit: Self.pageLimit))
            } catch let error as DabbiError {
                result = .failure(error)
            } catch {
                result = .failure(DabbiError(.internal, "The relationship could not be read.", underlying: error))
            }
            guard !Task.isCancelled, let self, self.followed == wanted else { return }
            switch result {
            case .success(let objects):
                self.related = objects
                self.relatedError = nil
            case .failure(let error):
                self.related = nil
                self.relatedError = error
            }
        }
    }

    // MARK: What the user does

    /// Follows another relationship of the same object.
    func select(_ name: String?) {
        guard selected != name else { return }
        selected = name
        context.updateSelection { $0.relationship = name }
        if selectedItem != nil { selectItem(nil) }
        related = nil
        relatedError = nil
        followed = nil
        if let session = context.session { loadItems(from: session) }
    }

    /// Looks at one of the related objects: the inspector and the content viewer follow it, the grid does not
    /// (REL-1). `nil` gives them the grid's row back.
    func selectItem(_ object: PendingObjectID?) {
        context.inspect(object ?? source.map(PendingObjectID.init))
    }

    /// Whether there is a related object to jump to — what the Reveal button and the menu item go by (REL-3).
    /// One only inserted is in no grid until it is committed.
    var canReveal: Bool { selected != nil && selectedItem?.ref != nil }

    /// Reveals what is picked, for a command that comes from the menu rather than from a row (§8.4).
    func revealSelected() {
        guard let ref = selectedItem?.ref else { return }
        reveal(ref)
    }

    /// Jumps the main grid to a related object, remembering the way there for the breadcrumb (REL-3).
    func reveal(_ ref: ObjectRef) {
        guard let relationship = selected else { return }
        context.reveal(
            ref, from: source, labelled: sourceLabel ?? source?.description ?? ref.entity, through: relationship)
    }

    // MARK: Editing (EDT-3)

    /// Whether the relationship being followed can be changed from here: the store is open for editing.
    var canEdit: Bool { context.editing.isEditable && source != nil && selectedRow != nil }

    /// What a new related object can be: the followed relationship's destination and its sub-entities, leaving
    /// out the abstract ones. For a to-one, the new object replaces what it held.
    var insertableEntities: [String] {
        guard let relationship = selectedRow?.relationship, let model = context.model else { return [] }
        return model.entityAndDescendants(of: relationship.destinationEntity).filter { !$0.isAbstract }.map(\.name)
    }

    /// Stages a new object of `entity`, linked to the selected object through the followed relationship, and
    /// shows it in the inspector to be filled in.
    func insertRelated(_ entity: String) {
        guard canEdit, insertableEntities.contains(entity), let source, let name = selected else { return }
        context.editing.insertRelatedObject(of: entity, to: PendingObjectID(source), through: name) {
            [weak self] object in self?.context.inspect(object)
        }
    }

    /// A picker of saved objects to link into the followed relationship: any number for a to-many, one for a
    /// to-one, which it replaces. What the picker chooses is staged as one edit.
    func makePicker() -> ObjectPicker? {
        guard canEdit, let session = context.session, let model = context.model, let source, let name = selected,
            let relationship = selectedRow?.relationship
        else { return nil }
        let destination = relationship.destinationEntity
        let linked = Set(related?.items.compactMap(\.ref) ?? [])
        let displayAttribute =
            context.layout(of: destination).displayAttribute ?? model.entity(named: destination)?.displayAttributeName
        return ObjectPicker(
            entity: destination, relationship: name, isToMany: relationship.isToMany, linked: linked,
            session: session, model: model, displayAttribute: displayAttribute
        ) { [weak self] refs in
            self?.context.editing.link(refs.map(PendingObjectID.init), to: PendingObjectID(source), through: name)
        }
    }

    /// Takes `item` out of the followed relationship; a to-one is emptied. The object itself stays. Only what the
    /// list shows is taken out: the inspector may be showing an object from somewhere else.
    func unlink(_ item: PendingObjectID) {
        guard canEdit, let source, let name = selected, related?.items.contains(where: { $0.object == item }) == true
        else { return }
        // It is no longer on this side to be looked at.
        if selectedItem == item { selectItem(nil) }
        context.editing.unlink([item], from: PendingObjectID(source), through: name)
    }

    /// Returns once the panel has read what it is showing. For the tests.
    func whenSettled() async {
        await rowsTask?.value
        await itemsTask?.value
    }
}
