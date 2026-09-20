import Foundation

enum Output {
    /// Pretty, key-sorted JSON on stdout.
    static func printJSON(_ object: Any) throws {
        let data = try JSONSerialization.data(
            withJSONObject: object, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
        print(String(decoding: data, as: UTF8.self))
    }

    static func printJSON(_ value: some Encodable) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        encoder.dateEncodingStrategy = .iso8601
        print(String(decoding: try encoder.encode(value), as: UTF8.self))
    }

    /// A plain text table. Cells are single-line and cut at `maxWidth`; numbers are not right-aligned, on purpose:
    /// the output is for reading and `--json` is for scripts.
    static func table(headers: [String], rows: [[String]], maxWidth: Int = 40) -> String {
        let cells = ([headers] + rows).map { $0.map { clip($0, to: maxWidth) } }
        let widths = headers.indices.map { column in cells.map { $0[column].count }.max() ?? 0 }
        func line(_ row: [String]) -> String {
            zip(row, widths).map { $0.padding(toLength: $1, withPad: " ", startingAt: 0) }
                .joined(separator: "  ").trimmingCharacters(in: .whitespaces)
        }
        let rule = widths.map { String(repeating: "─", count: $0) }.joined(separator: "  ")
        return ([line(cells[0]), rule] + cells.dropFirst().map(line)).joined(separator: "\n")
    }

    private static func clip(_ text: String, to width: Int) -> String {
        let flat = text.replacing(/\s+/, with: " ")
        return flat.count > width ? flat.prefix(width - 1) + "…" : flat
    }
}
