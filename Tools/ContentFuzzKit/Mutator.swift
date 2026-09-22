import Foundation

/// SplitMix64: small, fast, and the same sequence everywhere — a failing run is its seed.
public struct SplitMix64: RandomNumberGenerator, Sendable {
    private var state: UInt64

    public init(seed: UInt64) { state = seed }

    public mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
}

/// Byte-level mutations of the kind coverage-guided fuzzers start from. Without coverage feedback (Xcode's
/// toolchains ship no libFuzzer runtime) the seeds have to do more of the work: every format has one, and the
/// places parsers trust most — counts, offsets, the trailer of a binary property list — are hit more often.
public struct Mutator: Sendable {
    public var random: SplitMix64
    /// Inputs never grow beyond this, so that a campaign's speed stays predictable.
    public var maxLength = 64 * 1024

    public init(seed: UInt64) { random = SplitMix64(seed: seed) }

    private static let interesting: [UInt64] = [
        0, 1, 0x7F, 0x80, 0xFF, 0x100, 0x7FFF, 0x8000, 0xFFFF, 0x7FFF_FFFF, 0x8000_0000, 0xFFFF_FFFF,
        0x7FFF_FFFF_FFFF_FFFF, 0x8000_0000_0000_0000, 0xFFFF_FFFF_FFFF_FFFF,
    ]

    /// `input` with one to four mutations applied; `others` are spliced from.
    public mutating func mutate(_ input: Data, others: [Data]) -> Data {
        var bytes = [UInt8](input)
        for _ in 0..<Int.random(in: 1...4, using: &random) {
            mutateOnce(&bytes, others: others)
        }
        if bytes.count > maxLength { bytes.removeLast(bytes.count - maxLength) }
        return Data(bytes)
    }

    /// What the text formats are made of. A random byte turns JSON into "not text" and the parser never sees
    /// it; one of these keeps it text and makes it wrong.
    private static let tokens: [String] = [
        "{", "}", "[", "]", "\"", ":", ",", "\\", "\\u", "\\ud83c", "\\udf71", "\\u0000", "-", "0", "1e999", "-0.0e-0",
        ".",
        "true", "null", "<", ">", "</", "/>", "&", "&amp;", "&#x110000;", "&undefined;", "<!--", "-->", "<![CDATA[",
        "]]>", "<?xml version=\"1.0\"?>", "<!DOCTYPE plist>", "<!DOCTYPE x [<!ENTITY a \"aaaaaaaaaa\">]>", "&a;&a;&a;",
        "<plist>", "<dict>", "</dict>", "<array>", "</array>", "<key>", "</key>", "<key>CF$UID</key>", "<integer>",
        "</integer>", "<integer>99999999999999999999</integer>", "<integer>0x</integer>", "<real>nan</real>",
        "<date>0000-00-00T00:00:00Z</date>", "<data>====</data>", "<string>", "<svg>", "<html>", "$archiver",
        "$objects",
        "$top", "$class", "NS.objects", "NS.keys", "\u{FEFF}", "\u{2028}", "é", "🍱",
    ]
    /// Openers, repeated: the depth limits are there for these.
    private static let nesters = ["[", "{\"a\":", "<a>", "<array>", "<dict><key>k</key>"]

    private mutating func mutateText(_ bytes: inout [UInt8]) {
        let at = position(in: bytes)
        switch Int.random(in: 0..<6, using: &random) {
        case 0, 1:
            bytes.insert(contentsOf: Array(Self.tokens.randomElement(using: &random)!.utf8), at: at)
        case 2:
            let token = Array(Self.tokens.randomElement(using: &random)!.utf8)
            bytes.replaceSubrange(at..<min(bytes.count, at + token.count), with: token)
        case 3:
            bytes.removeSubrange(range(in: bytes))
        case 4:
            let range = range(in: bytes)
            bytes.insert(contentsOf: bytes[range], at: at)
        default:
            let opener = Self.nesters.randomElement(using: &random)!
            let count = Int.random(in: 1...400, using: &random)
            bytes.insert(contentsOf: Array(String(repeating: opener, count: count).utf8), at: at)
        }
    }

    private mutating func mutateOnce(_ bytes: inout [UInt8], others: [Data]) {
        guard !bytes.isEmpty else {
            bytes = (0..<Int.random(in: 1...64, using: &random)).map { _ in
                UInt8.random(in: .min ... .max, using: &random)
            }
            return
        }
        let looksLikeText = bytes.prefix(256).allSatisfy { $0 >= 0x09 && !(0x0E...0x1F).contains($0) }
        if looksLikeText, Int.random(in: 0..<4, using: &random) > 0 { return mutateText(&bytes) }

        switch Int.random(in: 0..<10, using: &random) {
        case 0:
            bytes[position(in: bytes)] ^= 1 << UInt8.random(in: 0..<8, using: &random)
        case 1:
            bytes[position(in: bytes)] = UInt8.random(in: .min ... .max, using: &random)
        case 2, 3:
            // An interesting integer, big-endian (property lists) or little-endian (gzip), 1 to 8 bytes wide.
            let width = [1, 2, 4, 8].randomElement(using: &random)!
            var value = Self.interesting.randomElement(using: &random)!
            if Bool.random(using: &random) { value = value.byteSwapped >> UInt64((8 - width) * 8) }
            let start = position(in: bytes)
            for offset in 0..<width where start + offset < bytes.count {
                bytes[start + offset] = UInt8(truncatingIfNeeded: value >> UInt64((width - 1 - offset) * 8))
            }
        case 4:
            bytes.removeLast(Int.random(in: 1...max(1, bytes.count / 2), using: &random))
        case 5:
            let range = range(in: bytes)
            bytes.removeSubrange(range)
        case 6:
            let range = range(in: bytes)
            bytes.insert(contentsOf: bytes[range], at: position(in: bytes))
        case 7:
            let count = Int.random(in: 1...16, using: &random)
            let filler = (0..<count).map { _ in UInt8.random(in: .min ... .max, using: &random) }
            bytes.insert(contentsOf: filler, at: position(in: bytes))
        case 8:
            guard let other = others.randomElement(using: &random), !other.isEmpty else { return }
            let donor = [UInt8](other)
            let range = range(in: donor)
            let start = position(in: bytes)
            bytes.replaceSubrange(start..<min(bytes.count, start + range.count), with: donor[range])
        default:
            // Swap two chunks: a valid structure in the wrong place.
            let first = range(in: bytes)
            let chunk = Array(bytes[first])
            bytes.removeSubrange(first)
            bytes.insert(contentsOf: chunk, at: bytes.isEmpty ? 0 : position(in: bytes))
        }
    }

    /// Anywhere — but one time in four in the last 40 bytes, where a binary property list keeps its trailer and
    /// the end of its offset table, and one in eight in the first 16, where everyone keeps their header.
    private mutating func position(in bytes: [UInt8]) -> Int {
        switch Int.random(in: 0..<8, using: &random) {
        case 0, 1: Int.random(in: max(0, bytes.count - 40)..<bytes.count, using: &random)
        case 2: Int.random(in: 0..<min(16, bytes.count), using: &random)
        default: Int.random(in: 0..<bytes.count, using: &random)
        }
    }

    private mutating func range(in bytes: [UInt8]) -> Range<Int> {
        let start = Int.random(in: 0..<bytes.count, using: &random)
        let length = Int.random(in: 1...min(256, bytes.count - start), using: &random)
        return start..<start + length
    }
}
