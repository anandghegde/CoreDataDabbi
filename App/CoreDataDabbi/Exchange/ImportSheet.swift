import AppKit
import DabbiKit
import SwiftUI

/// Data › Import (IMX-2 – IMX-4): a file's columns mapped onto the entity's properties, with how the first row
/// reads under each, a dry run's report row by row, and the import itself — staged, for Commit to write.
@MainActor
@Observable
final class ImportSheetModel {
    /// A column of the file, as the mapping table lists it.
    struct ColumnRow: Identifiable, Hashable {
        let id: Int
        let name: String
    }

    /// A row of the report, as its table lists it.
    struct ReportLine: Identifiable, Hashable {
        let id: Int
        let result: ImportRowResult
    }

    let table: ImportTable
    let fileName: String
    let entity: EntityDescription
    let model: ModelDescription
    /// What a column can be mapped onto, in the pop-up's order.
    let targets: [ImportMapping.Target]
    let columnRows: [ColumnRow]

    /// Changing the mapping or the options makes the last report stale: it is dropped.
    var mapping: ImportMapping { didSet { report = nil } }
    var mode: ImportOptions.Mode = .allOrNothing { didSet { report = nil } }
    var upsert = false { didSet { report = nil } }

    /// The last dry run's report, or an import's that staged nothing.
    private(set) var report: ImportReport?
    private(set) var isRunning = false
    /// Why the last dry run could not run. An import that cannot says so through the window, as any edit does.
    private(set) var problem: String?

    /// The report, or `nil` for Cancel. Called once the rows are staged.
    @ObservationIgnored var onFinish: (ImportReport?) -> Void = { _ in }
    @ObservationIgnored private let editing: EditingSession
    /// What is running now; the tests wait for it.
    @ObservationIgnored private(set) var work: Task<Void, Never>?

    init(
        table: ImportTable, fileName: String, entity: EntityDescription, model: ModelDescription, timeZone: TimeZone,
        editing: EditingSession
    ) {
        self.table = table
        self.fileName = fileName
        self.entity = entity
        self.model = model
        self.editing = editing
        targets = ImportMapping.targets(for: entity, model: model)
        columnRows = table.columns.enumerated().map { ColumnRow(id: $0.offset, name: $0.element) }
        mapping = ImportMapping.automatic(for: table, entity: entity, timeZone: timeZone)
    }

    var title: String { String(localized: "Import “\(fileName)” into \(entity.name)") }

    var subtitle: String {
        String(localized: "Rows: \(table.rows.count) · Columns: \(table.columns.count)")
    }

    /// Whether anything would be set: at least one column is mapped onto a property.
    var canRun: Bool { !isRunning && mapping.columns.contains { $0.property != nil } }

    var options: ImportOptions {
        ImportOptions(mode: mode, upsert: upsert, actionName: String(localized: "Import \(entity.name)"))
    }

    // MARK: Mapping

    func target(ofColumn index: Int) -> ImportMapping.Target { mapping.columns[index].target }

    func setTarget(_ target: ImportMapping.Target, ofColumn index: Int) {
        mapping.columns[index].target = target
    }

    /// The first row's cell as the column reads it, and whether it can be.
    func preview(ofColumn index: Int) -> (text: String, isValid: Bool) {
        guard let row = table.rows.first else { return ("", true) }
        switch mapping.coerce(row, column: mapping.columns[index], model: model) {
        case .skipped: return ("—", true)
        case .id(let url): return (url.absoluteString, true)
        case .value(let value): return (value.previewText(timeZone: mapping.timeZone), true)
        case .invalid(let message): return (message, false)
        }
    }

    /// A target as the pop-up names it.
    static func name(of target: ImportMapping.Target) -> String {
        switch target {
        case .ignored: String(localized: "Do Not Import")
        case .relationshipKey(let name, let key): String(localized: "\(name) by \(key)")
        default: ImportMapping.name(of: target)
        }
    }

    // MARK: Running

    /// Tries every row in a scratch context: the report says what an import would do, and nothing is staged.
    func dryRun() {
        guard canRun else { return }
        let rows = mapping.rows(from: table, model: model)
        let (entity, options) = (entity.name, options)
        isRunning = true
        problem = nil
        work = Task { [weak self, editing] in
            do {
                let report = try await editing.previewImport(rows, into: entity, options: options)
                self?.isRunning = false
                if let report { self?.show(report) }
            } catch {
                self?.isRunning = false
                self?.problem = DabbiError.wrapping(error).message
            }
        }
    }

    /// Stages the rows as one edit. The sheet closes once they are; an all-or-nothing import with a row that
    /// fails stages nothing and shows why.
    func importRows() {
        guard canRun else { return }
        let rows = mapping.rows(from: table, model: model)
        isRunning = true
        problem = nil
        editing.importRows(rows, into: entity.name, options: options) { [weak self] report in
            guard let self else { return }
            if report.isApplied {
                self.onFinish(report)
            } else {
                self.show(report)
            }
        }
        work = Task { [weak self, editing] in
            await editing.whenSettled()
            self?.isRunning = false
        }
    }

    func cancel() { onFinish(nil) }

    private func show(_ report: ImportReport) {
        self.report = report
    }

    // MARK: Report

    var reportLines: [ReportLine] {
        (report?.rows ?? []).enumerated().map { ReportLine(id: $0.offset, result: $0.element) }
    }

    /// What the report comes to, in a line.
    var summary: String? {
        guard let report else { return nil }
        return String(
            localized:
                "New: \(report.count(.inserted)) · Updated: \(report.count(.updated)) · Unchanged: \(report.count(.unchanged)) · Failed: \(report.count(.failed))"
        )
    }

    /// Why an import staged nothing, when a row failing is why.
    var reportNote: String? {
        guard let report, !report.isApplied, mode == .allOrNothing, !report.failed.isEmpty,
            report.rows.contains(where: { $0.outcome != .failed })
        else { return nil }
        return String(localized: "Nothing is imported while a row fails. Skip failing rows to import the rest.")
    }

    static func name(of outcome: ImportRowResult.Outcome) -> String {
        switch outcome {
        case .inserted: String(localized: "New")
        case .updated: String(localized: "Updated")
        case .unchanged: String(localized: "Unchanged")
        case .failed: String(localized: "Failed")
        }
    }

    static func issueText(_ result: ImportRowResult) -> String {
        result.issues.map(\.description).joined(separator: "; ")
    }
}

struct ImportSheet: View {
    @Bindable var model: ImportSheetModel

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text(model.title).font(.headline)
                Text(model.subtitle).font(.callout).foregroundStyle(.secondary)
            }
            mappingTable
            Form {
                Picker(String(localized: "Rows that fail:"), selection: $model.mode) {
                    Text(String(localized: "Import Nothing")).tag(ImportOptions.Mode.allOrNothing)
                    Text(String(localized: "Skip Them, Import the Rest")).tag(ImportOptions.Mode.skipInvalid)
                }
                .fixedSize()
                Toggle(String(localized: "Update objects that match by URI or by a unique key"), isOn: $model.upsert)
            }
            Text(
                String(
                    localized:
                        "A to-many column read by key takes its keys separated by “|”. Imported rows are staged: Commit writes them."
                )
            )
            .font(.callout)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
            if let problem = model.problem {
                Text(problem).font(.callout).foregroundStyle(.red)
            }
            if let summary = model.summary {
                Text(summary).font(.callout.weight(.medium))
                if let note = model.reportNote {
                    Text(note).font(.callout).fixedSize(horizontal: false, vertical: true)
                }
                reportTable
            }
            HStack {
                if model.isRunning { ProgressView().controlSize(.small) }
                Spacer()
                Button(String(localized: "Cancel"), role: .cancel) { model.cancel() }
                    .keyboardShortcut(.cancelAction)
                Button(String(localized: "Dry Run")) { model.dryRun() }
                    .disabled(!model.canRun)
                Button(String(localized: "Import")) { model.importRows() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(!model.canRun)
            }
        }
        .padding(20)
        .frame(width: 680)
    }

    private var mappingTable: some View {
        Table(model.columnRows) {
            TableColumn(String(localized: "Column")) { row in Text(row.name) }
                .width(min: 90, ideal: 140)
            TableColumn(String(localized: "Imports Into")) { row in
                Picker(
                    String(localized: "Property for \(row.name)"),
                    selection: Binding(
                        get: { model.target(ofColumn: row.id) }, set: { model.setTarget($0, ofColumn: row.id) })
                ) {
                    ForEach(model.targets, id: \.self) { target in
                        Text(ImportSheetModel.name(of: target)).tag(target)
                    }
                }
                .labelsHidden()
                .accessibilityLabel(String(localized: "Property for \(row.name)"))
            }
            .width(min: 140, ideal: 200)
            TableColumn(String(localized: "First Row")) { row in
                let preview = model.preview(ofColumn: row.id)
                Text(preview.text)
                    .foregroundStyle(preview.isValid ? Color.primary : Color.red)
                    .lineLimit(1)
                    .help(preview.text)
            }
        }
        .frame(height: 200)
        .accessibilityLabel(String(localized: "Column mapping"))
    }

    private var reportTable: some View {
        Table(model.reportLines) {
            TableColumn(String(localized: "Line")) { line in Text(line.result.line, format: .number) }
                .width(50)
            TableColumn(String(localized: "Result")) { line in
                Text(ImportSheetModel.name(of: line.result.outcome))
                    .foregroundStyle(line.result.outcome == .failed ? Color.red : Color.primary)
            }
            .width(80)
            TableColumn(String(localized: "Issues")) { line in
                Text(ImportSheetModel.issueText(line.result)).lineLimit(2).help(ImportSheetModel.issueText(line.result))
            }
        }
        .frame(height: 140)
        .accessibilityLabel(String(localized: "Import report"))
    }
}

final class ImportSheetController: NSHostingController<ImportSheet> {
    let model: ImportSheetModel

    init(_ model: ImportSheetModel) {
        self.model = model
        super.init(rootView: ImportSheet(model: model))
        sizingOptions = [.preferredContentSize]
        title = model.title
    }

    @available(*, unavailable)
    @MainActor required dynamic init?(coder: NSCoder) { fatalError("not in a nib") }
}
