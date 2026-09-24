import DabbiKit
import Foundation
import Observation
import SwiftUI

/// Picks saved objects of one entity to link into a relationship (EDT-3): the entity's objects, narrowed by what
/// is typed as the grid's quick filter narrows it (PRD-6), labelled by the display attribute and sorted by it.
///
/// A to-many takes any number of them; a to-one takes one, which replaces what it held. Objects already on the
/// far side are listed and marked, and not offered again.
@MainActor
@Observable
final class ObjectPicker: Identifiable {
    struct Item: Identifiable, Hashable {
        var ref: ObjectRef
        var label: String
        /// Already on the far side of the relationship.
        var isLinked: Bool

        var id: ObjectRef { ref }
    }

    /// How many objects one search lists: more than anyone picks from. The count says how many match.
    static let limit = 200

    let id = UUID()
    /// The entity the relationship leads to; its sub-entities are listed too.
    let entity: String
    let relationship: String
    let isToMany: Bool

    /// What is typed. Each change searches again, a moment later, so that typing is not a read per key.
    var term = "" {
        didSet { if term != oldValue { search() } }
    }
    var selection: Set<ObjectRef> = []

    private(set) var items: [Item] = []
    /// How many objects match, which can be more than `items` holds.
    private(set) var matching = 0
    private(set) var error: DabbiError?
    private(set) var hasSearched = false

    private let session: StoreSession
    private let quickFilter: QuickFilter?
    private let displayAttribute: String?
    private let linked: Set<ObjectRef>
    private let onChoose: @MainActor ([ObjectRef]) -> Void
    @ObservationIgnored private var task: Task<Void, Never>?

    init(
        entity: String, relationship: String, isToMany: Bool, linked: Set<ObjectRef>, session: StoreSession,
        model: ModelDescription, displayAttribute: String?, onChoose: @escaping @MainActor ([ObjectRef]) -> Void
    ) {
        self.entity = entity
        self.relationship = relationship
        self.isToMany = isToMany
        self.linked = linked
        self.session = session
        self.quickFilter = QuickFilter(model: model, entity: entity)
        self.displayAttribute = displayAttribute
        self.onChoose = onChoose
    }

    /// Whether what is selected can be linked: something new, and one object for a to-one.
    var canChoose: Bool {
        let fresh = selection.subtracting(linked)
        return !fresh.isEmpty && (isToMany || selection.count == 1)
    }

    /// Links what is selected, in the order it is listed.
    func choose() {
        guard canChoose else { return }
        let chosen = items.map(\.ref).filter { selection.contains($0) && !linked.contains($0) }
        onChoose(chosen)
    }

    /// Reads the objects that match what is typed. The first read starts at once; the ones typing starts wait a
    /// moment for the next key.
    func search() {
        task?.cancel()
        let term = term
        let pause = hasSearched
        task = Task { [weak self] in
            if pause {
                try? await Task.sleep(for: .milliseconds(150))
                guard !Task.isCancelled else { return }
            }
            await self?.read(term)
        }
    }

    private func read(_ term: String) async {
        let predicate = quickFilter?.narrowing(nil, by: term)
        let sort = displayAttribute.map { [SortKey(keyPath: $0)] } ?? []
        do {
            let handle = try await session.openPager(FetchSpec(entity: entity, predicate: predicate, sort: sort))
            // Only the label is read; an entity with no display attribute is listed by identity.
            let labelColumn = displayAttribute.flatMap { handle.columns.index(of: $0) == nil ? nil : $0 }
            let columns = ColumnSet(labelColumn.map { [$0] } ?? [])
            let page: RowPage
            do {
                page = try await session.page(handle, range: 0..<min(handle.count, Self.limit), columns: columns)
            } catch {
                await session.closePager(handle)
                throw error
            }
            await session.closePager(handle)
            guard !Task.isCancelled else { return }
            items = page.rows.map { row in
                var label = row.ref.description
                if case .string(let value)? = row.values.first, !value.isEmpty { label = value }
                return Item(ref: row.ref, label: label, isLinked: linked.contains(row.ref))
            }
            matching = handle.count
            error = nil
        } catch {
            guard !Task.isCancelled else { return }
            items = []
            matching = 0
            self.error = DabbiError.wrapping(error)
        }
        hasSearched = true
    }

    /// Returns once the search under way is done. For the tests.
    func whenSettled() async {
        await task?.value
    }
}

/// The picker as a sheet: a search field, what matches, and Link (or Choose, for a to-one).
struct ObjectPickerView: View {
    @Bindable var picker: ObjectPicker
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(
                picker.isToMany
                    ? String(localized: "Link to “\(picker.relationship)”")
                    : String(localized: "Choose “\(picker.relationship)”")
            )
            .font(.headline)
            TextField(String(localized: "Search"), text: $picker.term, prompt: Text(picker.entity))
                .textFieldStyle(.roundedBorder)
            list
            HStack {
                if picker.matching > picker.items.count {
                    Text(String(localized: "The first \(ObjectPicker.limit) of \(picker.matching) are listed."))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button(String(localized: "Cancel"), role: .cancel) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button(picker.isToMany ? String(localized: "Link") : String(localized: "Choose")) {
                    picker.choose()
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
                .disabled(!picker.canChoose)
            }
        }
        .padding(16)
        .frame(width: 400, height: 440)
        .task { picker.search() }
    }

    @ViewBuilder
    private var list: some View {
        if let error = picker.error {
            InspectorMessage(
                symbol: "exclamationmark.triangle",
                title: error.errorDescription ?? String(localized: "The objects could not be read."),
                detail: error.recoverySuggestion)
        } else if picker.hasSearched, picker.items.isEmpty {
            InspectorMessage(symbol: "magnifyingglass", title: String(localized: "Nothing matches"))
        } else if picker.isToMany {
            List(picker.items, selection: $picker.selection) { row($0) }
                .listStyle(.bordered)
        } else {
            List(picker.items, selection: single) { row($0) }
                .listStyle(.bordered)
        }
    }

    /// A to-one takes one object: the selection is one or none.
    private var single: Binding<ObjectRef?> {
        Binding(get: { picker.selection.first }, set: { picker.selection = $0.map { [$0] } ?? [] })
    }

    private func row(_ item: ObjectPicker.Item) -> some View {
        HStack(spacing: 6) {
            Text(item.label).lineLimit(1)
            Spacer(minLength: 4)
            if item.isLinked {
                Text(String(localized: "Linked"))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            if item.ref.entity != picker.entity {
                Text(item.ref.entity)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .tag(item.ref)
        .help(item.ref.description)
        .selectionDisabled(item.isLinked)
        .accessibilityElement(children: .combine)
    }
}
