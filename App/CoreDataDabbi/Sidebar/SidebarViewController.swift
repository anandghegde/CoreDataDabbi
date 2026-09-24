import AppKit
import DabbiKit

/// The entity tree, and the project's saved predicates under it (PRD §8.2, MOD-2, M1-03, PRD-3).
///
/// Inheritance is shown as nesting, because that is what it is: a row of `Manager` is a row of `Employee`, and
/// clicking `Person` shows all three. Counts arrive after the tree does — a store with a hundred tables must
/// not make the window wait for a hundred `COUNT(*)`s (§7).
@MainActor
final class SidebarViewController: NSViewController, NSOutlineViewDataSource, NSOutlineViewDelegate,
    NSSearchFieldDelegate, NSMenuDelegate
{
    let context: ProjectContext

    let outlineView = NSOutlineView()
    private let scrollView = NSScrollView()
    private let filterField = NSSearchField()

    /// The whole tree, and the part of it the filter leaves.
    private var tree: [SidebarNode] = []
    private var shown: [SidebarNode] = []
    /// What the tree was built from; rebuilt only when the model or the saved predicates change.
    private var builtFrom: ModelDescription?
    private var builtPredicates: [SavedPredicate] = []
    private var builtSnapshots: [SnapshotManifest] = []
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
        let menu = NSMenu()
        menu.delegate = self
        outlineView.menu = menu

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
        let predicates = context.savedPredicates
        let snapshots = context.snapshots.snapshots
        let counts = context.entityCounts
        let selected = context.navigation.current

        if model != builtFrom || predicates != builtPredicates || snapshots != builtSnapshots {
            builtFrom = model
            builtPredicates = predicates
            builtSnapshots = snapshots
            // Checked here, against the model the store was opened with, so that a predicate the model has
            // moved away from says so as soon as the project is open (PRD-5).
            tree =
                model.map {
                    SidebarNode.tree(
                        of: $0, savedPredicates: predicates.map { ($0, context.check($0)) }, snapshots: snapshots)
                } ?? []
            applyFilter()
        }
        refreshCounts(counts)
        syncSelection(to: selected)
    }

    // MARK: Filtering

    @objc func controlTextDidChange(_ notification: Notification) {
        guard notification.object as? NSSearchField === filterField else { return }
        applyFilter()
        syncSelection(to: context.navigation.current)
    }

    /// Filters as typing into the field does. For the tests, which have no one to type.
    func filter(by query: String) {
        filterField.stringValue = query
        applyFilter()
        syncSelection(to: context.navigation.current)
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

    /// Selects the row of what the grid shows: the saved predicate or the template it is seen through, or else
    /// the entity.
    private func syncSelection(to location: BrowseLocation?) {
        let nodes = shown.flatMap { $0.flattened() }
        let found =
            if let id = location?.savedPredicate {
                nodes.first { $0.savedPredicateID == id }
            } else if let run = location?.fetchRequest {
                nodes.first { $0.fetchRequest?.name == run.name }
            } else {
                nodes.first { location != nil && $0.entityName == location?.entity }
            }
        guard let node = found else {
            if location == nil { outlineView.deselectAll(nil) }
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
        let current = context.navigation.current
        if let id = node.savedPredicateID {
            if id != current?.savedPredicate { context.show(savedPredicate: id) }
        } else if let plan = node.fetchRequest {
            if plan.name != current?.fetchRequest?.name { run(plan) }
        } else if let entity = node.entityName,
            entity != current?.entity || current?.savedPredicate != nil || current?.fetchRequest != nil
        {
            context.select(entity: entity)
        }
    }

    // MARK: Fetch requests (BRW-1)

    /// Runs a template: at once when it asks for nothing, otherwise once the user has said what its variables
    /// are. Cancelling the prompt leaves the grid where it was, and the selection with it.
    func run(_ plan: FetchTemplatePlan) {
        guard !plan.variables.isEmpty else {
            try? context.run(fetchRequest: plan)
            return
        }
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = context.timeZone
        let prompt = FetchRequestPromptController(
            model: FetchRequestPromptModel(
                plan: plan, previous: context.lastValues(forFetchRequest: plan.name),
                today: calendar.startOfDay(for: .now)),
            timeZone: context.timeZone)
        prompt.onFinish = { [weak self, weak prompt] values in
            guard let self else { return }
            if let prompt { self.dismiss(prompt) }
            if let values {
                // The prompt only lets values through that the template takes.
                try? self.context.run(fetchRequest: plan, values: values)
            }
            self.syncSelection(to: self.context.navigation.current)
        }
        presentAsSheet(prompt)
    }

    /// The template a context menu was opened on, else the selected one.
    private var targetFetchRequest: FetchTemplatePlan? {
        let row = outlineView.clickedRow >= 0 ? outlineView.clickedRow : outlineView.selectedRow
        return (outlineView.item(atRow: row) as? SidebarNode)?.fetchRequest
    }

    @objc private func runFetchRequest(_ sender: NSMenuItem) {
        guard let plan = sender.representedObject as? FetchTemplatePlan else { return }
        run(plan)
    }

    // MARK: Saved predicates (PRD-3)

    /// The saved predicate a context menu was opened on, else the selected one.
    private var targetPredicate: UUID? {
        let row = outlineView.clickedRow >= 0 ? outlineView.clickedRow : outlineView.selectedRow
        return (outlineView.item(atRow: row) as? SidebarNode)?.savedPredicateID
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        if let plan = targetFetchRequest, plan.isRunnable {
            let item = NSMenuItem(
                title: String(localized: "Run…", comment: "Fetch request context menu"),
                action: #selector(runFetchRequest(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = plan
            menu.addItem(item)
            return
        }
        if let snapshot = targetSnapshot {
            addSnapshotItems(for: snapshot, to: menu)
            return
        }
        guard let id = targetPredicate else { return }
        for (title, action) in [
            (
                String(localized: "Rename", comment: "Sidebar context menu, on a saved predicate or a snapshot"),
                #selector(renamePredicate(_:))
            ),
            (
                String(localized: "Duplicate", comment: "Saved predicate context menu"),
                #selector(duplicatePredicate(_:))
            ),
            (String(localized: "Delete", comment: "Saved predicate context menu"), #selector(deletePredicate(_:))),
        ] {
            let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
            item.target = self
            item.representedObject = id
            menu.addItem(item)
        }
    }

    @objc private func renamePredicate(_ sender: NSMenuItem) {
        guard let id = sender.representedObject as? UUID else { return }
        beginRenaming(savedPredicate: id)
    }

    @objc private func duplicatePredicate(_ sender: NSMenuItem) {
        guard let id = sender.representedObject as? UUID, let copy = context.duplicate(savedPredicate: id) else {
            return
        }
        beginRenaming(savedPredicate: copy.id)
    }

    @objc private func deletePredicate(_ sender: NSMenuItem) {
        guard let id = sender.representedObject as? UUID else { return }
        context.delete(savedPredicate: id)
    }

    /// Puts a saved predicate's name into editing in place, the way the Finder renames a file. A new one comes
    /// here straight away, named after its first condition, for the user to keep or type over (PRD-3).
    func beginRenaming(savedPredicate id: UUID) {
        // The row may not be there yet: the context has only just been told about it.
        observe()
        if !shown.flatMap({ $0.flattened() }).contains(where: { $0.savedPredicateID == id }) {
            filter(by: "")
        }
        guard let node = shown.flatMap({ $0.flattened() }).first(where: { $0.savedPredicateID == id }) else {
            return
        }
        let row = outlineView.row(forItem: node)
        guard row >= 0 else { return }
        outlineView.scrollRowToVisible(row)
        guard let cell = outlineView.view(atColumn: 0, row: row, makeIfNecessary: true) as? SidebarCellView else {
            return
        }
        cell.beginEditing { [weak self] name in
            self?.context.rename(savedPredicate: id, to: name)
            self?.view.window?.makeFirstResponder(self?.outlineView)
        }
    }

    // MARK: Snapshots (§7.3)

    /// The snapshot a context menu was opened on.
    private var targetSnapshot: SnapshotManifest? {
        (outlineView.item(atRow: outlineView.clickedRow) as? SidebarNode)?.snapshot
    }

    /// Restoring, editing the note and deleting ask the window, which has the sheets and the alerts.
    private func addSnapshotItems(for snapshot: SnapshotManifest, to menu: NSMenu) {
        let restore = NSMenuItem(
            title: String(localized: "Restore…", comment: "Snapshot context menu"),
            action: #selector(ProjectWindowController.restoreSnapshot(_:)), keyEquivalent: "")
        let rename = NSMenuItem(
            title: String(localized: "Rename", comment: "Sidebar context menu, on a saved predicate or a snapshot"),
            action: #selector(renameSnapshot(_:)), keyEquivalent: "")
        rename.target = self
        let note = NSMenuItem(
            title: String(localized: "Edit Note…", comment: "Snapshot context menu"),
            action: #selector(ProjectWindowController.editSnapshotNote(_:)), keyEquivalent: "")
        let reveal = NSMenuItem(
            title: String(localized: "Show in Finder", comment: "Snapshot context menu"),
            action: #selector(revealSnapshot(_:)), keyEquivalent: "")
        reveal.target = self
        let delete = NSMenuItem(
            title: String(localized: "Delete…", comment: "Snapshot context menu"),
            action: #selector(ProjectWindowController.deleteSnapshot(_:)), keyEquivalent: "")
        for item in [restore, rename, note, reveal, delete] {
            item.representedObject = snapshot.id
            menu.addItem(item)
        }
        menu.insertItem(.separator(), at: 1)
        menu.insertItem(.separator(), at: menu.items.count - 1)
    }

    @objc private func renameSnapshot(_ sender: NSMenuItem) {
        guard let id = sender.representedObject as? UUID else { return }
        beginRenaming(snapshot: id)
    }

    @objc private func revealSnapshot(_ sender: NSMenuItem) {
        guard let id = sender.representedObject as? UUID, let snapshot = context.snapshots.snapshot(id),
            let library = context.snapshots.library
        else { return }
        NSWorkspace.shared.activateFileViewerSelecting([library.databaseURL(of: snapshot)])
    }

    /// Puts a snapshot's name into editing in place, as a saved predicate's is.
    func beginRenaming(snapshot id: UUID) {
        observe()
        if !shown.flatMap({ $0.flattened() }).contains(where: { $0.snapshot?.id == id }) { filter(by: "") }
        guard let node = shown.flatMap({ $0.flattened() }).first(where: { $0.snapshot?.id == id }) else { return }
        let row = outlineView.row(forItem: node)
        guard row >= 0 else { return }
        outlineView.scrollRowToVisible(row)
        guard let cell = outlineView.view(atColumn: 0, row: row, makeIfNecessary: true) as? SidebarCellView else {
            return
        }
        cell.beginEditing { [weak self] name in
            self?.context.snapshots.rename(id, to: name)
            self?.view.window?.makeFirstResponder(self?.outlineView)
        }
    }

    /// The cell a snapshot is shown in, for the tests.
    func cell(forSnapshot id: UUID) -> SidebarCellView? {
        guard let node = shown.flatMap({ $0.flattened() }).first(where: { $0.snapshot?.id == id }) else {
            return nil
        }
        let row = outlineView.row(forItem: node)
        return row < 0 ? nil : outlineView.view(atColumn: 0, row: row, makeIfNecessary: true) as? SidebarCellView
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
        (item as? SidebarNode)?.isSelectable ?? false
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

/// Icon, name, and how many rows there are — once that is known. A saved predicate that no longer fits the
/// model has a warning where the count would be.
@MainActor
final class SidebarCellView: NSTableCellView, NSTextFieldDelegate {
    private let icon = NSImageView()
    private let name = NSTextField(labelWithString: "")
    private let badge = NSTextField(labelWithString: "")
    /// The warning badge (PRD-5). Exposed for the tests.
    let warning = NSImageView()
    private var onRename: ((String) -> Void)?
    private var nameBeforeEditing = ""

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

        warning.image = NSImage(
            systemSymbolName: "exclamationmark.triangle.fill", accessibilityDescription: nil)
        warning.symbolConfiguration = .init(pointSize: 11, weight: .regular)
        warning.contentTintColor = .systemYellow
        warning.isHidden = true
        warning.setContentCompressionResistancePriority(.required, for: .horizontal)
        name.delegate = self

        let stack = NSStackView(views: [icon, name, warning, badge])
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
        name.isEditable = false
        onRename = nil
        warning.isHidden = true
        warning.toolTip = nil
        warning.setAccessibilityLabel(nil)
        switch node.kind {
        case .entity(let entity):
            // An abstract entity has no rows of its own; its dashed icon says so before the count does.
            let symbol = entity.isAbstract ? "rectangle.dashed" : "tablecells"
            icon.image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)
            name.textColor = entity.isAbstract ? .secondaryLabelColor : .labelColor
            toolTip = entity.isAbstract ? String(localized: "Abstract — its rows are its subentities'") : nil
        case .fetchRequest(let plan):
            icon.image = NSImage(systemSymbolName: "line.3.horizontal.decrease", accessibilityDescription: nil)
            name.textColor = plan.isRunnable ? .labelColor : .secondaryLabelColor
            toolTip = plan.template.predicateFormat ?? plan.template.entity.map { String(localized: "Every \($0)") }
            guard !plan.isRunnable else { break }
            warning.isHidden = false
            warning.toolTip = plan.problems.joined(separator: "\n")
            warning.setAccessibilityLabel(
                String(localized: "Cannot be run", comment: "Fetch request warning badge"))
        case .savedPredicate(let predicate, let check):
            icon.image = NSImage(systemSymbolName: "line.3.horizontal.decrease.circle", accessibilityDescription: nil)
            name.textColor = check.isMissingEntity ? .secondaryLabelColor : .labelColor
            toolTip = predicate.predicate?.format ?? String(localized: "Every \(predicate.entity)")
            guard !check.isUsable else { break }
            // What is missing is named on the badge itself, so the list says which predicates the model has
            // moved away from without one having to be opened to find out (PRD-5).
            warning.isHidden = false
            warning.toolTip = check.problems.joined(separator: "\n")
            let missing = check.missingKeyPaths.joined(separator: ", ")
            warning.setAccessibilityLabel(
                missing.isEmpty
                    ? String(localized: "Does not fit the model", comment: "Saved predicate warning badge")
                    : String(
                        localized: "Missing \(missing)",
                        comment: "Saved predicate warning badge; the key paths the model no longer has"))
            warning.setAccessibilityElement(true)
        case .snapshot(let manifest):
            // A backup is the app's: the same copy, with the clock that says when it was taken.
            let symbol = manifest.kind == .backup ? "clock.arrow.circlepath" : "camera"
            icon.image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)
            name.textColor = .labelColor
            toolTip = Self.describe(manifest)
        case .group:
            icon.image = nil
            toolTip = nil
        }
    }

    /// When, what kind, how big, and the note.
    static func describe(_ manifest: SnapshotManifest) -> String {
        let when = manifest.createdAt.formatted(date: .abbreviated, time: .standard)
        let size = ByteCountFormatter.string(fromByteCount: manifest.totalBytes, countStyle: .file)
        var lines = [
            manifest.kind == .backup
                ? String(localized: "Backup taken \(when)", comment: "Snapshot tooltip; the argument is a date")
                : String(localized: "Snapshot taken \(when)", comment: "Snapshot tooltip; the argument is a date"),
            size,
        ]
        if !manifest.note.isEmpty { lines.append(manifest.note) }
        return lines.joined(separator: "\n")
    }

    // MARK: Renaming

    /// Makes the name editable and puts the keyboard in it. `completion` gets the name when editing ends —
    /// unless it was Escape, which puts the old one back.
    func beginEditing(_ completion: @escaping (String) -> Void) {
        onRename = completion
        nameBeforeEditing = name.stringValue
        name.isEditable = true
        name.isSelectable = true
        guard window?.makeFirstResponder(name) == true else { return }
        name.currentEditor()?.selectAll(nil)
    }

    var isEditingName: Bool { name.isEditable }

    /// Ends editing as Return would. For the tests.
    func commitEditing(as text: String) {
        name.stringValue = text
        finishEditing(commit: true)
    }

    func controlTextDidEndEditing(_ notification: Notification) {
        finishEditing(commit: true)
    }

    func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
        guard selector == #selector(cancelOperation(_:)) else { return false }
        name.stringValue = nameBeforeEditing
        finishEditing(commit: false)
        return true
    }

    private func finishEditing(commit: Bool) {
        guard name.isEditable else { return }
        name.isEditable = false
        name.isSelectable = false
        let completion = onRename
        onRename = nil
        if commit {
            completion?(name.stringValue)
        } else {
            // Back to the list, which is where the keyboard was before the rename.
            window?.makeFirstResponder(enclosingScrollView?.documentView)
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
