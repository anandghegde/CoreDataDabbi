import DabbiKit
import Foundation
import Observation

/// One of the batch edits (EDT-4) — *Batch Update*, *Find and Replace* or *Nullify Attributes* — being set up:
/// which attribute, what it becomes, and which rows, with how many would change and a few of them before and
/// after. Nothing is staged until it is applied, and then as one edit, which one ⌘Z takes back.
@MainActor
@Observable
final class BatchEditModel {
    enum Kind: CaseIterable, Hashable {
        case set, replace, nullify

        var title: String {
            switch self {
            case .set: String(localized: "Batch Update")
            case .replace: String(localized: "Find and Replace")
            case .nullify: String(localized: "Nullify Attributes")
            }
        }
    }

    /// Which rows the edit changes.
    enum Scope: Hashable {
        /// The rows selected in the grid.
        case selection
        /// Every row the grid's fetch matches, as far as its limit.
        case all
    }

    let context: ProjectContext
    /// The grid's fetch when the sheet was opened.
    let fetch: FetchSpec
    /// The grid's selection when the sheet was opened.
    let selection: [PendingObjectID]

    var kind: Kind {
        didSet { if !attributes.contains(where: { $0.name == attribute }) { attribute = attributes.first?.name } }
    }
    var scope: Scope
    var attribute: String?
    /// The new value, as it is typed in the inspector (Batch Update).
    var text = ""
    var find = ""
    var replacement = ""
    var isRegularExpression = false
    var ignoresCase = false

    /// What the edit would do, as last worked out; `nil` while it cannot be.
    private(set) var preview: BatchPreview?
    /// Why the edit cannot be made as it is: a value that is not one of the attribute's type, a bad pattern.
    private(set) var problem: String?
    private(set) var isPreviewing = false

    /// The sheet is done with, applied or cancelled.
    @ObservationIgnored var onClose: (() -> Void)?

    init(
        context: ProjectContext, kind: Kind, fetch: FetchSpec, selection: [PendingObjectID], attribute: String? = nil
    ) {
        self.context = context
        self.kind = kind
        self.fetch = fetch
        self.selection = selection
        scope = selection.count > 1 ? .selection : .all
        self.attribute = nil
        let names = attributes.map(\.name)
        self.attribute = attribute.flatMap { names.contains($0) ? $0 : nil } ?? names.first
    }

    var entity: String { fetch.entity }

    /// The attributes the edit can change: stored ones that can be typed for Batch Update, text for Find and
    /// Replace, and any optional one for Nullify.
    var attributes: [AttributeDescription] {
        let all = context.model?.entity(named: entity)?.attributes ?? []
        return all.filter { attribute in
            guard !attribute.isTransient, !attribute.isDerived else { return false }
            switch kind {
            case .set: return ValueText.isEditableAsText(attribute.type)
            case .replace: return attribute.type == .string
            case .nullify: return attribute.isOptional && attribute.type != .objectID
            }
        }
    }

    var target: BatchTarget {
        switch scope {
        case .selection: .objects(selection)
        case .all: .fetch(fetch)
        }
    }

    /// How many rows the scope names, before anything is read: the selection's, or what the grid shows.
    var hasSelection: Bool { !selection.isEmpty }

    /// The edit as the session takes it; throws with why it cannot be.
    func operation() throws -> BatchOperation {
        switch kind {
        case .set:
            guard let attribute, let description = attributes.first(where: { $0.name == attribute }) else {
                throw DabbiError(.invalidValue, String(localized: "Choose an attribute."))
            }
            return .set(try ValueText.value(from: text, for: description.type, timeZone: context.timeZone))
        case .replace:
            return .replace(
                FindReplace(
                    find: find, replacement: replacement, isRegularExpression: isRegularExpression,
                    ignoresCase: ignoresCase))
        case .nullify:
            return .nullify
        }
    }

    /// Everything the preview depends on.
    struct Trigger: Hashable {
        var kind: Kind
        var scope: Scope
        var attribute: String?
        var text: String
        var find: String
        var replacement: String
        var isRegularExpression: Bool
        var ignoresCase: Bool
        var revision: Int
    }

    var trigger: Trigger {
        Trigger(
            kind: kind, scope: scope, attribute: attribute, text: text, find: find, replacement: replacement,
            isRegularExpression: isRegularExpression, ignoresCase: ignoresCase, revision: context.editing.revision)
    }

    /// Works out what the edit would do as it is set up now.
    func updatePreview() async {
        let asked = trigger
        guard let attribute else {
            preview = nil
            problem = String(localized: "\(entity) has no attribute this edit can change.")
            return
        }
        if kind == .replace, find.isEmpty {
            preview = nil
            problem = nil
            return
        }
        let operation: BatchOperation
        do {
            operation = try self.operation()
        } catch {
            preview = nil
            problem = DabbiError.wrapping(error).message
            return
        }
        isPreviewing = true
        defer { if asked == trigger { isPreviewing = false } }
        do {
            let result = try await context.editing.batchPreview(
                operation, attribute: attribute, entity: entity, target: target)
            guard asked == trigger else { return }
            preview = result
            problem = nil
        } catch {
            guard asked == trigger else { return }
            preview = nil
            problem = DabbiError.wrapping(error).message
        }
    }

    /// Whether Apply would change anything.
    var canApply: Bool {
        guard problem == nil, let preview, preview.changing > 0 else { return false }
        return context.editing.isEditable
    }

    /// Stages the edit and closes the sheet.
    func apply() {
        guard canApply, let attribute, let operation = try? operation() else { return }
        context.editing.batchEdit(operation, attribute: attribute, entity: entity, target: target)
        onClose?()
    }

    func cancel() { onClose?() }
}
