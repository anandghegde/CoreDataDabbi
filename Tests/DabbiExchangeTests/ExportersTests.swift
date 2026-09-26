import DabbiBase
import DabbiModel
import Foundation
import Testing

@testable import DabbiExchange

/// IMX-1, BRW-12: the exporters on their own — records in, text out, checked against the text they must write.
@Suite struct ExportersTests {
    private let store = "x-coredata://F00D/"

    private func record(_ pk: Int, _ fields: [ExportField]) -> ExportRecord {
        ExportRecord(id: URL(string: "\(store)Item/p\(pk)")!, entity: "Item", fields: fields)
    }

    private var layout: ExportLayout {
        ExportLayout(
            entity: "Item",
            columns: [
                ExportLayout.Column("$id"), ExportLayout.Column("$entity"), ExportLayout.Column("name"),
                ExportLayout.Column("count"), ExportLayout.Column("place.city"), ExportLayout.Column("owner"),
            ])
    }

    private var records: [ExportRecord] {
        [
            record(
                1,
                [
                    ExportField("name", .scalar(.string("Plain"))),
                    ExportField("count", .scalar(.int(3))),
                    ExportField("place", .composite([ExportField("city", .scalar(.string("Pune")))])),
                    ExportField("owner", .reference(URL(string: "\(store)Person/p9")!, entity: "Person")),
                ]),
            record(
                2,
                [
                    ExportField("name", .scalar(.string("Comma, \"quote\"\nand line"))),
                    ExportField("count", .scalar(.null)),
                    ExportField("place", .scalar(.null)),
                    ExportField("owner", .nothing),
                ]),
            record(3, [ExportField("name", .scalar(.string(""))), ExportField("count", .scalar(.int(-1)))]),
        ]
    }

    @Test func csvQuotesOnlyWhatItMustAndTellsEmptyFromNothing() {
        let text = CSVExporter().text(for: records, layout: layout)
        #expect(
            text == """
                $id,$entity,name,count,place.city,owner\r
                \(store)Item/p1,Item,Plain,3,Pune,\(store)Person/p9\r
                \(store)Item/p2,Item,"Comma, ""quote""
                and line",,,\r
                \(store)Item/p3,Item,"",-1,,\r

                """)
    }

    @Test func tsvSeparatesWithTabsForTheSpreadsheet() {
        let text = CSVExporter.tsv().text(for: [records[0]], layout: layout)
        #expect(
            text == "$id\t$entity\tname\tcount\tplace.city\towner\n"
                + "\(store)Item/p1\tItem\tPlain\t3\tPune\t\(store)Person/p9\n")
        #expect(CSVExporter.tsv().quoted("a\tb") == "\"a\tb\"")
        #expect(CSVExporter.tsv().quoted("a,b") == "a,b")
    }

    @Test func markdownEscapesPipesAndLineBreaks() {
        let table = MarkdownTableExporter()
        let pipes = record(4, [ExportField("name", .scalar(.string("a|b\nc")))])
        let text = table.text(
            for: [pipes], layout: ExportLayout(entity: "Item", columns: [ExportLayout.Column("name")]))
        #expect(text == "| name |\n| --- |\n| a\\|b<br>c |\n")
    }

    @Test func jsonWritesRecordsInOrderWithTheirKinds() {
        let summary = BlobSummary(byteCount: 12, sniffedType: .png, isExternal: false)
        let full = record(
            5,
            [
                ExportField("flag", .scalar(.bool(true))),
                ExportField("price", .scalar(.decimal(Decimal(string: "12345678901234567890.25")!))),
                ExportField("ratio", .scalar(.double(.nan))),
                ExportField("when", .scalar(.date(Date(timeIntervalSince1970: 86400.5)))),
                ExportField("bytes", .data(Data([1, 2, 3]))),
                ExportField("picture", .blob(summary)),
                ExportField("tags", .objects([.reference(URL(string: "\(store)Tag/p1")!, entity: "Tag")])),
                ExportField("reports", .count(2)),
            ])
        let text = JSONExporter().text(for: [full, record(6, [])], layout: layout)
        #expect(
            text == """
                [
                  {
                    "$id": "\(store)Item/p5",
                    "$entity": "Item",
                    "flag": true,
                    "price": 12345678901234567890.25,
                    "ratio": "nan",
                    "when": "1970-01-02T00:00:00.500Z",
                    "bytes": "AQID",
                    "picture": {
                      "$blob": {
                        "byteCount": 12,
                        "type": "png"
                      }
                    },
                    "tags": [
                      {
                        "$ref": "\(store)Tag/p1",
                        "$entity": "Tag"
                      }
                    ],
                    "reports": {
                      "$count": 2
                    }
                  },
                  {
                    "$id": "\(store)Item/p6",
                    "$entity": "Item"
                  }
                ]

                """)
        #expect(JSONExporter().text(for: [], layout: layout) == "[]\n")
        // What it wrote is JSON, and reads back as the same tree.
        #expect(throws: Never.self) { try JSONNode.parse(text) }
    }

    @Test func aCellHoldsBytesAsBase64AndAToManyAsItsURIs() {
        let tz = TimeZone.gmt
        #expect(ExportCellText.text(for: .data(Data("hi".utf8)), timeZone: tz) == "aGk=")
        #expect(
            ExportCellText.text(
                for: .blob(BlobSummary(byteCount: 1, sniffedType: nil, isExternal: false)), timeZone: tz) == nil)
        #expect(
            ExportCellText.text(
                for: .objects([
                    .reference(URL(string: "\(store)Tag/p1")!, entity: "Tag"),
                    .reference(URL(string: "\(store)Tag/p2")!, entity: "Tag"),
                ]), timeZone: tz) == "\(store)Tag/p1 \(store)Tag/p2")
        #expect(ExportCellText.text(for: .count(4), timeZone: tz) == "4")
        #expect(ExportCellText.text(for: .scalar(.null), timeZone: tz) == nil)
    }
}

/// The JSON reader and writer import and export share.
@Suite struct JSONNodeTests {
    @Test func parsingKeepsKeyOrderAndDigits() throws {
        let node = try JSONNode.parse(#"{"b": 1.10, "a": [true, null, "x\u00e9\n"], "big": 12345678901234567890123}"#)
        guard case .object(let members) = node else { Issue.record("not an object"); return }
        #expect(members.map(\.key) == ["b", "a", "big"])
        #expect(node["b"] == .number("1.10"))
        #expect(node["big"]?.scalarText == "12345678901234567890123")
        #expect(node["a"] == .array([.bool(true), .null, .string("xé\n")]))
    }

    @Test func writingAndReadingRoundTrip() throws {
        let node = JSONNode.object([
            ("text", .string("tab\t\"quote\" \u{1} 😀")), ("list", .array([.number("-0.5e3"), .object([])])),
        ])
        #expect(try JSONNode.parse(node.text()) == node)
        #expect(try JSONNode.parse(node.text(indent: 0)) == node)
        #expect(node.text(indent: 0) == #"{"text":"tab\t\"quote\" \u0001 😀","list":[-0.5e3,{}]}"#)
    }

    @Test func surrogatePairsDecodeToOneScalar() throws {
        #expect(try JSONNode.parse(#""\ud83d\ude00""#) == .string("😀"))
    }

    @Test(arguments: ["", "{", "[1,]", "{\"a\" 1}", "tru", "01", "\"abc", "1 2", "\"\\x\""])
    func brokenJSONSaysWhereAndNotWhat(_ text: String) {
        let error = #expect(throws: DabbiError.self) { try JSONNode.parse(text) }
        #expect(error?.code == .invalidValue)
        #expect(error?.arguments["line"] != nil)
        #expect(error?.arguments["column"] != nil)
    }

    @Test func theLineAndColumnPointAtTheProblem() {
        let error = #expect(throws: DabbiError.self) { try JSONNode.parse("[\n  1,\n  secret\n]") }
        #expect(error?.arguments == ["line": "3", "column": "3"])
        #expect(error?.message.contains("secret") == false)
    }

    @Test func nestingIsBounded() {
        let deep = String(repeating: "[", count: 600) + String(repeating: "]", count: 600)
        #expect(throws: DabbiError.self) { try JSONNode.parse(deep) }
    }
}
