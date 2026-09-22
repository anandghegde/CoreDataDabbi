import DabbiBase
import Foundation
import Testing

@testable import DabbiContent

@Suite struct JSONTreeTests {
    private func parse(_ text: String, limits: DecodeLimits = .standard) throws -> ContentNode {
        try JSONTreeParser.parse(text, limits: limits)
    }

    @Test func keepsKeysInTheOrderTheyWereWritten() throws {
        let root = try parse(#"{"zebra": 1, "apple": 2, "mango": {"b": [], "a": {}}}"#)
        #expect(root.children.map(\.key) == ["zebra", "apple", "mango"])
        #expect(root[path: "mango"]?.children.map(\.key) == ["b", "a"])
    }

    @Test func keepsNumbersAsTheyWereWritten() throws {
        let root = try parse("[12345678901234567890.5, 1e400, -0, 0.10, 1E+2]")
        #expect(root.children.map(\.value) == ["12345678901234567890.5", "1e400", "-0", "0.10", "1E+2"])
        #expect(root.children.allSatisfy { $0.kind == .number })
    }

    @Test func readsEscapesAndSurrogatePairs() throws {
        let root = try parse(#"["a\"b\\c\/d\n\t", "\u00e9", "\ud83c\udf71", "\ud83c", "\udf71x", "\ud83cA"]"#)
        #expect(root.children.map(\.value) == ["a\"b\\c/d\n\t", "é", "🍱", "\u{FFFD}", "\u{FFFD}x", "\u{FFFD}A"])
    }

    @Test func readsLiteralsAndScalarsAtTheTop() throws {
        #expect(try parse(" true ").value == "true")
        #expect(try parse("null").kind == .null)
        #expect(try parse(#""text""#).value == "text")
        #expect(try parse("[]").children.isEmpty)
    }

    @Test(arguments: [
        ("[1, 2,]", "Line 1"), ("{\"a\": 1,}", "key must be a string"), ("[01]", "continues with"),
        ("[1.]", "decimal point"), ("[1e]", "exponent"), ("[\"abc]", "not closed"), ("[\"a\nb\"]", "control character"),
        ("{\"a\" 1}", "colon"), ("[1] x", "follows the document"), ("[\n\n  nope]", "Line 3"), ("", "ends where"),
        ("[\"\\x\"]", "unknown escape"), ("[\"\\u12\"]", "hexadecimal"), ("{1: 2}", "key must be a string"),
        ("[-]", "not a JSON value"),
    ])
    func saysWhatIsWrongAndWhere(_ text: String, _ expected: String) {
        let error = #expect(throws: DabbiError.self) { try JSONTreeParser.parse(text, limits: .standard) }
        #expect(error?.code == .contentMalformed)
        #expect(error?.diagnosis.first?.contains(expected) == true, "\(error?.diagnosis ?? [])")
    }

    @Test func prettyPrintingChangesNothingButTheWhiteSpace() throws {
        let text = #"{"z":[1,2.50,{"k":"v\n\u0001\"q\""}],"a":{},"e":[],"t":true,"n":null,"s":"日本語"}"#
        let root = try parse(text)
        let pretty = JSONPrettyPrinter.print(root)
        #expect(try parse(pretty) == root)
        #expect(pretty.hasPrefix("{\n  \"z\": [\n    1,\n    2.50,\n"))
        #expect(pretty.contains(#""a": {}"#))
        #expect(pretty.contains(#"\u0001"#))
    }

    @Test func stopsAtTheDepthAndNodeLimits() throws {
        var limits = DecodeLimits()
        limits.maxTreeDepth = 10
        #expect(throws: DabbiError.self) { try JSONTreeParser.parse(String(repeating: "[", count: 11), limits: limits) }
        let tenDeep = String(repeating: "[", count: 10) + String(repeating: "]", count: 10)
        #expect(try parse(tenDeep, limits: limits).nodeCount == 10)

        limits.maxNodes = 5
        let error = #expect(throws: DabbiError.self) { try JSONTreeParser.parse("[1, 2, 3, 4, 5, 6]", limits: limits) }
        #expect(error?.code == .limitExceeded)
    }

    @Test func theDecoderFallsBackToTextWhenTheTreeWouldBeTooBig() throws {
        var limits = DecodeLimits()
        limits.maxNodes = 3
        let report = ContentRegistry.standard.decode(Data("[1, 2, 3, 4, 5]".utf8), limits: limits)
        #expect(report.type == .json)
        #expect(report.content == .text("[1, 2, 3, 4, 5]", syntax: .json))
    }

    @Test func deepNestingDoesNotOverflowASmallStack() {
        let text = String(repeating: "[", count: 100_000)
        let report = onSmallStack { ContentRegistry.standard.decode(Data(text.utf8)) }
        // Too deep for a tree, so not a tree: still JSON to look at.
        #expect(report.content == .text(text, syntax: .json))
    }
}
