import DabbiKit
import Foundation
import Observation

/// One object in a window of its own: its fields, and optionally its relationships (BRW-9).
///
/// For comparing rows side by side, which the one inspector cannot do. The window reads and edits through the
/// same context as the project window — the same session, the same staged edits and the same undo stack — and
/// follows its object through the commit that gives an inserted one its reference.
@MainActor
@Observable
final class ObjectWindowModel {
    let context: ProjectContext
    private(set) var object: PendingObjectID
    /// The object's fields, as the inspector's Details tab shows them, editable when the store is.
    let details: InspectorModel
    /// Its relationships, with the link and unlink picker and New Related Object when the store is editable.
    let relationships: RelationshipsModel
    /// Whether the relationships pane is shown. Shown by default: that is half of what the window is for.
    var showsRelationships = true

    @ObservationIgnored private var loop: ObservationLoop?

    init(context: ProjectContext, object: PendingObjectID) {
        self.context = context
        self.object = object
        details = InspectorModel(context: context, pinned: object)
        relationships = RelationshipsModel(context: context, pinned: object.ref)
        loop = ObservationLoop { [weak self] in self?.followCommit() }
    }

    /// "Sample 12", or "New Sample" while it is only inserted.
    var title: String {
        guard let ref = object.ref else { return String(localized: "New \(object.entity)") }
        return String(localized: "\(ref.entity) \(ref.pk.formatted(.number.grouping(.never)))")
    }

    /// An object only inserted has no relationships to read until it is committed.
    var hasRelationships: Bool { object.ref != nil }

    /// The commit gave the object a reference: it is shown by that from now on, as the inspector does.
    private func followCommit() {
        _ = context.editing.commits
        guard object.isInserted, let ref = context.editing.lastCommit?.insertedRefs[object] else { return }
        object = PendingObjectID(ref)
        details.pinned = object
        relationships.pinned = ref
    }

    /// Returns once both panes have read what they show. For the tests.
    func whenSettled() async {
        await details.whenSettled()
        await relationships.whenSettled()
    }
}
