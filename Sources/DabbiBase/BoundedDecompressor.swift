import Compression
import Foundation

/// Streaming decompression with a hard cap on the output size, so a hostile payload cannot exhaust memory.
///
/// Used for the store's cached model (ARCHITECTURE.md §6.3) and, later, for compressed field content.
public enum BoundedDecompressor {
    public enum Algorithm: Sendable, CaseIterable {
        /// A raw DEFLATE stream (RFC 1951) — what Core Data writes for the model cache.
        case rawDeflate
        /// DEFLATE inside a zlib wrapper (RFC 1950): two header bytes and an Adler-32 trailer.
        case zlib
        case lzfse
        case lz4
        case lzma
    }

    /// Decompresses `data`, failing with `.limitExceeded` as soon as the output would pass `maxOutputBytes`.
    public static func decompress(_ data: Data, using algorithm: Algorithm, maxOutputBytes: Int) throws -> Data {
        var input = data
        let native: compression_algorithm
        switch algorithm {
        case .rawDeflate: native = COMPRESSION_ZLIB
        case .zlib:
            guard input.count > 6 else { throw failure("The zlib stream is too short.") }
            // The Compression framework speaks raw DEFLATE only: drop the 2-byte header. The trailer is ignored
            // because the stream ends itself.
            input = input.dropFirst(2)
            native = COMPRESSION_ZLIB
        case .lzfse: native = COMPRESSION_LZFSE
        case .lz4: native = COMPRESSION_LZ4
        case .lzma: native = COMPRESSION_LZMA
        }
        guard !input.isEmpty else { throw failure("There is no data to decompress.") }

        let stream = UnsafeMutablePointer<compression_stream>.allocate(capacity: 1)
        defer { stream.deallocate() }
        guard compression_stream_init(stream, COMPRESSION_STREAM_DECODE, native) == COMPRESSION_STATUS_OK else {
            throw failure("The decompressor could not be initialised.")
        }
        defer { compression_stream_destroy(stream) }

        let chunkSize = 64 * 1024
        let chunk = UnsafeMutablePointer<UInt8>.allocate(capacity: chunkSize)
        defer { chunk.deallocate() }

        var output = Data()
        try input.withUnsafeBytes { (source: UnsafeRawBufferPointer) in
            guard let base = source.bindMemory(to: UInt8.self).baseAddress else {
                throw failure("There is no data to decompress.")
            }
            stream.pointee.src_ptr = base
            stream.pointee.src_size = source.count

            while true {
                stream.pointee.dst_ptr = chunk
                stream.pointee.dst_size = chunkSize
                let status = compression_stream_process(stream, Int32(COMPRESSION_STREAM_FINALIZE.rawValue))
                let produced = chunkSize - stream.pointee.dst_size

                if output.count + produced > maxOutputBytes {
                    throw DabbiError(
                        .limitExceeded,
                        "The compressed data expands beyond the \(maxOutputBytes)-byte safety limit.",
                        arguments: ["limit": String(maxOutputBytes)]
                    )
                }
                output.append(chunk, count: produced)

                switch status {
                case COMPRESSION_STATUS_END:
                    return
                case COMPRESSION_STATUS_OK:
                    // No output and no input left means a truncated stream; stop instead of spinning.
                    if produced == 0 && stream.pointee.src_size == 0 {
                        throw failure("The compressed stream ends unexpectedly.")
                    }
                default:
                    throw failure("The data is not a valid \(algorithm) stream.")
                }
            }
        }
        return output
    }

    private static func failure(_ message: String) -> DabbiError {
        DabbiError(.decompressionFailed, message)
    }
}
