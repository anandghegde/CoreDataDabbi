import AppKit
import DabbiKit
import SwiftUI

/// The window the welcome screen lives in (PRJ-16): one for the app, and out of the way as soon as something
/// is open.
@MainActor
final class WelcomeWindowController: NSWindowController {
    static let shared = WelcomeWindowController()

    let model: WelcomeModel

    init(model: WelcomeModel = WelcomeModel()) {
        self.model = model
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 760, height: 460),
            styleMask: [.titled, .closable, .fullSizeContentView], backing: .buffered, defer: false)
        window.title = String(localized: "Welcome to CoreDataDabbi")
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        window.isMovableByWindowBackground = true
        window.isReleasedWhenClosed = false
        // Not restored: the welcome window is shown when there is nothing to show, not because it was open.
        window.isRestorable = false
        super.init(window: window)
        window.contentView = NSHostingView(rootView: WelcomeView(model: model))
        window.center()
        model.actions = WelcomeModel.Actions(
            open: { [weak self] url in self?.open(url) },
            openDatabase: { [weak self] in self?.run(#selector(DocumentController.openDatabase(_:))) },
            openProject: { [weak self] in self?.run(#selector(NSDocumentController.openDocument(_:))) },
            browseSimulators: { [weak self] in self?.run(#selector(DocumentController.browseSimulators(_:))) })
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("not in a nib") }

    // MARK: Showing

    /// Shown when the app has nothing else to show and the user has not said to stop (PRJ-16).
    static func showIfWanted() {
        guard shared.model.showsAtLaunch, DocumentController.current?.documents.isEmpty != false else { return }
        show()
    }

    static func show() {
        shared.model.refresh()
        shared.showWindow(nil)
        shared.window?.makeKeyAndOrderFront(nil)
    }

    /// Something is open now: the welcome window has said what it had to say.
    static func closeIfOpen() {
        guard shared.isWindowLoaded, shared.window?.isVisible == true else { return }
        shared.close()
    }

    // MARK: What it asks the app for

    private func open(_ url: URL) {
        DocumentController.current?.openDocument(withContentsOf: url, display: true) { [weak self] document, _, error in
            if let error {
                self?.report(error)
            } else if document != nil {
                self?.close()
            }
        }
    }

    /// Hands the menu action to the responder chain, which is where the panels those items open belong. The
    /// welcome window stays until something is actually open.
    private func run(_ selector: Selector) {
        NSApp.sendAction(selector, to: nil, from: self)
    }

    private func report(_ error: any Error) {
        guard let window, window.isVisible else {
            _ = NSApp.presentError(error)
            return
        }
        NSApp.presentError(error, modalFor: window, delegate: nil, didPresent: nil, contextInfo: nil)
    }
}
