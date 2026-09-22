import AppKit

/// A pane the keyboard can be sent to by name (§8.4: full keyboard navigation).
///
/// Tab walks the panes that are on screen; this is the other half — a way to reach a pane that is shut, and a
/// way back to the grid from anywhere, without the pointer.
@MainActor
protocol KeyboardPane: NSViewController {
    /// What takes the keyboard when the pane is asked for: the list itself, or — for a pane drawn in SwiftUI —
    /// the hosting view, which hands focus on to whatever inside it can hold it.
    var keyboardResponder: NSResponder? { get }
}

extension KeyboardPane {
    var keyboardResponder: NSResponder? { view }
}
