import AppKit
import DabbiKit
import SwiftUI

/// The centre of the window: the grid when the store is open, the change log while tracking is on, and the
/// reason why not when there is no store (TRK-1).
final class BrowseViewController: NSViewController {
    let context: ProjectContext
    let grid: GridViewController
    /// The change log. It takes the grid's place rather than sharing its table: see `TrackingViewController`.
    let tracking: TrackingViewController
    /// The predicate bar above the grid (§7.1). Always there while a store is open; what it filters is the
    /// entity the grid shows.
    let bar: PredicateBarViewController
    /// The way here through relationships, when there was one (REL-3). It sizes itself, and takes no room at
    /// all until something has been followed.
    private(set) var breadcrumb: NSHostingView<BreadcrumbView>!
    private var stateView: NSView?
    private var observation: ObservationLoop?

    init(context: ProjectContext) {
        self.context = context
        grid = GridViewController(context: context)
        tracking = TrackingViewController(context: context, session: context.tracking)
        bar = PredicateBarViewController(context: context)
        super.init(nibName: nil, bundle: nil)
        // Escape in a field that says what the grid shows means "back to the rows".
        bar.onDone = { [weak self] in
            guard let self, let table = self.grid.keyboardResponder else { return }
            self.view.window?.makeFirstResponder(table)
        }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("not in a nib") }

    override func loadView() {
        view = NSView()
        addChild(bar)
        addChild(grid)
        addChild(tracking)

        breadcrumb = NSHostingView(rootView: BreadcrumbView(context: context))
        breadcrumb.sizingOptions = [.intrinsicContentSize]
        breadcrumb.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(breadcrumb)

        bar.view.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(bar.view)

        grid.view.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(grid.view)
        tracking.view.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(tracking.view)
        NSLayoutConstraint.activate([
            breadcrumb.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            breadcrumb.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            breadcrumb.topAnchor.constraint(equalTo: view.topAnchor),
            bar.view.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            bar.view.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            bar.view.topAnchor.constraint(equalTo: breadcrumb.bottomAnchor),
            grid.view.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            grid.view.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            grid.view.topAnchor.constraint(equalTo: bar.view.bottomAnchor),
            grid.view.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            tracking.view.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            tracking.view.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            tracking.view.topAnchor.constraint(equalTo: bar.view.bottomAnchor),
            tracking.view.bottomAnchor.constraint(equalTo: view.bottomAnchor),
        ])

        let state = NSHostingView(
            rootView: StoreStateView(
                context: context,
                chooseStore: { [weak self] in
                    NSApp.sendAction(#selector(ProjectWindowController.chooseStore(_:)), to: nil, from: self)
                },
                browseSimulators: { [weak self] in
                    NSApp.sendAction(#selector(DocumentController.browseSimulators(_:)), to: nil, from: self)
                }))
        embed(state)
        stateView = state

        observation = ObservationLoop { [weak self] in
            guard let self else { return }
            let isOpen = self.context.openedStore != nil
            let isLogging = self.context.tracking.isShowingLog
            self.stateView?.isHidden = isOpen
            self.grid.view.isHidden = !isOpen || isLogging
            self.tracking.view.isHidden = !isOpen || !isLogging
            // The filter still says what the log is scoped by, so it stays up beside it (TRK-7).
            self.bar.view.isHidden = !isOpen
            self.breadcrumb.isHidden = !isOpen
            self.followSelection()
        }
    }

    // MARK: Tracking (TRK-1)

    /// Whichever of the two is showing — what "the rows" means to the keyboard and to a reveal (§8.4).
    var rowsPane: KeyboardPane { context.tracking.isShowingLog ? tracking : grid }

    /// Play/Stop: starts tracking the entity on screen, or stops the tracker and leaves the log to be read.
    func toggleTracking() {
        if context.tracking.isRunning {
            context.tracking.stop()
        } else {
            startTracking()
        }
    }

    /// Starts, or re-scopes, tracking on the entity the window is showing, through the filter it is showing it
    /// through — the quick filter's search included (TRK-7, PRD-6).
    private func startTracking() {
        guard let store = context.session, let entity = context.selectedEntity else { return }
        context.tracking.start(
            on: store, entity: entity, filter: context.shownFetchFilter,
            // Handed over *after* the tracker has started, which is when it will keep them: the rows the user
            // is already looking at are the ones whose first change must read as before -> after (TRK-2).
            alreadyRead: { [weak self] in self?.grid.rows?.loadedPages() ?? [] })
    }

    /// The log is a live view of one entity through one filter, as the grid is: when either changes the log
    /// follows, and when it is no longer live there is nothing for it to follow, so the rows come back.
    private func followSelection() {
        let session = context.tracking
        guard session.isShowingLog else { return }
        guard let entity = context.selectedEntity else {
            session.close()
            return
        }
        let filter = context.shownFetchFilter
        guard entity != session.entity || filter != session.filter else { return }
        if session.isRunning {
            startTracking()
        } else {
            session.close()
        }
    }

    private func embed(_ subview: NSView) {
        subview.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(subview)
        NSLayoutConstraint.activate([
            subview.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            subview.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            subview.topAnchor.constraint(equalTo: view.topAnchor),
            subview.bottomAnchor.constraint(equalTo: view.bottomAnchor),
        ])
    }
}
