import AppKit
import DabbiKit

/// A split view whose divider positions and collapsed panes are the project's, not the app's (PRD §8.1: "all
/// panes collapsible; layout saved per project"). `autosaveName` would keep them in the user defaults, one
/// layout for every project.
class PersistentSplitViewController: NSSplitViewController {
    let context: ProjectContext
    /// The key of this split view in `WindowState.dividers`.
    let layoutIdentifier: String
    /// Pane identifiers by item, for `WindowState.collapsedPanes`. An item without one is never collapsed.
    private var paneIdentifiers: [ObjectIdentifier: String] = [:]
    private var hasRestored = false

    init(context: ProjectContext, layoutIdentifier: String) {
        self.context = context
        self.layoutIdentifier = layoutIdentifier
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("not in a nib") }

    func addPane(_ item: NSSplitViewItem, identifier: String? = nil) {
        if let identifier {
            paneIdentifiers[ObjectIdentifier(item)] = identifier
            item.canCollapse = true
        }
        addSplitViewItem(item)
    }

    func item(for identifier: String) -> NSSplitViewItem? {
        splitViewItems.first { paneIdentifiers[ObjectIdentifier($0)] == identifier }
    }

    func toggle(_ identifier: String) {
        guard let item = item(for: identifier) else { return }
        show(item, collapsed: !item.isCollapsed)
    }

    /// Opens a pane that is shut, so that asking for it by keyboard reaches it (§8.4).
    func show(_ identifier: String) {
        guard let item = item(for: identifier), item.isCollapsed else { return }
        show(item, collapsed: false)
    }

    private func show(_ item: NSSplitViewItem, collapsed: Bool) {
        // Reduce Motion means the pane is simply there or not: the slide is the thing being asked about (§8.4).
        if NSWorkspace.shared.accessibilityDisplayShouldReduceMotion {
            item.isCollapsed = collapsed
        } else {
            item.animator().isCollapsed = collapsed
        }
    }

    // MARK: Restoring and saving

    override func viewDidLayout() {
        super.viewDidLayout()
        // Positions mean nothing before the view has its size.
        guard !hasRestored, view.bounds.width > 0, view.bounds.height > 0 else { return }
        restore()
        hasRestored = true
    }

    private func restore() {
        let state = context.local.window
        // Positions first, while every pane is there to take one.
        if let positions = state.dividers[layoutIdentifier], positions.count == splitViewItems.count - 1 {
            for (index, position) in positions.enumerated() {
                splitView.setPosition(position, ofDividerAt: index)
            }
        }
        for item in splitViewItems {
            guard let identifier = paneIdentifiers[ObjectIdentifier(item)] else { continue }
            item.isCollapsed = state.collapsedPanes.contains(identifier)
        }
    }

    override func splitViewDidResizeSubviews(_ notification: Notification) {
        super.splitViewDidResizeSubviews(notification)
        guard hasRestored else { return }
        let collapsed = splitViewItems.filter(\.isCollapsed)
        let mine = Set(paneIdentifiers.values)
        let positions: [Double]? =
            collapsed.isEmpty
            ? splitViewItems.dropLast().map { item in
                let frame = item.viewController.view.frame
                return Double(splitView.isVertical ? frame.maxX : frame.maxY).rounded()
            } : nil
        context.updateWindow { state in
            state.collapsedPanes.subtract(mine)
            state.collapsedPanes.formUnion(collapsed.compactMap { paneIdentifiers[ObjectIdentifier($0)] })
            // With a pane collapsed the positions say nothing about where it was; the last full set is kept.
            if let positions { state.dividers[layoutIdentifier] = positions }
        }
    }
}
