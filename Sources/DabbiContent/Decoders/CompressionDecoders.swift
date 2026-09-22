import DabbiBase
import Foundation

/// gzip (RFC 1952): a header of variable length, a raw DEFLATE stream, a checksum. The inflated bytes go back
/// into detection (CNT-1), capped at `DecodeLimits.maxInflatedBytes`.
public struct GzipDecoder: ContentDecoder {
    public let id = ContentTypeID.gzip

    public init() {}

    public func probe(_ head: ByteView, hint: ContentHint) -> Confidence? {
        head.sniffed == .gzip ? .certain : nil
    }

    public func decode(_ data: Data, limits: DecodeLimits) throws -> DecodedContent {
        let bytes = [UInt8](data.prefix(64 * 1024))
        guard bytes.count >= 18, bytes[0] == 0x1F, bytes[1] == 0x8B, bytes[2] == 8 else {
            throw malformed("gzip stream", "Its header is incomplete.")
        }
        let flags = bytes[3]
        var position = 10
        // Every length in the header is the file's own claim; `position` is checked after each one.
        func skip(_ count: Int) throws {
            position += count
            guard position <= bytes.count else { throw malformed("gzip stream", "Its header is incomplete.") }
        }
        func skipZeroTerminated() throws {
            guard position < bytes.count, let end = bytes[position...].firstIndex(of: 0) else {
                throw malformed("gzip stream", "A name in its header does not end.")
            }
            position = end + 1
        }
        if flags & 0x04 != 0 {  // FEXTRA: a little-endian length, then that many bytes
            try skip(2)
            try skip(Int(bytes[position - 2]) | Int(bytes[position - 1]) << 8)
        }
        if flags & 0x08 != 0 { try skipZeroTerminated() }  // FNAME
        if flags & 0x10 != 0 { try skipZeroTerminated() }  // FCOMMENT
        if flags & 0x02 != 0 { try skip(2) }  // FHCRC
        guard position < data.count else { throw malformed("gzip stream", "There is nothing after its header.") }

        let inner = try BoundedDecompressor.decompress(
            data.dropFirst(position), using: .rawDeflate, maxOutputBytes: limits.maxInflatedBytes)
        return .wrapped(by: id, inner: inner)
    }
}

/// zlib (RFC 1950) — what `NSData.compressed(using: .zlib)` does *not* write (that is raw DEFLATE, which has no
/// signature to go by) but what most other libraries do.
public struct ZlibDecoder: ContentDecoder {
    public let id = ContentTypeID.zlib

    public init() {}

    public func probe(_ head: ByteView, hint: ContentHint) -> Confidence? {
        // Two bytes are a thin signature: one blob in a few thousand passes by chance, and then fails to inflate.
        head.sniffed == .zlib ? .likely : nil
    }

    public func decode(_ data: Data, limits: DecodeLimits) throws -> DecodedContent {
        guard data.count > 6, data[data.startIndex + 1] & 0x20 == 0 else {
            throw malformed("zlib stream", "It is too short, or needs a preset dictionary.")
        }
        let inner = try BoundedDecompressor.decompress(data, using: .zlib, maxOutputBytes: limits.maxInflatedBytes)
        return .wrapped(by: id, inner: inner)
    }
}
