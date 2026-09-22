import Foundation
import Testing

@testable import DabbiContent

@Suite struct HexDumpTests {
    @Test func formatsLinesLikeHexdumpC() {
        let data = Data("Hello, world!\n".utf8) + Data([0x00, 0xFF, 0x41])
        #expect(HexDump.lineCount(forByteCount: data.count) == 2)
        #expect(
            HexDump.lines(of: data, in: 0..<10) == [
                "00000000  48 65 6c 6c 6f 2c 20 77  6f 72 6c 64 21 0a 00 ff  |Hello, world!...|",
                "00000010  41                                                |A|",
            ])
        #expect(HexDump.lines(of: data, in: 1..<2).count == 1)
        #expect(HexDump.lines(of: data, in: 2..<5).isEmpty)
        #expect(HexDump.lines(of: Data(), in: 0..<1).isEmpty)
    }

    @Test func worksOnASliceOfData() {
        let data = Data((0..<64).map { UInt8($0) }).dropFirst(32)
        #expect(HexDump.lines(of: data, in: 0..<1).first?.hasPrefix("00000000  20 21 22") == true)
    }

    @Test func capsTheTextOfALargeBlob() {
        let text = HexDump.text(of: Data(repeating: 0x41, count: 100), maxBytes: 32)
        #expect(text.split(separator: "\n").count == 3)
        #expect(text.hasSuffix("… 68 more bytes"))
    }

    @Test func findsASCIIAndUTF16Strings() {
        var data = Data([0x00, 0x01]) + Data("first".utf8) + Data([0x00, 0x02]) + Data("no".utf8) + Data([0xFF])
        let wideOffset = data.count
        data += Data("wide".utf16.flatMap { [UInt8($0 & 0xFF), UInt8($0 >> 8)] }) + Data([0xFF, 0xFE])
        data += Data("tail end".utf8)

        let found = HexDump.strings(in: data)
        #expect(found.map(\.text) == ["first", "wide", "tail end"])
        #expect(found.map(\.offset) == [2, wideOffset, wideOffset + 10])
        #expect(HexDump.strings(in: data, minimumLength: 2).contains { $0.text == "no" })
        #expect(HexDump.strings(in: Data(repeating: 0x41, count: 100), limit: 1).count == 1)
    }
}
