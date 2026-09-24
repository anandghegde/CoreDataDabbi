import DabbiKit
import Foundation
import Observation

/// What the inspector shows, and the reading it takes to know (BRW-7, BRW-8).
///
/// The grid selection changes far more often than anyone can read; every load is therefore cancellable, and the
/// last answer stays on screen until the next one arrives rather than blinking through an empty state.
@MainActor
@Observable
final class InspectorModel {
    enum Tab: String, CaseIterable, Identifiable {
        case details, entity, structure
        var id: String { rawValue }

        var title: String {
            switch self {
            case .details: String(localized: "Details")
            case .entity: String(localized: "Entity")
            case .structure: String(localized: "Structure")
            }
        }

        var symbol: String {
            switch self {
            case .details: "list.bullet.rectangle"
            case .entity: "square.on.square.dashed"
            case .structure: "tablecells.badge.ellipsis"
            }
        }
    }

    /// What has been read for the object the grid has selected.
    enum Details {
        /// Nothing is selected: the grid has no focus, or the store is not open.
        case noObject
        case loading(ObjectRef)
        case object(ObjectRef, ObjectSnapshot)
        case failed(ObjectRef, DabbiError)
    }

    private let context: ProjectContext

    private(set) var details: Details = .noObject
    private(set) var structure: TableStructure?
    private(set) var structureError: DabbiError?

    @ObservationIgnored private var detailsTask: Task<Void, Never>?
    @ObservationIgnored private var structureTask: Task<Void, Never>?
    /// What each task was started for, so that a repeated ask is not a repeated read.
    @ObservationIgnored private var loadedObject: ObjectRef?
    /// The staged edits the object was read under: a new revision reads it again, so that the inspector shows
    /// what is staged and not what was (EDT-8).
    @ObservationIgnored private var loadedRevision = 0
    @ObservationIgnored private var loadedStructure: String?
    @ObservationIgnored private var loadedFrom: ObjectIdentifier?

    init(context: ProjectContext) {
        self.context = context
    }

    var tab: Tab {
        get { context.local.selection.inspectorTab.flatMap(Tab.init) ?? .details }
        set { context.updateSelection { $0.inspectorTab = newValue.rawValue } }
    }

    var entityName: String? { context.selectedEntity }

    var entity: EntityDescription? {
        guard let name = context.selectedEntity else { return nil }
        return context.model?.entity(named: name)
    }

    /// The object being looked at — the grid's selection, or one picked in the relationships panel (REL-1) —
    /// and which store it belongs to: what the inspector's reading depends on.
    var focusedObject: ObjectRef? { context.inspectedObject }
    var sessionIdentity: ObjectIdentifier? { context.session.map(ObjectIdentifier.init) }

    var facts: EntityFacts? {
        guard let entity, let model = context.model else { return nil }
        return EntityFacts(entity: entity, in: model)
    }

    var timeZone: TimeZone { context.timeZone }

    /// Bumped whenever what is staged may have changed.
    var editRevision: Int { context.editing.revision }

    /// The rules of the model `ref` breaks as staged, its fields' and its own (EDT-2).
    func issues(for ref: ObjectRef) -> [ValidationIssue] {
        context.editing.issues(for: PendingObjectID(ref))
    }

    // MARK: Editing (EDT-3)

    /// The attribute `name` of `ref`'s own entity, when the store is open for editing and the attribute is one a
    /// person can type: stored, not derived, and of a type `ValueText` reads.
    func editableAttribute(_ name: String, of ref: ObjectRef) -> AttributeDescription? {
        guard context.accessMode == .editable,
            let attribute = context.model?.entity(named: ref.entity)?.attribute(named: name),
            !attribute.isTransient, !attribute.isDerived, ValueText.isEditableAsText(attribute.type)
        else { return nil }
        return attribute
    }

    /// Stages what was typed into `attribute`'s field of `ref`, read in the project's time zone.
    ///
    /// - Returns: why the text cannot be a value of the attribute's type, for the field to show while it keeps the
    ///   text; `nil` once the value is sent to be staged. A value the session then refuses is explained by the
    ///   window, as any refused edit is.
    func stage(_ text: String, for attribute: AttributeDescription, of ref: ObjectRef) -> String? {
        do {
            let value = try ValueText.value(from: text, for: attribute.type, timeZone: timeZone)
            context.editing.setValue(value, for: attribute.name, of: PendingObjectID(ref))
            return nil
        } catch {
            return DabbiError.wrapping(error).message
        }
    }

    /// Stages no value for `attribute` of `ref`.
    func clear(_ attribute: AttributeDescription, of ref: ObjectRef) {
        context.editing.setValue(.null, for: attribute.name, of: PendingObjectID(ref))
    }

    /// Reads whatever the current tab needs. Called from the view's `task`, so that a tab nobody looks at costs
    /// nothing — the Structure tab in particular runs four `PRAGMA`s the Details tab has no use for.
    func refresh() {
        let session = context.session
        let identity = session.map(ObjectIdentifier.init)
        if identity != loadedFrom {
            // Another store, or the same one reopened: nothing read from the old one still applies.
            loadedFrom = identity
            loadedObject = nil
            loadedStructure = nil
            structure = nil
            structureError = nil
            details = .noObject
        }
        loadDetails(from: session)
        if tab == .structure { loadStructure(from: session) }
    }

    // MARK: Details

    private func loadDetails(from session: StoreSession?) {
        guard let session, let ref = context.inspectedObject else {
            detailsTask?.cancel()
            loadedObject = nil
            details = .noObject
            return
        }
        let revision = context.editing.revision
        guard ref != loadedObject || revision != loadedRevision else { return }
        // The same object read again for its staged values keeps the old ones up until the new ones arrive.
        let isAnotherObject = ref != loadedObject
        loadedObject = ref
        loadedRevision = revision
        detailsTask?.cancel()
        if isAnotherObject { details = .loading(ref) }
        detailsTask = Task { [weak self] in
            let result: Result<ObjectSnapshot, DabbiError>
            do {
                result = .success(try await session.object(ref))
            } catch let error as DabbiError {
                result = .failure(error)
            } catch {
                result = .failure(DabbiError(.internal, "The object could not be read.", underlying: error))
            }
            guard !Task.isCancelled, let self, self.loadedObject == ref else { return }
            switch result {
            case .success(let snapshot): self.details = .object(ref, snapshot)
            case .failure(let error): self.details = .failed(ref, error)
            }
        }
    }

    // MARK: Structure

    private func loadStructure(from session: StoreSession?) {
        guard let session, let entity = context.selectedEntity else {
            structureTask?.cancel()
            loadedStructure = nil
            structure = nil
            return
        }
        guard entity != loadedStructure else { return }
        loadedStructure = entity
        structureTask?.cancel()
        structureError = nil
        structureTask = Task { [weak self] in
            let result: Result<TableStructure, DabbiError>
            do {
                result = .success(try await session.structure(of: entity))
            } catch let error as DabbiError {
                result = .failure(error)
            } catch {
                result = .failure(DabbiError(.internal, "The table could not be read.", underlying: error))
            }
            guard !Task.isCancelled, let self, self.loadedStructure == entity else { return }
            switch result {
            case .success(let structure):
                self.structure = structure
                self.structureError = nil
            case .failure(let error):
                self.structure = nil
                self.structureError = error
            }
        }
    }

    /// Returns once everything the current tab needs is in. For the tests.
    func whenSettled() async {
        await detailsTask?.value
        await structureTask?.value
    }
}
