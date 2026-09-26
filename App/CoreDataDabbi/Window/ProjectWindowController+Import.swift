import AppKit
import DabbiKit
import UniformTypeIdentifiers

/// Data › Import (IMX-2 – IMX-4): a CSV or JSON file's rows staged into the entity on screen.
extension ProjectWindowController {
    /// The entity the grid shows, when rows can be imported into it: the store is editable and it is not
    /// abstract.
    var importableEntity: EntityDescription? {
        guard context.editing.isEditable, !context.tracking.isShowingLog,
            let entity = context.selectedEntity.flatMap({ context.model?.entity(named: $0) }), !entity.isAbstract
        else { return nil }
        return entity
    }

    /// Asks for a file, then shows the import sheet for it.
    @IBAction func importFile(_ sender: Any?) {
        guard let window, window.attachedSheet == nil, importableEntity != nil else { return }
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.commaSeparatedText, .tabSeparatedText, .json, .plainText]
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.message = String(localized: "Choose a CSV or JSON file, as an export writes them.")
        panel.beginSheetModal(for: window) { [weak self] response in
            guard response == .OK, let url = panel.url else { return }
            self?.showImport(of: url)
        }
    }

    /// Reads `url` and shows the sheet that maps its columns; says why if it cannot be read.
    func showImport(of url: URL) {
        guard let window, window.attachedSheet == nil, let content = window.contentViewController,
            let entity = importableEntity, let model = context.model
        else { return }
        let table: ImportTable
        do {
            table = try ImportTable.read(url)
        } catch {
            explainExchangeError(DabbiError.wrapping(error))
            return
        }
        guard !table.rows.isEmpty else {
            explainExchangeError(
                DabbiError(.importUnreadable, String(localized: "“\(url.lastPathComponent)” has no rows to import.")))
            return
        }
        let sheetModel = ImportSheetModel(
            table: table, fileName: url.lastPathComponent, entity: entity, model: model, timeZone: context.timeZone,
            editing: context.editing)
        let sheet = ImportSheetController(sheetModel)
        sheetModel.onFinish = { [weak sheet] _ in
            if let sheet { content.dismiss(sheet) }
        }
        content.presentAsSheet(sheet)
    }
}
