import CryptoKit
import DabbiBase
import Foundation

/// What the content viewer shows for one field (CNT-1…5).
public struct ContentReport: Sendable, Hashable {
    /// A decoder that claimed the content and could not read it.
    public struct Issue: Sendable, Hashable {
        public var decoder: ContentTypeID
        public var error: DabbiError

        public init(decoder: ContentTypeID, error: DabbiError) {
            self.decoder = decoder
            self.error = error
        }
    }

    /// What `content` was decoded as; `nil` when nothing recognised it.
    public var type: ContentTypeID?
    /// The compression peeled off on the way, outermost first: gzip around JSON is `[gzip]` and `json`.
    public var wrappers: [ContentTypeID]
    public var content: DecodedContent
    /// The bytes `content` was decoded from — the field's own, or what was inside its wrappers. The Hex mode
    /// shows these.
    public var payload: Data
    /// The size of the field as stored.
    public var byteCount: Int
    /// SHA-256 of the field as stored, in hexadecimal.
    public var sha256: String
    public var issues: [Issue]
    /// Other decoders that claim this content, for the "Decode as" menu; the best first.
    public var alternatives: [ContentTypeID]
}

/// The decoders, and the order they are asked in (ARCHITECTURE.md §6.8).
///
/// Every decoder gets a cheap look at the first kilobyte; those that claim the content are tried, the most
/// confident first, until one succeeds. One that fails is noted and the next one tried — a truncated PNG ends
/// up as hex with a note saying why, never as an error in place of the field.
public struct ContentRegistry: Sendable {
    public private(set) var decoders: [any ContentDecoder]

    public init(decoders: [any ContentDecoder]) {
        self.decoders = decoders
    }

    /// Asked in this order among equally confident ones: the specific before the general — an archive before
    /// the property list it is written as, SVG before XML, a link before text.
    public static let standard = ContentRegistry(
        decoders: [KeyedArchiveDecoder(), BinaryPlistDecoder(), XMLPlistDecoder()]
            + PassThroughDecoder.all
            + [
                GzipDecoder(), ZlibDecoder(), SVGDecoder(), HTMLDecoder(), JSONContentDecoder(), XMLContentDecoder(),
                LinkDecoder(), PlainTextDecoder(),
            ]
    )

    /// Adds a decoder ahead of the built-in ones, so that it wins a tie.
    public mutating func register(_ decoder: any ContentDecoder) {
        decoders.insert(decoder, at: 0)
    }

    public func decoder(for id: ContentTypeID) -> (any ContentDecoder)? {
        decoders.first { $0.id == id }
    }

    // MARK: Detection

    /// The decoders that claim `data`, the best first. Probes only: cheap enough for a whole column.
    public func candidates(for data: Data, hint: ContentHint = .none) -> [any ContentDecoder] {
        guard !data.isEmpty else { return [] }
        let head = ByteView(data)
        return
            decoders.enumerated()
            .compactMap { offset, decoder in
                decoder.probe(head, hint: hint).map { (decoder: decoder, confidence: $0, offset: offset) }
            }
            .sorted { ($0.confidence, $1.offset) > ($1.confidence, $0.offset) }
            .map(\.decoder)
    }

    /// The best guess without decoding anything. An archive and the property list it is written as look alike
    /// from here; `decode` tells them apart.
    public func detect(_ data: Data, hint: ContentHint = .none) -> ContentTypeID? {
        candidates(for: data, hint: hint).first?.id
    }

    // MARK: Decoding

    public func decode(_ data: Data, hint: ContentHint = .none, limits: DecodeLimits = .standard) -> ContentReport {
        Self.onDeepStack {
            var report = ContentReport(
                type: nil, wrappers: [], content: .opaque, payload: data, byteCount: data.count,
                sha256: Self.sha256(data), issues: [], alternatives: [])
            decode(data, candidates: candidates(for: data, hint: hint), hint: hint, limits: limits, into: &report)
            return report
        }
    }

    /// "Decode as": the user knows better than the magic bytes. Wrappers are still peeled off first when the
    /// forced type is not itself the wrapper.
    public func decode(_ data: Data, as id: ContentTypeID, limits: DecodeLimits = .standard) -> ContentReport {
        var report = ContentReport(
            type: nil, wrappers: [], content: .opaque, payload: data, byteCount: data.count,
            sha256: Self.sha256(data), issues: [], alternatives: candidates(for: data).map(\.id).filter { $0 != id })
        guard let decoder = decoder(for: id) else {
            report.issues.append(
                .init(decoder: id, error: DabbiError(.noDecoder, "There is no decoder for “\(id.rawValue)”.")))
            return report
        }
        let alternatives = report.alternatives
        let blank = report
        report = Self.onDeepStack {
            var report = blank
            decode(data, candidates: [decoder], hint: .none, limits: limits, into: &report)
            return report
        }
        report.alternatives = alternatives
        return report
    }

    private func decode(
        _ data: Data, candidates: [any ContentDecoder], hint: ContentHint, limits: DecodeLimits,
        into report: inout ContentReport
    ) {
        for (position, decoder) in candidates.enumerated() {
            let content: DecodedContent
            do {
                content = try decoder.decode(data, limits: limits)
            } catch is NotThisContent {
                continue
            } catch {
                report.issues.append(.init(decoder: decoder.id, error: Self.describe(error)))
                continue
            }

            report.payload = data
            report.alternatives = candidates[(position + 1)...].map(\.id)
            guard case .wrapped(let wrapper, let inner) = content else {
                report.type = decoder.id
                report.content = content
                return
            }

            report.wrappers.append(wrapper)
            report.type = nil
            report.content = .opaque
            report.payload = inner
            guard report.wrappers.count <= limits.maxWrapDepth else {
                report.issues.append(
                    .init(
                        decoder: wrapper,
                        error: limitExceeded("Compressed \(report.wrappers.count) times over; the viewer stops here.")))
                return
            }
            // What is inside is anybody's guess again — but it is still the same attribute.
            let inside = ContentHint(storage: .binary, attributeName: hint.attributeName)
            decode(
                inner, candidates: self.candidates(for: inner, hint: inside), hint: inside, limits: limits,
                into: &report)
            return
        }
    }

    /// Trees are built by recursion, `maxTreeDepth` deep and several frames a level — more than the 512 KB a
    /// Swift concurrency worker has, in a debug build. Where the caller happens to be running must not decide
    /// whether a hostile archive can overflow the stack, so decoding brings its own: a thread per call, which
    /// costs microseconds against a decode that is asked for once per field the user looks at.
    private static func onDeepStack(_ body: @escaping @Sendable () -> ContentReport) -> ContentReport {
        final class Box: @unchecked Sendable {
            var value: ContentReport?
        }
        let box = Box()
        let done = DispatchSemaphore(value: 0)
        let thread = Thread {
            box.value = body()
            done.signal()
        }
        thread.name = "org.coredatadabbi.content-decode"
        thread.stackSize = 16 * 1024 * 1024
        thread.start()
        done.wait()
        // `body` has run: `signal` comes after the assignment.
        return box.value!
    }

    private static func describe(_ error: any Error) -> DabbiError {
        (error as? DabbiError)
            ?? DabbiError(.contentMalformed, "The content could not be decoded.", underlying: error)
    }

    static func sha256(_ data: Data) -> String {
        SHA256.hash(data: data).map { String($0, radix: 16).leftPadded(to: 2) }.joined()
    }
}
