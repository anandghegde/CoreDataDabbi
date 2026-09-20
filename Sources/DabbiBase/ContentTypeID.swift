import Foundation

/// Identifies a kind of field content (PNG, JSON, keyed archive …). Content decoders register under these IDs.
public struct ContentTypeID: RawRepresentable, Sendable, Hashable, Codable, ExpressibleByStringLiteral {
    public let rawValue: String
    public init(rawValue: String) { self.rawValue = rawValue }
    public init(stringLiteral value: String) { self.rawValue = value }
}

extension ContentTypeID {
    public static let png: Self = "png"
    public static let jpeg: Self = "jpeg"
    public static let gif: Self = "gif"
    public static let tiff: Self = "tiff"
    public static let webp: Self = "webp"
    public static let heic: Self = "heic"
    public static let pdf: Self = "pdf"
    public static let mpeg4: Self = "mpeg4"
    public static let quickTime: Self = "quicktime"
    public static let binaryPlist: Self = "bplist"
    public static let xmlPlist: Self = "plist"
    public static let json: Self = "json"
    public static let xml: Self = "xml"
    public static let html: Self = "html"
    public static let rtf: Self = "rtf"
    public static let gzip: Self = "gzip"
    public static let zlib: Self = "zlib"
    public static let sqlite: Self = "sqlite"
    public static let text: Self = "text"
}

/// Magic-byte detection over a bounded prefix. Cheap enough to run for every blob cell in a page.
///
/// This is only the *summary* guess shown in grids; the content viewer's decoder registry makes the real decision.
public enum MagicSniffer {
    /// How many leading bytes `sniff` looks at.
    public static let prefixLength = 64

    public static func sniff(_ data: Data) -> ContentTypeID? {
        let head = [UInt8](data.prefix(prefixLength))
        guard !head.isEmpty else { return nil }

        func starts(_ bytes: [UInt8], at offset: Int = 0) -> Bool {
            head.count >= offset + bytes.count && Array(head[offset..<offset + bytes.count]) == bytes
        }
        func startsASCII(_ text: String, at offset: Int = 0) -> Bool { starts(Array(text.utf8), at: offset) }

        if starts([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A]) { return .png }
        if starts([0xFF, 0xD8, 0xFF]) { return .jpeg }
        if startsASCII("GIF87a") || startsASCII("GIF89a") { return .gif }
        if starts([0x49, 0x49, 0x2A, 0x00]) || starts([0x4D, 0x4D, 0x00, 0x2A]) { return .tiff }
        if startsASCII("RIFF"), startsASCII("WEBP", at: 8) { return .webp }
        if startsASCII("ftyp", at: 4) {
            let brand = String(decoding: head.dropFirst(8).prefix(4), as: UTF8.self)
            switch brand {
            case "heic", "heix", "hevc", "mif1", "msf1", "avif": return .heic
            case "qt  ": return .quickTime
            default: return .mpeg4
            }
        }
        if startsASCII("%PDF-") { return .pdf }
        if startsASCII("bplist0") { return .binaryPlist }
        if startsASCII("SQLite format 3\0") { return .sqlite }
        if startsASCII("{\\rtf") { return .rtf }
        if starts([0x1F, 0x8B, 0x08]) { return .gzip }
        // zlib: CMF 0x78 and a header checksum that is a multiple of 31.
        if head.count >= 2, head[0] == 0x78, (UInt16(head[0]) << 8 | UInt16(head[1])) % 31 == 0 { return .zlib }

        return sniffText(head)
    }

    private static func sniffText(_ head: [UInt8]) -> ContentTypeID? {
        var bytes = head[...]
        if bytes.starts(with: [0xEF, 0xBB, 0xBF]) { bytes = bytes.dropFirst(3) }
        // A prefix can end in the middle of a multi-byte scalar, so tolerate a few trailing bytes.
        var text: String?
        for trim in 0...3 where bytes.count > trim {
            if let decoded = String(bytes: bytes.dropLast(trim), encoding: .utf8) {
                text = decoded
                break
            }
        }
        guard let text, !text.unicodeScalars.contains(where: { $0.value < 0x09 || (0x0E...0x1F).contains($0.value) })
        else { return nil }

        let trimmed = text.drop(while: \.isWhitespace).lowercased()
        if trimmed.hasPrefix("<?xml") || trimmed.hasPrefix("<!doctype plist") {
            return trimmed.contains("<plist") || trimmed.contains("doctype plist") ? .xmlPlist : .xml
        }
        if trimmed.hasPrefix("<plist") { return .xmlPlist }
        if trimmed.hasPrefix("<!doctype html") || trimmed.hasPrefix("<html") { return .html }
        if trimmed.hasPrefix("<") { return .xml }
        if trimmed.hasPrefix("{") || trimmed.hasPrefix("[") { return .json }
        return .text
    }
}
