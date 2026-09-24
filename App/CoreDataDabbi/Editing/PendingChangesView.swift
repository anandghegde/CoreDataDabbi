import AppKit
import DabbiKit
import SwiftUI

/// Hosts the Pending Changes panel (EDT-8).
final class PendingChangesViewController: NSViewController {
    let context: ProjectContext

    init(context: ProjectContext) {
        self.context = context
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("not in a nib") }

    private var hosting: NSHostingView<PendingChangesView>?

    override func loadView() {
        let hosting = NSHostingView(rootView: PendingChangesView(context: context))
        hosting.translatesAutoresizingMaskIntoConstraints = false
        self.hosting = hosting
        view = NSView()
        view.addSubview(hosting)
        NSLayoutConstraint.activate([
            hosting.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            hosting.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            hosting.topAnchor.constraint(equalTo: view.topAnchor),
            hosting.bottomAnchor.constraint(equalTo: view.bottomAnchor),
        ])
    }
}

extension PendingChangesViewController: KeyboardPane {
    var keyboardResponder: NSResponder? { hosting }
}

/// Everything staged and not yet committed, object by object, each property as it is in the file and as it
/// will be (EDT-8). Commit and Discard are at the top, where the count of what they act on is.
struct PendingChangesView: View {
    let context: ProjectContext

    var body: some View {
        let editing = context.editing
        VStack(spacing: 0) {
            header(editing)
            Divider()
            if editing.changes.isEmpty {
                InspectorMessage(
                    symbol: "tray",
                    title: String(localized: "No pending changes"),
                    detail: editing.isEditable
                        ? String(localized: "Edits are staged here until they are committed to the store.")
                        : String(localized: "The store is read-only. Allow editing to stage changes."))
            } else {
                list(editing.changes.changes)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func header(_ editing: EditingSession) -> some View {
        HStack(spacing: 8) {
            Text("Pending Changes").font(.headline)
            if !editing.changes.isEmpty {
                Text(Self.summary(of: editing.changes))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            if !editing.changes.issues.isEmpty {
                // Committing stays possible: the commit is what decides, and it says why when it refuses.
                HStack(spacing: 4) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundStyle(.red)
                        .accessibilityHidden(true)
                    Text(Self.problems(editing.changes.issues.count))
                        .lineLimit(1)
                }
                .help(String(localized: "The commit would be refused until these are resolved."))
                .accessibilityElement(children: .combine)
            }
            Spacer(minLength: 8)
            if editing.isCommitting { ProgressView().controlSize(.small) }
            Button(String(localized: "Discard")) { context.editing.discard() }
                .disabled(!editing.hasChanges || editing.isCommitting)
            // ⌘↩ is the Data menu's, which works from anywhere in the window.
            Button(String(localized: "Commit")) { context.editing.commit() }
                .disabled(!editing.canCommit)
        }
        .controlSize(.small)
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
    }

    private func list(_ changes: [PendingChange]) -> some View {
        List(changes) { change in
            VStack(alignment: .leading, spacing: 3) {
                ChangeTitle(change: change)
                ForEach(change.fields, id: \.property) { field in
                    FieldDiff(field: field, timeZone: context.timeZone)
                }
                ForEach(context.editing.issues(for: change.object), id: \.self) { issue in
                    IssueLine(issue: issue)
                }
            }
            .padding(.vertical, 2)
            .contentShape(Rectangle())
            // Any object listed can be looked at, and edited, in the inspector; one only inserted is listed here and
            // nowhere else until it is committed (EDT-3).
            .onTapGesture { context.inspect(change.object) }
        }
        .listStyle(.inset)
    }

    /// "2 updated · 1 deleted".
    static func summary(of changes: PendingChanges) -> String {
        var parts: [String] = []
        let inserted = changes.count(of: .inserted)
        let updated = changes.count(of: .updated)
        let deleted = changes.count(of: .deleted)
        if inserted > 0 { parts.append(String(localized: "\(inserted) new")) }
        if updated > 0 { parts.append(String(localized: "\(updated) updated")) }
        if deleted > 0 { parts.append(String(localized: "\(deleted) deleted")) }
        return parts.joined(separator: " · ")
    }

    /// "1 problem", "3 problems": the rules of the model the staged objects break (EDT-2).
    static func problems(_ count: Int) -> String {
        count == 1 ? String(localized: "1 problem") : String(localized: "\(count) problems")
    }
}

/// A rule of the model an object breaks as staged — what the commit would refuse (EDT-2). The symbol says so as
/// well as its colour; the sentence keeps the text's own contrast.
struct IssueLine: View {
    let issue: ValidationIssue

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.red)
                .accessibilityHidden(true)
            if let property = issue.property {
                Text(property)
                    .foregroundStyle(.secondary)
                    .frame(minWidth: 90, alignment: .leading)
            }
            Text(issue.message)
        }
        .font(.callout)
        .lineLimit(2)
        .padding(.leading, 22)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Self.spoken(issue))
    }

    static func spoken(_ issue: ValidationIssue) -> String {
        issue.property.map { String(localized: "\($0), \(issue.message)") } ?? issue.message
    }
}

/// The object: what happens to it, its entity and key, and its name when it has one.
private struct ChangeTitle: View {
    let change: PendingChange

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: symbol)
                .foregroundStyle(tint)
                .accessibilityLabel(kindName)
            Text(change.object.description).font(.body.monospaced())
            if let label = change.label {
                Text(label).foregroundStyle(.secondary).lineLimit(1)
            }
        }
        .accessibilityElement(children: .combine)
    }

    private var symbol: String {
        switch change.kind {
        case .inserted: "plus.circle.fill"
        case .updated: "pencil.circle.fill"
        case .deleted: "minus.circle.fill"
        }
    }

    private var tint: Color {
        switch change.kind {
        case .inserted: .green
        case .updated: .orange
        case .deleted: .red
        }
    }

    private var kindName: String {
        switch change.kind {
        case .inserted: String(localized: "New")
        case .updated: String(localized: "Updated")
        case .deleted: String(localized: "Deleted")
        }
    }
}

/// One property: the file's value struck through, then the staged one.
private struct FieldDiff: View {
    let field: PendingChange.Field
    let timeZone: TimeZone

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Text(field.property)
                .foregroundStyle(.secondary)
                .frame(minWidth: 90, alignment: .leading)
            if let before = field.before.map(render) {
                Text(before.text)
                    .strikethrough(field.after != nil)
                    .foregroundStyle(field.after == nil ? .secondary : .tertiary)
                    .help(before.tooltip ?? before.text)
            }
            if field.before != nil, field.after != nil {
                Image(systemName: "arrow.right").foregroundStyle(.tertiary).accessibilityHidden(true)
            }
            if let after = field.after.map(render) {
                Text(after.text)
                    .foregroundStyle(after.emphasis == .absent ? .secondary : .primary)
                    .help(after.tooltip ?? after.text)
            }
        }
        .font(.callout)
        .lineLimit(1)
        .padding(.leading, 22)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(spoken)
    }

    private func render(_ value: Value) -> GridValue {
        GridValue.render(value, timeZone: timeZone)
    }

    private var spoken: String {
        let before = field.before.map(render)?.accessibleText
        let after = field.after.map(render)?.accessibleText
        switch (before, after) {
        case (let before?, let after?): return String(localized: "\(field.property), from \(before) to \(after)")
        case (nil, let after?): return String(localized: "\(field.property), \(after)")
        case (let before?, nil): return String(localized: "\(field.property), was \(before)")
        case (nil, nil): return field.property
        }
    }
}
