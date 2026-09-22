import DabbiBase
import Foundation

/// Text that is one URL: shown as a link, and as the page or image behind it if the project allows (CNT-1).
public struct LinkDecoder: ContentDecoder {
    public let id = ContentTypeID.link

    public init() {}

    public func probe(_ head: ByteView, hint: ContentHint) -> Confidence? {
        guard head.totalCount <= 8192, let text = head.text, Self.url(in: text) != nil else { return nil }
        return hint.storage == .uri ? .certain : .likely
    }

    public func decode(_ data: Data, limits: DecodeLimits) throws -> DecodedContent {
        guard data.count <= 8192, let text = decodeText(data), let url = Self.url(in: text) else {
            throw NotThisContent()
        }
        return .link(url)
    }

    /// A scheme, `://`, something after it, and no white space: `https://…`, `file:///…`, `myapp://…`.
    static func url(in text: String) -> URL? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.contains(where: \.isWhitespace), let separator = trimmed.range(of: "://"),
            separator.upperBound < trimmed.endIndex, let url = URL(string: trimmed), let scheme = url.scheme,
            scheme.first?.isLetter == true,
            scheme.count == trimmed.distance(from: trimmed.startIndex, to: separator.lowerBound)
        else { return nil }
        return url
    }
}

/// Text, when it is nothing more specific.
public struct PlainTextDecoder: ContentDecoder {
    public let id = ContentTypeID.text

    public init() {}

    public func probe(_ head: ByteView, hint: ContentHint) -> Confidence? {
        head.text == nil ? nil : .possible
    }

    public func decode(_ data: Data, limits: DecodeLimits) throws -> DecodedContent {
        guard let text = decodeText(data) else { throw NotThisContent() }
        return .text(text, syntax: nil)
    }
}
