import DabbiBase
import Foundation
import UniformTypeIdentifiers

/// One kind of field content: how to recognise it and how to turn it into something the viewer can show
/// (ARCHITECTURE.md §6.8).
///
/// A decoder is one file and one sample in the tests — the easiest first contribution there is. It must be safe
/// on hostile input: bounded by `DecodeLimits`, no class instantiated from the data, nothing fetched.
public protocol ContentDecoder: Sendable {
    var id: ContentTypeID { get }
    /// A cheap look at the first bytes. `nil` = not mine. Decoders are tried most confident first, and among
    /// equals in the order they were registered.
    func probe(_ head: ByteView, hint: ContentHint) -> Confidence?
    /// Throws `NotThisContent` to pass to the next decoder without a complaint, anything else to pass with one.
    func decode(_ data: Data, limits: DecodeLimits) throws -> DecodedContent
}

public enum Confidence: Int, Sendable, Hashable, Comparable {
    /// Nothing speaks against it (valid UTF-8 → text).
    case possible = 1
    /// It starts the right way (`{` → JSON).
    case likely
    /// Magic bytes.
    case certain

    public static func < (lhs: Self, rhs: Self) -> Bool { lhs.rawValue < rhs.rawValue }
}

/// What the viewer knows about the field besides its bytes.
public struct ContentHint: Sendable, Hashable {
    public enum Storage: String, Sendable, Hashable, Codable {
        /// A string attribute; the bytes are its UTF-8.
        case string
        case binary
        case transformable
        case uri
    }

    public var storage: Storage?
    public var attributeName: String?

    public init(storage: Storage? = nil, attributeName: String? = nil) {
        self.storage = storage
        self.attributeName = attributeName
    }

    public static let none = ContentHint()

    /// `true` when the attribute's name contains `word`, ignoring case: `avatarURL`, `payload_json`.
    public func nameContains(_ word: String) -> Bool {
        attributeName?.range(of: word, options: .caseInsensitive) != nil
    }
}

public struct DecodeLimits: Sendable, Hashable {
    /// The most a compressed payload may inflate to.
    public var maxInflatedBytes = 64 * 1024 * 1024
    /// How many wrappers are peeled off: gzip in gzip in gzip.
    public var maxWrapDepth = 3
    /// Nodes in one tree. The outline view shows them lazily, but they are all in memory.
    public var maxNodes = 200_000
    /// How deep a tree may nest. Trees are built by recursion; `ContentRegistry` decodes on a stack of its own
    /// that has room for this many levels many times over, and the tests hold it to that from a 512 KB thread.
    public var maxTreeDepth = 128
    /// Text longer than this is shown as it is, not pretty-printed or parsed into a tree.
    public var maxStructuredBytes = 32 * 1024 * 1024

    public init() {}

    public static let standard = DecodeLimits()
}

public enum Syntax: String, Sendable, Hashable, Codable {
    case json, xml, html
}

public enum DecodedContent: Sendable, Hashable {
    /// Text mode only. `syntax` picks the highlighter.
    case text(String, syntax: Syntax?)
    /// A foldable tree. `source` is its Text mode when the content was text to begin with (JSON, an XML
    /// property list), pretty-printed; without one the viewer shows the tree's outline.
    case tree(ContentNode, source: String?, syntax: Syntax?)
    case image(Data)
    case pdf(Data)
    case media(Data, UTType)
    /// Rendered in a web view; remote loads are the project's decision (CNT-3).
    case web(html: String)
    case rtf(Data)
    /// One URL. Whether to load it is, again, the project's decision.
    case link(URL)
    /// A compressed payload, inflated: detection starts again on `inner`.
    case wrapped(by: ContentTypeID, inner: Data)
    /// Nothing better than hex and strings.
    case opaque
}

/// Thrown by `decode` when a closer look shows the content is somebody else's: a binary property list that is
/// not an archive. The registry moves on without recording a failure.
public struct NotThisContent: Error, Sendable {
    public init() {}
}

/// The first bytes of a field, with the questions probes ask of them.
public struct ByteView: Sendable, Hashable {
    /// How much of a field a probe gets to see.
    public static let length = 1024

    public let bytes: [UInt8]
    /// The size of the whole field.
    public let totalCount: Int
    /// What the magic bytes say — the same guess the grid shows, made once for all probes.
    public let sniffed: ContentTypeID?

    public init(_ data: Data) {
        let head = data.prefix(Self.length)
        bytes = [UInt8](head)
        totalCount = data.count
        sniffed = MagicSniffer.sniff(head)
    }

    public func starts(with prefix: [UInt8], at offset: Int = 0) -> Bool {
        offset >= 0 && bytes.count >= offset + prefix.count
            && bytes[offset..<offset + prefix.count].elementsEqual(prefix)
    }

    public func starts(withASCII text: String, at offset: Int = 0) -> Bool {
        starts(with: Array(text.utf8), at: offset)
    }

    /// The bytes as text when they are text: UTF-8 (a scalar cut off at the end of the view is forgiven) or
    /// UTF-16 with a byte-order mark, and free of control characters.
    public var text: String? {
        guard !bytes.isEmpty else { return nil }
        var decoded: String?
        if starts(with: [0xFF, 0xFE]) || starts(with: [0xFE, 0xFF]) {
            decoded = String(bytes: bytes.count % 2 == 0 ? bytes[...] : bytes.dropLast(), encoding: .utf16)
        } else {
            let body = starts(with: [0xEF, 0xBB, 0xBF]) ? bytes.dropFirst(3) : bytes[...]
            let forgiven = totalCount > bytes.count ? 3 : 0
            for trim in 0...forgiven where body.count > trim {
                decoded = String(bytes: body.dropLast(trim), encoding: .utf8)
                if decoded != nil { break }
            }
        }
        guard let decoded, !decoded.unicodeScalars.contains(where: Self.isBinaryControl) else { return nil }
        return decoded
    }

    /// `text`, lowercased, without leading white space — what the markup probes look at.
    public var markupStart: Substring? {
        text.map { $0.lowercased().drop(while: \.isWhitespace) }
    }

    static func isBinaryControl(_ scalar: Unicode.Scalar) -> Bool {
        // Escape stays: logs with ANSI colours are text.
        scalar.value < 0x09 || ((0x0E...0x1F).contains(scalar.value) && scalar.value != 0x1B)
    }
}

/// The whole of a field as text, by the same rules as `ByteView.text`.
func decodeText(_ data: Data) -> String? {
    let text: String?
    if data.starts(with: [0xFF, 0xFE]) || data.starts(with: [0xFE, 0xFF]) {
        text = data.count % 2 == 0 ? String(data: data, encoding: .utf16) : nil
    } else if data.starts(with: [0xEF, 0xBB, 0xBF]) {
        text = String(data: data.dropFirst(3), encoding: .utf8)
    } else {
        text = String(data: data, encoding: .utf8)
    }
    guard let text, !text.isEmpty, !text.unicodeScalars.contains(where: ByteView.isBinaryControl) else {
        return nil
    }
    return text
}

func malformed(_ what: String, _ detail: String) -> DabbiError {
    DabbiError(.contentMalformed, "This is not a valid \(what).", diagnosis: [detail])
}

func limitExceeded(_ message: String) -> DabbiError {
    DabbiError(.limitExceeded, message)
}
