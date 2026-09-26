import AppKit
import DabbiKit
import UniformTypeIdentifiers

/// Export and Copy As (IMX-1, BRW-12, TRK-5): what leaves the store for a file or the pasteboard.
extension ProjectWindowController {
    private var grid: GridViewController { panes.centre.browse.grid }

    /// The rows the grid has selected, unless it is showing the tracking log instead of rows.
    private var selectedRows: [ObjectRef] {
        context.tracking.isShowingLog ? [] : grid.selectedObjects
    }

    // MARK: Export

    /// Data › Export ▸ — which rows and which format are the menu item's represented object, `scope.format`.
    @IBAction func exportRows(_ sender: Any?) {
        guard let (scope, format) = Self.exportChoice(of: sender), let session = context.session,
            let entity = context.selectedEntity,
            let source = ExportCommands.source(for: scope, context: context, selection: selectedRows)
        else { return }
        let columns = grid.columns
        let timeZone = context.timeZone
        askWhereToExport(
            name: ExportCommands.fileName(entity: entity, scope: scope, format: format), format: format,
            relationships: true
        ) { [weak self] url, settings in
            let reader = ExportReader(
                session: session, options: ExportCommands.options(for: scope, settings: settings, columns: columns))
            self?.runExport {
                try await reader.write(source, as: settings.exporter(for: format, timeZone: timeZone), to: url)
            }
        }
    }

    /// Data › Export ▸ Tracked Session: every version the log holds, oldest first (TRK-5).
    @IBAction func exportTrackedSession(_ sender: Any?) {
        guard let raw = (sender as? NSMenuItem)?.representedObject as? String,
            let format = ExportFormat(rawValue: raw), !context.tracking.log.isEmpty
        else { return }
        let export = ExportCommands.trackedSession(context.tracking.log)
        let timeZone = context.timeZone
        let name = String(localized: "Tracked Changes") + "." + format.fileExtension
        askWhereToExport(name: name, format: format, relationships: false) { [weak self] url, settings in
            self?.runExport {
                try await export.write(as: settings.exporter(for: format, timeZone: timeZone), to: url)
            }
        }
    }

    static func exportChoice(of sender: Any?) -> (ExportScope, ExportFormat)? {
        guard let raw = (sender as? NSMenuItem)?.representedObject as? String else { return nil }
        let parts = raw.split(separator: ".").map(String.init)
        guard parts.count == 2, let scope = ExportScope(rawValue: parts[0]),
            let format = ExportFormat(rawValue: parts[1])
        else { return nil }
        return (scope, format)
    }

    /// The save panel, with what the format can be asked about under it.
    private func askWhereToExport(
        name: String, format: ExportFormat, relationships: Bool,
        _ export: @escaping @MainActor (URL, ExportSettings) -> Void
    ) {
        guard let window, window.attachedSheet == nil else { return }
        let panel = NSSavePanel()
        panel.nameFieldStringValue = name
        panel.allowedContentTypes = [format == .csv ? .commaSeparatedText : .json]
        panel.canCreateDirectories = true
        let accessory = ExportAccessory(format: format, relationships: relationships)
        panel.accessoryView = accessory.view
        panel.beginSheetModal(for: window) { response in
            guard response == .OK, let url = panel.url else { return }
            export(url, accessory.settings)
        }
    }

    /// Runs an export off the main actor's way, and says so if it fails. The file appears only when complete.
    private func runExport(_ body: @escaping @Sendable () async throws -> Int) {
        Task { [weak self] in
            do {
                _ = try await body()
            } catch is CancellationError {
            } catch {
                self?.explainExchangeError(DabbiError.wrapping(error))
            }
        }
    }

    // MARK: Copy As (BRW-12)

    /// Edit › Copy As ▸ — the selected rows as tab-separated text, JSON or a Markdown table.
    @IBAction func copyRowsAs(_ sender: Any?) {
        guard let raw = (sender as? NSMenuItem)?.representedObject as? String,
            let format = CopyFormat(rawValue: raw), let session = context.session,
            let entity = context.selectedEntity
        else { return }
        let selection = selectedRows
        guard !selection.isEmpty else { return }
        let columns = grid.columns
        let timeZone = context.timeZone
        Task { [weak self] in
            do {
                let text = try await ExportCommands.copyText(
                    format, of: selection, entity: entity, columns: columns, session: session, timeZone: timeZone)
                Self.putOnPasteboard(text)
            } catch {
                self?.explainExchangeError(DabbiError.wrapping(error))
            }
        }
    }

    /// Edit › Copy Object URI: the selected objects' URIs, one a line.
    @IBAction func copyObjectURI(_ sender: Any?) {
        let selection = selectedRows
        guard !selection.isEmpty else { return }
        Self.putOnPasteboard(ExportCommands.uriText(of: selection))
    }

    private static func putOnPasteboard(_ text: String) {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)
    }

    private func explainExchangeError(_ error: DabbiError) {
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

    // MARK: Validation

    /// Whether an export or copy item can run; `nil` for items that are not about exchange.
    func validateExchangeItem(_ item: NSMenuItem) -> Bool? {
        switch item.action {
        case #selector(exportRows(_:)):
            guard let (scope, _) = Self.exportChoice(of: item), context.session != nil else { return false }
            return ExportCommands.source(for: scope, context: context, selection: selectedRows) != nil
        case #selector(exportTrackedSession(_:)):
            return !context.tracking.log.isEmpty
        case #selector(copyRowsAs(_:)), #selector(copyObjectURI(_:)):
            return context.session != nil && !selectedRows.isEmpty
        default:
            return nil
        }
    }
}

/// Under the save panel: the CSV separator and header row, how relationships are written, and whether bytes are.
@MainActor
final class ExportAccessory {
    let view: NSView
    private let separator = NSPopUpButton()
    private let header = NSButton(checkboxWithTitle: String(localized: "Header row"), target: nil, action: nil)
    private let relationships = NSPopUpButton()
    private let binary = NSButton(
        checkboxWithTitle: String(localized: "Include binary data"), target: nil, action: nil)
    private let format: ExportFormat
    private let choices: [ExportOptions.Relationships]

    init(format: ExportFormat, relationships showsRelationships: Bool, settings: ExportSettings = .init()) {
        self.format = format
        choices = ExportSettings.relationshipChoices(for: format)

        var rows: [[NSView]] = []
        if format == .csv {
            for choice in CSVSeparator.allCases { separator.addItem(withTitle: choice.name) }
            separator.selectItem(at: CSVSeparator.allCases.firstIndex(of: settings.separator) ?? 0)
            separator.setAccessibilityLabel(String(localized: "Separator"))
            rows.append([NSTextField(labelWithString: String(localized: "Separator:")), separator])
            header.state = settings.includesHeader ? .on : .off
            header.setAccessibilityLabel(String(localized: "Header row"))
            rows.append([NSGridCell.emptyContentView, header])
        }
        if showsRelationships {
            for choice in choices { relationships.addItem(withTitle: ExportSettings.name(of: choice)) }
            relationships.selectItem(at: choices.firstIndex(of: settings.relationships) ?? 0)
            relationships.setAccessibilityLabel(String(localized: "Relationships"))
            rows.append([NSTextField(labelWithString: String(localized: "Relationships:")), relationships])
            binary.state = settings.includesBinaryData ? .on : .off
            binary.setAccessibilityLabel(String(localized: "Include binary data"))
            rows.append([NSGridCell.emptyContentView, binary])
        }
        let grid = NSGridView(views: rows)
        grid.rowSpacing = 8
        grid.rowAlignment = .firstBaseline
        grid.column(at: 0).xPlacement = .trailing
        grid.translatesAutoresizingMaskIntoConstraints = false
        let container = NSView()
        container.addSubview(grid)
        NSLayoutConstraint.activate([
            grid.topAnchor.constraint(equalTo: container.topAnchor, constant: 12),
            grid.bottomAnchor.constraint(equalTo: container.bottomAnchor, constant: -12),
            grid.centerXAnchor.constraint(equalTo: container.centerXAnchor),
            grid.leadingAnchor.constraint(greaterThanOrEqualTo: container.leadingAnchor, constant: 20),
        ])
        view = container
    }

    /// What is chosen now.
    var settings: ExportSettings {
        var settings = ExportSettings()
        if format == .csv {
            settings.separator = CSVSeparator.allCases[max(0, separator.indexOfSelectedItem)]
            settings.includesHeader = header.state == .on
        }
        if relationships.numberOfItems > 0 {
            settings.relationships = choices[max(0, relationships.indexOfSelectedItem)]
            settings.includesBinaryData = binary.state == .on
        }
        return settings
    }

    /// For the tests: picks a relationship choice as a click would.
    func select(relationships choice: ExportOptions.Relationships) {
        relationships.selectItem(at: choices.firstIndex(of: choice) ?? 0)
    }

    func select(separator choice: CSVSeparator) {
        separator.selectItem(at: CSVSeparator.allCases.firstIndex(of: choice) ?? 0)
    }
}
