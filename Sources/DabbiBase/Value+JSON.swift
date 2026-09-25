import Foundation

/// Options for the plain JSON rendering shared by the CLI, the MCP server and the JSON exporter.
public struct JSONRenderOptions: Sendable, Hashable {
    /// Time zone for ISO 8601 dates. Dates always carry an explicit offset.
    public var timeZone: TimeZone
    public var includeFractionalSeconds: Bool

    public init(timeZone: TimeZone = .gmt, includeFractionalSeconds: Bool = true) {
        self.timeZone = timeZone
        self.includeFractionalSeconds = includeFractionalSeconds
    }
}

extension Value {
    /// A `JSONSerialization`-compatible object in the *plain* shape people expect from an export:
    /// scalars as JSON scalars, ISO 8601 dates, and small `$`-prefixed objects for what JSON cannot express.
    ///
    /// (The synthesised `Codable` conformance is the lossless wire format; this one is for humans and scripts.)
    public func jsonObject(options: JSONRenderOptions = .init()) -> Any {
        switch self {
        case .null: return NSNull()
        case .bool(let value): return value
        case .int(let value): return NSNumber(value: value)
        case .double(let value):
            // JSON has no NaN or infinities.
            return value.isFinite ? NSNumber(value: value) : String(value)
        case .decimal(let value): return NSDecimalNumber(decimal: value)
        case .string(let value): return value
        case .date(let value):
            // Not `.time(includingFractionalSeconds:)`: on a fresh style that drops the date.
            return value.formatted(
                Date.ISO8601FormatStyle(
                    includingFractionalSeconds: options.includeFractionalSeconds, timeZone: options.timeZone))
        case .uuid(let value): return value.uuidString
        case .url(let value): return value.absoluteString
        case .blob(let summary):
            var blob: [String: Any] = ["byteCount": summary.byteCount, "external": summary.isExternal]
            if let type = summary.sniffedType { blob["type"] = type.rawValue }
            return ["$blob": blob]
        case .composite(let elements):
            return elements.mapValues { $0.jsonObject(options: options) }
        case .toOne(let ref, let display):
            guard let ref else { return NSNull() }
            var object: [String: Any] = ["$ref": ref.uri.absoluteString]
            if let display { object["display"] = display }
            return object
        case .toOneInserted(let inserted, let display):
            // Not a `$ref`: the temporary URI names nothing outside the session that staged it.
            var object: [String: Any] = ["$inserted": inserted.uri.absoluteString, "$entity": inserted.entity]
            if let display { object["display"] = display }
            return object
        case .toMany(let count):
            return ["$count": count]
        }
    }
}

extension RowSnapshot {
    /// `{"$id": <uri>, "$entity": <name>, <property>: <value>, …}`
    public func jsonObject(columns: ColumnSet, options: JSONRenderOptions = .init()) -> [String: Any] {
        var object: [String: Any] = ["$id": ref.uri.absoluteString, "$entity": ref.entity]
        for (name, value) in zip(columns.properties, values) {
            object[name] = value.jsonObject(options: options)
        }
        return object
    }
}
