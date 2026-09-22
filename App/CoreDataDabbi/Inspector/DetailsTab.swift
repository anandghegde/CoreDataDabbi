import DabbiKit
import SwiftUI

/// Every stored property of the selected object, in one column (BRW-7).
///
/// Read-only in M1. The fields are laid out as they will be when they become editable in M3, so that unlocking
/// a store changes what the rows do and not where anything is.
struct DetailsTab: View {
    let model: InspectorModel

    var body: some View {
        switch model.details {
        case .noObject:
            InspectorMessage(
                symbol: "cursorarrow.rays",
                title: String(localized: "No row selected"),
                detail: String(localized: "Select a row in the grid to see everything it holds."))

        case .loading(let ref):
            VStack(spacing: 10) {
                ProgressView()
                Text(ref.description).font(.callout).foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)

        case .failed(let ref, let error):
            InspectorMessage(
                symbol: "exclamationmark.triangle",
                title: error.errorDescription ?? String(localized: "The row could not be read."),
                detail: error.recoverySuggestion ?? ref.description)

        case .object(let ref, let snapshot):
            object(ref, snapshot)
        }
    }

    private func object(_ ref: ObjectRef, _ snapshot: ObjectSnapshot) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                header(ref)
                Divider().padding(.bottom, 6)
                ForEach(properties(of: snapshot), id: \.name) { property in
                    row(property)
                }
            }
            .padding(.vertical, 10)
        }
        .scrollContentBackground(.hidden)
    }

    private func header(_ ref: ObjectRef) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(ref.entity)
                .font(.headline)
            // The URI is what identifies this row anywhere else — in a bug report, in another tool, in code.
            Text(ref.uri.absoluteString)
                .font(.caption)
                .foregroundStyle(.secondary)
                .textSelection(.enabled)
                .lineLimit(2)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 12)
        .padding(.bottom, 8)
        .contextMenu {
            Button(String(localized: "Copy Object ID URI")) {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(ref.uri.absoluteString, forType: .string)
            }
        }
    }

    private struct Property {
        var name: String
        var value: Value
        var type: String?
    }

    private func properties(of snapshot: ObjectSnapshot) -> [Property] {
        let entity = model.entity
        return snapshot.columns.properties.enumerated().map { index, name in
            Property(
                name: name,
                value: index < snapshot.row.values.count ? snapshot.row.values[index] : .null,
                type: entity?.attribute(named: name)?.type.displayName
                    ?? entity?.relationship(named: name).map {
                        $0.isToMany
                            ? String(localized: "To-many → \($0.destinationEntity)")
                            : String(localized: "To-one → \($0.destinationEntity)")
                    })
        }
    }

    @ViewBuilder
    private func row(_ property: Property) -> some View {
        let rendered = GridValue.render(property.value, timeZone: model.timeZone)
        VStack(alignment: .leading, spacing: 1) {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text(property.name)
                    .font(.callout.weight(.medium))
                if let type = property.type {
                    Text(type)
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                }
            }
            Text(rendered.text)
                .font(.body)
                .italic(rendered.emphasis == .absent)
                .foregroundStyle(colour(of: rendered.emphasis))
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 5)
        .help(rendered.tooltip ?? "")
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(property.name): \(rendered.text)")
    }

    private func colour(of emphasis: GridValue.Emphasis) -> Color {
        switch emphasis {
        case .value: .primary
        case .absent: .secondary
        case .reference: .accentColor
        }
    }
}
