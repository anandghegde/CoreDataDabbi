import DabbiBase
import Foundation
import Testing

@Suite struct ValueTests {
    private let ref = ObjectRef(entity: "Tag", pk: 7, uri: URL(string: "x-coredata://S/Tag/p7")!)

    @Test func displayStrings() {
        #expect(Value.null.displayString() == "nil")
        #expect(Value.string("").displayString() == "")
        #expect(Value.bool(true).displayString() == "true")
        #expect(Value.int(.min).displayString() == "-9223372036854775808")
        #expect(Value.decimal(Decimal(string: "12.3400")!).displayString() == "12.34")
        #expect(Value.date(Date(timeIntervalSinceReferenceDate: 0)).displayString() == "2001-01-01 00:00:00Z")
        #expect(Value.toMany(count: 1).displayString() == "1 object")
        #expect(Value.toMany(count: 2).displayString() == "2 objects")
        #expect(Value.toOne(ref, display: nil).displayString() == "Tag#7")
        #expect(Value.toOne(ref, display: "urgent").displayString() == "urgent")
        #expect(Value.toOne(nil, display: nil).displayString() == "nil")
        #expect(
            Value.blob(BlobSummary(byteCount: 12, sniffedType: .png, isExternal: false)).displayString()
                == "<12 bytes png>")
        #expect(Value.composite(["b": .int(2), "a": .null]).displayString() == "{a: nil, b: 2}")
    }

    @Test func plainJSON() throws {
        let row = RowSnapshot(
            ref: ref,
            values: [
                .null, .int(3), .double(.infinity), .date(Date(timeIntervalSinceReferenceDate: 0.5)),
                .toOne(ref, display: "urgent"), .toMany(count: 4), .composite(["x": .bool(false)]),
                .blob(BlobSummary(byteCount: 9, sniffedType: nil, isExternal: true)),
            ])
        let columns = ColumnSet(["nothing", "int", "inf", "date", "one", "many", "composite", "blob"])
        let object = row.jsonObject(columns: columns)
        let data = try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
        let json = String(decoding: data, as: UTF8.self)
        #expect(json.contains(#""$entity":"Tag""#))
        #expect(json.contains(#""nothing":null"#))
        #expect(json.contains(#""inf":"inf""#))
        #expect(json.contains(#""date":"2001-01-01T00:00:00.500Z""#))
        #expect(json.contains(#""many":{"$count":4}"#))
        #expect(json.contains(#""blob":{"$blob":{"byteCount":9,"external":true}}"#))
        #expect(json.contains(#""composite":{"x":false}"#))
    }

    @Test func codableRoundTrip() throws {
        let values: [Value] = [
            .null, .bool(true), .int(-1), .double(1.5), .decimal(Decimal(string: "0.1")!), .string("naïve"),
            .date(Date(timeIntervalSinceReferenceDate: 1)), .uuid(UUID()), .url(URL(string: "https://example.org")!),
            .blob(BlobSummary(byteCount: 1, sniffedType: .json, isExternal: false)),
            .composite(["a": .composite(["b": .int(1)])]), .toOne(ref, display: "x"), .toMany(count: 0),
        ]
        let decoded = try JSONDecoder().decode([Value].self, from: JSONEncoder().encode(values))
        #expect(decoded == values)
    }
}

@Suite struct MagicSnifferTests {
    @Test func recognisesCommonFormats() {
        #expect(MagicSniffer.sniff(Data([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A, 0, 0])) == .png)
        #expect(MagicSniffer.sniff(Data([0xFF, 0xD8, 0xFF, 0xE0])) == .jpeg)
        #expect(MagicSniffer.sniff(Data("bplist00…".utf8)) == .binaryPlist)
        #expect(MagicSniffer.sniff(Data("%PDF-1.7".utf8)) == .pdf)
        #expect(MagicSniffer.sniff(Data(#"{"a": 1}"#.utf8)) == .json)
        #expect(MagicSniffer.sniff(Data("SQLite format 3\0".utf8)) == .sqlite)
        #expect(MagicSniffer.sniff(Data()) == nil)
        #expect(MagicSniffer.sniff(Data([0x00, 0x01, 0x02, 0xFE])) == nil)
    }
}
