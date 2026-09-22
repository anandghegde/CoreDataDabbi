import AppKit
import DabbiKit

/// The entity tree (PRD §8.2, MOD-2, M1-03).
///
/// Inheritance is shown as nesting, because that is what it is: a row of `Manager` is a row of `Employee`, and
/// clicking `Person` shows all three. Counts arrive after the tree does — a store with a hundred tables must
/// not make the window wait for a hundred `COUNT(*)`s (§7).
@MainActor
final class SidebarViewController: NSViewController, NSOutlineViewDataSource, NSOutlineViewDelegate,
    NSSearchFieldDelegate
{
    let context: ProjectContext

    let outlineView = NSOutlineView()
    private let scrollView = NSScrollView()
    private let filterField = NSSearchField()

    /// The whole tree, and the part of it the filter leaves.
    private var tree: [SidebarNode] = []
    private var shown: [SidebarNode] = []
    /// What the tree was built from; rebuilt only when the model itself changes.
    private var builtFrom: ModelDescription?
    private var loop: ObservationLoop?
    /// Set while the outline view is being brought in line with the context, so that the change does not go
    /// back out as a click.
    private var isSyncingSelection = false

    init(context: ProjectContext) {
        self.context = context
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("not in a nib") }

    // MARK: The view

    override func loadView() {
        view = NSView()

        let column = NSTableColumn(identifier: .sidebarEntity)
        column.resizingMask = .autoresizingMask
        outlineView.addTableColumn(column)
        outlineView.outlineTableColumn = column
        outlineView.headerView = nil
        outlineView.style = .sourceList
        outlineView.indentationPerLevel = 14
        outlineView.autoresizesOutlineColumn = false
        outlineView.floatsGroupRows = false
        outlineView.dataSource = self
        outlineView.delegate = self
        outlineView.setAccessibilityLabel(String(localized: "Entities"))

        scrollView.documentView = outlineView
        scrollView.hasVerticalScroller = true
        scrollView.drawsBackground = false
        scrollView.automaticallyAdjustsContentInsets = true
        scrollView.translatesAutoresizingMaskIntoConstraints = false

        filterField.placeholderString = String(localized: "Filter")
        filterField.delegate = self
        filterField.sendsWholeSearchString = false
        filterField.sendsSearchStringImmediately = true
        filterField.controlSize = .small
        filterField.translatesAutoresizingMaskIntoConstraints = false

        let separator = NSBox()
        separator.boxType = .separator
        separator.translatesAutoresizingMaskIntoConstraints = false

        view.addSubview(scrollView)
        view.addSubview(separator)
        view.addSubview(filterField)
        NSLayoutConstraint.activate([
            scrollView.topAnchor.constraint(equalTo: view.topAnchor),
            scrollView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            scrollView.bottomAnchor.constraint(equalTo: separator.topAnchor),

            separator.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            separator.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            separator.bottomAnchor.constraint(equalTo: filterField.topAnchor, constant: -6),

            filterField.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 8),
            filterField.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -8),
            filterField.bottomAnchor.constraint(equalTo: view.safeAreaLayoutGuide.bottomAnchor, constant: -8),
        ])
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        loop = ObservationLoop { [weak self] in self?.observe() }
    }

    /// Reads everything the sidebar shows, so that a change to any of it brings this back.
    private func observe() {
        let model = context.model
        let counts = context.entityCounts
        let selected = context.selectedEntity

        if model != builtFrom {
            builtFrom = model
            tree = model.map(SidebarNode.tree(of:)) ?? []
            applyFilter()
        }
        refreshCounts(counts)
        syncSelection(to: selected)
    }

    // MARK: Filtering

    @objc func controlTextDidChange(_ notification: Notification) {
        applyFilter()
        syncSelection(to: context.selectedEntity)
    }

    /// Filters as typing into the field does. For the tests, which have no one to type.
    func filter(by query: String) {
        filterField.stringValue = query
        applyFilter()
        syncSelection(to: context.selectedEntity)
    }

    /// What the sidebar shows, top to bottom.
    var rowTitles: [String] {
        (0..<outlineView.numberOfRows).compactMap { (outlineView.item(atRow: $0) as? SidebarNode)?.title }
    }

    private func applyFilter() {
        shown = SidebarNode.filter(tree, matching: filterField.stringValue)
        outlineView.reloadData()
        // Entity trees are small and a collapsed one hides what the filter just found.
        outlineView.expandItem(nil, expandChildren: true)
    }

    // MARK: Counts

    /// Only the badges are touched: reloading rows would lose the selection and the open triangles.
    private func refreshCounts(_ counts: [String: EntityCount]) {
        for row in 0..<outlineView.numberOfRows {
            guard let node = outlineView.item(atRow: row) as? SidebarNode,
                let cell = outlineView.view(atColumn: 0, row: row, makeIfNecessary: false) as? SidebarCellView
            else { continue }
            cell.show(count(of: node, in: counts))
        }
    }

    private func count(of node: SidebarNode, in counts: [String: EntityCount]) -> EntityCount? {
        node.entityName.flatMap { counts[$0] }
    }

    // MARK: Selection

    private func syncSelection(to entity: String?) {
        guard let entity, let node = shown.flatMap({ $0.flattened() }).first(where: { $0.entityName == entity })
        else {
            if entity == nil { outlineView.deselectAll(nil) }
            return
        }
        for ancestor in node.ancestors.reversed() { outlineView.expandItem(ancestor) }
        let row = outlineView.row(forItem: node)
        guard row >= 0, outlineView.selectedRow != row else { return }
        isSyncingSelection = true
        outlineView.selectRowIndexes([row], byExtendingSelection: false)
        outlineView.scrollRowToVisible(row)
        isSyncingSelection = false
    }

    func outlineViewSelectionDidChange(_ notification: Notification) {
        guard !isSyncingSelection, let node = outlineView.item(atRow: outlineView.selectedRow) as? SidebarNode
        else { return }
        if let entity = node.entityName, entity != context.selectedEntity { context.select(entity: entity) }
    }

    // MARK: Data source

    func outlineView(_ outlineView: NSOutlineView, numberOfChildrenOfItem item: Any?) -> Int {
        (item as? SidebarNode)?.children.count ?? shown.count
    }

    func outlineView(_ outlineView: NSOutlineView, child index: Int, ofItem item: Any?) -> Any {
        (item as? SidebarNode)?.children[index] ?? shown[index]
    }

    func outlineView(_ outlineView: NSOutlineView, isItemExpandable item: Any) -> Bool {
        !((item as? SidebarNode)?.children.isEmpty ?? true)
    }

    // MARK: Delegate

    func outlineView(_ outlineView: NSOutlineView, isGroupItem item: Any) -> Bool {
        (item as? SidebarNode)?.isGroup ?? false
    }

    func outlineView(_ outlineView: NSOutlineView, shouldSelectItem item: Any) -> Bool {
        guard let node = item as? SidebarNode else { return false }
        // A fetch request is selectable from M2 on, when there is something to run it with.
        return node.entityName != nil
    }

    func outlineView(_ outlineView: NSOutlineView, viewFor tableColumn: NSTableColumn?, item: Any) -> NSView? {
        guard let node = item as? SidebarNode else { return nil }
        if node.isGroup {
            let identifier = NSUserInterfaceItemIdentifier("group")
            let view =
                outlineView.makeView(withIdentifier: identifier, owner: self) as? NSTableCellView
                ?? NSTableCellView.header(identifier: identifier)
            view.textField?.stringValue = node.title.localizedUppercase
            return view
        }
        let view =
            outlineView.makeView(withIdentifier: .sidebarCell, owner: self) as? SidebarCellView ?? SidebarCellView()
        view.show(node)
        view.show(count(of: node, in: context.entityCounts))
        return view
    }
}

extension SidebarViewController: KeyboardPane {
    /// The tree, not the filter field: asking for the entities means the list of them (§8.4).
    var keyboardResponder: NSResponder? { outlineView }
}

extension NSUserInterfaceItemIdentifier {
    static let sidebarEntity = NSUserInterfaceItemIdentifier("entity")
    static let sidebarCell = NSUserInterfaceItemIdentifier("sidebar")
}

extension NSTableCellView {
    /// A plain label cell, for the sidebar's headings.
    fileprivate static func header(identifier: NSUserInterfaceItemIdentifier) -> NSTableCellView {
        let cell = NSTableCellView()
        cell.identifier = identifier
        let label = NSTextField(labelWithString: "")
        label.font = .systemFont(ofSize: NSFont.smallSystemFontSize, weight: .semibold)
        label.textColor = .secondaryLabelColor
        label.translatesAutoresizingMaskIntoConstraints = false
        cell.addSubview(label)
        cell.textField = label
        NSLayoutConstraint.activate([
            label.leadingAnchor.constraint(equalTo: cell.leadingAnchor),
            label.trailingAnchor.constraint(lessThanOrEqualTo: cell.trailingAnchor),
            label.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
        ])
        return cell
    }
}

/// Icon, name, and how many rows there are — once that is known.
@MainActor
final class SidebarCellView: NSTableCellView {
    private let icon = NSImageView()
    private let name = NSTextField(labelWithString: "")
    private let badge = NSTextField(labelWithString: "")

    init() {
        super.init(frame: .zero)
        identifier = .sidebarCell

        icon.symbolConfiguration = .init(pointSize: 12, weight: .regular)
        icon.contentTintColor = .secondaryLabelColor
        badge.font = .monospacedDigitSystemFont(ofSize: NSFont.smallSystemFontSize, weight: .regular)
        badge.textColor = .tertiaryLabelColor
        badge.alignment = .right
        badge.setContentCompressionResistancePriority(.required, for: .horizontal)
        name.lineBreakMode = .byTruncatingTail
        name.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        let stack = NSStackView(views: [icon, name, badge])
        stack.spacing = 6
        stack.alignment = .centerY
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        imageView = icon
        textField = name
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor),
            stack.centerYAnchor.constraint(equalTo: centerYAnchor),
            icon.widthAnchor.constraint(equalToConstant: 16),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("not in a nib") }

    func show(_ node: SidebarNode) {
        name.stringValue = node.title
        switch node.kind {
        case .entity(let entity):
            // An abstract entity has no rows of its own; its dashed icon says so before the count does.
            let symbol = entity.isAbstract ? "rectangle.dashed" : "tablecells"
            icon.image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)
            name.textColor = entity.isAbstract ? .secondaryLabelColor : .labelColor
            toolTip = entity.isAbstract ? String(localized: "Abstract — its rows are its subentities'") : nil
        case .fetchRequest:
            icon.image = NSImage(systemSymbolName: "line.3.horizontal.decrease", accessibilityDescription: nil)
            name.textColor = .labelColor
            toolTip = nil
        case .group:
            icon.image = nil
            toolTip = nil
        }
    }

    /// Blank until the counts are in, so that nothing has to be unsaid afterwards.
    func show(_ count: EntityCount?) {
        guard let count else {
            badge.stringValue = ""
            setAccessibilityValue(nil)
            return
        }
        badge.stringValue = Self.formatter.string(from: NSNumber(value: count.total)) ?? "\(count.total)"
        badge.toolTip =
            count.own == count.total
            ? nil
            : String(
                localized: "\(count.own) of its own, \(count.total) with its subentities",
                comment: "Tooltip on the row count of an entity that has subentities")
        setAccessibilityValue(String(localized: "\(count.total) rows"))
    }

    private static let formatter: NumberFormatter = {
        let formatter = NumberFormatter()
        formatter.numberStyle = .decimal
        return formatter
    }()
}
