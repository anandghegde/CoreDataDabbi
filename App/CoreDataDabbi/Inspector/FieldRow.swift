import DabbiKit
import SwiftUI

/// How a field of the Details tab is edited, when it can be (EDT-3).
struct FieldEditing {
    /// What the text field starts from: the value as `ValueText` writes it, which reads back as the same value.
    let text: String
    /// Stages what was typed. Returns why it cannot be a value of the attribute's type, or `nil` once it is sent.
    let stage: @MainActor (String) -> String?
    /// Stages no value; `nil` when the attribute must have one, or has none already.
    let clear: (@MainActor () -> Void)?
}

/// One field of the Details tab: its name and type, its value, and the rule of the model its staged value breaks
/// (EDT-2).
///
/// When the store is open for editing the value is edited in place (EDT-3). The pencil, *Edit Value* in the
/// context menu or VoiceOver's action open a text field; Return stages what was typed, Escape leaves the value
/// as it was, and leaving the field stages it too. Text that cannot be a value of the attribute's type stays in
/// the field, with the reason under it.
struct FieldRow: View {
    let name: String
    let type: String?
    let rendered: GridValue
    let issue: ValidationIssue?
    let editing: FieldEditing?

    /// Whether the value is being typed rather than only shown.
    @State private var isEditing = false
    /// The text being typed.
    @State private var draft = ""
    /// Why `draft` cannot be staged.
    @State private var problem: String?
    @FocusState private var isFocused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 1) {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text(name)
                    .font(.callout.weight(.medium))
                if let type {
                    Text(type)
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                }
                if editing != nil, !isEditing {
                    Spacer(minLength: 4)
                    Button(action: begin) {
                        Image(systemName: "pencil")
                    }
                    .buttonStyle(.borderless)
                    .help(String(localized: "Edit Value"))
                    .accessibilityHidden(true)
                }
            }
            if isEditing {
                field
            } else {
                value
            }
            if let problem {
                warning(problem)
            } else if let issue {
                warning(issue.message)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 5)
        .help(rendered.tooltip ?? "")
        .contextMenu {
            if let editing {
                Button(String(localized: "Edit Value"), action: begin)
                if let clear = editing.clear {
                    Button(String(localized: "Set to Nil")) { clear() }
                }
            }
        }
        // Read as one line while it is shown; while it is edited, the text field has to be reachable on its own.
        .accessibilityElement(children: isEditing ? .contain : .combine)
        .accessibilityLabel(DetailsTab.spoken(name, rendered.text, issue: issue))
        .accessibilityActions {
            if editing != nil, !isEditing {
                Button(String(localized: "Edit Value"), action: begin)
            }
        }
    }

    private var value: some View {
        Text(rendered.text)
            .font(.body)
            .italic(rendered.emphasis == .absent)
            .foregroundStyle(colour)
            .textSelection(.enabled)
            .frame(maxWidth: .infinity, alignment: .leading)
            .fixedSize(horizontal: false, vertical: true)
    }

    private var field: some View {
        TextField(name, text: $draft)
            .labelsHidden()
            .textFieldStyle(.roundedBorder)
            .focused($isFocused)
            .onSubmit(commit)
            .onExitCommand(perform: cancel)
            .onAppear { isFocused = true }
            .onChange(of: isFocused) { _, focused in
                if !focused { commit() }
            }
    }

    private func warning(_ message: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 4) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.red)
            Text(message)
                .fixedSize(horizontal: false, vertical: true)
        }
        .font(.caption)
    }

    private var colour: Color {
        switch rendered.emphasis {
        case .value: .primary
        case .absent: .secondary
        case .reference: .accentColor
        }
    }

    // MARK: Editing

    private func begin() {
        guard let editing else { return }
        problem = nil
        draft = editing.text
        isEditing = true
    }

    /// Stages what was typed, unless it is what the field started from.
    private func commit() {
        guard isEditing, let editing else { return }
        guard draft != editing.text else { return cancel() }
        if let problem = editing.stage(draft) {
            self.problem = problem
        } else {
            cancel()
        }
    }

    private func cancel() {
        isEditing = false
        problem = nil
    }
}
