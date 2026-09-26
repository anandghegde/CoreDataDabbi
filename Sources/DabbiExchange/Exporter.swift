import DabbiBase
import Foundation

/// A file format rows can be written in (IMX-1, BRW-12, ARCHITECTURE.md §6.9).
///
/// An exporter turns records into text and knows nothing of stores: `ExportReader` reads the records, and hands
/// them over one at a time, so a million rows are never all in memory. A new format is one type with three
/// methods — see `MarkdownTableExporter` for the smallest.
///
/// The output is `header`, then `record` for each record, then `footer`, concatenated.
public protocol Exporter: Sendable {
    /// What the format is called, as a menu names it.
    var formatName: String { get }
    /// The file name extension, without the dot.
    var fileExtension: String { get }

    /// What comes before the first record: a header row, an opening bracket.
    func header(for layout: ExportLayout) -> String
    /// One record. `index` counts from 0, for a format that separates records.
    func record(_ record: ExportRecord, index: Int, layout: ExportLayout) -> String
    /// What comes after the last record.
    func footer(for layout: ExportLayout, count: Int) -> String
}

extension Exporter {
    /// Every record at once, for what is small enough to hold: a copy to the pasteboard, a test.
    public func text(for records: [ExportRecord], layout: ExportLayout) -> String {
        var output = header(for: layout)
        for (index, record) in records.enumerated() {
            output += self.record(record, index: index, layout: layout)
        }
        return output + footer(for: layout, count: records.count)
    }
}

/// The columns a tabular format writes, in order.
///
/// JSON writes a record's fields as they are, nested; CSV, TSV and Markdown need one column per value, which is
/// what this is: `$id`, `$entity`, then each property, with a composite spread over one column per element
/// (`address.city`) so that it reads back into the same attribute.
public struct ExportLayout: Sendable, Hashable {
    public struct Column: Sendable, Hashable {
        /// The header: the property's name, a path into a composite, or `$id` / `$entity`.
        public var name: String
        /// The field path within a record: `[property]`, or `[composite, element, …]`.
        public var path: [String]

        public init(name: String, path: [String]) {
            self.name = name
            self.path = path
        }

        public init(_ name: String) {
            self.init(name: name, path: name.split(separator: ".").map(String.init))
        }
    }

    /// The entity the records are of — or the root of them, when sub-entities are among them.
    public var entity: String
    public var columns: [Column]

    public init(entity: String, columns: [Column]) {
        self.entity = entity
        self.columns = columns
    }

    public static let idColumn = "$id"
    public static let entityColumn = "$entity"
}

/// One object, ready to be written: its identity and its fields in order.
public struct ExportRecord: Sendable, Hashable {
    public var id: URL
    public var entity: String
    public var fields: [ExportField]

    public init(id: URL, entity: String, fields: [ExportField]) {
        self.id = id
        self.entity = entity
        self.fields = fields
    }

    /// The value at a path of field names, into composites; `nil` where there is none.
    public func value(at path: [String]) -> ExportValue? {
        guard let first = path.first else { return nil }
        if path == [ExportLayout.idColumn] { return .scalar(.url(id)) }
        if path == [ExportLayout.entityColumn] { return .scalar(.string(entity)) }
        var value = fields.first { $0.name == first }?.value
        for component in path.dropFirst() {
            guard case .composite(let elements) = value else { return nil }
            value = elements.first { $0.name == component }?.value
        }
        return value
    }
}

public struct ExportField: Sendable, Hashable {
    public var name: String
    public var value: ExportValue

    public init(_ name: String, _ value: ExportValue) {
        self.name = name
        self.value = value
    }
}

/// A field's value, as far as an export follows it.
public indirect enum ExportValue: Sendable, Hashable {
    /// An attribute's value: never a blob, a composite or a relationship, which have cases of their own.
    case scalar(Value)
    /// A binary or transformable attribute's bytes: Base64 in the file.
    case data(Data)
    /// Bytes that were left out: what they are, not what they say.
    case blob(BlobSummary)
    case composite([ExportField])
    /// A to-one that leads nowhere.
    case nothing
    /// An object named by its URI, not written out: beyond the depth, or already on the way to it (a cycle).
    case reference(URL, entity: String)
    /// An object written out in full.
    case object(ExportRecord)
    /// A to-many's objects, each a `.reference` or an `.object`, in the relationship's order.
    case objects([ExportValue])
    /// A to-many that was not followed: how many objects it leads to.
    case count(Int)
}
