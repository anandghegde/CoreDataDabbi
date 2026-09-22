import AppKit
import DabbiKit

@main
final class AppDelegate: NSObject, NSApplicationDelegate {
    /// There is no main nib: the menu is built in code (`MainMenu`) and every window belongs to a document.
    static func main() {
        let application = NSApplication.shared
        let delegate = AppDelegate()
        application.delegate = delegate
        application.run()
    }

    func applicationWillFinishLaunching(_ notification: Notification) {
        // The first document controller that is made becomes the shared one, so ours has to be the first.
        _ = DocumentController()
        NSApp.mainMenu = MainMenu.make()

        // Before window restoration opens anything: a copy that is still here belongs to a run that crashed or
        // was force-quit (§6.2).
        if !AppEnvironment.isRunningTests { StoreOpener().removeStaleWorkingCopies() }
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        // After restoration has had its say: a window that came back is something to show, and beats a welcome.
        guard !AppEnvironment.isRunningTests else { return }
        WelcomeWindowController.showIfWanted()
    }

    /// A project without a store is not a useful thing to start with.
    func applicationShouldOpenUntitledFile(_ sender: NSApplication) -> Bool { false }

    /// Clicking the Dock icon with every window closed: the welcome window is the way back in (PRJ-16).
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows: Bool) -> Bool {
        if !hasVisibleWindows { WelcomeWindowController.show() }
        return true
    }

    func applicationSupportsSecureRestorableState(_ app: NSApplication) -> Bool { true }
}
