import DabbiKit
import Foundation

/// How one value reads in a cell of the grid (PRD §8.3, BRW-3).
///
/// `Value.displayString` is the engine's rendering — one line, not localised, made for terminals. The grid
/// wants the user's locale, the project's time zone, and a difference between the things that look alike in
/// plain text: `nil`, the empty string, and the literal word "nil" someone stored.
struct GridValue: Equatable {
    enum Emphasis: Equatable {
        /// An ordinary value the user stored.
        case value
        /// Absent, empty, or not read yet: shown dimmed, so that a column of them reads as a column of nothing.
        case absent
        /// Something to follow: a related object.
        case reference
    }

    var text: String
    var emphasis: Emphasis = .value
    /// What the pointer reveals: the full date, a blob's details, a relationship's object ID.
    var tooltip: String?
    /// What VoiceOver says, where the text on screen leans on how it is drawn (§8.4). A dimmed, italic "nil"
    /// and a stored string reading `nil` are one word apart when they are spoken; the short forms say which.
    var spoken: String?

    /// What is read aloud: the short form where there is one, otherwise what is on screen.
    var accessibleText: String { spoken ?? text }

    static let notLoaded = GridValue(
        text: "", emphasis: .absent,
        spoken: String(localized: "Not read yet", comment: "Spoken for a grid cell whose page has not arrived"))
    static let deleted = GridValue(
        text: String(localized: "deleted", comment: "Placeholder for a row that was removed while being read"),
        emphasis: .absent,
        spoken: String(localized: "Deleted while it was being read"))

    static func render(_ value: Value, timeZone: TimeZone, locale: Locale = .current) -> GridValue {
        switch value {
        case .null:
            return GridValue(
                text: String(localized: "nil"), emphasis: .absent,
                spoken: String(localized: "No value", comment: "Spoken for a NULL column"))

        case .string(let string):
            // An empty string is a value; nothing on screen would say so.
            guard !string.isEmpty else {
                return GridValue(
                    text: String(localized: "empty", comment: "Shown for a stored zero-length string"),
                    emphasis: .absent, tooltip: String(localized: "An empty string, not nil"),
                    spoken: String(localized: "Empty text, not nil"))
            }
            // Newlines and tabs would break the row's height and its alignment.
            let single = string.replacingOccurrences(of: "\n", with: "⏎ ").replacingOccurrences(of: "\t", with: "  ")
            return GridValue(text: single, tooltip: single == string ? nil : string)

        case .bool(let flag):
            return GridValue(text: flag ? String(localized: "true") : String(localized: "false"))

        case .int(let number):
            return GridValue(text: number.formatted(.number.locale(locale)))
        case .double(let number):
            return GridValue(text: number.formatted(.number.locale(locale)), tooltip: String(number))
        case .decimal(let number):
            return GridValue(text: number.formatted(.number.locale(locale)), tooltip: number.description)

        case .date(let date):
            // The project's time zone decides what the day is; the tooltip carries what was stored, so that a
            // value can always be checked against the database (BRW-3).
            var style = Date.FormatStyle(date: .numeric, time: .standard, locale: locale)
            style.timeZone = timeZone
            // UTC, and the number the column actually holds: both so that a cell can be checked against the
            // database without arithmetic. Neither is localised — they are what is stored, not what is shown.
            let stored = String(date.timeIntervalSinceReferenceDate)
            return GridValue(
                text: date.formatted(style),
                tooltip: """
                    \(date.formatted(.iso8601))
                    \(String(localized: "Core Data timestamp: \(stored)"))
                    """)

        case .uuid(let uuid):
            return GridValue(text: uuid.uuidString)
        case .url(let url):
            return GridValue(text: url.absoluteString, tooltip: url.absoluteString)

        case .blob(let summary):
            return GridValue(
                text: blobText(summary, locale: locale), tooltip: blobTooltip(summary, locale: locale),
                // The interpunct between the type and the size is a pause on screen and a word aloud.
                spoken: blobText(summary, locale: locale).replacingOccurrences(of: " · ", with: ", "))

        case .composite(let elements):
            // Small ones read perfectly well inline; the inspector has the rest.
            let body = elements.keys.sorted().map { key in
                "\(key): \(GridValue.render(elements[key] ?? .null, timeZone: timeZone, locale: locale).text)"
            }
            return GridValue(text: "{" + body.joined(separator: ", ") + "}", tooltip: value.displayString())

        case .toOne(let ref, let display):
            guard let ref else {
                return GridValue(
                    text: String(localized: "nil"), emphasis: .absent,
                    spoken: String(localized: "No object", comment: "Spoken for an empty to-one relationship"))
            }
            return GridValue(text: display ?? ref.description, emphasis: .reference, tooltip: ref.description)

        case .toOneInserted(let object, let display):
            // Only inserted: no object ID to show yet, and nothing in the store to point at until the commit.
            let label = display ?? String(localized: "New \(object.entity)")
            return GridValue(
                text: label, emphasis: .reference,
                tooltip: String(localized: "\(object.entity), not in the store until it is committed"),
                spoken: String(localized: "\(label), not committed yet"))

        case .toMany(let count):
            guard count > 0 else {
                return GridValue(
                    text: String(localized: "none", comment: "An empty to-many relationship"), emphasis: .absent,
                    spoken: String(localized: "No objects"))
            }
            return GridValue(
                text: String(localized: "\(count) objects", comment: "Number of objects in a relationship"),
                emphasis: .reference)
        }
    }

    private static func blobText(_ summary: BlobSummary, locale: Locale) -> String {
        let size = summary.byteCount.formatted(
            .byteCount(style: .file).locale(locale))
        guard let type = summary.sniffedType else { return size }
        return "\(type.rawValue.uppercased()) · \(size)"
    }

    private static func blobTooltip(_ summary: BlobSummary, locale: Locale) -> String {
        var lines = [String(localized: "\(summary.byteCount) bytes")]
        if let type = summary.sniffedType {
            lines.append(String(localized: "Looks like \(type.rawValue)"))
        }
        if summary.isExternal {
            // The model's flag, not this row's fate: Core Data writes a blob to a file of its own only once it
            // is big enough, and the size it uses is its own business.
            lines.append(String(localized: "May be stored outside the database"))
        }
        return lines.joined(separator: "\n")
    }
}
