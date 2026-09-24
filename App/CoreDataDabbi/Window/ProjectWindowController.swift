import AppKit
import DabbiKit

/// A project's window: toolbar, the split-view tree, and the commands that are about the project as a whole.
final class ProjectWindowController: NSWindowController, NSWindowDelegate, NSToolbarDelegate, NSMenuItemValidation {
    let context: ProjectContext
    private let panes: ProjectSplitViewController
    private let capsule: StatusCapsuleView
    private var observation: ObservationLoop?
    /// The store went missing before the window was on screen: Project Settings waits for it (PRJ-12).
    private var settingsPending = false

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
        context.onStoreLost = { [weak self] in
            self?.settingsPending = true
            self?.showPendingSettings()
        }
        context.onEditingRefused = { [weak self] error in self?.explainRefusal(error) }
        context.onLeavingChanges = { [weak self] decide in
            guard let self else { return decide(.cancel) }
            self.askAboutChanges(decide)
        }
        context.editing.onError = { [weak self] error in self?.explainEditError(error) }
        context.snapshots.onError = { [weak self] error in self?.explainEditError(error) }
        context.onStoreInUse = { [weak self] holders, canQuit, decide in
            guard let self else { return decide(false) }
            self.askToQuit(holders, canQuit: canQuit, decide)
        }
        observation = ObservationLoop { [weak self] in self?.showStatus() }
        changesObservation = ObservationLoop { [weak self] in self?.revealFirstChange() }
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

    /// Store edits have an undo stack of their own, which the session keeps (EDT-8); the document has none.
    func windowWillReturnUndoManager(_ window: NSWindow) -> UndoManager? {
        context.editing.undoManager
    }

    func windowDidMove(_ notification: Notification) { rememberFrame() }

    /// Coming back to the window is when a store that moved or went away is noticed (PRJ-12): the simulator was
    /// erased, the app reinstalled, the file thrown away while the user was elsewhere.
    func windowDidBecomeKey(_ notification: Notification) {
        showPendingSettings()
        context.checkReachability()
    }
    func windowDidEndLiveResize(_ notification: Notification) { rememberFrame() }

    /// A delete still waiting on its question when the window goes would hold up every edit after it, for good:
    /// closing answers No.
    func windowWillClose(_ notification: Notification) {
        if let question = deleteQuestion { window?.endSheet(question, returnCode: .cancel) }
    }

    private func rememberFrame() {
        guard let window, !window.styleMask.contains(.fullScreen) else { return }
        context.updateWindow { $0.frame = window.frameDescriptor }
    }

    // MARK: Commands

    @IBAction func reloadStore(_ sender: Any?) { context.reloadStore() }

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

    /// The store, the model and the time zone; and, when the store is lost, what was found and where it may be.
    @IBAction func showProjectSettings(_ sender: Any?) {
        settingsPending = false
        guard let window, window.attachedSheet == nil, let content = window.contentViewController else { return }
        content.presentAsSheet(ProjectSettingsController(context: context))
    }

    private func showPendingSettings() {
        guard settingsPending, let window, window.isVisible else { return }
        showProjectSettings(nil)
    }

    @IBAction func toggleBottomPanel(_ sender: Any?) { panes.centre.toggle(Pane.bottom) }

    // MARK: Staged edits (EDT-8)

    private var changesObservation: ObservationLoop?
    private var hadChanges = false

    /// Writes what is staged to the store, after the session's backup (EDT-9).
    @IBAction func commitChanges(_ sender: Any?) { context.editing.commit() }

    /// Throws away what is staged, after asking: it cannot be undone.
    @IBAction func discardChanges(_ sender: Any?) {
        guard let window, context.editing.hasChanges else { return }
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = String(localized: "Discard all pending changes?")
        alert.informativeText = String(localized: "The store stays as it is. This cannot be undone.")
        alert.addButton(withTitle: String(localized: "Discard"))
        alert.addButton(withTitle: String(localized: "Cancel"))
        alert.buttons[0].hasDestructiveAction = true
        alert.beginSheetModal(for: window) { [context] response in
            guard response == .alertFirstButtonReturn else { return }
            context.editing.discard()
        }
    }

    /// Stages the deletion of the rows selected in the grid. When the model's delete rules reach further than the
    /// rows, the window says how, and asks first (EDT-2).
    @IBAction func deleteObjects(_ sender: Any?) {
        let objects = panes.centre.browse.grid.selectedObjects.map(PendingObjectID.init)
        context.editing.delete(objects) { [weak self] preview in
            await self?.confirmDelete(preview) ?? false
        }
    }

    /// What the delete rules would do besides deleting the rows, and whether to go ahead.
    private func confirmDelete(_ preview: DeletePreview) async -> Bool {
        guard let window else { return false }
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText =
            preview.issues.isEmpty
            ? String(localized: "The delete reaches beyond the selected rows")
            : String(localized: "The commit would refuse this delete")
        alert.informativeText = Self.describe(preview)
        alert.addButton(withTitle: String(localized: "Delete"))
        alert.addButton(withTitle: String(localized: "Cancel"))
        alert.buttons[0].hasDestructiveAction = true
        guard window.attachedSheet == nil else { return alert.runModal() == .alertFirstButtonReturn }
        return await withCheckedContinuation { continuation in
            deleteQuestion = alert.window
            alert.beginSheetModal(for: window) { [weak self] response in
                self?.deleteQuestion = nil
                continuation.resume(returning: response == .alertFirstButtonReturn)
            }
        }
    }

    /// The delete confirmation on screen, while there is one.
    private var deleteQuestion: NSWindow?

    /// One line per consequence: what goes with the rows, what is left pointing at nothing, what is unlinked,
    /// and what the commit would refuse.
    static func describe(_ preview: DeletePreview) -> String {
        func list(_ groups: [DeletePreview.Group]) -> String {
            ListFormatter.localizedString(byJoining: groups.map { String(localized: "\($0.entity) (\($0.count))") })
        }
        var lines: [String] = []
        if !preview.cascaded.isEmpty {
            lines.append(String(localized: "Also deleted, by Cascade rules: \(list(preview.cascaded))"))
        }
        if !preview.dangling.isEmpty {
            let dangling = list(preview.dangling)
            lines.append(String(localized: "Left pointing at a deleted object, with no rule to unlink it: \(dangling)"))
        }
        if !preview.nullified.isEmpty {
            lines.append(String(localized: "Unlinked, by Nullify rules: \(list(preview.nullified))"))
        }
        if !preview.issues.isEmpty {
            lines.append(String(localized: "The commit would be refused until these are resolved."))
            // The engine's sentences, as an error's diagnosis is shown: object, property and rule.
            lines += preview.issues.prefix(Self.issuesListed).map(\.description)
            if preview.issues.count > Self.issuesListed {
                lines.append(String(localized: "…and \(preview.issues.count - Self.issuesListed) more"))
            }
        }
        lines.append(String(localized: "The delete can be undone until it is committed."))
        return lines.joined(separator: "\n")
    }

    private static let issuesListed = 5

    @IBAction func togglePendingChanges(_ sender: Any?) {
        let bottom = panes.centre.bottom
        if panes.centre.item(for: Pane.bottom)?.isCollapsed == true
            || bottom.item(for: Pane.changes)?.isCollapsed == true
        {
            _ = panes.reveal(pane: Pane.changes)
        } else {
            bottom.toggle(Pane.changes)
        }
    }

    /// The first edit opens the panel it is listed in, so that staging something is never invisible. After
    /// that the panel is where the user leaves it.
    private func revealFirstChange() {
        let hasChanges = context.editing.hasChanges
        defer { hadChanges = hasChanges }
        guard hasChanges, !hadChanges, window?.isVisible == true else { return }
        _ = panes.reveal(pane: Pane.changes)
    }

    /// Asked before something that would lose staged edits: Commit, Discard or Cancel.
    private func askAboutChanges(_ decide: @escaping @MainActor (LeavingChanges) -> Void) {
        guard let window, window.attachedSheet == nil else { return decide(.cancel) }
        let count = context.editing.changes.changes.count
        let alert = NSAlert()
        alert.messageText = String(localized: "Commit the pending changes first?")
        alert.informativeText = String(
            localized:
                "\(count) objects have changes that are not in the store yet. Discarded changes cannot be recovered.")
        alert.addButton(withTitle: String(localized: "Commit"))
        alert.addButton(withTitle: String(localized: "Discard"))
        alert.addButton(withTitle: String(localized: "Cancel"))
        alert.buttons[1].hasDestructiveAction = true
        alert.beginSheetModal(for: window) { response in
            switch response {
            case .alertFirstButtonReturn: decide(.commit)
            case .alertSecondButtonReturn: decide(.discard)
            default: decide(.cancel)
            }
        }
    }

    /// An edit was refused, or a commit: nothing was staged or written by it, and what was staged still is.
    private func explainEditError(_ error: DabbiError) {
        guard let window else { return }
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = error.message
        alert.informativeText = (error.diagnosis + error.recovery).joined(separator: "\n")
        if window.attachedSheet == nil {
            alert.beginSheetModal(for: window)
        } else {
            alert.runModal()
        }
    }

    // MARK: Snapshots (§7.3)

    /// Asks for a name and a note, and copies the store as it is on disk.
    @IBAction func takeSnapshot(_ sender: Any?) {
        guard context.snapshots.canTake, let window, window.attachedSheet == nil,
            let content = window.contentViewController
        else { return }
        let model = SnapshotSheet.Model(
            title: String(localized: "Take a Snapshot"), confirmTitle: String(localized: "Take Snapshot"),
            name: SnapshotsSession.defaultName(at: .now), note: "", editsName: true)
        let sheet = SnapshotSheetController(model)
        model.onFinish = { [weak self, weak sheet] answer in
            if let sheet { content.dismiss(sheet) }
            guard let self, let (name, note) = answer else { return }
            self.context.takeSnapshot(name: name, note: note)
            _ = self.panes.reveal(pane: Pane.sidebar)
        }
        content.presentAsSheet(sheet)
    }

    /// The snapshot a sidebar menu item stands for.
    private func snapshot(for sender: Any?) -> SnapshotManifest? {
        ((sender as? NSMenuItem)?.representedObject as? UUID).flatMap(context.snapshots.snapshot(_:))
    }

    /// Puts a snapshot back in place of the store, after saying what that does.
    @IBAction func restoreSnapshot(_ sender: Any?) {
        guard let snapshot = snapshot(for: sender), context.canRestore, let window, window.attachedSheet == nil
        else { return }
        let alert = NSAlert()
        alert.messageText = String(localized: "Restore “\(snapshot.name)”?")
        alert.informativeText = String(
            localized:
                "The store is replaced by the snapshot taken \(snapshot.createdAt.formatted(date: .abbreviated, time: .shortened)). A backup of the store as it is now is taken first, and listed with the snapshots."
        )
        alert.addButton(withTitle: String(localized: "Restore"))
        alert.addButton(withTitle: String(localized: "Cancel"))
        alert.buttons[0].hasDestructiveAction = true
        alert.beginSheetModal(for: window) { [context] response in
            guard response == .alertFirstButtonReturn else { return }
            context.restore(snapshot)
        }
    }

    @IBAction func editSnapshotNote(_ sender: Any?) {
        guard let snapshot = snapshot(for: sender), let window, window.attachedSheet == nil,
            let content = window.contentViewController
        else { return }
        let model = SnapshotSheet.Model(
            title: String(localized: "Edit Note"), confirmTitle: String(localized: "Save"),
            name: snapshot.name, note: snapshot.note, editsName: false)
        let sheet = SnapshotSheetController(model)
        model.onFinish = { [weak self, weak sheet] answer in
            if let sheet { content.dismiss(sheet) }
            guard let (_, note) = answer else { return }
            self?.context.snapshots.setNote(note, of: snapshot.id)
        }
        content.presentAsSheet(sheet)
    }

    @IBAction func deleteSnapshot(_ sender: Any?) {
        guard let snapshot = snapshot(for: sender), let window, window.attachedSheet == nil else { return }
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = String(localized: "Delete “\(snapshot.name)”?")
        alert.informativeText = String(localized: "The copy of the store is thrown away. This cannot be undone.")
        alert.addButton(withTitle: String(localized: "Delete"))
        alert.addButton(withTitle: String(localized: "Cancel"))
        alert.buttons[0].hasDestructiveAction = true
        alert.beginSheetModal(for: window) { [context] response in
            guard response == .alertFirstButtonReturn else { return }
            context.snapshots.delete(snapshot.id)
        }
    }

    /// Other processes have the store open: name them, and offer to quit them when there is a way to.
    private func askToQuit(_ holders: [LiveProcess], canQuit: Bool, _ decide: @escaping @MainActor (Bool) -> Void) {
        guard let window, window.attachedSheet == nil else { return decide(false) }
        let names = holders.map(\.name).joined(separator: ", ")
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = String(localized: "The store is open in \(names)")
        alert.informativeText =
            canQuit
            ? String(
                localized: "A snapshot cannot be restored while another app has the store open. Quit it, then restore?")
            : String(
                localized:
                    "A snapshot cannot be restored while another process has the store open. Quit it, then try again.")
        if canQuit {
            alert.addButton(withTitle: String(localized: "Quit and Restore"))
            alert.addButton(withTitle: String(localized: "Cancel"))
            alert.buttons[0].hasDestructiveAction = true
        } else {
            alert.addButton(withTitle: String(localized: "OK"))
        }
        alert.beginSheetModal(for: window) { response in
            decide(canQuit && response == .alertFirstButtonReturn)
        }
    }

    // MARK: Access mode (EDT-1)

    /// The lock: read-only ↔ editable. The store is reopened the other way, keeping the place.
    @IBAction func toggleAccessMode(_ sender: Any?) { context.toggleAccessMode() }

    /// The store could not be opened for editing; it is open read-only again.
    private func explainRefusal(_ error: DabbiError) {
        guard let window else { return }
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = String(localized: "This store cannot be edited")
        alert.informativeText = (error.diagnosis + error.recovery).joined(separator: "\n")
        alert.beginSheetModal(for: window)
    }

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
        case #selector(commitChanges(_:)):
            return context.editing.canCommit
        case #selector(discardChanges(_:)):
            return context.editing.hasChanges && !context.editing.isCommitting
        case #selector(deleteObjects(_:)):
            // Only from the grid: elsewhere ⌘⌫ is the text field's, deleting to the start of the line.
            return context.editing.isEditable && window?.firstResponder === panes.centre.browse.grid.tableView
                && !context.tracking.isShowingLog && !panes.centre.browse.grid.selectedObjects.isEmpty
        case #selector(togglePendingChanges(_:)):
            let shown =
                panes.centre.item(for: Pane.bottom)?.isCollapsed == false
                && panes.centre.bottom.item(for: Pane.changes)?.isCollapsed == false
            item.title = shown ? String(localized: "Hide Pending Changes") : String(localized: "Show Pending Changes")
            return true
        case #selector(revealStore(_:)):
            return context.storeURL != nil
        case #selector(takeSnapshot(_:)):
            return context.snapshots.canTake
        case #selector(restoreSnapshot(_:)):
            return context.canRestore
        case #selector(editSnapshotNote(_:)), #selector(deleteSnapshot(_:)):
            return !context.snapshots.isBusy
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
        case #selector(toggleAccessMode(_:)):
            item.title = Self.accessTitle(for: context.accessMode)
            return context.canChangeAccessMode
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
            .inspectorTrackingSeparator, .accessMode, .tracking, .flexibleSpace, .toggleInspector,
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
        case .accessMode:
            let item = NSToolbarItem(itemIdentifier: identifier)
            item.target = self
            item.action = #selector(toggleAccessMode(_:))
            item.autovalidates = false
            accessItem = item
            showAccessMode()
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
    private var accessItem: NSToolbarItem?
    private var accessObservation: ObservationLoop?
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

    /// What the lock does next, as a menu item or a button title says it.
    static func accessTitle(for mode: AccessMode?) -> String {
        mode == .editable ? String(localized: "Lock Store") : String(localized: "Allow Editing")
    }

    /// A closed padlock while the store is read-only, an open one while it is editable — the symbol says what
    /// the store is, the label and tooltip what a click does (§8.4).
    private func showAccessMode() {
        accessObservation = ObservationLoop { [weak self] in
            guard let self, let item = self.accessItem else { return }
            let mode = self.context.accessMode
            let editable = mode == .editable
            let title = Self.accessTitle(for: mode)
            item.image = NSImage(
                systemSymbolName: editable ? "lock.open.fill" : "lock.fill",
                accessibilityDescription: editable ? String(localized: "Editable") : String(localized: "Read-only"))
            item.label = title
            item.toolTip =
                editable
                ? String(localized: "The store is editable. Click to make it read-only.")
                : String(localized: "The store is read-only. Click to allow editing.")
            item.isEnabled = self.context.canChangeAccessMode
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
    static let accessMode = NSToolbarItem.Identifier("org.coredatadabbi.accessMode")
}
