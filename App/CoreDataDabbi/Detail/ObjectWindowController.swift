import AppKit
import DabbiKit
import SwiftUI

/// A window of one object's own (BRW-9), opened by double-clicking its row or *Data › Open in Separate Window*.
///
/// It belongs to the project's document, so it closes with it, and it edits through the project's staged edits:
/// ⌘Z here undoes the same stack the project window does.
final class ObjectWindowController: NSWindowController, NSWindowDelegate {
    let model: ObjectWindowModel
    private var observation: ObservationLoop?

    init(context: ProjectContext, object: PendingObjectID) {
        model = ObjectWindowModel(context: context, object: object)
        let window = SessionUndoWindow(
            contentRect: NSRect(x: 0, y: 0, width: 720, height: 520),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered, defer: true)
        window.sessionUndoManager = { [context] in context.editing.undoManager }
        window.minSize = NSSize(width: 320, height: 280)
        window.contentViewController = NSHostingController(rootView: ObjectWindowView(model: model))
        window.setContentSize(NSSize(width: 720, height: 520))
        window.tabbingMode = .disallowed
        super.init(window: window)
        window.delegate = self
        shouldCascadeWindows = true
        observation = ObservationLoop { [weak self] in self?.showTitle() }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("not in a nib") }

    /// The object the window shows, by the reference its commit gave it once it has one.
    var object: PendingObjectID { model.object }

    private func showTitle() {
        window?.title = model.title
        window?.subtitle = model.context.project.store?.fileName ?? ""
    }

    override func windowTitle(forDocumentDisplayName displayName: String) -> String { model.title }

    /// Staged edits have one undo stack, the session's (EDT-8), wherever they were made.
    func windowWillReturnUndoManager(_ window: NSWindow) -> UndoManager? {
        model.context.editing.undoManager
    }
}

/// A window whose undo stack is the session's. A window with SwiftUI content does not ask its delegate for one,
/// so the window says so itself.
private final class SessionUndoWindow: NSWindow {
    var sessionUndoManager: (() -> UndoManager?)?

    override var undoManager: UndoManager? { sessionUndoManager?() ?? super.undoManager }
}
