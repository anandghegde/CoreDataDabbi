import DabbiBase
import Foundation
import UniformTypeIdentifiers

/// Formats the engine only has to recognise, because the platform renders them: images, PDF, audio and video,
/// RTF. Recognition is the magic-byte sniffer's, so the grid's guess and the viewer's choice cannot disagree.
public struct PassThroughDecoder: ContentDecoder {
    public enum Presentation: Sendable, Hashable {
        case image, pdf, rtf
        case media(UTType)
    }

    public let id: ContentTypeID
    public let presentation: Presentation

    public init(_ id: ContentTypeID, _ presentation: Presentation) {
        self.id = id
        self.presentation = presentation
    }

    public static let all: [PassThroughDecoder] = [
        .init(.png, .image), .init(.jpeg, .image), .init(.gif, .image), .init(.tiff, .image),
        .init(.webp, .image), .init(.heic, .image), .init(.pdf, .pdf), .init(.rtf, .rtf),
        .init(.mpeg4, .media(.mpeg4Movie)), .init(.quickTime, .media(.quickTimeMovie)),
        .init(.mpeg4Audio, .media(.mpeg4Audio)),
    ]

    public func probe(_ head: ByteView, hint: ContentHint) -> Confidence? {
        head.sniffed == id ? .certain : nil
    }

    public func decode(_ data: Data, limits: DecodeLimits) throws -> DecodedContent {
        switch presentation {
        case .image: .image(data)
        case .pdf: .pdf(data)
        case .rtf: .rtf(data)
        case .media(let type): .media(data, type)
        }
    }
}
