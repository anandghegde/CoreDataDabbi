import DabbiBase
import DabbiModel
import Foundation

/// A JSON array with one object per record (IMX-1): `$id` and `$entity` first, then the fields in the model's
/// order.
///
/// What JSON has no type for is written so that import can tell it apart:
/// - numbers are numbers, with every digit a Decimal has; a Double that is not finite is the string `"nan"`,
///   `"inf"` or `"-inf"`, which is how `ValueText` reads it back;
/// - dates are ISO 8601 strings, UUIDs and URIs strings, bytes Base64 strings;
/// - an object not written out is `{"$ref": uri, "$entity": name}`; bytes left out are `{"$blob": {…}}`, and a
///   to-many that was not followed `{"$count": n}` — neither reads back as a value.
public struct JSONExporter: Exporter {
    public var timeZone: TimeZone

    public init(timeZone: TimeZone = .gmt) {
        self.timeZone = timeZone
    }

    public var formatName: String { "JSON" }
    public var fileExtension: String { "json" }

    public func header(for layout: ExportLayout) -> String { "[" }

    public func record(_ record: ExportRecord, index: Int, layout: ExportLayout) -> String {
        var output = index == 0 ? "\n  " : ",\n  "
        Self.node(for: record, timeZone: timeZone).write(to: &output, indent: 2, level: 1)
        return output
    }

    public func footer(for layout: ExportLayout, count: Int) -> String { count == 0 ? "]\n" : "\n]\n" }

    public static let referenceKey = "$ref"
    public static let countKey = "$count"
    public static let blobKey = "$blob"

    public static func node(for record: ExportRecord, timeZone: TimeZone) -> JSONNode {
        .object(
            [
                (ExportLayout.idColumn, .string(record.id.absoluteString)),
                (ExportLayout.entityColumn, .string(record.entity)),
            ] + record.fields.map { ($0.name, node(for: $0.value, timeZone: timeZone)) })
    }

    public static func node(for value: ExportValue, timeZone: TimeZone) -> JSONNode {
        switch value {
        case .scalar(let value): node(for: value, timeZone: timeZone)
        case .data(let data): .string(data.base64EncodedString())
        case .blob(let summary):
            .object([
                (
                    blobKey,
                    .object(
                        [("byteCount", .number(String(summary.byteCount)))]
                            + (summary.sniffedType.map { [("type", JSONNode.string($0.rawValue))] } ?? [])
                    )
                )
            ])
        case .composite(let elements): .object(elements.map { ($0.name, node(for: $0.value, timeZone: timeZone)) })
        case .nothing: .null
        case .reference(let url, let entity):
            .object([(referenceKey, .string(url.absoluteString)), (ExportLayout.entityColumn, .string(entity))])
        case .object(let record): node(for: record, timeZone: timeZone)
        case .objects(let values): .array(values.map { node(for: $0, timeZone: timeZone) })
        case .count(let count): .object([(countKey, .number(String(count)))])
        }
    }

    public static func node(for value: Value, timeZone: TimeZone) -> JSONNode {
        switch value {
        case .null: .null
        case .bool(let flag): .bool(flag)
        case .int(let number): .number(String(number))
        case .double(let number) where number.isFinite: .number(String(number))
        case .decimal(let number) where number.isFinite: .number(NSDecimalNumber(decimal: number).stringValue)
        case .double, .decimal, .string, .date, .uuid, .url:
            .string(ValueText.text(for: value, timeZone: timeZone))
        case .blob(let summary): node(for: ExportValue.blob(summary), timeZone: timeZone)
        case .composite(let elements):
            .object(elements.sorted { $0.key < $1.key }.map { ($0.key, node(for: $0.value, timeZone: timeZone)) })
        case .toOne(let ref, _):
            ref.map { node(for: .reference($0.uri, entity: $0.entity), timeZone: timeZone) } ?? .null
        case .toOneInserted(let object, _): node(for: .reference(object.uri, entity: object.entity), timeZone: timeZone)
        case .toMany(let count): node(for: .count(count), timeZone: timeZone)
        }
    }
}
