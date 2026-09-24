import DabbiBase
import Foundation
import Testing

@testable import DabbiModel

/// EDT-3: what an editor shows for a value reads back as that value, and what a person types becomes the value
/// of the attribute's type — or an explanation of what the type takes that does not repeat what was typed.
@Suite struct ValueTextTests {
    private let utc = TimeZone.gmt
    private let plusTwo = TimeZone(secondsFromGMT: 7200)!

    private func value(_ text: String, _ type: AttributeType, _ timeZone: TimeZone = .gmt) throws -> Value {
        try ValueText.value(from: text, for: type, timeZone: timeZone)
    }

    private func refusal(_ text: String, _ type: AttributeType) -> DabbiError? {
        do {
            _ = try value(text, type)
            return nil
        } catch {
            return error as? DabbiError
        }
    }

    @Test func everyEditableValueReadsBackAsItself() throws {
        let instant = Date(timeIntervalSinceReferenceDate: 780_000_000.25)
        let values: [(Value, AttributeType)] = [
            (.int(-42), .integer16), (.int(Int64(Int32.max)), .integer32), (.int(.min), .integer64),
            (.double(0.1), .double), (.double(-1.5e-7), .float), (.decimal(Decimal(string: "12.3400")!), .decimal),
            (.bool(true), .boolean), (.bool(false), .boolean),
            (.string("  spaced, and \"quoted\"  "), .string), (.string(""), .string),
            (.date(instant), .date), (.date(Date(timeIntervalSinceReferenceDate: 0)), .date),
            (.uuid(UUID()), .uuid), (.url(URL(string: "https://example.org/a?b=c#d")!), .uri),
            (.null, .integer32), (.null, .date),
        ]
        for (original, type) in values {
            for timeZone in [utc, plusTwo] {
                let text = ValueText.text(for: original, timeZone: timeZone)
                #expect(try value(text, type, timeZone) == original, "\(type) through “\(text)”")
            }
        }
    }

    @Test func numbersAreWrittenAsTheyAreStored() throws {
        #expect(try value(" 42 ", .integer32) == .int(42))
        #expect(try value("-7", .integer16) == .int(-7))
        #expect(try value("1e3", .double) == .double(1000))
        #expect(try value(".5", .decimal) == .decimal(Decimal(string: "0.5")!))
        #expect(ValueText.text(for: .decimal(Decimal(string: "1234.5")!)) == "1234.5")
        #expect(ValueText.text(for: .int(1_000_000)) == "1000000")

        #expect(refusal("1.5", .integer64)?.message == "This is not a whole number.")
        #expect(refusal("12abc", .decimal)?.message == "This is not a number.")
        #expect(refusal("1,5", .decimal) != nil)
        #expect(refusal("ten", .double) != nil)
        let range = refusal("70000", .integer16)
        #expect(range?.message == "Integer 16 holds whole numbers from -32768 to 32767.")
        #expect(range?.message.contains("70000") == false)
    }

    @Test func emptyIsNoValueExceptForText() throws {
        #expect(try value("", .integer64) == .null)
        #expect(try value("   ", .date) == .null)
        #expect(try value("", .string) == .string(""))
        #expect(try value("  ", .string) == .string("  "))
    }

    @Test func booleansTakeTheUsualWords() throws {
        #expect(try value("YES", .boolean) == .bool(true))
        #expect(try value("0", .boolean) == .bool(false))
        #expect(refusal("maybe", .boolean)?.message == "This is not true or false.")
    }

    @Test func datesAreISO8601InTheProjectsTimeZone() throws {
        let instant = try #require(ISO8601DateFormatter().date(from: "2026-09-24T15:30:00Z"))
        #expect(ValueText.text(for: .date(instant), timeZone: plusTwo) == "2026-09-24T17:30:00+02:00")
        #expect(ValueText.text(for: .date(instant), timeZone: utc) == "2026-09-24T15:30:00Z")

        // Any offset means the same instant; without one, the project's time zone is meant.
        #expect(try value("2026-09-24T15:30:00Z", .date) == .date(instant))
        #expect(try value("2026-09-24T17:30:00+02:00", .date) == .date(instant))
        #expect(try value("2026-09-24 17:30:00", .date, plusTwo) == .date(instant))
        #expect(try value("2026-09-24 15:30", .date) == .date(instant))
        #expect(try value("2026-09-24", .date) == .date(instant.addingTimeInterval(-15.5 * 3600)))

        #expect(refusal("2026-02-30", .date) != nil)
        #expect(refusal("2026-09-24 25:00", .date) != nil)
        #expect(refusal("yesterday", .date) != nil)
    }

    @Test func identifiersAndAddresses() throws {
        let uuid = UUID()
        #expect(try value(uuid.uuidString.lowercased(), .uuid) == .uuid(uuid))
        #expect(refusal("not-a-uuid", .uuid) != nil)
        #expect(try value("https://example.org", .uri) == .url(URL(string: "https://example.org")!))
        #expect(refusal("example.org", .uri) != nil)
    }

    @Test func onlyScalarsAreEditedAsText() {
        #expect(ValueText.isEditableAsText(.string) && ValueText.isEditableAsText(.date))
        #expect(!ValueText.isEditableAsText(.binaryData) && !ValueText.isEditableAsText(.composite))
        #expect(refusal("AAAA", .binaryData)?.code == .invalidValue)
    }
}
