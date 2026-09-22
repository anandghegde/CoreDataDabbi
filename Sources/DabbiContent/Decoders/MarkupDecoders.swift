import DabbiBase
import Foundation

/// SVG: XML to the sniffer, a picture to the user.
public struct SVGDecoder: ContentDecoder {
    public let id = ContentTypeID.svg

    public init() {}

    public func probe(_ head: ByteView, hint: ContentHint) -> Confidence? {
        guard let start = head.markupStart, start.hasPrefix("<") else { return nil }
        return start.contains("<svg") ? .likely : nil
    }

    public func decode(_ data: Data, limits: DecodeLimits) throws -> DecodedContent {
        // Whether it is a *valid* picture is for whoever draws it to find out; this only keeps an HTML page
        // with an inline <svg> from being taken for one.
        guard let text = decodeText(data), let root = XMLIndenter.rootElementName(text)?.lowercased(),
            root == "svg" || root.hasSuffix(":svg")
        else { throw NotThisContent() }
        return .image(data)
    }
}

/// HTML, for the web view (CNT-3). What the page may load is decided where it is shown, not here.
public struct HTMLDecoder: ContentDecoder {
    public let id = ContentTypeID.html

    public init() {}

    public func probe(_ head: ByteView, hint: ContentHint) -> Confidence? {
        if head.sniffed == .html { return .likely }
        // A fragment — `<p>Hello</p>` — has nothing to go by but the attribute's name.
        guard hint.nameContains("html"), head.markupStart?.hasPrefix("<") == true else { return nil }
        return .likely
    }

    public func decode(_ data: Data, limits: DecodeLimits) throws -> DecodedContent {
        guard let text = decodeText(data) else { throw NotThisContent() }
        return .web(html: text)
    }
}

/// Any other XML, as indented text — every tag and entity as written (`XMLIndenter`).
public struct XMLContentDecoder: ContentDecoder {
    public let id = ContentTypeID.xml

    public init() {}

    public func probe(_ head: ByteView, hint: ContentHint) -> Confidence? {
        switch head.sniffed {
        case .xml?: .likely
        // A property list the plist decoder could not read is still worth showing as the XML it is.
        case .xmlPlist?: .possible
        default: nil
        }
    }

    public func decode(_ data: Data, limits: DecodeLimits) throws -> DecodedContent {
        guard let text = decodeText(data) else { throw NotThisContent() }
        guard data.count <= limits.maxStructuredBytes else { return .text(text, syntax: .xml) }
        do {
            return .text(try XMLIndenter.indent(text, maxDepth: limits.maxTreeDepth), syntax: .xml)
        } catch let error as DabbiError where error.code == .limitExceeded {
            return .text(text, syntax: .xml)
        }
    }
}
