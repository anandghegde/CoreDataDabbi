import AppKit
import DabbiKit
import SwiftUI

/// The store changed underneath staged edits (EDT-10): each object somebody else saved or deleted since it was
/// edited here, what either side made of each property, and whose values stand — Mine or Theirs, per object.
/// Commit settles them as chosen and commits; Cancel leaves everything staged.
struct CommitConflictsView: View {
    @Observable
    final class Model {
        let conflicts: [CommitConflict]
        var choices: [PendingObjectID: CommitConflict.Choice]
        let timeZone: TimeZone
        /// A choice per object, or `nil` for Cancel.
        @ObservationIgnored var onFinish: ([PendingObjectID: CommitConflict.Choice]?) -> Void = { _ in }

        /// Every object starts on Theirs: nothing somebody else saved is written over unless the user says so.
        init(conflicts: [CommitConflict], timeZone: TimeZone) {
            self.conflicts = conflicts
            self.timeZone = timeZone
            choices = Dictionary(uniqueKeysWithValues: conflicts.map { ($0.object, .theirs) })
        }

        /// Mine wherever a row is still there to write to.
        func chooseAll(_ choice: CommitConflict.Choice) {
            for conflict in conflicts {
                choices[conflict.object] = conflict.choices.contains(choice) ? choice : .theirs
            }
        }
    }

    @Bindable var model: Model

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(Self.title(model.conflicts.count)).font(.headline)
            Text(
                String(
                    localized:
                        "Somebody else saved these objects after they were edited here. Choose whose values the commit keeps: Mine writes the staged edits over theirs, Theirs lets the staged edits go."
                )
            )
            .font(.callout)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
            List(model.conflicts) { conflict in
                ConflictRow(conflict: conflict, choice: $model.choices[conflict.object], timeZone: model.timeZone)
            }
            .listStyle(.bordered)
            .frame(minHeight: 180)
            HStack {
                Button(String(localized: "Use All Mine")) { model.chooseAll(.mine) }
                    .accessibilityHint(String(localized: "Keeps the staged edits of every object that is still there."))
                Button(String(localized: "Use All Theirs")) { model.chooseAll(.theirs) }
                    .accessibilityHint(String(localized: "Lets the staged edits of every object go."))
                Spacer()
                Button(String(localized: "Cancel"), role: .cancel) { model.onFinish(nil) }
                    .keyboardShortcut(.cancelAction)
                Button(String(localized: "Commit")) { model.onFinish(model.choices) }
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 560, height: 420)
    }

    static func title(_ count: Int) -> String {
        count == 1
            ? String(localized: "1 object changed in the store since it was edited")
            : String(localized: "\(count) objects changed in the store since they were edited")
    }
}

/// One object in conflict: its identity, what happened to it, the properties either side changed, and the choice.
private struct ConflictRow: View {
    let conflict: CommitConflict
    /// Always set: every object starts with one.
    @Binding var choice: CommitConflict.Choice?
    let timeZone: TimeZone

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                Image(systemName: conflict.kind == .deleted ? "trash.circle.fill" : "exclamationmark.circle.fill")
                    .foregroundStyle(conflict.kind == .deleted ? .red : .orange)
                    .accessibilityHidden(true)
                Text(conflict.object.description).font(.body.monospaced())
                if let label = conflict.label {
                    Text(label).foregroundStyle(.secondary).lineLimit(1)
                }
                Spacer(minLength: 8)
                Picker(String(localized: "Keep"), selection: $choice) {
                    if conflict.choices.contains(.mine) {
                        Text(String(localized: "Mine")).tag(CommitConflict.Choice?.some(.mine))
                    }
                    Text(String(localized: "Theirs")).tag(CommitConflict.Choice?.some(.theirs))
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .fixedSize()
                .accessibilityLabel(String(localized: "Keep for \(conflict.object.description)"))
            }
            Text(Self.situation(conflict))
                .font(.callout)
                .foregroundStyle(.secondary)
            ForEach(conflict.fields, id: \.property) { field in
                ConflictField(field: field, deletedHere: conflict.staged == .deleted, timeZone: timeZone)
            }
        }
        .padding(.vertical, 2)
    }

    static func situation(_ conflict: CommitConflict) -> String {
        switch (conflict.kind, conflict.staged) {
        case (.deleted, _):
            String(localized: "Deleted in the store. The staged edits can only be let go.")
        case (.changed, .deleted):
            String(localized: "Deleted here, saved again in the store.")
        default:
            String(localized: "Edited here, saved again in the store.")
        }
    }
}

/// One property: Mine and Theirs side by side, a clash — both changed it, differently — marked.
private struct ConflictField: View {
    let field: CommitConflict.Field
    /// The object is staged for deletion: Mine is no value at all.
    let deletedHere: Bool
    let timeZone: TimeZone

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Text(field.property)
                .foregroundStyle(.secondary)
                .frame(minWidth: 90, alignment: .leading)
            side(String(localized: "Mine"), mine)
            side(String(localized: "Theirs"), theirs)
            if field.isClash {
                Image(systemName: "bolt.fill").foregroundStyle(.orange).accessibilityHidden(true)
            }
        }
        .font(.callout)
        .lineLimit(1)
        .padding(.leading, 22)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(spoken)
    }

    private func side(_ name: String, _ text: String) -> some View {
        HStack(spacing: 4) {
            Text(name).foregroundStyle(.tertiary)
            Text(text)
        }
        .frame(minWidth: 150, alignment: .leading)
    }

    /// Mine: as staged, as it was when nothing was staged for the property, or nothing — deleted here.
    private var mine: String {
        if deletedHere { return String(localized: "(deleted)") }
        return GridValue.render(field.mine ?? field.original, timeZone: timeZone).text
    }

    /// Theirs: as the store has it, or nothing — the row is gone.
    private var theirs: String {
        field.theirs.map { GridValue.render($0, timeZone: timeZone).text } ?? String(localized: "(deleted)")
    }

    private var spoken: String {
        field.isClash
            ? String(localized: "\(field.property): mine \(mine), theirs \(theirs), both changed")
            : String(localized: "\(field.property): mine \(mine), theirs \(theirs)")
    }
}

final class CommitConflictsController: NSHostingController<CommitConflictsView> {
    let model: CommitConflictsView.Model

    init(_ model: CommitConflictsView.Model) {
        self.model = model
        super.init(rootView: CommitConflictsView(model: model))
        sizingOptions = [.preferredContentSize]
        title = CommitConflictsView.title(model.conflicts.count)
    }

    @available(*, unavailable)
    @MainActor required dynamic init?(coder: NSCoder) { fatalError("not in a nib") }
}
