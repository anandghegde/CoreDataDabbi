import DabbiBase
import Foundation

/// An import file, parsed: its columns, and its rows as cells (IMX-2).
///
/// A cell is a `JSONNode` whichever the file was. A CSV cell is a string, or `.null` for a field left empty and
/// unquoted — the empty string is written `""` — so that the two read back apart, as `CSVExporter` writes them.
/// A JSON cell is whatever the member was: a number, an object for a composite or a reference, an array for a
/// to-many.
public struct ImportTable: Sendable, Hashable {
    public struct Row: Sendable, Hashable {
        /// A CSV record's first line, counting the header as line 1; a JSON object's position in the array, from 1.
        public var line: Int
        /// Column → cell. A column a row has no cell for is not here: a short CSV record, a JSON object without it.
        public var cells: [String: JSONNode]

        public init(line: Int, cells: [String: JSONNode]) {
            self.line = line
            self.cells = cells
        }
    }

    /// In the file's order: the header's, or the order JSON members are first met in.
    public var columns: [String]
    public var rows: [Row]

    public init(columns: [String], rows: [Row]) {
        self.columns = columns
        self.rows = rows
    }

    public enum Format: String, Sendable, Hashable, CaseIterable {
        case csv, json
    }

    /// Reads `url` as `format`: JSON for a `.json` file, CSV — with the separator its header suggests — for
    /// anything else, when not given.
    public static func read(_ url: URL, format: Format? = nil, separator: Character? = nil) throws -> ImportTable {
        let text: String
        do {
            text = try String(contentsOf: url, encoding: .utf8)
        } catch {
            throw DabbiError(
                .importUnreadable, "“\(url.lastPathComponent)” could not be read as UTF-8 text.",
                arguments: ["path": url.path], recovery: ["Save the file as UTF-8, then import it again."],
                underlying: error)
        }
        switch format ?? (url.pathExtension.lowercased() == "json" ? .json : .csv) {
        case .json: return try json(text)
        case .csv: return try csv(text, separator: separator ?? guessSeparator(text))
        }
    }

    // MARK: CSV

    /// The separator the first line uses most of: a comma, a semicolon or a tab.
    public static func guessSeparator(_ text: String) -> Character {
        let firstLine = text.prefix { $0 != "\n" && $0 != "\r\n" && $0 != "\r" }
        let counts = [",", ";", "\t"].map { separator in
            (separator, firstLine.count { $0 == Character(separator) })
        }
        return Character(counts.max { $0.1 < $1.1 }.map { $0.1 > 0 ? $0.0 : "," } ?? ",")
    }

    /// RFC 4180, with any separator: fields may be quoted, and a quoted field may hold separators, quotes
    /// (doubled) and line breaks. The first record is the header. Lines end with CR LF, LF or CR.
    ///
    /// Throws `.importUnreadable` for a quote left open, and for a header with no columns or a column twice.
    public static func csv(_ text: String, separator: Character = ",") throws -> ImportTable {
        guard let separator = separator.unicodeScalars.first else { return ImportTable(columns: [], rows: []) }
        var scalars = Substring(text).unicodeScalars[...]
        if scalars.first == "\u{FEFF}" { scalars = scalars.dropFirst() }

        var records: [(line: Int, fields: [String?])] = []
        var fields: [String?] = []
        var field = String.UnicodeScalarView()
        var isQuoted = false, inQuotes = false, fieldStarted = false
        var line = 1, recordLine = 1
        var iterator = scalars.makeIterator()
        var pending: Unicode.Scalar? = nil
        func next() -> Unicode.Scalar? {
            if let scalar = pending {
                pending = nil
                return scalar
            }
            return iterator.next()
        }
        func endField() {
            fields.append(isQuoted || !field.isEmpty ? String(field) : nil)
            field = String.UnicodeScalarView()
            isQuoted = false
            fieldStarted = false
        }
        func endRecord() {
            endField()
            // A blank line is no record.
            if !(fields.count == 1 && fields[0] == nil) { records.append((recordLine, fields)) }
            fields = []
        }
        while let scalar = next() {
            if inQuotes {
                if scalar == "\"" {
                    let following = next()
                    if following == "\"" {
                        field.append("\"")
                    } else {
                        inQuotes = false
                        pending = following
                    }
                } else {
                    field.append(scalar)
                    if scalar == "\n" {
                        line += 1
                    } else if scalar == "\r" {
                        let following = next()
                        if following == "\n" { field.append("\n") } else { pending = following }
                        line += 1
                    }
                }
                continue
            }
            switch scalar {
            case "\"" where !fieldStarted:
                isQuoted = true
                inQuotes = true
                fieldStarted = true
            case separator:
                endField()
            case "\r", "\n":
                if scalar == "\r" {
                    let following = next()
                    if following != "\n" { pending = following }
                }
                endRecord()
                line += 1
                recordLine = line
            default:
                field.append(scalar)
                fieldStarted = true
            }
        }
        if inQuotes {
            throw DabbiError(
                .importUnreadable, "The CSV file ends inside a quoted field that begins on line \(recordLine).",
                arguments: ["line": String(recordLine)],
                recovery: ["Close the quotes, or double a quote that is part of a field."])
        }
        if fieldStarted || !fields.isEmpty { endRecord() }

        guard let header = records.first else { return ImportTable(columns: [], rows: []) }
        let columns = header.fields.map { $0 ?? "" }
        try checkColumns(columns)
        let rows = records.dropFirst().map { record in
            var cells: [String: JSONNode] = [:]
            for (column, value) in zip(columns, record.fields) { cells[column] = value.map(JSONNode.string) ?? .null }
            return Row(line: record.line, cells: cells)
        }
        return ImportTable(columns: columns, rows: rows)
    }

    private static func checkColumns(_ columns: [String]) throws {
        if let empty = columns.firstIndex(of: "") {
            throw DabbiError(
                .importUnreadable, "Column \(empty + 1) of the header has no name.",
                recovery: ["Give every column a name in the first line: the name of the property it is for."])
        }
        var seen = Set<String>()
        for column in columns where !seen.insert(column).inserted {
            throw DabbiError(
                .importUnreadable, "The header names the column “\(column)” twice.", arguments: ["column": column])
        }
    }

    // MARK: JSON

    /// An array of objects, one a row — or one object, a row on its own — as `JSONExporter` writes them.
    public static func json(_ text: String) throws -> ImportTable {
        let root: JSONNode
        do {
            root = try JSONNode.parse(text)
        } catch let error as DabbiError {
            throw DabbiError(.importUnreadable, "The file is not JSON. \(error.message)", underlying: error)
        }
        let items: [JSONNode]
        switch root {
        case .array(let array): items = array
        case .object: items = [root]
        default:
            throw DabbiError(
                .importUnreadable, "The JSON file holds neither an array of objects nor an object.",
                recovery: ["Import an array with one object per row, as an export writes."])
        }
        var columns: [String] = []
        var seen = Set<String>()
        var rows: [Row] = []
        for (index, item) in items.enumerated() {
            guard case .object(let members) = item else {
                throw DabbiError(
                    .importUnreadable, "Item \(index + 1) of the array is not an object.",
                    arguments: ["line": String(index + 1)])
            }
            var cells: [String: JSONNode] = [:]
            for (key, value) in members {
                if seen.insert(key).inserted { columns.append(key) }
                cells[key] = value
            }
            rows.append(Row(line: index + 1, cells: cells))
        }
        return ImportTable(columns: columns, rows: rows)
    }
}
