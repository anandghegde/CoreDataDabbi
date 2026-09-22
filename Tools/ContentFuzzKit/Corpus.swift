import Foundation

/// One well-formed sample of every format the decoders parse themselves. Mutations start here.
public enum Corpus {
    public static func seeds() -> [(name: String, data: Data)] {
        let nested: [String: Any] = [
            "name": "Dabbi", "count": 42, "ratio": 0.25, "big": Int64.min, "flag": true,
            "when": Date(timeIntervalSinceReferenceDate: 700_000_000), "blob": Data((0..<40).map { UInt8($0) }),
            "list": Array(0..<20), "unicode": "naïve — 日本語 🍱", "deep": ["a": ["b": ["c": [1, 2, [3, [4]]]]]],
            "long": String(repeating: "x", count: 300),
        ]
        var seeds: [(String, Data)] = []
        func add(_ name: String, _ make: () throws -> Data) {
            if let data = try? make() { seeds.append((name, data)) }
        }

        add("binary.plist") {
            try PropertyListSerialization.data(fromPropertyList: nested, format: .binary, options: 0)
        }
        add("xml.plist") { try PropertyListSerialization.data(fromPropertyList: nested, format: .xml, options: 0) }
        add("archive.bin") { try archive(nested, format: .binary) }
        add("archive.xml") { try archive(nested, format: .xml) }
        add("archive-in-archive.bin") {
            let inner = try archive(
                ["inner": [1, 2, 3], "url": NSURL(string: "https://example.org/a")!], format: .binary)
            return try archive(["payload": inner, "set": NSSet(array: ["a", "b"]), "id": NSUUID()], format: .binary)
        }
        add("attributed.bin") {
            try archive(NSAttributedString(string: "Hello", attributes: [.init("k"): "v"]), format: .binary)
        }
        add("document.json") {
            Data(
                #"{"z": [1, 2.5e10, -0, true, false, null], "a": {"nested": {"deeper": ["é🍱", "\n"]}}, "n": 12345678901234567890.5}"#
                    .utf8)
        }
        add("document.xml") {
            Data(#"<?xml version="1.0"?><root a="1"><child>text &amp; more</child><![CDATA[raw]]><empty/></root>"#.utf8)
        }
        add("picture.svg") {
            Data(
                #"<svg xmlns="http://www.w3.org/2000/svg" width="4" height="4"><rect width="4" height="4"/></svg>"#.utf8
            )
        }
        add("json.gz") {
            try gzip(Data(#"{"compressed": [1, 2, 3], "text": "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"}"#.utf8))
        }
        add("plist.zlib") {
            let plist = try PropertyListSerialization.data(fromPropertyList: nested, format: .binary, options: 0)
            return Data([0x78, 0x9C]) + (try (plist as NSData).compressed(using: .zlib) as Data) + Data([0, 0, 0, 0])
        }
        return seeds
    }

    public static func archive(_ root: Any, format: PropertyListSerialization.PropertyListFormat) throws -> Data {
        let archiver = NSKeyedArchiver(requiringSecureCoding: false)
        archiver.outputFormat = format
        archiver.encode(root, forKey: NSKeyedArchiveRootObjectKey)
        archiver.finishEncoding()
        return archiver.encodedData
    }

    /// A gzip member around `data`: header, raw DEFLATE (which is what `NSData` calls zlib), CRC-32 and size.
    /// The decoder does not check the last two, and neither are they right here.
    public static func gzip(_ data: Data, name: String? = nil) throws -> Data {
        var member = Data([0x1F, 0x8B, 0x08, name == nil ? 0x00 : 0x08, 0, 0, 0, 0, 0x00, 0x03])
        if let name { member += Data(name.utf8) + Data([0]) }
        member += try (data as NSData).compressed(using: .zlib) as Data
        member += Data([0, 0, 0, 0])
        member += withUnsafeBytes(of: UInt32(truncatingIfNeeded: data.count).littleEndian) { Data($0) }
        return member
    }
}
