import DabbiKit
import Foundation

/// Which rows Data › Export writes (IMX-1).
enum ExportScope: String, CaseIterable, Sendable {
    /// The rows selected in the grid, in its order.
    case selection
    /// What the grid shows: its filter, its sort, a template's limit, and its visible columns in their order.
    case view
    /// Every object of the entity and its sub-entities, every stored property.
    case entity
}

/// The file formats an export writes.
enum ExportFormat: String, CaseIterable, Sendable {
    case csv, json

    var name: String {
        switch self {
        case .csv: String(localized: "CSV")
        case .json: String(localized: "JSON")
        }
    }

    var fileExtension: String { rawValue }
}

/// What Copy As puts on the pasteboard (BRW-12).
enum CopyFormat: String, CaseIterable, Sendable {
    case tsv, json, markdown
}

/// The separators a CSV file can be written with.
enum CSVSeparator: String, CaseIterable, Sendable {
    case comma = ",", semicolon = ";", tab = "\t"

    var name: String {
        switch self {
        case .comma: String(localized: "Comma")
        case .semicolon: String(localized: "Semicolon")
        case .tab: String(localized: "Tab")
        }
    }
}

/// What the save panel asks for besides the file: how the rows are written.
struct ExportSettings: Hashable, Sendable {
    var separator: CSVSeparator = .comma
    var includesHeader = true
    var relationships: ExportOptions.Relationships = .references
    var includesBinaryData = true

    /// The relationship choices a format offers, in the order the pop-up lists them. A table has one cell per
    /// relationship, so embedding is for JSON.
    static func relationshipChoices(for format: ExportFormat) -> [ExportOptions.Relationships] {
        switch format {
        case .csv: [.omitted, .counts, .references]
        case .json: [.omitted, .counts, .references, .embedded(depth: 1), .embedded(depth: 2)]
        }
    }

    static func name(of relationships: ExportOptions.Relationships) -> String {
        switch relationships {
        case .omitted: String(localized: "Leave Out")
        case .counts: String(localized: "Counts Only")
        case .references: String(localized: "Object URIs")
        case .embedded(let depth) where depth <= 1: String(localized: "Embed Related Objects")
        case .embedded(let depth): String(localized: "Embed \(depth) Levels Deep")
        }
    }

    func exporter(for format: ExportFormat, timeZone: TimeZone) -> any Exporter {
        switch format {
        case .csv:
            CSVExporter(separator: Character(separator.rawValue), includesHeader: includesHeader, timeZone: timeZone)
        case .json: JSONExporter(timeZone: timeZone)
        }
    }
}

/// Turns what the window shows into what the exchange engine reads, for export and Copy As (IMX-1, BRW-12, TRK-5).
///
/// Everything here is decided from the context and the grid, without a window, so that the tests can check it.
@MainActor
enum ExportCommands {
    /// What `scope` reads, or `nil` when there is nothing to read: no entity on screen, or no rows selected.
    static func source(for scope: ExportScope, context: ProjectContext, selection: [ObjectRef]) -> ExportSource? {
        guard let entity = context.selectedEntity else { return nil }
        switch scope {
        case .selection:
            return selection.isEmpty ? nil : .objects(selection, entity: entity)
        case .view:
            return .fetch(
                FetchSpec(
                    entity: entity, predicate: context.shownFetchFilter, sort: context.shownLayout.sort,
                    limit: context.navigation.current?.fetchRequest?.limit))
        case .entity:
            return .fetch(FetchSpec(entity: entity))
        }
    }

    /// The properties the grid shows, in its order: what the selection and the view are exported with.
    static func properties(of columns: [GridColumn]) -> [String] {
        columns.visible.compactMap { column in
            switch column.kind {
            case .objectID, .entity: nil
            case .attribute, .relationship: column.property
            }
        }
    }

    /// The options for `scope`: the grid's columns for what is on screen, everything for the whole entity.
    static func options(
        for scope: ExportScope, settings: ExportSettings, columns: [GridColumn]
    ) -> ExportOptions {
        ExportOptions(
            properties: scope == .entity ? nil : properties(of: columns), relationships: settings.relationships,
            includesBinaryData: settings.includesBinaryData)
    }

    /// The name the save panel suggests.
    static func fileName(entity: String, scope: ExportScope, format: ExportFormat) -> String {
        let base =
            switch scope {
            case .selection: String(localized: "\(entity) Selection")
            case .view, .entity: entity
            }
        return base + "." + format.fileExtension
    }

    /// The selected rows as `format` text: what Copy As puts on the pasteboard. Relationships are copied as
    /// the grid shows them, and bytes are left out — a pasteboard is no place for a photo library.
    static func copyText(
        _ format: CopyFormat, of selection: [ObjectRef], entity: String, columns: [GridColumn],
        session: StoreSession, timeZone: TimeZone
    ) async throws -> String {
        let reader = ExportReader(
            session: session,
            options: ExportOptions(
                properties: properties(of: columns), relationships: .counts, includesBinaryData: false))
        let source = ExportSource.objects(selection, entity: entity)
        switch format {
        case .tsv: return try await reader.text(source, as: CSVExporter.tsv(timeZone: timeZone))
        case .json: return try await reader.text(source, as: JSONExporter(timeZone: timeZone))
        case .markdown: return try await reader.text(source, as: MarkdownTableExporter(timeZone: timeZone))
        }
    }

    /// The selected objects' URIs, one a line: what Copy Object URI puts on the pasteboard.
    static func uriText(of selection: [ObjectRef]) -> String {
        selection.map(\.uri.absoluteString).joined(separator: "\n")
    }

    /// The tracked session's versions, oldest first, as the log on screen holds them (TRK-5). The tracker's own
    /// log is gone once it stops; this one stays until it is cleared or closed.
    static func trackedSession(_ log: TrackingLog) -> TrackedSessionExport {
        TrackedSessionExport(
            versions: log.entries.flatMap(\.versions).map {
                VersionLog.Version(sequence: $0.sequence, at: $0.at, event: $0.event)
            })
    }
}
