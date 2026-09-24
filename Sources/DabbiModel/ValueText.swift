import DabbiBase
import Foundation

/// Attribute values as text a person types: what an editor shows for a value, and what it makes of what was typed
/// (EDT-3). Import's coercion (IMX-2) reads its columns by the same rules.
///
/// The text is the value's own, not the grid's: numbers without grouping and with a full stop, dates as
/// ISO 8601 with their offset. What the grid shows is for reading; this is for typing, and it reads back exactly —
/// `value(from: text(for: v), …)` is `v` for every value an attribute of that type can hold.
///
/// Empty text means no value for every type but String, where it is the empty string: an editor that has to say
/// nil for a string says so some other way.
public enum ValueText {
    /// The types an editor can offer a text field for. Binary data, transformables, composites and object IDs
    /// have editors of their own, or none.
    public static func isEditableAsText(_ type: AttributeType) -> Bool {
        switch type {
        case .integer16, .integer32, .integer64, .decimal, .double, .float, .string, .boolean, .date, .uuid, .uri:
            true
        case .binaryData, .transformable, .objectID, .composite, .undefined:
            false
        }
    }

    /// The text an editor starts from. `value(from:for:timeZone:)` reads it back as the same value.
    ///
    /// - Parameter timeZone: the offset a date is written with — the project's, so that it reads as the grid shows
    ///   it. The instant is the same in any zone.
    public static func text(for value: Value, timeZone: TimeZone = .gmt) -> String {
        switch value {
        case .null: ""
        case .bool(let flag): flag ? "true" : "false"
        case .int(let number): String(number)
        case .double(let number): String(number)
        case .decimal(let number): NSDecimalNumber(decimal: number).stringValue
        case .string(let string): string
        case .date(let date): Self.dateText(date, timeZone: timeZone)
        case .uuid(let uuid): uuid.uuidString
        case .url(let url): url.absoluteString
        case .blob, .composite, .toOne, .toMany: value.displayString(timeZone: timeZone)
        }
    }

    /// What `text` means for an attribute of `type`.
    ///
    /// Throws `.invalidValue` with a message that says what the type takes — never the text itself (privacy): a
    /// front end shows the message next to the field the text is still in.
    ///
    /// - Parameter timeZone: what a date written without an offset is read in: the project's.
    public static func value(from text: String, for type: AttributeType, timeZone: TimeZone = .gmt) throws -> Value {
        // Text is kept as typed: leading and trailing spaces can be the value.
        if type == .string { return .string(text) }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty { return .null }
        func refused(_ expected: String) -> DabbiError {
            DabbiError(.invalidValue, "This is not \(expected).", arguments: ["type": type.displayName])
        }
        switch type {
        case .integer16, .integer32, .integer64:
            guard let number = Int64(trimmed) else { throw refused("a whole number") }
            let range: ClosedRange<Int64> =
                switch type {
                case .integer16: Int64(Int16.min)...Int64(Int16.max)
                case .integer32: Int64(Int32.min)...Int64(Int32.max)
                default: Int64.min...Int64.max
                }
            guard range.contains(number) else {
                throw DabbiError(
                    .invalidValue,
                    "\(type.displayName) holds whole numbers from \(range.lowerBound) to \(range.upperBound).",
                    arguments: ["type": type.displayName])
            }
            return .int(number)
        case .double, .float:
            guard let number = Double(trimmed) else { throw refused("a number") }
            return .double(number)
        case .decimal:
            guard trimmed.wholeMatch(of: decimalPattern) != nil,
                let number = Decimal(string: trimmed, locale: Locale(identifier: "en_US_POSIX"))
            else { throw refused("a number") }
            return .decimal(number)
        case .boolean:
            switch trimmed.lowercased() {
            case "true", "yes", "1": return .bool(true)
            case "false", "no", "0": return .bool(false)
            default: throw refused("true or false")
            }
        case .date:
            guard let date = Self.date(from: trimmed, timeZone: timeZone) else {
                throw refused("a date such as 2026-09-24T15:30:00Z or 2026-09-24 15:30:00")
            }
            return .date(date)
        case .uuid:
            guard let uuid = UUID(uuidString: trimmed) else { throw refused("a UUID") }
            return .uuid(uuid)
        case .uri:
            guard let url = URL(string: trimmed), url.scheme != nil else {
                throw refused("a URL with a scheme, such as https://example.org")
            }
            return .url(url)
        case .string, .binaryData, .transformable, .objectID, .composite, .undefined:
            throw DabbiError(
                .invalidValue, "\(type.displayName) attributes are not edited as text.",
                arguments: ["type": type.displayName])
        }
    }

    // MARK: Numbers

    /// A plain decimal: sign, digits, one full stop, an exponent. `Decimal(string:)` alone would stop at the first
    /// character it does not like and call the rest a number.
    private nonisolated(unsafe) static let decimalPattern = /[+-]?(\d+(\.\d*)?|\.\d+)([eE][+-]?\d+)?/

    // MARK: Dates

    /// ISO 8601 with the offset of `timeZone`, and fractions of a second only when there are any, so that a date
    /// written back unchanged is the same instant to the millisecond.
    private static func dateText(_ date: Date, timeZone: TimeZone) -> String {
        let whole = date.timeIntervalSinceReferenceDate.rounded(.down) == date.timeIntervalSinceReferenceDate
        var style = Date.ISO8601FormatStyle(includingFractionalSeconds: !whole, timeZone: timeZone)
        style = style.year().month().day().dateSeparator(.dash).time(includingFractionalSeconds: !whole)
            .timeSeparator(.colon).timeZone(separator: .colon)
        return date.formatted(style)
    }

    /// ISO 8601, with or without fractions and with any offset; or `yyyy-MM-dd HH:mm:ss` and `yyyy-MM-dd`, which
    /// the grid's time zone is taken to mean.
    private static func date(from text: String, timeZone: TimeZone) -> Date? {
        for fractions in [false, true] {
            let style = Date.ISO8601FormatStyle(includingFractionalSeconds: fractions)
            if let date = try? style.parse(text) { return date }
        }
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        guard let match = text.wholeMatch(of: localPattern),
            let year = Int(match.1), let month = Int(match.2), let day = Int(match.3)
        else { return nil }
        let hour = match.4.flatMap { Int($0) } ?? 0
        let minute = match.5.flatMap { Int($0) } ?? 0
        let second = match.6.flatMap { Int($0) } ?? 0
        guard hour < 24, minute < 60, second < 60 else { return nil }
        let components = DateComponents(
            year: year, month: month, day: day, hour: hour, minute: minute, second: second)
        // A calendar rolls 30 February over into March; a date that is not one is refused instead.
        guard let date = calendar.date(from: components) else { return nil }
        let back = calendar.dateComponents([.year, .month, .day], from: date)
        guard back.year == year, back.month == month, back.day == day else { return nil }
        return date
    }

    private nonisolated(unsafe) static let localPattern =
        /(\d{4})-(\d{2})-(\d{2})(?:[ T](\d{2}):(\d{2})(?::(\d{2}))?)?/
}
