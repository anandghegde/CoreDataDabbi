import DabbiKit
import SwiftUI

/// The bottom-left panel: the selected object's relationships, and what is on the far side of the one being
/// followed (REL-1, REL-2, REL-3).
struct RelationshipsView: View {
    @Bindable var model: RelationshipsModel
    /// The objects being offered for the followed relationship, while the picker is open (EDT-3).
    @State private var picker: ObjectPicker?

    /// Below this the two lists are too narrow to read, and the relationships move into a menu instead.
    private static let twoColumnWidth: CGFloat = 380
    private static let listWidth: CGFloat = 190

    var body: some View {
        content
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .task(id: Trigger(model: model)) { model.refresh() }
            .sheet(item: $picker) { ObjectPickerView(picker: $0) }
    }

    /// Everything a read depends on, so that SwiftUI restarts the task when any of it moves. Reading these
    /// inside the view body is what subscribes it to the context in the first place.
    private struct Trigger: Equatable {
        var source: ObjectRef?
        var session: ObjectIdentifier?
        var edits: Int

        @MainActor
        init(model: RelationshipsModel) {
            source = model.source
            session = model.sessionIdentity
            edits = model.editRevision
        }
    }

    @ViewBuilder
    private var content: some View {
        switch model.state {
        case .noObject:
            InspectorMessage(
                symbol: "point.3.connected.trianglepath.dotted",
                title: String(localized: "No row selected"),
                detail: String(localized: "Select a row in the grid to see what it is joined to."))

        case .loading:
            ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)

        case .failed(_, let error):
            InspectorMessage(
                symbol: "exclamationmark.triangle",
                title: error.errorDescription ?? String(localized: "The row could not be read."),
                detail: error.recoverySuggestion)

        case .ready(let ref, let rows):
            if rows.isEmpty {
                InspectorMessage(
                    symbol: "point.3.connected.trianglepath.dotted",
                    title: String(localized: "No relationships"),
                    detail: String(localized: "\(ref.entity) points at nothing else."))
            } else {
                panel(rows)
            }
        }
    }

    private func panel(_ rows: [RelationshipsModel.Row]) -> some View {
        GeometryReader { proxy in
            if proxy.size.width >= Self.twoColumnWidth {
                HStack(spacing: 0) {
                    relationshipList(rows).frame(width: Self.listWidth)
                    Divider()
                    objects
                }
            } else {
                VStack(spacing: 0) {
                    relationshipMenu(rows)
                    Divider()
                    objects
                }
            }
        }
    }

    // MARK: The relationships

    private var selection: Binding<String?> {
        Binding(get: { model.selected }, set: { model.select($0) })
    }

    private func relationshipList(_ rows: [RelationshipsModel.Row]) -> some View {
        List(rows, selection: selection) { row in
            VStack(alignment: .leading, spacing: 1) {
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Text(row.relationship.name)
                        .font(.callout.weight(.medium))
                        .lineLimit(1)
                    Spacer(minLength: 2)
                    count(of: row)
                }
                Text(row.summary)
                    .font(.caption)
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
            }
            .padding(.vertical, 1)
            .tag(row.id)
            .accessibilityElement(children: .combine)
            .accessibilityLabel("\(row.relationship.name), \(row.summary), \(row.count.formatted())")
        }
        .listStyle(.sidebar)
        .accessibilityLabel(String(localized: "Relationships"))
    }

    /// The narrow-panel form of the same list.
    private func relationshipMenu(_ rows: [RelationshipsModel.Row]) -> some View {
        Picker("", selection: selection) {
            ForEach(rows) { row in
                Text("\(row.relationship.name) · \(row.count.formatted())").tag(row.id as String?)
            }
        }
        .labelsHidden()
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        .accessibilityLabel(String(localized: "Relationship"))
    }

    @ViewBuilder
    private func count(of row: RelationshipsModel.Row) -> some View {
        if row.relationship.isToMany {
            Text(row.count.formatted())
                .font(.caption.monospacedDigit())
                .foregroundStyle(row.isEmpty ? AnyShapeStyle(.tertiary) : AnyShapeStyle(.secondary))
        } else if let display = row.display {
            Text(display)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
        } else if row.isEmpty {
            Text("—").font(.caption).foregroundStyle(.tertiary)
        }
    }

    // MARK: What is on the far side

    @ViewBuilder
    private var objects: some View {
        VStack(spacing: 0) {
            header
            Divider()
            if let error = model.relatedError {
                InspectorMessage(
                    symbol: "exclamationmark.triangle",
                    title: error.errorDescription ?? String(localized: "The relationship could not be read."),
                    detail: error.recoverySuggestion)
            } else if let related = model.related {
                if related.items.isEmpty {
                    InspectorMessage(
                        symbol: "circle.dashed",
                        title: String(localized: "Nothing on the other side"),
                        detail: String(localized: "This object's “\(related.relationship)” is empty."))
                } else {
                    items(of: related)
                }
            } else if model.selected == nil {
                InspectorMessage(symbol: "arrow.left", title: String(localized: "Choose a relationship"))
            } else {
                ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
    }

    private var header: some View {
        HStack(spacing: 8) {
            if let row = model.selectedRow {
                Text(row.relationship.name)
                    .font(.callout.weight(.medium))
                    .lineLimit(1)
                Text(row.relationship.destinationEntity)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer(minLength: 4)
            if let related = model.related, related.isTruncated {
                // The count is the whole relationship; the list is as much of it as was read (REL-1).
                Text("\(related.items.count.formatted()) of \(related.count.formatted())")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .help(String(localized: "The first \(RelationshipsModel.pageLimit) are listed."))
            }
            if model.canEdit {
                Button(
                    model.selectedRow?.relationship.isToMany == false
                        ? String(localized: "Choose…") : String(localized: "Link…"),
                    systemImage: "link"
                ) { picker = model.makePicker() }
                .labelStyle(.iconOnly)
                .controlSize(.small)
                .help(String(localized: "Link objects that are already in the store"))
                newRelated
            }
            Button(String(localized: "Reveal"), action: model.revealSelected)
                .disabled(!model.canReveal)
                .controlSize(.small)
                .help(String(localized: "Show this object in the main grid"))
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
    }

    /// A new object on the far side, linked already (EDT-3): one button for a destination that is one entity, a
    /// menu for one with sub-entities to choose from.
    @ViewBuilder
    private var newRelated: some View {
        let entities = model.insertableEntities
        if entities.count == 1, let entity = entities.first {
            Button(String(localized: "New Related Object"), systemImage: "plus") { model.insertRelated(entity) }
                .labelStyle(.iconOnly)
                .controlSize(.small)
                .help(String(localized: "New \(entity), linked to this object"))
        } else if entities.count > 1 {
            Menu(String(localized: "New Related Object"), systemImage: "plus") {
                ForEach(entities, id: \.self) { entity in
                    Button(entity) { model.insertRelated(entity) }
                }
            }
            .labelStyle(.iconOnly)
            .menuIndicator(.hidden)
            .fixedSize()
            .controlSize(.small)
            .help(String(localized: "New related object, linked to this object"))
        }
    }

    private var itemSelection: Binding<PendingObjectID?> {
        Binding(get: { model.selectedItem }, set: { model.selectItem($0) })
    }

    private func items(of related: RelatedObjects) -> some View {
        List(Array(related.items.enumerated()), id: \.element.object, selection: itemSelection) { index, item in
            HStack(spacing: 6) {
                // An ordered relationship keeps the order it was given, and the position is part of the data
                // (REL-2).
                if related.isOrdered {
                    Text((index + 1).formatted())
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.tertiary)
                        .frame(minWidth: 20, alignment: .trailing)
                }
                Text(item.label)
                    .lineLimit(1)
                Spacer(minLength: 4)
                // Only inserted: in no grid, and with no URI worth copying, until it is committed.
                if item.ref == nil {
                    Text(String(localized: "New"))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                // Which sub-entity it turned out to be, where that is not the destination itself.
                if item.object.entity != related.destinationEntity {
                    Text(item.object.entity)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .tag(item.object)
            .help(item.object.description)
            .contentShape(Rectangle())
            // The list's own click keeps working; this only adds the second one.
            .simultaneousGesture(TapGesture(count: 2).onEnded { if let ref = item.ref { model.reveal(ref) } })
            .contextMenu {
                if let ref = item.ref {
                    Button(String(localized: "Reveal in Entity")) { model.reveal(ref) }
                    Button(String(localized: "Copy Object ID URI")) {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(ref.uri.absoluteString, forType: .string)
                    }
                }
                if model.canEdit {
                    Divider()
                    Button(String(localized: "Unlink")) { model.unlink(item.object) }
                }
            }
            .accessibilityElement(children: .combine)
            .accessibilityLabel("\(item.label), \(item.object.entity)")
            .accessibilityActions {
                if model.canEdit { Button(String(localized: "Unlink")) { model.unlink(item.object) } }
            }
        }
        .listStyle(.inset)
        // Delete takes the selected object out of the relationship, as Delete Rows does in the grid; the object
        // itself stays.
        .onDeleteCommand {
            if let item = model.selectedItem { model.unlink(item) }
        }
        .accessibilityLabel(String(localized: "Related objects"))
    }
}
