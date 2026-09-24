import AppKit
import DabbiKit
import SwiftUI

/// Edits one cell of the grid in a popover anchored to it (EDT-3).
///
/// A popover rather than the cell's own label: the grid reloads and reuses its cells as pages arrive and as
/// edits are staged, and a label being typed into would be written over. The popover holds the text until it is
/// staged or given up.
@MainActor
enum CellEditor {
    /// Opens the editor over `rect` of `view`. Return stages what was typed and closes it; Escape, or a click
    /// anywhere else, closes it and stages nothing.
    static func show(
        _ editing: FieldEditing, named name: String, relativeTo rect: NSRect, of view: NSView
    ) -> NSPopover {
        let popover = NSPopover()
        popover.behavior = .transient
        popover.animates = false
        popover.contentViewController = NSHostingController(
            rootView: CellEditorView(
                name: name, editing: editing, close: { [weak popover] in popover?.performClose(nil) }))
        popover.show(relativeTo: rect, of: view, preferredEdge: .maxY)
        return popover
    }
}

/// The text field of a cell being edited, what is wrong with what is in it, and Set to Nil when the attribute
/// may have no value.
struct CellEditorView: View {
    let name: String
    let editing: FieldEditing
    let close: @MainActor () -> Void

    @State private var draft: String
    @State private var problem: String?
    @FocusState private var isFocused: Bool

    init(name: String, editing: FieldEditing, close: @escaping @MainActor () -> Void) {
        self.name = name
        self.editing = editing
        self.close = close
        _draft = State(initialValue: editing.text)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(name)
                .font(.callout.weight(.medium))
            TextField(name, text: $draft)
                .labelsHidden()
                .textFieldStyle(.roundedBorder)
                .frame(minWidth: 240)
                .focused($isFocused)
                .onSubmit(commit)
                .onExitCommand(perform: close)
            if let problem {
                HStack(alignment: .firstTextBaseline, spacing: 4) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundStyle(.red)
                        .accessibilityHidden(true)
                    Text(problem)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .font(.caption)
            }
            if let clear = editing.clear {
                Button(String(localized: "Set to Nil")) {
                    clear()
                    close()
                }
                .controlSize(.small)
            }
        }
        .padding(12)
        .onAppear { isFocused = true }
    }

    /// Stages what was typed, unless it is what the field started from, and closes; keeps the text and says why
    /// when it cannot be a value of the attribute's type.
    private func commit() {
        guard draft != editing.text else { return close() }
        if let problem = editing.stage(draft) {
            self.problem = problem
        } else {
            close()
        }
    }
}
