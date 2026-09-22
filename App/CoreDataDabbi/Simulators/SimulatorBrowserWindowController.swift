import AppKit
import DabbiKit
import SwiftUI

/// The window the simulator browser lives in (PRJ-8): one for the app, remembered where the user left it.
@MainActor
final class SimulatorBrowserWindowController: NSWindowController {
    static let shared = SimulatorBrowserWindowController(source: Simulators.index)

    let model: SimulatorBrowserModel

    init(source: any SimulatorBrowsing) {
        // The closure is set below: it needs the controller, to close the window once a store is on screen.
        model = SimulatorBrowserModel(source: source, open: { _ in })
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 860, height: 520),
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
            backing: .buffered, defer: false)
        window.title = String(localized: "Simulators")
        window.setFrameAutosaveName("SimulatorBrowser")
        window.isReleasedWhenClosed = false
        window.minSize = NSSize(width: 640, height: 360)
        super.init(window: window)
        window.delegate = self
        window.contentView = NSHostingView(rootView: SimulatorBrowserView(model: model))
        model.openStore = { [weak self] location in self?.open(location) }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("not in a nib") }

    /// One click on a store: a project for it, and the browser out of the way (PRJ-8).
    private func open(_ location: StoreLocation) {
        do {
            try DocumentController.current?.openProject(for: location)
            close()
        } catch {
            report(error)
        }
    }

    private func report(_ error: any Error) {
        guard let window else {
            _ = NSApp.presentError(error)
            return
        }
        NSApp.presentError(error, modalFor: window, delegate: nil, didPresent: nil, contextInfo: nil)
    }
}

extension SimulatorBrowserWindowController: NSWindowDelegate {
    /// A closed browser watches no containers: FSEvents on thirty device folders is not something to leave
    /// running behind a window nobody can see.
    func windowWillClose(_ notification: Notification) {
        model.stopWatching()
    }
}
