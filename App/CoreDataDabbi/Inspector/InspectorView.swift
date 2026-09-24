import DabbiKit
import SwiftUI

/// The inspector: what this row holds, what this entity is, and how it is stored (BRW-7, BRW-8).
struct InspectorView: View {
    @Bindable var model: InspectorModel

    var body: some View {
        VStack(spacing: 0) {
            Picker("", selection: $model.tab) {
                ForEach(InspectorModel.Tab.allCases) { tab in
                    Text(tab.title).tag(tab)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .padding(.horizontal, 10)
            .padding(.vertical, 7)
            .accessibilityLabel(String(localized: "Inspector tab"))

            Divider()

            Group {
                switch model.tab {
                case .details: DetailsTab(model: model)
                case .entity: EntityTab(model: model)
                case .structure: StructureTab(model: model)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .task(id: Trigger(model: model)) { model.refresh() }
    }

    /// Everything a refresh depends on, so that SwiftUI restarts the task when any of it moves. Reading these
    /// inside the view body is what subscribes it to the context in the first place.
    private struct Trigger: Equatable {
        var object: PendingObjectID?
        var entity: String?
        var tab: InspectorModel.Tab
        var session: ObjectIdentifier?
        var edits: Int

        @MainActor
        init(model: InspectorModel) {
            object = model.focusedObject
            entity = model.entityName
            tab = model.tab
            session = model.sessionIdentity
            edits = model.editRevision
        }
    }
}

/// Nothing is selected, nothing was found, or the pane has nothing to say yet.
struct InspectorMessage: View {
    var symbol: String
    var title: String
    var detail: String?

    var body: some View {
        VStack(spacing: 8) {
            Image(systemName: symbol)
                .font(.system(size: 26, weight: .light))
                .foregroundStyle(.tertiary)
                .accessibilityHidden(true)
            Text(title)
                .foregroundStyle(.secondary)
            if let detail {
                Text(detail)
                    .font(.callout)
                    .foregroundStyle(.tertiary)
                    .multilineTextAlignment(.center)
            }
        }
        .padding(24)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

/// A label on the left, a selectable value on the right — the shape of nearly everything in here.
struct FactRow: View {
    var label: String
    var value: String
    var weight: EntityFacts.Fact.Weight = .plain
    var isMonospaced = false

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(label)
                .foregroundStyle(.secondary)
                .frame(width: 112, alignment: .trailing)
            Text(value)
                .font(isMonospaced ? .system(.body, design: .monospaced) : .body)
                .foregroundStyle(colour)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .accessibilityElement(children: .combine)
    }

    private var colour: Color {
        switch weight {
        case .plain: .primary
        case .notable: .primary
        case .warning: .orange
        }
    }
}
