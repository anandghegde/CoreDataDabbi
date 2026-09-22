import DabbiBase
import Foundation
import Testing

@testable import DabbiContent

@Suite struct BinaryPlistTests {
    private let registry = ContentRegistry.standard

    @Test func readsWhatPropertyListSerializationWrites() throws {
        let plist: [String: Any] = [
            "name": "Dabbi", "count": 42, "negative": -7, "min": Int64.min, "ratio": 0.25, "yes": true, "no": false,
            "when": Date(timeIntervalSinceReferenceDate: 0), "blob": Data([1, 2, 3]),
            "unicode": "naïve — 日本語 🍱", "long": String(repeating: "x", count: 300),
            "list": Array(0..<20), "nested": ["inner": ["deep": "value"]], "empty": [String: Any](),
        ]
        let data = try PropertyListSerialization.data(fromPropertyList: plist, format: .binary, options: 0)
        let report = registry.decode(data)
        #expect(report.type == .binaryPlist)
        #expect(report.issues.isEmpty)
        let root = try #require(tree(report))

        #expect(root.kind == .dictionary)
        #expect(root.children.count == plist.count)
        #expect(root[path: "name"]?.value == "Dabbi")
        #expect(root[path: "count"]?.value == "42")
        #expect(root[path: "negative"]?.value == "-7")
        #expect(root[path: "min"]?.value == String(Int64.min))
        #expect(root[path: "ratio"]?.value == "0.25")
        #expect(root[path: "yes"]?.kind == .bool)
        #expect(root[path: "yes"]?.value == "true")
        #expect(root[path: "no"]?.value == "false")
        #expect(root[path: "when"]?.kind == .date)
        #expect(root[path: "when"]?.value?.hasPrefix("2001-01-01T00:00:00") == true)
        #expect(root[path: "blob"]?.value == "3 bytes · 01 02 03")
        #expect(root[path: "unicode"]?.value == "naïve — 日本語 🍱")
        #expect(root[path: "long"]?.value?.count == 300)
        #expect(root[path: "list"]?.children.count == 20)
        #expect(root[path: "list", "[19]"]?.value == "19")
        #expect(root[path: "nested", "inner", "deep"]?.value == "value")
        #expect(root[path: "empty"]?.children.isEmpty == true)
    }

    @Test func readsEveryIntegerWidth() throws {
        let data = binaryPlist([
            .array([1, 2, 3, 4, 5, 6]),
            .int(0xFF, bytes: 1), .int(0xFFFF, bytes: 2), .int(0xFFFF_FFFF, bytes: 4),
            .int(UInt64(bitPattern: -2), bytes: 8), .int(12, bytes: 16),
            .bytes([0x14] + [UInt8](repeating: 0x01, count: 16)),
        ])
        let root = try #require(tree(registry.decode(data)))
        // Only eight bytes are signed; the narrower ones are what they look like.
        #expect(
            root.children.map(\.value) == [
                "255", "65535", "4294967295", "-2", "12", "0x101010101010101" + "0101010101010101",
            ])
    }

    @Test func readsUTF16StringsUIDsSetsAndNull() throws {
        let data = binaryPlist([.array([1, 2, 3, 4]), .utf16("日本語 🍱"), .uid(7), .set([1]), .null])
        let root = try #require(tree(registry.decode(data)))
        #expect(root.children[0].value == "日本語 🍱")
        #expect(root.children[1].kind == .uid)
        #expect(root.children[1].value == "UID 7")
        #expect(root.children[2].kind == .set)
        #expect(root.children[3].kind == .null)
    }

    @Test func opensAPropertyListInsideADataValue() throws {
        let inner = try PropertyListSerialization.data(fromPropertyList: ["k": "v"], format: .binary, options: 0)
        let outer = try PropertyListSerialization.data(
            fromPropertyList: ["payload": inner], format: .binary, options: 0)
        let root = try #require(tree(registry.decode(outer)))
        let payload = try #require(root[path: "payload"])
        #expect(payload.kind == .data)
        #expect(payload.value?.hasPrefix("property list, \(inner.count) bytes") == true)
        #expect(payload[path: "contents", "k"]?.value == "v")
    }

    // MARK: Hostile input

    @Test func anArrayThatContainsItselfBecomesAReference() throws {
        let data = binaryPlist([.array([1, 0]), .ascii("leaf")])
        let root = try #require(tree(registry.decode(data)))
        #expect(root.children[0].value == "leaf")
        #expect(root.children[1].kind == .reference)
    }

    @Test func aBadChildCostsOnlyItsOwnNode() throws {
        let data = binaryPlist([
            .array([1, 99, 2, 3]), .ascii("fine"),
            .dict([(0, 1)]),  // its key is an array
            .bytes([0xB0]),  // no such marker
        ])
        let root = try #require(tree(registry.decode(data)))
        #expect(root.children.map(\.kind) == [.string, .truncated, .truncated, .truncated])
        #expect(root.children[1].value?.contains("object 99") == true)
        #expect(root.children[2].value?.contains("key is not a string") == true)
    }

    /// 1,000 references to one array of 1,000 references to one array …: 10¹⁸ leaves in 12 KB.
    @Test func aliasingIsCutOffByTheNodeBudget() throws {
        let fanOut = Array(repeating: 0, count: 1_000)
        let levels = 6
        var objects: [Raw] = (0..<levels).map { level in .array(fanOut.map { _ in level + 1 }) }
        objects.append(.ascii("leaf"))
        var limits = DecodeLimits()
        limits.maxNodes = 5_000

        let report = registry.decode(binaryPlist(objects), limits: limits)
        let root = try #require(tree(report))
        #expect(root.nodeCount <= limits.maxNodes + levels + 1)
        #expect(root.contains { $0.kind == .truncated })
    }

    /// 2,000 objects that all sit at the offset of one 64 KB blob: every one is "read", none is new.
    @Test func offsetAliasingIsCutOffByTheWorkLimit() throws {
        let count = 2_000
        var objects: [Raw] = [.array(Array(1...count)), .data([UInt8](repeating: 0xAB, count: 64 * 1024))]
        objects += Array(repeating: .alias(1), count: count - 1)
        let report = registry.decode(binaryPlist(objects))
        #expect(report.type == nil)
        #expect(report.issues.contains { $0.decoder == .binaryPlist && $0.error.code == .limitExceeded })
    }

    @Test func aTreeDeeperThanTheLimitIsTruncatedNotOverflowed() throws {
        let depth = 1_000
        var objects: [Raw] = (0..<depth).map { .array([$0 + 1]) }
        objects.append(.ascii("bottom"))
        let data = binaryPlist(objects)
        let outline = onSmallStack { tree(ContentRegistry.standard.decode(data))?.outline() ?? "" }
        #expect(outline.contains("nested too deeply"))
        #expect(!outline.contains("bottom"))
    }

    @Test(arguments: [
        ("too short", Data("bplist00".utf8) + Data([0x00, 0x01])),
        ("no trailer", Data("bplist00".utf8) + Data(repeating: 0, count: 40)),
        ("count beyond the file", binaryPlist([.null], declaredCount: 1 << 40)),
        ("top beyond the count", binaryPlist([.null], top: 5)),
    ])
    func rejectsATrailerThatDoesNotDescribeTheFile(_ name: String, _ data: Data) {
        let report = registry.decode(data)
        #expect(report.type == nil, "\(name)")
        #expect(report.content == .opaque)
        #expect(report.issues.map(\.decoder) == [.keyedArchive, .binaryPlist])
        #expect(report.issues.allSatisfy { $0.error.code == .contentMalformed })
    }

    @Test func aLengthLongerThanTheFileIsMalformed() throws {
        let data = binaryPlist([.bytes([0x5F, 0x12, 0x7F, 0xFF, 0xFF, 0xFF])])
        #expect(registry.decode(data).issues.contains { $0.error.code == .contentMalformed })
    }
}
