import Foundation

/// One property value of a managed object, converted to a `Sendable` value inside the engine.
///
/// Front ends render rows from `Value`s only — they never see `NSManagedObject`.
public enum Value: Sendable, Hashable, Codable {
    /// No value. Rendered distinctly from an empty string (BRW-4).
    case null
    case bool(Bool)
    /// Integer 16, 32 and 64 attributes.
    case int(Int64)
    /// Double and float attributes.
    case double(Double)
    case decimal(Decimal)
    case string(String)
    /// A date. The raw stored value is `date.timeIntervalSinceReferenceDate`.
    case date(Date)
    case uuid(UUID)
    /// URI attributes.
    case url(URL)
    /// Binary and transformable attributes. The bytes are never inlined in pages; ask the session for them.
    case blob(BlobSummary)
    /// A composite attribute: element name → value, possibly nested.
    case composite([String: Value])
    /// A to-one relationship: the destination and a human-friendly label for it.
    case toOne(ObjectRef?, display: String?)
    /// A to-one relationship whose destination is only inserted — staged in an editable session, not committed —
    /// named by the identity it was staged under, and a label for it. It has no reference until the commit
    /// gives it one, and reads as `.toOne` from then on (EDT-3).
    case toOneInserted(PendingObjectID, display: String?)
    /// A to-many relationship, summarised by its count.
    case toMany(count: Int)

    public var isNull: Bool {
        if case .null = self { return true }
        return false
    }
}

/// What a row page knows about a binary or transformable value without carrying its bytes.
public struct BlobSummary: Sendable, Hashable, Codable {
    public let byteCount: Int
    /// A guess from a bounded prefix of the data (magic bytes only).
    public let sniffedType: ContentTypeID?
    /// Whether the attribute has "Allows External Storage" set in the model.
    public let isExternal: Bool

    public init(byteCount: Int, sniffedType: ContentTypeID?, isExternal: Bool) {
        self.byteCount = byteCount
        self.sniffedType = sniffedType
        self.isExternal = isExternal
    }
}

extension Value {
    /// A compact single-line rendering for terminals and debugging. Not localised.
    public func displayString(timeZone: TimeZone = .gmt) -> String {
        switch self {
        case .null: return "nil"
        case .bool(let value): return value ? "true" : "false"
        case .int(let value): return String(value)
        case .double(let value): return String(value)
        case .decimal(let value): return value.description
        case .string(let value): return value
        case .date(let value):
            return value.formatted(
                Date.ISO8601FormatStyle(timeZone: timeZone).year().month().day()
                    .dateTimeSeparator(.space).time(includingFractionalSeconds: false).timeZone(separator: .omitted)
            )
        case .uuid(let value): return value.uuidString
        case .url(let value): return value.absoluteString
        case .blob(let summary):
            let type = summary.sniffedType.map { " \($0.rawValue)" } ?? ""
            return "<\(summary.byteCount) bytes\(type)>"
        case .composite(let elements):
            let body = elements.keys.sorted().map { "\($0): \(elements[$0]!.displayString(timeZone: timeZone))" }
            return "{" + body.joined(separator: ", ") + "}"
        case .toOne(let ref, let display):
            guard let ref else { return "nil" }
            return display ?? ref.description
        case .toOneInserted(let object, let display): return display ?? object.description
        case .toMany(let count): return "\(count) object\(count == 1 ? "" : "s")"
        }
    }
}
