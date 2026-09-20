import DabbiBase
import Foundation
import Testing

@Suite struct ObjCGuardTests {
    @Test func returnsTheBodysValue() throws {
        #expect(try objcGuarded("unused") { 21 * 2 } == 42)
    }

    @Test func turnsAnExceptionIntoADabbiError() {
        let error = #expect(throws: DabbiError.self) {
            try objcGuarded("Parsing failed.", code: .invalidPredicate) {
                NSPredicate(format: "name ==", argumentArray: [])
            }
        }
        #expect(error?.code == .invalidPredicate)
        #expect(error?.message == "Parsing failed.")
        #expect(error?.arguments["exception"] == NSExceptionName.invalidArgumentException.rawValue)
        #expect(error?.diagnosis.first?.contains("Unable to parse") == true)
    }

    @Test func passesSwiftErrorsThroughUnchanged() {
        struct Sentinel: Error {}
        #expect(throws: Sentinel.self) { try objcGuarded("unused") { throw Sentinel() } }
    }
}

@Suite struct BoundedDecompressorTests {
    private let plain = Data(String(repeating: "core data dabbi ", count: 4_096).utf8)

    @Test func inflatesRawDeflate() throws {
        let packed = try (plain as NSData).compressed(using: .zlib) as Data
        #expect(packed.count < plain.count / 10)
        #expect(try BoundedDecompressor.decompress(packed, using: .rawDeflate, maxOutputBytes: 1 << 20) == plain)
    }

    @Test(arguments: [NSData.CompressionAlgorithm.lzfse, .lz4, .lzma])
    func inflatesTheOtherAlgorithms(_ algorithm: NSData.CompressionAlgorithm) throws {
        let packed = try (plain as NSData).compressed(using: algorithm) as Data
        let ours: BoundedDecompressor.Algorithm =
            switch algorithm {
            case .lzfse: .lzfse
            case .lz4: .lz4
            default: .lzma
            }
        #expect(try BoundedDecompressor.decompress(packed, using: ours, maxOutputBytes: 1 << 20) == plain)
    }

    @Test func stopsAtTheLimit() throws {
        let packed = try (plain as NSData).compressed(using: .zlib) as Data
        let error = #expect(throws: DabbiError.self) {
            try BoundedDecompressor.decompress(packed, using: .rawDeflate, maxOutputBytes: 1_000)
        }
        #expect(error?.code == .limitExceeded)
    }

    @Test func rejectsGarbage() {
        let error = #expect(throws: DabbiError.self) {
            try BoundedDecompressor.decompress(
                Data(repeating: 0xFF, count: 64), using: .rawDeflate, maxOutputBytes: 1_000)
        }
        #expect(error?.code == .decompressionFailed)
    }
}

@Suite struct DabbiErrorTests {
    @Test func rendersForTerminals() {
        let error = DabbiError(
            .modelCacheMissing, "No cached model.", diagnosis: ["Looked in Z_MODELCACHE."],
            recovery: ["Choose the app."])
        #expect(
            error.description == """
                No cached model. [model.cacheMissing]
                  · Looked in Z_MODELCACHE.
                  → Choose the app.
                """)
        #expect(error.errorDescription == "No cached model.")
    }

    @Test func redactedValuesNeverPrint() {
        let secret = Redacted("row data")
        #expect("\(secret)" == "<redacted>")
        #expect(String(reflecting: secret) == "<redacted>")
        #expect(secret.unredacted == "row data")
    }
}
