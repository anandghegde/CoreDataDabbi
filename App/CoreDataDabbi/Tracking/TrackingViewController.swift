import AppKit
import DabbiKit

/// The change log (PRD §8.3, TRK-1, TRK-2, TRK-9).
///
/// A second `NSTableView` that takes the grid's place in the centre of the window while tracking is on. §8 sketched
/// one table with two data sources; two tables turned out simpler and less risky — the grid's columns are a pager's
/// `ColumnSet` and its rows are positions in a fetch, while the log's rows are objects with versions folded under
/// them and its columns are the log's two plus the entity's. Nothing about the grid had to be made conditional, and
/// what the user was looking at is still there, unchanged, when tracking stops.
@MainActor
final class TrackingViewController: NSViewController, NSTableViewDataSource, NSTableViewDelegate {
    let context: ProjectContext
    let session: TrackingSession

    let tableView = NSTableView()
    private let scrollView = NSScrollView()
    private let footer = TrackingFooterView()

    private(set) var columns: [TrackingColumn] = []
    /// What the columns were built for, so that a batch does not rebuild them.
    private var shownEntity: String?
    private var shownLayout: EntityLayout?
    private var shownRevision = -1
    private var loop: ObservationLoop?
    /// Set while the log writes to the table or the context, to keep a change from coming straight back.
    private var isUpdating = false

    init(context: ProjectContext, session: TrackingSession) {
        self.context = context
        self.session = session
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("not in a nib") }

    // MARK: The view

    override func loadView() {
        view = NSView()

        tableView.dataSource = self
        tableView.delegate = self
        tableView.style = .fullWidth
        // The wash behind a row says what happened to it; alternating backgrounds would fight it.
        tableView.usesAlternatingRowBackgroundColors = false
        tableView.gridStyleMask = [.solidVerticalGridLineMask]
        // The log's own two columns anchor it, so the order is the log's and only the widths are the user's.
        tableView.allowsColumnReordering = false
        tableView.allowsColumnResizing = true
        tableView.allowsMultipleSelection = true
        tableView.allowsColumnSelection = false
        tableView.columnAutoresizingStyle = .noColumnAutoresizing
        tableView.usesAutomaticRowHeights = false
        tableView.rowHeight = 20
        tableView.intercellSpacing = NSSize(width: 6, height: 2)
        tableView.setAccessibilityLabel(String(localized: "Change log", comment: "The tracking table"))

        scrollView.documentView = tableView
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.translatesAutoresizingMaskIntoConstraints = false

        footer.translatesAutoresizingMaskIntoConstraints = false
        footer.onShowRows = { [weak self] in self?.session.close() }

        view.addSubview(scrollView)
        view.addSubview(footer)
        NSLayoutConstraint.activate([
            scrollView.topAnchor.constraint(equalTo: view.topAnchor),
            scrollView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            scrollView.bottomAnchor.constraint(equalTo: footer.topAnchor),
            footer.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            footer.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            footer.bottomAnchor.constraint(equalTo: view.bottomAnchor),
        ])
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        loop = ObservationLoop { [weak self] in self?.observe() }
    }

    // MARK: Following the session

    private func observe() {
        let entity = session.entity
        // Tracking follows the grid, so the log is seen through what the grid is: a saved predicate's columns
        // when it shows one (BRW-3).
        let layout = entity.map { entity in
            context.navigation.current.flatMap { $0.entity == entity ? context.layout(at: $0) : nil }
                ?? context.layout(of: entity)
        }
        let revision = session.revision
        // Reading these here means a change to any of them redraws the log.
        _ = context.timeZone
        let state = session.state

        if entity != shownEntity || layout != shownLayout {
            shownEntity = entity
            shownLayout = layout
            rebuildColumns()
            reload()
        } else if revision != shownRevision {
            reload()
        }
        shownRevision = revision

        footer.show(
            TrackingFooterView.Summary(
                state: state,
                entity: entity,
                counts: session.log.counts,
                limitations: session.limitations,
                droppedObjects: session.log.droppedObjects,
                latency: session.lastLatency,
                storeWasReplaced: session.storeWasReplaced))
    }

    /// Redraws the whole log. It holds thousands of lines at most — bounded by `TrackingLog.objectLimit` — so a
    /// reload costs less than working out which lines moved when everything above the newest one shifts down.
    private func reload() {
        let selected = tableView.selectedRow >= 0 ? session.log.object(at: tableView.selectedRow) : nil
        let wasAtTop = isScrolledToTop
        isUpdating = true
        tableView.reloadData()
        if let selected, let line = session.log.line(of: selected) {
            tableView.selectRowIndexes([line], byExtendingSelection: false)
        }
        isUpdating = false
        // Newest first means the newest row is the top one; a log that has been scrolled stays where it was, and
        // one that has not follows what is happening (TRK-1).
        if wasAtTop { tableView.scrollRowToVisible(0) }
    }

    private var isScrolledToTop: Bool {
        scrollView.contentView.bounds.origin.y <= tableView.rowHeight
    }

    // MARK: Columns

    private func rebuildColumns() {
        guard let entity = shownEntity, let model = context.model,
            let description = model.entity(named: entity)
        else {
            columns = []
            rebuildTableColumns()
            return
        }
        columns = TrackingColumn.columns(
            for: description, in: model, layout: shownLayout ?? EntityLayout())
        rebuildTableColumns()
    }

    private func rebuildTableColumns() {
        isUpdating = true
        defer { isUpdating = false }
        for column in tableView.tableColumns { tableView.removeTableColumn(column) }
        for column in columns.visible {
            let tableColumn = NSTableColumn(identifier: NSUserInterfaceItemIdentifier(column.property))
            tableColumn.title = column.title
            tableColumn.width = column.width
            tableColumn.minWidth = 40
            tableColumn.maxWidth = 1200
            tableColumn.headerToolTip = column.typeName
            tableView.addTableColumn(tableColumn)
        }
    }

    private func column(for tableColumn: NSTableColumn) -> TrackingColumn? {
        columns.first { $0.property == tableColumn.identifier.rawValue }
    }

    /// A width set here is the same column's width in the grid: it is the same column.
    func tableViewColumnDidResize(_ notification: Notification) {
        guard !isUpdating, let entity = shownEntity, entity == context.selectedEntity,
            let tableColumn = notification.userInfo?["NSTableColumn"] as? NSTableColumn,
            let index = columns.firstIndex(where: { $0.property == tableColumn.identifier.rawValue }),
            case .grid(var grid) = columns[index]
        else { return }
        grid.width = tableColumn.width
        columns[index] = .grid(grid)
        let saved = columns.compactMap { column -> GridColumn? in
            guard case .grid(let grid) = column else { return nil }
            return grid
        }
        shownLayout?.columns = GridColumn.layout(of: saved)
        context.updateShownLayout { $0.columns = GridColumn.layout(of: saved) }
    }

    // MARK: Rows

    func numberOfRows(in tableView: NSTableView) -> Int {
        session.log.lineCount
    }

    func tableView(_ tableView: NSTableView, rowViewForRow row: Int) -> NSTableRowView? {
        let view =
            tableView.makeView(withIdentifier: .trackingRow, owner: self) as? TrackingRowView
            ?? {
                let view = TrackingRowView()
                view.identifier = .trackingRow
                return view
            }()
        view.kind = session.log.badge(at: row)?.kind
        return view
    }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        guard let tableColumn, let column = column(for: tableColumn) else { return nil }
        if case .change = column {
            let cell =
                tableView.makeView(withIdentifier: .trackingBadgeCell, owner: self) as? TrackingBadgeCellView
                ?? TrackingBadgeCellView()
            guard let badge = session.log.badge(at: row) else { return cell }
            cell.show(badge)
            cell.onFold = { [weak self] in self?.toggleFold(at: row) }
            return cell
        }
        let cell =
            tableView.makeView(withIdentifier: .trackingValueCell, owner: self) as? TrackingValueCellView
            ?? TrackingValueCellView()
        let value = session.log.cell(at: row, column: column, timeZone: context.timeZone)
        cell.show(value ?? TrackingCell(value: .notLoaded), trailing: column.isTrailing, column: column.title)
        return cell
    }

    private func toggleFold(at row: Int) {
        guard let line = session.log.line(at: row) else { return }
        // The redraw comes back through the observation, as a batch's does.
        session.toggleFold(ofEntryAt: line.entry)
    }

    // MARK: Selection

    func tableViewSelectionDidChange(_ notification: Notification) {
        guard !isUpdating else { return }
        // The inspector and the content viewer follow the log's selection, as they follow the grid's. The row
        // may be one the store no longer has; the inspector says so rather than the log pretending otherwise.
        context.focus(on: session.log.object(at: tableView.selectedRow))
    }

    /// Escape leaves the log for the rows, as it leaves the predicate bar for them (§8.4).
    override func cancelOperation(_ sender: Any?) {
        session.close()
    }
}

extension TrackingViewController: KeyboardPane {
    var keyboardResponder: NSResponder? { tableView }
}

extension NSUserInterfaceItemIdentifier {
    static let trackingRow = NSUserInterfaceItemIdentifier("tracking.row")
}
