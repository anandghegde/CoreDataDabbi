import DabbiKit
import SwiftUI

/// A detail window's content: the object's fields on the left, its relationships on the right (BRW-9).
struct ObjectWindowView: View {
    @Bindable var model: ObjectWindowModel

    var body: some View {
        VStack(spacing: 0) {
            bar
            Divider()
            HSplitView {
                DetailsTab(model: model.details)
                    .frame(minWidth: 260, maxWidth: .infinity, maxHeight: .infinity)
                    .task(id: DetailsTrigger(model: model.details)) { model.details.refresh() }
                if model.showsRelationships {
                    relationships
                        .frame(minWidth: 320, maxWidth: .infinity, maxHeight: .infinity)
                }
            }
        }
    }

    private var bar: some View {
        HStack(spacing: 8) {
            Text(model.object.entity)
                .font(.callout.weight(.medium))
            Spacer()
            Toggle(isOn: $model.showsRelationships) {
                Label(String(localized: "Relationships"), systemImage: "point.3.connected.trianglepath.dotted")
            }
            .toggleStyle(.button)
            .labelStyle(.iconOnly)
            .controlSize(.small)
            .help(String(localized: "Show or hide this object's relationships"))
            .accessibilityLabel(String(localized: "Relationships"))
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
    }

    @ViewBuilder
    private var relationships: some View {
        if model.hasRelationships {
            RelationshipsView(model: model.relationships)
        } else {
            InspectorMessage(
                symbol: "point.3.connected.trianglepath.dotted",
                title: String(localized: "Not committed yet"),
                detail: String(localized: "A new object's relationships can be followed here once it is committed."))
        }
    }

    /// What the fields depend on, as the inspector's own trigger has it.
    private struct DetailsTrigger: Equatable {
        var object: PendingObjectID?
        var session: ObjectIdentifier?
        var edits: Int

        @MainActor
        init(model: InspectorModel) {
            object = model.focusedObject
            session = model.sessionIdentity
            edits = model.editRevision
        }
    }
}
