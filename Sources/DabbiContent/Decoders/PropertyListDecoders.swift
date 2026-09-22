import DabbiBase
import Foundation

/// An `NSKeyedArchiver` archive, binary or XML, as a tree of objects (CNT-4). Most transformable attributes.
///
/// It is asked before the property-list decoders and passes (`NotThisContent`) when the list is no archive.
public struct KeyedArchiveDecoder: ContentDecoder {
    public let id = ContentTypeID.keyedArchive

    public init() {}

    public func probe(_ head: ByteView, hint: ContentHint) -> Confidence? {
        if head.sniffed == .binaryPlist { return .certain }
        // The archiver writes its own keys first, so an XML archive says so within the first kilobyte.
        return head.isXMLPlist && head.text?.contains("$archiver") == true ? .certain : nil
    }

    public func decode(_ data: Data, limits: DecodeLimits) throws -> DecodedContent {
        let source: any PlistSource =
            data.starts(with: BinaryPlist.magic) ? try BinaryPlist(data) : try XMLPlist(data, limits: limits)
        let trees = PlistTreeBuilder(limits: limits)
        guard let archive = try KeyedArchiveTreeBuilder(source: source, trees: trees) else { throw NotThisContent() }
        return .tree(try archive.build(key: nil), source: nil, syntax: nil)
    }
}

/// A binary property list, read by our own parser (ADR-08).
public struct BinaryPlistDecoder: ContentDecoder {
    public let id = ContentTypeID.binaryPlist

    public init() {}

    public func probe(_ head: ByteView, hint: ContentHint) -> Confidence? {
        head.sniffed == .binaryPlist ? .certain : nil
    }

    public func decode(_ data: Data, limits: DecodeLimits) throws -> DecodedContent {
        .tree(try PlistTreeBuilder(limits: limits).build(try BinaryPlist(data)).node, source: nil, syntax: nil)
    }
}

/// An XML property list: a tree, and its own text as the Text mode.
public struct XMLPlistDecoder: ContentDecoder {
    public let id = ContentTypeID.xmlPlist

    public init() {}

    public func probe(_ head: ByteView, hint: ContentHint) -> Confidence? {
        head.isXMLPlist ? .certain : nil
    }

    public func decode(_ data: Data, limits: DecodeLimits) throws -> DecodedContent {
        guard data.count <= limits.maxStructuredBytes else { throw NotThisContent() }
        let node = try PlistTreeBuilder(limits: limits).build(try XMLPlist(data, limits: limits)).node
        return .tree(node, source: decodeText(data), syntax: .xml)
    }
}

extension ByteView {
    /// The sniffer looks at 64 bytes; a prologue with a comment in it pushes `<plist` past them.
    var isXMLPlist: Bool {
        sniffed == .xmlPlist || (sniffed == .xml && markupStart?.contains("<plist") == true)
    }
}
