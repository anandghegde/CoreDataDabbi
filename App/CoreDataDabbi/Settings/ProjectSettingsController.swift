import AppKit
import DabbiKit
import SwiftUI

/// Project Settings, as a sheet on the project's window (PRJ-12).
final class ProjectSettingsController: NSHostingController<ProjectSettingsView> {
    let context: ProjectContext

    init(context: ProjectContext) {
        self.context = context
        let actions = ProjectSettingsView.Actions()
        super.init(rootView: ProjectSettingsView(context: context, actions: actions))
        sizingOptions = [.preferredContentSize]
        title = String(localized: "Project Settings")
        actions.chooseStore = { [weak self] in self?.chooseStore() }
        actions.chooseModel = { [weak self] in self?.chooseModel() }
        actions.done = { [weak self] in self?.dismiss(nil) }
    }

    @available(*, unavailable)
    @MainActor required dynamic init?(coder: NSCoder) { fatalError("not in a nib") }

    private func chooseStore() {
        let panel = NSOpenPanel()
        panel.message = String(localized: "Choose a Core Data or SwiftData store.")
        panel.prompt = String(localized: "Choose")
        panel.treatsFilePackagesAsDirectories = true
        panel.showsHiddenFiles = true
        begin(panel) { [context] url in context.chooseStore(at: url) }
    }

    private func chooseModel() {
        let panel = NSOpenPanel()
        panel.message = String(localized: "Choose a model — a .mom, a .momd, or the app it is in.")
        panel.prompt = String(localized: "Choose")
        panel.canChooseDirectories = true
        // A .momd is a folder and an app is a package: either is the answer, not somewhere to look inside.
        panel.treatsFilePackagesAsDirectories = false
        begin(panel) { [context] url in context.chooseModel(at: url) }
    }

    private func begin(_ panel: NSOpenPanel, then choose: @escaping (URL) -> Void) {
        guard let window = view.window else { return }
        panel.beginSheetModal(for: window) { response in
            guard response == .OK, let url = panel.url else { return }
            choose(url)
        }
    }
}
