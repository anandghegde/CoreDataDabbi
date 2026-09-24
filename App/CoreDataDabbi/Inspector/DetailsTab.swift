import DabbiKit
import SwiftUI

/// Every stored property of the selected object, in one column (BRW-7).
///
/// When the store is open for editing, attribute values are edited in place (EDT-3): unlocking a store changes
/// what the rows do and not where anything is.
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
        let fields = properties(of: snapshot)
        let issues = model.issues(for: ref)
        // Issues about the object as a whole, or a property it has no field for, go under the header.
        let shown = Set(fields.map(\.name))
        let general = issues.filter { issue in issue.property.map { !shown.contains($0) } ?? true }
        return ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                header(ref)
                ForEach(general, id: \.self) { issue in
                    IssueLine(issue: issue)
                        .padding(.leading, -10)
                        .padding(.bottom, 4)
                }
                Divider().padding(.bottom, 6)
                ForEach(fields, id: \.name) { property in
                    FieldRow(
                        name: property.name, type: property.type,
                        rendered: GridValue.render(property.value, timeZone: model.timeZone),
                        issue: issues.first { $0.property == property.name },
                        editing: model.fieldEditing(property.name, value: property.value, of: ref))
                }
            }
            .padding(.vertical, 10)
        }
        .scrollContentBackground(.hidden)
        // Rows are per object: a field half typed into is never carried over to the next one.
        .id(ref)
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

    /// “name: sample-3”, and what is wrong with it when something is.
    static func spoken(_ name: String, _ value: String, issue: ValidationIssue?) -> String {
        let field = String(localized: "\(name): \(value)")
        return issue.map { String(localized: "\(field), \($0.message)") } ?? field
    }
}
