import DabbiBase
import Foundation

/// JSON: a tree in the order it was written, and pretty-printed text. Codable blobs, mostly (CNT-5).
public struct JSONContentDecoder: ContentDecoder {
    public let id = ContentTypeID.json

    public init() {}

    public func probe(_ head: ByteView, hint: ContentHint) -> Confidence? {
        // A bare `12` or `"text"` is JSON too, and nobody is helped by hearing it.
        head.sniffed == .json ? .likely : nil
    }

    public func decode(_ data: Data, limits: DecodeLimits) throws -> DecodedContent {
        guard let text = decodeText(data) else { throw NotThisContent() }
        guard data.count <= limits.maxStructuredBytes else { return .text(text, syntax: .json) }
        do {
            let tree = try JSONTreeParser.parse(text, limits: limits)
            return .tree(tree, source: JSONPrettyPrinter.print(tree), syntax: .json)
        } catch let error as DabbiError where error.code == .limitExceeded {
            // Too big for a tree is still JSON, and still readable.
            return .text(text, syntax: .json)
        }
    }
}
