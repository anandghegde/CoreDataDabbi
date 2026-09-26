import DabbiBase
import DabbiModel
import Foundation

/// A field as the text a table cell holds: `nil` for no value, which a table writes differently from the empty
/// string where it can.
///
/// Scalars are written as `ValueText` writes them — numbers with a full stop, dates in ISO 8601 with their offset —
/// so that importing the file reads back the same values. Bytes are Base64; an object is its URI, and a to-many
/// its objects' URIs separated by spaces.
public enum ExportCellText {
    public static func text(for value: ExportValue?, timeZone: TimeZone) -> String? {
        switch value {
        case nil, .nothing?, .scalar(.null)?: nil
        case .scalar(let value): ValueText.text(for: value, timeZone: timeZone)
        case .data(let data): data.base64EncodedString()
        // Left out on purpose: nothing, rather than a summary that would read back as the bytes.
        case .blob: nil
        case .composite(let elements):
            JSONExporter.node(for: .composite(elements), timeZone: timeZone).text(indent: 0)
        case .reference(let url, _): url.absoluteString
        case .object(let record): record.id.absoluteString
        case .objects(let values): values.compactMap { text(for: $0, timeZone: timeZone) }.joined(separator: " ")
        case .count(let count): String(count)
        }
    }
}

/// Comma-separated values, RFC 4180 (IMX-1) — or any other separator: a tab makes the TSV that Copy As writes
/// (BRW-12).
///
/// A field is quoted when it has to be: it holds the separator, a quote, a line break, or space at either end.
/// The empty string is written as `""` and no value as nothing at all, so the two read back apart.
public struct CSVExporter: Exporter {
    public var separator: Character
    public var includesHeader: Bool
    public var lineEnding: String
    public var timeZone: TimeZone

    public init(
        separator: Character = ",", includesHeader: Bool = true, lineEnding: String = "\r\n", timeZone: TimeZone = .gmt
    ) {
        self.separator = separator
        self.includesHeader = includesHeader
        self.lineEnding = lineEnding
        self.timeZone = timeZone
    }

    /// Tab-separated, for the pasteboard: a spreadsheet pastes it into cells.
    public static func tsv(timeZone: TimeZone = .gmt) -> CSVExporter {
        CSVExporter(separator: "\t", lineEnding: "\n", timeZone: timeZone)
    }

    public var formatName: String { separator == "\t" ? "TSV" : "CSV" }
    public var fileExtension: String { separator == "\t" ? "tsv" : "csv" }

    public func header(for layout: ExportLayout) -> String {
        guard includesHeader else { return "" }
        return line(layout.columns.map { quoted($0.name) })
    }

    public func record(_ record: ExportRecord, index: Int, layout: ExportLayout) -> String {
        line(
            layout.columns.map { column in
                ExportCellText.text(for: record.value(at: column.path), timeZone: timeZone).map(quoted) ?? ""
            })
    }

    public func footer(for layout: ExportLayout, count: Int) -> String { "" }

    private func line(_ fields: [String]) -> String {
        fields.joined(separator: String(separator)) + lineEnding
    }

    /// The field, quoted if it must be. The empty string always is: unquoted, it would read back as no value.
    func quoted(_ field: String) -> String {
        let needsQuotes =
            field.isEmpty || field.first == " " || field.last == " "
            || field.contains { $0 == separator || $0 == "\"" || $0 == "\n" || $0 == "\r" }
        guard needsQuotes else { return field }
        return "\"" + field.replacingOccurrences(of: "\"", with: "\"\"") + "\""
    }
}

/// A GitHub-flavoured Markdown table, for pasting rows into an issue or a note (BRW-12).
///
/// The smallest exporter, and the one to copy for a new format.
public struct MarkdownTableExporter: Exporter {
    public var timeZone: TimeZone

    public init(timeZone: TimeZone = .gmt) {
        self.timeZone = timeZone
    }

    public var formatName: String { "Markdown" }
    public var fileExtension: String { "md" }

    public func header(for layout: ExportLayout) -> String {
        row(layout.columns.map(\.name)) + row(layout.columns.map { _ in "---" })
    }

    public func record(_ record: ExportRecord, index: Int, layout: ExportLayout) -> String {
        row(
            layout.columns.map {
                ExportCellText.text(for: record.value(at: $0.path), timeZone: timeZone).map(escaped) ?? ""
            })
    }

    public func footer(for layout: ExportLayout, count: Int) -> String { "" }

    private func row(_ cells: [String]) -> String {
        "| " + cells.joined(separator: " | ") + " |\n"
    }

    /// A pipe would end the cell, and a line break the row.
    private func escaped(_ text: String) -> String {
        text.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "|", with: "\\|")
            .replacingOccurrences(of: "\r\n", with: "<br>").replacingOccurrences(of: "\n", with: "<br>")
            .replacingOccurrences(of: "\r", with: "<br>")
    }
}
