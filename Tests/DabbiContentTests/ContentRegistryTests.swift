import ContentFuzzKit
import DabbiBase
import Foundation
import Testing
import UniformTypeIdentifiers

@testable import DabbiContent

@Suite struct ContentRegistryTests {
    private let registry = ContentRegistry.standard

    private func text(_ string: String, hint: ContentHint = .none) -> ContentReport {
        registry.decode(Data(string.utf8), hint: hint)
    }

    // MARK: Recognised by their magic bytes

    @Test(
        arguments: [
            (ContentTypeID.png, [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A]),
            (.jpeg, [0xFF, 0xD8, 0xFF, 0xE0]), (.gif, Array("GIF89a".utf8)), (.tiff, [0x49, 0x49, 0x2A, 0x00]),
            (.webp, Array("RIFF\0\0\0\0WEBP".utf8)), (.heic, [0, 0, 0, 24] + Array("ftypheic".utf8)),
        ] as [(ContentTypeID, [UInt8])])
    func imagesPassThrough(_ id: ContentTypeID, _ magic: [UInt8]) {
        let data = Data(magic) + Data(repeating: 0, count: 32)
        let report = registry.decode(data)
        #expect(report.type == id)
        #expect(report.content == .image(data))
        #expect(registry.detect(data) == id)
    }

    @Test func documentsAndMediaPassThrough() {
        let pdf = Data("%PDF-1.7\n".utf8)
        #expect(registry.decode(pdf).content == .pdf(pdf))
        let rtf = Data(#"{\rtf1\ansi Hello}"#.utf8)
        #expect(registry.decode(rtf).content == .rtf(rtf))

        func container(_ brand: String) -> Data { Data([0, 0, 0, 24]) + Data("ftyp\(brand)".utf8) + Data(count: 16) }
        #expect(registry.decode(container("isom")).content == .media(container("isom"), .mpeg4Movie))
        #expect(registry.decode(container("qt  ")).content == .media(container("qt  "), .quickTimeMovie))
        #expect(registry.decode(container("M4A ")).content == .media(container("M4A "), .mpeg4Audio))
    }

    // MARK: Compression

    @Test func gzipIsPeeledOffAndWhatIsInsideDetectedAgain() throws {
        let json = Data(#"{"inside": [1, 2, 3]}"#.utf8)
        for name in [nil, "payload.json"] {
            let report = registry.decode(try Corpus.gzip(json, name: name))
            #expect(report.wrappers == [.gzip])
            #expect(report.type == .json)
            #expect(report.payload == json)
            #expect(tree(report)?[path: "inside", "[2]"]?.value == "3")
        }
    }

    @Test func zlibIsPeeledOffToo() throws {
        let plist = try PropertyListSerialization.data(fromPropertyList: ["k": "v"], format: .binary, options: 0)
        let packed = Data([0x78, 0x9C]) + (try (plist as NSData).compressed(using: .zlib) as Data) + Data(count: 4)
        let report = registry.decode(packed)
        #expect(report.wrappers == [.zlib])
        #expect(report.type == .binaryPlist)
        #expect(report.byteCount == packed.count)
        #expect(report.sha256 == ContentRegistry.sha256(packed))
    }

    @Test func aCompressionBombStopsAtTheLimit() throws {
        var limits = DecodeLimits()
        limits.maxInflatedBytes = 64 * 1024
        let bomb = try Corpus.gzip(Data(repeating: 0x41, count: 8 * 1024 * 1024))
        #expect(bomb.count < 16 * 1024)
        let report = registry.decode(bomb, limits: limits)
        #expect(report.type == nil)
        #expect(report.content == .opaque)
        #expect(report.issues.map(\.error.code) == [.limitExceeded])
    }

    @Test func wrappersAreOnlyPeeledSoDeep() throws {
        var data = Data("at the bottom".utf8)
        for _ in 0..<5 { data = try Corpus.gzip(data) }
        let report = registry.decode(data)
        #expect(report.wrappers == Array(repeating: .gzip, count: DecodeLimits.standard.maxWrapDepth + 1))
        #expect(report.type == nil)
        #expect(report.issues.last?.error.code == .limitExceeded)

        var three = Data("at the bottom".utf8)
        for _ in 0..<3 { three = try Corpus.gzip(three) }
        #expect(registry.decode(three).content == .text("at the bottom", syntax: nil))
    }

    /// Found by `ContentFuzz`: an FEXTRA length that points past the end of the file.
    @Test func aGzipHeaderThatLiesAboutItsLengthIsMalformed() {
        let data = Data([0x1F, 0x8B, 0x08, 0x04, 0, 0, 0, 0, 0, 3, 0xFF, 0xFF]) + Data(count: 20)
        let report = registry.decode(data)
        #expect(report.type == nil)
        #expect(report.issues.first?.error.code == .contentMalformed)
        for flags: UInt8 in [0x08, 0x10, 0x18, 0x02, 0x1E] {
            let unterminated = Data([0x1F, 0x8B, 0x08, flags, 0, 0, 0, 0, 0, 3]) + Data(repeating: 0x41, count: 12)
            #expect(registry.decode(unterminated).type == nil)
        }
    }

    // MARK: Text formats

    @Test func aSingleURLIsALink() {
        #expect(text("https://example.org/a.png").content == .link(URL(string: "https://example.org/a.png")!))
        #expect(text("  myapp://open/item/7\n").type == .link)
        #expect(text("file:///Users/me/a.txt").type == .link)
        #expect(text("see https://example.org").type == .text)
        #expect(text("note: remember the milk").type == .text)
        #expect(text("https://").type == .text)
        #expect(text("https://example.org", hint: ContentHint(storage: .uri)).alternatives == [.text])
    }

    @Test func htmlIsForTheWebView() {
        let page = "<!DOCTYPE html><html><body><p>Hi</p></body></html>"
        #expect(text(page).content == .web(html: page))
        // A fragment is XML to look at, and HTML when the attribute says so.
        #expect(text("<p>Hi <b>there</b></p>").type == .xml)
        #expect(text("<p>Hi <b>there</b></p>", hint: ContentHint(attributeName: "bodyHTML")).type == .html)
    }

    @Test func svgIsAPicture() {
        let svg = #"<?xml version="1.0"?><!-- logo --><svg xmlns="http://www.w3.org/2000/svg"><rect/></svg>"#
        #expect(text(svg).content == .image(Data(svg.utf8)))
        #expect(text("<svg:svg xmlns:svg=\"http://www.w3.org/2000/svg\"/>").type == .svg)
        // An XML document that merely mentions <svg is not one.
        #expect(text("<doc><svg/></doc>").type == .xml)
    }

    @Test func xmlIsIndentedAndOtherwiseLeftAlone() {
        let report = text(
            #"<?xml version="1.0"?><root b="2" a="1"><item>one &amp; two</item><empty/><!-- note --><group><x></x></group></root>"#
        )
        #expect(report.type == .xml)
        #expect(
            report.content
                == .text(
                    """
                    <?xml version="1.0"?>
                    <root b="2" a="1">
                      <item>one &amp; two</item>
                      <empty/>
                      <!-- note -->
                      <group>
                        <x></x>
                      </group>
                    </root>
                    """, syntax: .xml))
    }

    @Test func xmlThatIsNotWellFormedIsStillText() {
        let report = text("<root><a></b></root>")
        #expect(report.type == .text)
        #expect(report.issues.map(\.decoder) == [.xml])
        #expect(report.issues.first?.error.diagnosis.first == "</b> closes <a>, which is still open.")
        #expect(text("<root>").issues.first?.error.diagnosis.first == "<root> is never closed.")
        #expect(text("<a b='>'>ok</a>").type == .xml)
    }

    /// Entities are never expanded, so there is nothing to blow up and nothing to fetch.
    @Test func entitiesAreLeftAsWritten() throws {
        let bomb =
            #"<!DOCTYPE x [<!ENTITY a "aaaaaaaaaa"><!ENTITY b "&a;&a;&a;&a;"><!ENTITY f SYSTEM "file:///etc/passwd">]><x>&b;&f;</x>"#
        guard case .text(let shown, _) = text(bomb).content else {
            Issue.record("not text")
            return
        }
        #expect(shown.contains("<x>&b;&f;</x>"))
        #expect(!shown.contains("root:"))
    }

    @Test func anXMLPropertyListIsATreeWithItsSource() throws {
        let data = try PropertyListSerialization.data(
            fromPropertyList: ["b": [1, 2], "a": "text", "n": -5, "big": UInt64.max, "d": Data([1])], format: .xml,
            options: 0)
        let report = registry.decode(data)
        #expect(report.type == .xmlPlist)
        guard case .tree(let root, let source, let syntax) = report.content else {
            Issue.record("not a tree")
            return
        }
        #expect(syntax == .xml)
        #expect(source?.contains("<plist") == true)
        #expect(root.children.map(\.key) == ["a", "b", "big", "d", "n"])
        #expect(root[path: "big"]?.value == String(UInt64.max))
        #expect(root[path: "n"]?.value == "-5")
        #expect(root[path: "d"]?.value == "1 byte · 01")
    }

    @Test func aPropertyListBehindALongPrologueIsStillOne() {
        let prologue = "<?xml version=\"1.0\"?>\n<!-- \(String(repeating: "padding ", count: 20)) -->\n"
        let report = text(prologue + "<plist version=\"1.0\"><array><true/><real>2.5</real></array></plist>")
        #expect(report.type == .xmlPlist)
        #expect(tree(report)?.children.map(\.value) == ["true", "2.5"])
    }

    @Test func aBrokenPropertyListFallsBackToXMLAndSaysWhy() {
        let report = text("<plist><array><banana/></array></plist>")
        #expect(report.type == .xml)
        #expect(report.issues.first?.decoder == .xmlPlist)
        #expect(report.issues.first?.error.diagnosis.first?.contains("<banana>") == true)
    }

    @Test func textIsTextInUTF8AndUTF16() {
        #expect(text("plain — text\nwith lines").content == .text("plain — text\nwith lines", syntax: nil))
        #expect(text("\u{1B}[31mred\u{1B}[0m").type == .text)
        let utf16 = Data([0xFF, 0xFE]) + "wide".data(using: .utf16LittleEndian)!
        #expect(registry.decode(utf16).content == .text("wide", syntax: nil))
    }

    // MARK: The registry itself

    @Test func whatNobodyRecognisesIsOpaque() {
        let noise = Data([0x00, 0x9F, 0x13, 0xC8, 0x02, 0xFE, 0x01])
        let report = registry.decode(noise)
        #expect(report.type == nil)
        #expect(report.content == .opaque)
        #expect(report.payload == noise)
        #expect(report.issues.isEmpty)
        #expect(registry.detect(noise) == nil)

        let empty = registry.decode(Data())
        #expect(empty.content == .opaque)
        #expect(empty.byteCount == 0)
    }

    @Test func reportsTheHashOfTheFieldAsStored() {
        #expect(text("abc").sha256 == "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad")
    }

    @Test func offersTheOtherReadingsAsAlternatives() {
        let report = text(#"{"a": 1}"#)
        #expect(report.type == .json)
        #expect(report.alternatives == [.text])
        // "bplist00" is eight letters as well as a signature.
        #expect(registry.candidates(for: Data("bplist00".utf8)).map(\.id) == [.keyedArchive, .binaryPlist, .text])
    }

    @Test func decodeAsOverridesDetection() throws {
        let json = Data(#"{"a": 1}"#.utf8)
        let forced = registry.decode(json, as: .text)
        #expect(forced.content == .text(#"{"a": 1}"#, syntax: nil))
        #expect(forced.alternatives == [.json])

        let wrong = registry.decode(json, as: .binaryPlist)
        #expect(wrong.content == .opaque)
        #expect(wrong.issues.first?.error.code == .contentMalformed)

        #expect(registry.decode(json, as: "application/x-nothing").issues.first?.error.code == .noDecoder)
        // The wrapper comes off before the forced reading is applied to what is inside… only when it is asked for.
        #expect(registry.decode(try Corpus.gzip(json), as: .gzip).type == .json)
    }

    @Test func aRegisteredDecoderWinsATie() {
        struct Shout: ContentDecoder {
            let id: ContentTypeID = "test.shout"
            func probe(_ head: ByteView, hint: ContentHint) -> Confidence? {
                head.starts(withASCII: "{") ? .likely : nil
            }
            func decode(_ data: Data, limits: DecodeLimits) throws -> DecodedContent { .text("SHOUT", syntax: nil) }
        }
        var registry = ContentRegistry.standard
        registry.register(Shout())
        let report = registry.decode(Data(#"{"a": 1}"#.utf8))
        #expect(report.type == "test.shout")
        #expect(report.alternatives == [.json, .text])
    }
}

@Suite struct ContentFuzzTests {
    /// The campaign `ContentFuzz` runs for hours, run for a second: the same seeds and mutations, a fixed random
    /// seed. A crash here is a finding — the log names the iteration, and `ContentFuzz --seed` replays it.
    @Test func aShortCampaignFindsNothing() {
        let outcome = onSmallStack { Campaign().run(iterations: 4_000, seed: 0xDABB1) }
        #expect(outcome.violations.isEmpty, "\(outcome.violations.map(\.description))")
        // It has to have got past the front door of every parser to mean anything.
        for path in ["bplist", "keyedArchive", "json", "xml", "plist", "gzip → json"] {
            #expect(outcome.tally[path, default: 0] > 0, "no input ended up as \(path): \(outcome.tally)")
        }
    }

    @Test func theSeedsThemselvesDecodeCleanly() {
        for seed in Corpus.seeds() {
            let report = ContentRegistry.standard.decode(seed.data)
            #expect(report.type != nil, "\(seed.name)")
            #expect(report.issues.isEmpty, "\(seed.name): \(report.issues)")
        }
        #expect(Corpus.seeds().count == 11)
    }
}
