import AppKit
import DabbiKit

/// The main grid (PRD §8.3, BRW-2…BRW-11, M1-05).
///
/// A view-based `NSTableView` over `PagedRows`: the table asks for a cell and gets whatever is in memory,
/// never a fetch — that is what keeps a million-row entity scrolling (ARCHITECTURE.md §6.4). What the user
/// does to the columns is kept in the project, per entity.
@MainActor
final class GridViewController: NSViewController, NSTableViewDataSource, NSTableViewDelegate, NSMenuDelegate {
    let context: ProjectContext

    let tableView = NSTableView()
    private let scrollView = NSScrollView()
    let footer = GridFooterView()

    private(set) var rows: PagedRows?
    private(set) var columns: [GridColumn] = []

    /// What the grid currently shows, so that a change to anything else does not reopen the pager.
    private var shownEntity: String?
    /// The saved predicate the entity is seen through. Another has other columns, even with the same rows.
    private var shownPredicate: UUID?
    private var shownSort: [SortKey] = []
    private var shownFilter: PredicateSource?
    private var shownCap: Int?
    private var shownSession: ObjectIdentifier?
    /// Staged edits as last read (EDT-8): a new revision re-reads the rows, a new commit reopens the pager —
    /// the session is in a new generation, and the old pager is stale.
    private var shownRevision = 0
    private var shownCommits = 0
    /// Bumped per open; a pager that arrives after another open started is dropped.
    private var openAttempt = 0
    /// Only so that a test can wait for the rows the user simply watches arrive.
    private var openTask: Task<Void, Never>?

    private var loop: ObservationLoop?
    /// Set while the grid writes to the table or the context, to keep a change from coming straight back.
    private var isUpdating = false
    private var isShiftClickingHeader = false

    init(context: ProjectContext) {
        self.context = context
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("not in a nib") }

    deinit {
        MainActor.assumeIsolated { rows?.close() }
    }

    // MARK: The view

    override func loadView() {
        view = NSView()

        tableView.dataSource = self
        tableView.delegate = self
        tableView.style = .fullWidth
        tableView.usesAlternatingRowBackgroundColors = true
        tableView.gridStyleMask = [.solidVerticalGridLineMask]
        tableView.allowsColumnReordering = true
        tableView.allowsColumnResizing = true
        tableView.allowsMultipleSelection = true
        tableView.allowsColumnSelection = false
        tableView.columnAutoresizingStyle = .noColumnAutoresizing
        tableView.usesAutomaticRowHeights = false
        tableView.rowHeight = 20
        tableView.intercellSpacing = NSSize(width: 6, height: 2)
        tableView.setAccessibilityLabel(String(localized: "Rows"))
        tableView.target = self
        tableView.action = #selector(cellClicked)

        let headerMenu = NSMenu()
        headerMenu.delegate = self
        tableView.headerView?.menu = headerMenu

        scrollView.documentView = tableView
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        scrollView.contentView.postsBoundsChangedNotifications = true
        NotificationCenter.default.addObserver(
            self, selector: #selector(visibleRowsChanged), name: NSView.boundsDidChangeNotification,
            object: scrollView.contentView)

        footer.translatesAutoresizingMaskIntoConstraints = false
        footer.onLoadMore = { [weak self] in self?.loadMore() }

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

    override func viewDidLayout() {
        super.viewDidLayout()
        updateVisibleRows()
    }

    // MARK: Following the context

    private func observe() {
        let session = context.session
        let location = context.navigation.current
        let layout = location.map { context.layout(at: $0) }
        let sort = layout?.sort ?? []
        // The predicate bar applies by writing it here, which is what brings the grid back through this (§7.1);
        // the quick filter narrows it (PRD-6).
        let filter = location.flatMap { context.fetchFilter(at: $0) }
        // A fetch-request template's limit is part of what it asks for (BRW-1).
        let cap = location?.fetchRequest?.limit
        // Reading the time zone here means changing it redraws the grid.
        _ = context.timeZone
        let revision = context.editing.revision
        let commits = context.editing.commits

        let identity = session.map(ObjectIdentifier.init)
        if location?.entity != shownEntity || location?.savedPredicate != shownPredicate || sort != shownSort
            || filter != shownFilter || cap != shownCap || identity != shownSession || commits != shownCommits
        {
            shownCommits = commits
            shownRevision = revision
            shownEntity = location?.entity
            shownPredicate = location?.savedPredicate
            shownSort = sort
            shownFilter = filter
            shownCap = cap
            shownSession = identity
            open(entity: location?.entity, sort: sort, filter: filter, in: session)
        } else if revision != shownRevision {
            shownRevision = revision
            rows?.reload()
        } else {
            reloadVisibleCells()
        }
    }

    private func open(entity: String?, sort: [SortKey], filter: PredicateSource?, in session: StoreSession?) {
        openAttempt += 1
        let attempt = openAttempt
        rows?.close()
        rows = nil
        tableView.reloadData()

        guard let entity, let session, let model = context.model, let description = model.entity(named: entity) else {
            columns = []
            rebuildTableColumns()
            footer.show(.empty)
            return
        }
        footer.show(.loading)

        let spec = FetchSpec(
            entity: entity, predicate: filter, sort: sort, limit: min(Self.firstPage, shownCap ?? .max))
        openTask = Task { [weak self] in
            let handle: PagerHandle
            do {
                handle = try await session.openPager(spec)
            } catch {
                guard let self, self.openAttempt == attempt else { return }
                self.footer.show(.failed(DabbiError.wrapping(error)))
                return
            }
            guard let self, self.openAttempt == attempt else {
                await session.closePager(handle)
                return
            }
            self.start(handle, of: description, in: model, session: session)
        }
    }

    /// Returns once the pager is open and its first page is in. Nothing in the app waits for that; the tests do.
    func whenSettled() async {
        await openTask?.value
        await rows?.waitUntilIdle()
    }

    /// The fetch limit of a first look at an entity. Everything beyond it arrives through "Load more", so that
    /// opening a huge entity costs one bounded query (BRW-11).
    private static let firstPage = 10_000

    private func start(
        _ handle: PagerHandle, of entity: EntityDescription, in model: ModelDescription, session: StoreSession
    ) {
        columns = GridColumn.columns(
            for: entity, in: model, reading: handle.columns, layout: context.shownLayout)
        rebuildTableColumns()

        let paged = PagedRows(session: session, handle: handle, columns: columns.columnSet)
        paged.onEvent = { [weak self] event in self?.handle(event) }
        rows = paged
        tableView.reloadData()
        updateVisibleRows()
        updateFooter()
        restoreSelection()
    }

    private func handle(_ event: PagedRows.Event) {
        switch event {
        case .loaded(let range):
            let columns = IndexSet(integersIn: 0..<max(tableView.numberOfColumns, 1))
            let visible = range.clamped(to: 0..<tableView.numberOfRows)
            if !visible.isEmpty {
                tableView.reloadData(forRowIndexes: IndexSet(integersIn: visible), columnIndexes: columns)
            }
            updateFooter()
            // The row the window was sent to is only identifiable once its page is in: a reveal lands here,
            // one page after the grid opened (REL-3).
            if reference(at: tableView.selectedRow) != context.navigation.current?.focus { restoreSelection() }
        case .failed(let error):
            footer.show(.failed(error))
        }
    }

    @objc private func visibleRowsChanged() {
        updateVisibleRows()
    }

    private func updateVisibleRows() {
        guard let rows else { return }
        let visible = tableView.rows(in: scrollView.contentView.bounds)
        guard visible.length > 0 else { return }
        rows.setVisible(visible.lowerBound..<min(visible.upperBound, rows.count))
    }

    private func reloadVisibleCells() {
        let visible = tableView.rows(in: scrollView.contentView.bounds)
        guard visible.length > 0, tableView.numberOfColumns > 0 else { return }
        tableView.reloadData(
            forRowIndexes: IndexSet(integersIn: visible.lowerBound..<min(visible.upperBound, tableView.numberOfRows)),
            columnIndexes: IndexSet(integersIn: 0..<tableView.numberOfColumns))
    }

    // MARK: Columns

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
            if column.isSortable {
                tableColumn.sortDescriptorPrototype = NSSortDescriptor(key: column.property, ascending: true)
            }
            tableView.addTableColumn(tableColumn)
        }
        tableView.sortDescriptors = shownSort.map { NSSortDescriptor(key: $0.keyPath, ascending: $0.ascending) }
    }

    private func column(for tableColumn: NSTableColumn) -> GridColumn? {
        columns.first { $0.property == tableColumn.identifier.rawValue }
    }

    /// Writes the columns back to the project, and re-reads if what is read has changed.
    private func persistColumns(reread: Bool) {
        guard shownEntity != nil else { return }
        context.updateShownLayout { $0.columns = GridColumn.layout(of: columns) }
        if reread { rows?.setColumns(columns.columnSet) }
    }

    func tableViewColumnDidMove(_ notification: Notification) {
        guard !isUpdating else { return }
        // The table knows the new order; the hidden columns keep the place they had among their neighbours.
        let order = tableView.tableColumns.map(\.identifier.rawValue)
        columns.sort { left, right in
            switch (order.firstIndex(of: left.property), order.firstIndex(of: right.property)) {
            case (let a?, let b?): a < b
            default: false
            }
        }
        persistColumns(reread: false)
    }

    func tableViewColumnDidResize(_ notification: Notification) {
        guard !isUpdating, let tableColumn = notification.userInfo?["NSTableColumn"] as? NSTableColumn,
            let index = columns.firstIndex(where: { $0.property == tableColumn.identifier.rawValue })
        else { return }
        columns[index].width = tableColumn.width
        persistColumns(reread: false)
    }

    // MARK: The header menu

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        for column in columns {
            let item = NSMenuItem(
                title: column.title, action: #selector(toggleColumn(_:)), keyEquivalent: "")
            item.target = self
            item.state = column.isHidden ? .off : .on
            item.representedObject = column.property
            // A grid with no columns at all cannot be got out of by clicking.
            item.isEnabled = !(columns.visible.count == 1 && !column.isHidden)
            menu.addItem(item)
        }
        menu.addItem(.separator())
        let showAll = NSMenuItem(
            title: String(localized: "Show All Columns"), action: #selector(showAllColumns(_:)), keyEquivalent: "")
        showAll.target = self
        showAll.isEnabled = columns.contains { $0.isHidden }
        menu.addItem(showAll)
        let fit = NSMenuItem(
            title: String(localized: "Size All Columns to Fit"), action: #selector(sizeColumnsToFit(_:)),
            keyEquivalent: "")
        fit.target = self
        menu.addItem(fit)
    }

    @objc private func toggleColumn(_ sender: NSMenuItem) {
        guard let property = sender.representedObject as? String,
            let index = columns.firstIndex(where: { $0.property == property })
        else { return }
        columns[index].isHidden.toggle()
        rebuildTableColumns()
        persistColumns(reread: true)
        tableView.reloadData()
    }

    @objc private func showAllColumns(_ sender: Any?) {
        for index in columns.indices { columns[index].isHidden = false }
        rebuildTableColumns()
        persistColumns(reread: true)
        tableView.reloadData()
    }

    /// Widens every column to the widest value in memory, which is what the user can see. Rows not yet read
    /// are not waited for: a size that arrives half a second later is worse than one that is slightly off.
    @objc private func sizeColumnsToFit(_ sender: Any?) {
        let visible = tableView.rows(in: scrollView.contentView.bounds)
        let font = NSFont.systemFont(ofSize: NSFont.systemFontSize)
        for tableColumn in tableView.tableColumns {
            guard let column = column(for: tableColumn) else { continue }
            var width =
                (column.title as NSString).size(withAttributes: [.font: NSFont.boldSystemFont(ofSize: 11)])
                .width + 20
            for row in visible.lowerBound..<min(visible.upperBound, tableView.numberOfRows) {
                let text = value(at: row, column: column)?.text ?? ""
                width = max(width, (text as NSString).size(withAttributes: [.font: font]).width + 12)
            }
            tableColumn.width = min(max(width, 40), 400)
        }
    }

    // MARK: Sorting

    func tableView(_ tableView: NSTableView, mouseDownInHeaderOf tableColumn: NSTableColumn) {
        isShiftClickingHeader = NSApp.currentEvent?.modifierFlags.contains(.shift) ?? false
    }

    func tableView(_ tableView: NSTableView, sortDescriptorsDidChange oldDescriptors: [NSSortDescriptor]) {
        guard !isUpdating, shownEntity != nil else { return }
        guard let changed = tableView.sortDescriptors.first else {
            applySort([])
            return
        }
        var keys = shownSort
        let key = SortKey(keyPath: changed.key ?? "", ascending: changed.ascending)
        if isShiftClickingHeader, let index = keys.firstIndex(where: { $0.keyPath == key.keyPath }) {
            keys[index] = key
        } else if isShiftClickingHeader {
            // Shift-click adds a tie-breaker to what is already sorted (BRW-9).
            keys.append(key)
        } else {
            keys = [key]
        }
        isShiftClickingHeader = false
        applySort(keys)
    }

    private func applySort(_ keys: [SortKey]) {
        isUpdating = true
        tableView.sortDescriptors = keys.map { NSSortDescriptor(key: $0.keyPath, ascending: $0.ascending) }
        isUpdating = false
        // The layout change comes back through the observation loop, which reopens the pager.
        context.updateShownLayout { $0.sort = keys }
    }

    // MARK: Rows

    func numberOfRows(in tableView: NSTableView) -> Int {
        rows?.count ?? 0
    }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        guard let tableColumn, let column = column(for: tableColumn) else { return nil }
        let cell =
            tableView.makeView(withIdentifier: .gridCell, owner: self) as? GridCellView ?? GridCellView()
        cell.show(
            value(at: row, column: column) ?? .notLoaded, trailing: column.isTrailing, column: column.title,
            issue: issue(at: row, column: column)?.message)
        return cell
    }

    /// The rule of the model the staged value in this cell breaks, if it breaks one (EDT-2). The grid re-reads
    /// its rows whenever what is staged changes, which is what brings the cells back through here.
    func issue(at row: Int, column: GridColumn) -> ValidationIssue? {
        guard !context.editing.changes.issues.isEmpty, let ref = reference(at: row) else { return nil }
        switch column.kind {
        case .attribute, .relationship:
            return context.editing.issue(for: PendingObjectID(ref), property: column.property)
        case .objectID, .entity:
            return nil
        }
    }

    func value(at row: Int, column: GridColumn) -> GridValue? {
        guard let rows, row >= 0, row < rows.count else { return nil }
        switch rows.row(at: row) {
        case .notLoaded:
            return .notLoaded
        case .deleted:
            return .deleted
        case .row(let snapshot):
            switch column.kind {
            case .objectID:
                return GridValue(text: String(snapshot.ref.pk), tooltip: snapshot.ref.uri.absoluteString)
            case .entity:
                return GridValue(text: snapshot.ref.entity)
            case .attribute, .relationship:
                // Rows carry the columns the pager was last told to read, which is the visible set.
                let read = rows.columns ?? rows.handle.columns
                guard let index = read.index(of: column.property), index < snapshot.values.count else {
                    return .notLoaded
                }
                return GridValue.render(snapshot.values[index], timeZone: context.timeZone)
            }
        }
    }

    /// The selected rows' objects, in the grid's order. Rows not read yet, or deleted, are not among them.
    var selectedObjects: [ObjectRef] {
        tableView.selectedRowIndexes.compactMap(reference(at:))
    }

    private func reference(at row: Int) -> ObjectRef? {
        guard let rows, row >= 0, row < rows.count, case .row(let snapshot) = rows.row(at: row) else { return nil }
        return snapshot.ref
    }

    // MARK: Selection

    func tableViewSelectionDidChange(_ notification: Notification) {
        guard !isUpdating else { return }
        context.focus(on: reference(at: tableView.selectedRow))
    }

    /// Which cell was clicked, for the content viewer (CNT-1). Moving down a column with the keyboard keeps
    /// reading the same column, which is why this is the only thing that changes it.
    @objc private func cellClicked(_ sender: Any?) {
        let clicked = tableView.clickedColumn
        guard clicked >= 0, clicked < tableView.tableColumns.count else { return }
        focus(onColumnAt: clicked)
    }

    /// Reads a column of the selected row, as a click on it would. The keyboard has no way to say this yet;
    /// the tests do.
    func focus(onColumnAt index: Int) {
        guard index >= 0, index < tableView.tableColumns.count else { return }
        let property = tableView.tableColumns[index].identifier.rawValue
        // The object ID and the entity are the grid's own columns, not fields of the row: clicking one leaves
        // the content viewer where it was rather than emptying it.
        switch columns.first(where: { $0.property == property })?.kind {
        case .attribute, .relationship:
            // A click in the grid is also a click away from whatever the relationships panel had picked: the
            // column being read belongs to this row (REL-1).
            context.focus(on: reference(at: tableView.selectedRow))
            context.focus(onProperty: property)
        default:
            break
        }
    }

    /// Brings the selection back to where the context says it is — after a reopen, or when somewhere else in
    /// the window said to show an object. A row outside what has been read cannot be found yet; the object is
    /// still shown in the inspector, so nothing is lost but the highlight.
    private func restoreSelection() {
        guard let focus = context.navigation.current?.focus, let rows else { return }
        for row in 0..<min(rows.count, PagedRows.searchLimit) where reference(at: row) == focus {
            isUpdating = true
            tableView.selectRowIndexes([row], byExtendingSelection: false)
            tableView.scrollRowToVisible(row)
            isUpdating = false
            return
        }
    }

    // MARK: Load more

    private func loadMore() {
        guard let rows else { return }
        footer.show(.loading)
        Task { [weak self] in
            // Up to a template's limit and no further.
            _ = try? await rows.loadMore(count: self?.shownCap.map { min(Self.firstPage, max($0 - rows.count, 1)) })
            guard let self, self.rows === rows else { return }
            self.tableView.noteNumberOfRowsChanged()
            self.updateVisibleRows()
            self.updateFooter()
        }
    }

    private func updateFooter() {
        guard let rows else {
            footer.show(.empty)
            return
        }
        footer.show(.rows(count: rows.count, hasMore: rows.hasMore && rows.count < (shownCap ?? .max)))
    }
}

extension GridViewController: KeyboardPane {
    /// The table: arrow keys move the selection, which is what "the rows" means from the keyboard (§8.4).
    var keyboardResponder: NSResponder? { tableView }
}

extension PagedRows {
    /// How far into the list `restoreSelection` looks for an object. Beyond it the row is certainly not in
    /// memory, and finding it would need a query the engine does not offer yet.
    static let searchLimit = 5_000
}

extension DabbiError {
    static func wrapping(_ error: any Error) -> DabbiError {
        error as? DabbiError ?? DabbiError(.internal, "The rows could not be read.", underlying: error)
    }
}

extension NSUserInterfaceItemIdentifier {
    static let gridCell = NSUserInterfaceItemIdentifier("grid")
}
