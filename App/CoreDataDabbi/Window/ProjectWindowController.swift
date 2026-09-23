import AppKit
import DabbiKit

/// A project's window: toolbar, the split-view tree, and the commands that are about the project as a whole.
final class ProjectWindowController: NSWindowController, NSWindowDelegate, NSToolbarDelegate, NSMenuItemValidation {
    let context: ProjectContext
    private let panes: ProjectSplitViewController
    private let capsule: StatusCapsuleView
    private var observation: ObservationLoop?

    init(context: ProjectContext) {
        self.context = context
        panes = ProjectSplitViewController(context: context)
        capsule = StatusCapsuleView()

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1320, height: 820),
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
            backing: .buffered, defer: true)
        window.minSize = NSSize(width: 860, height: 480)
        window.tabbingMode = .preferred
        window.tabbingIdentifier = "org.coredatadabbi.project"
        window.toolbarStyle = .unified
        window.titlebarSeparatorStyle = .automatic
        super.init(window: window)

        window.delegate = self
        window.contentViewController = panes
        // The rows are what a project window is for, so that is where the keyboard starts (§8.4).
        window.initialFirstResponder = panes.centre.browse.grid.tableView
        // The content view controller sizes the window to fit itself; the size asked for above is the one meant.
        if let frame = context.local.window.frame {
            window.setFrame(from: frame)
            shouldCascadeWindows = false
        } else {
            window.setContentSize(NSSize(width: 1320, height: 820))
            window.center()
        }

        let toolbar = NSToolbar(identifier: "org.coredatadabbi.project.toolbar")
        toolbar.delegate = self
        toolbar.displayMode = .iconOnly
        toolbar.allowsUserCustomization = false
        toolbar.centeredItemIdentifiers = [.statusCapsule]
        window.toolbar = toolbar

        capsule.onReload = { [weak self] in self?.reloadStore(nil) }
        observation = ObservationLoop { [weak self] in self?.showStatus() }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("not in a nib") }

    private func showStatus() {
        capsule.status = StoreStatus(context: context)
        // A saved predicate is named for what it shows; the entity is the predicate bar's to say (PRD-3).
        window?.subtitle =
            context.shownPredicate?.name ?? context.shownFetchRequest?.name ?? context.selectedEntity ?? ""
    }

    // MARK: Window state

    func windowDidMove(_ notification: Notification) { rememberFrame() }
    func windowDidEndLiveResize(_ notification: Notification) { rememberFrame() }

    private func rememberFrame() {
        guard let window, !window.styleMask.contains(.fullScreen) else { return }
        context.updateWindow { $0.frame = window.frameDescriptor }
    }

    // MARK: Commands

    @IBAction func reloadStore(_ sender: Any?) { context.openStore() }

    @IBAction func revealStore(_ sender: Any?) {
        guard let url = context.storeURL else { return }
        NSWorkspace.shared.activateFileViewerSelecting([url])
    }

    /// Points the project at another store file.
    @IBAction func chooseStore(_ sender: Any?) {
        guard let window else { return }
        let panel = NSOpenPanel()
        panel.message = String(localized: "Choose a Core Data or SwiftData store.")
        panel.prompt = String(localized: "Choose")
        panel.treatsFilePackagesAsDirectories = true
        panel.showsHiddenFiles = true
        panel.beginSheetModal(for: window) { [context] response in
            guard response == .OK, let url = panel.url else { return }
            context.chooseStore(at: url)
        }
    }

    @IBAction func toggleBottomPanel(_ sender: Any?) { panes.centre.toggle(Pane.bottom) }

    // MARK: Tracking (TRK-1, TRK-9)

    /// Play/Stop. The grid becomes a live log of what the watched app is writing, and stops being one again.
    @IBAction func toggleTracking(_ sender: Any?) { panes.centre.browse.toggleTracking() }

    @IBAction func pauseTracking(_ sender: Any?) {
        let tracking = context.tracking
        tracking.canPause ? tracking.pause() : tracking.resume()
    }

    /// Empties the log. With nothing left to read and nothing still arriving, it closes with what it held.
    @IBAction func clearTracking(_ sender: Any?) { context.tracking.clear() }

    /// Leaves the log for the rows, keeping the tracker running if it is.
    @IBAction func showRows(_ sender: Any?) { context.tracking.close() }

    @IBAction func goBack(_ sender: Any?) { context.goBack() }
    @IBAction func goForward(_ sender: Any?) { context.goForward() }

    /// Sends the keyboard to one of the panes, opening it first if it is shut (§8.4). The pane is named by the
    /// menu item's represented object, so that the five items are one command.
    @IBAction func focusPane(_ sender: Any?) {
        guard let name = (sender as? NSMenuItem)?.representedObject as? String else { return }
        focus(pane: name)
    }

    /// Sends the keyboard to the predicate bar, which is where a filter is written (§7.1, §8.3).
    @IBAction func focusFilter(_ sender: Any?) { focus(pane: Pane.filter) }

    /// Sends the keyboard to the quick filter at the end of the predicate bar (PRD-6).
    @IBAction func focusQuickFilter(_ sender: Any?) {
        guard panes.reveal(pane: Pane.filter) != nil else { return }
        panes.view.layoutSubtreeIfNeeded()
        panes.centre.browse.bar.focusQuickFilter()
    }

    /// Opens or closes the visual builder under the predicate field (M2-03).
    @IBAction func togglePredicateBuilder(_ sender: Any?) {
        panes.centre.browse.bar.toggleBuilder(sender)
    }

    /// Starts a predicate in the builder, on the entity's `name` or `title`, with the keyboard in its value
    /// (PRD-3). It is saved with "Save Predicate" once it shows what it should.
    @IBAction func newPredicate(_ sender: Any?) {
        _ = panes.reveal(pane: Pane.filter)
        panes.view.layoutSubtreeIfNeeded()
        panes.centre.browse.bar.startNewPredicate()
    }

    /// Keeps the rows on screen — the entity's filter, columns and sort — as a saved predicate, and puts its
    /// name into editing in the sidebar (PRD-3).
    @IBAction func savePredicate(_ sender: Any?) {
        guard let predicate = context.saveShownPredicate() else { return }
        _ = panes.reveal(pane: Pane.sidebar)
        panes.view.layoutSubtreeIfNeeded()
        panes.sidebar.beginRenaming(savedPredicate: predicate.id)
    }

    /// Returns what took the keyboard, for the tests.
    @discardableResult
    func focus(pane name: String) -> NSResponder? {
        guard let pane = panes.reveal(pane: name), let responder = pane.keyboardResponder else { return nil }
        // Laying out first: a pane that has just been opened has no size yet, and AppKit will not give the
        // keyboard to a view of nothing.
        panes.view.layoutSubtreeIfNeeded()
        return window?.makeFirstResponder(responder) == true ? responder : nil
    }

    /// Follows the related object the relationships panel has picked, from wherever the keyboard is (REL-3).
    @IBAction func revealInEntity(_ sender: Any?) {
        panes.centre.bottom.relationships.model.revealSelected()
    }

    func validateMenuItem(_ item: NSMenuItem) -> Bool {
        switch item.action {
        case #selector(reloadStore(_:)):
            return context.project.store != nil
        case #selector(revealStore(_:)):
            return context.storeURL != nil
        case #selector(toggleBottomPanel(_:)):
            let isCollapsed = panes.centre.item(for: Pane.bottom)?.isCollapsed ?? false
            item.title =
                isCollapsed ? String(localized: "Show Bottom Panel") : String(localized: "Hide Bottom Panel")
            return true
        case #selector(togglePredicateBuilder(_:)):
            item.title =
                panes.centre.browse.bar.model.isShowingBuilder
                ? String(localized: "Hide Predicate Builder") : String(localized: "Show Predicate Builder")
            return context.selectedEntity != nil
        case #selector(newPredicate(_:)):
            return context.selectedEntity != nil && context.model != nil
        case #selector(savePredicate(_:)):
            return context.canSavePredicate
        case #selector(focusQuickFilter(_:)):
            return context.shownQuickFilter?.isSearchable ?? false
        case #selector(focusFilter(_:)):
            // There is nothing to filter until an entity is on screen.
            return context.selectedEntity != nil
        case #selector(goBack(_:)):
            return context.navigation.canGoBack
        case #selector(goForward(_:)):
            return context.navigation.canGoForward
        case #selector(revealInEntity(_:)):
            return panes.centre.bottom.relationships.model.canReveal
        case #selector(toggleTracking(_:)):
            item.title =
                context.tracking.isRunning
                ? String(localized: "Stop Tracking") : String(localized: "Track Changes")
            // Something has to be watched, and a store has to be open to watch it in.
            return context.session != nil && context.selectedEntity != nil
        case #selector(pauseTracking(_:)):
            item.title =
                context.tracking.canResume
                ? String(localized: "Resume Tracking") : String(localized: "Pause Tracking")
            return context.tracking.canPause || context.tracking.canResume
        case #selector(clearTracking(_:)):
            return context.tracking.canClear
        case #selector(showRows(_:)):
            return context.tracking.isShowingLog
        default:
            return true
        }
    }

    // MARK: Toolbar

    func toolbarDefaultItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        [
            .toggleSidebar, .sidebarTrackingSeparator, .navigation, .flexibleSpace, .statusCapsule, .flexibleSpace,
            .inspectorTrackingSeparator, .tracking, .flexibleSpace, .toggleInspector,
        ]
    }

    func toolbarAllowedItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        toolbarDefaultItemIdentifiers(toolbar)
    }

    func toolbar(
        _ toolbar: NSToolbar, itemForItemIdentifier identifier: NSToolbarItem.Identifier,
        willBeInsertedIntoToolbar flag: Bool
    ) -> NSToolbarItem? {
        switch identifier {
        case .navigation:
            let group = NSToolbarItemGroup(
                itemIdentifier: identifier,
                images: [
                    NSImage(systemSymbolName: "chevron.left", accessibilityDescription: String(localized: "Back"))!,
                    NSImage(
                        systemSymbolName: "chevron.right", accessibilityDescription: String(localized: "Forward"))!,
                ],
                selectionMode: .momentary, labels: [String(localized: "Back"), String(localized: "Forward")],
                target: self, action: #selector(navigate(_:)))
            group.label = String(localized: "Back/Forward")
            group.isNavigational = true
            group.subitems[0].toolTip = String(localized: "Show the previous place")
            group.subitems[1].toolTip = String(localized: "Show the next place")
            group.autovalidates = false
            navigationGroup = group
            validateNavigation()
            return group
        case .statusCapsule:
            let item = NSToolbarItem(itemIdentifier: identifier)
            item.label = String(localized: "Store")
            item.view = capsule
            item.visibilityPriority = .high
            return item
        case .tracking:
            let item = NSToolbarItem(itemIdentifier: identifier)
            item.label = String(localized: "Track Changes")
            item.target = self
            item.action = #selector(toggleTracking(_:))
            item.autovalidates = false
            trackingItem = item
            showTracking()
            return item
        default:
            return nil
        }
    }

    private var navigationGroup: NSToolbarItemGroup?
    private var navigationObservation: ObservationLoop?
    private var trackingItem: NSToolbarItem?
    private var trackingObservation: ObservationLoop?

    /// Play while it is off, Stop while it is on — the one button TRK-1 asks for, saying which it is by its
    /// symbol, its label and its tooltip rather than by any of them alone (§8.4).
    private func showTracking() {
        trackingObservation = ObservationLoop { [weak self] in
            guard let self, let item = self.trackingItem else { return }
            let tracking = self.context.tracking
            let running = tracking.isRunning
            let symbol = running ? "stop.fill" : "play.fill"
            let title = running ? String(localized: "Stop Tracking") : String(localized: "Track Changes")
            item.image = NSImage(systemSymbolName: symbol, accessibilityDescription: title)
            item.label = title
            item.toolTip =
                running
                ? String(localized: "Stop logging what the app writes")
                : String(localized: "Log what the app writes to this store")
            item.isEnabled = self.context.session != nil && self.context.selectedEntity != nil
        }
    }

    @objc private func navigate(_ sender: NSToolbarItemGroup) {
        sender.selectedIndex == 0 ? goBack(sender) : goForward(sender)
    }

    private func validateNavigation() {
        navigationObservation = ObservationLoop { [weak self] in
            guard let self, let group = self.navigationGroup else { return }
            group.subitems[0].isEnabled = self.context.navigation.canGoBack
            group.subitems[1].isEnabled = self.context.navigation.canGoForward
        }
    }
}

extension NSToolbarItem.Identifier {
    static let navigation = NSToolbarItem.Identifier("org.coredatadabbi.navigation")
    static let statusCapsule = NSToolbarItem.Identifier("org.coredatadabbi.status")
    static let tracking = NSToolbarItem.Identifier("org.coredatadabbi.tracking")
}
