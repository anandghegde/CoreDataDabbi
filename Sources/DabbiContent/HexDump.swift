import Foundation

/// The Hex mode of the content viewer, and the strings found in the bytes (CNT-5). Every field has this view,
/// whatever else it turns out to be.
public enum HexDump {
    public static let bytesPerLine = 16

    /// How many lines `lines(of:in:)` has to offer for `byteCount` bytes. The view asks for the ones it shows.
    public static func lineCount(forByteCount byteCount: Int) -> Int {
        (byteCount + bytesPerLine - 1) / bytesPerLine
    }

    /// Lines `range` of the dump: `00000010  48 65 6c 6c 6f 2c 20 77  6f 72 6c 64 21 0a 00 00  |Hello, world!...|`.
    public static func lines(of data: Data, in range: Range<Int>) -> [String] {
        let bytes = [UInt8](data)
        let last = min(range.upperBound, lineCount(forByteCount: bytes.count))
        guard range.lowerBound >= 0, range.lowerBound < last else { return [] }
        return (range.lowerBound..<last).map { line in
            let start = line * bytesPerLine
            let chunk = bytes[start..<min(start + bytesPerLine, bytes.count)]
            var hex = ""
            for (position, byte) in chunk.enumerated() {
                hex += hexDigits(byte) + (position == 7 ? "  " : " ")
            }
            let width = bytesPerLine * 3 + 1
            hex += String(repeating: " ", count: max(0, width - hex.count))
            let ascii = String(String.UnicodeScalarView(chunk.map { isPrintable($0) ? Unicode.Scalar($0) : "." }))
            return String(start, radix: 16).leftPadded(to: 8) + "  " + hex + " |" + ascii + "|"
        }
    }

    /// The whole dump as one text, for Copy and for the CLI. `maxBytes` keeps a 50 MB blob from becoming
    /// 200 MB of text.
    public static func text(of data: Data, maxBytes: Int = 1024 * 1024) -> String {
        let shown = data.prefix(maxBytes)
        var lines = lines(of: shown, in: 0..<lineCount(forByteCount: shown.count))
        if shown.count < data.count { lines.append("… \(data.count - shown.count) more bytes") }
        return lines.joined(separator: "\n")
    }

    /// A run of printable characters, as `strings(1)` finds them.
    public struct FoundString: Sendable, Hashable {
        public var offset: Int
        public var text: String
    }

    /// Runs of at least `minimumLength` printable ASCII characters, and the same in UTF-16 (either byte order) —
    /// which is how `NSString`s that are not ASCII sit inside an archive.
    public static func strings(in data: Data, minimumLength: Int = 4, limit: Int = 10_000) -> [FoundString] {
        let bytes = [UInt8](data)
        var found: [FoundString] = []

        var start = 0
        var position = 0
        func closeASCII() {
            if position - start >= minimumLength, found.count < limit {
                found.append(FoundString(offset: start, text: String(decoding: bytes[start..<position], as: UTF8.self)))
            }
        }
        while position < bytes.count, found.count < limit {
            if !isPrintable(bytes[position]) {
                closeASCII()
                start = position + 1
            }
            position += 1
        }
        closeASCII()

        // UTF-16: a printable byte and a zero, over and over. `zeroFirst` is big-endian.
        for zeroFirst in [false, true] {
            var position = 0
            while position + 1 < bytes.count, found.count < limit {
                var end = position
                var text = String.UnicodeScalarView()
                while end + 1 < bytes.count {
                    let (character, zero) = zeroFirst ? (bytes[end + 1], bytes[end]) : (bytes[end], bytes[end + 1])
                    guard zero == 0, isPrintable(character) else { break }
                    text.append(Unicode.Scalar(character))
                    end += 2
                }
                if text.count >= minimumLength {
                    found.append(FoundString(offset: position, text: String(text)))
                    position = end
                } else {
                    position += 1
                }
            }
        }
        return found.sorted { $0.offset < $1.offset }
    }

    private static func isPrintable(_ byte: UInt8) -> Bool { (0x20...0x7E).contains(byte) }

    private static func hexDigits(_ byte: UInt8) -> String {
        String(byte, radix: 16).leftPadded(to: 2)
    }
}
