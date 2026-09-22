import Foundation
import Testing

@testable import DabbiLocator

@Suite struct MachOEntitlementsTests {
    @Test func readsTheSectionASimulatorBuildCarries() throws {
        let entitlements = try #require(MachOEntitlements.read(executable: try TestBinaries.withSection.get()))
        #expect(entitlements.applicationGroups == TestBinaries.groups)
        #expect(entitlements.isSandboxed)
    }

    @Test func readsTheCodeSignatureOfASignedBinary() throws {
        let entitlements = try #require(MachOEntitlements.read(executable: try TestBinaries.signed.get()))
        #expect(entitlements.applicationGroups == TestBinaries.groups)
        #expect(entitlements.isSandboxed)
    }

    @Test func aBinaryWithoutEntitlementsHasNone() throws {
        #expect(MachOEntitlements.read(executable: try TestBinaries.plain.get()) == nil)
    }

    /// A universal, Apple-signed app: fat header, arm64e slice, the signature's entitlements blob.
    @Test func readsASystemApp() throws {
        let calculator = URL(fileURLWithPath: "/System/Applications/Calculator.app")
        try #require(FileManager.default.fileExists(atPath: calculator.path))
        let entitlements = try #require(MachOEntitlements.read(appBundle: calculator))
        #expect(entitlements.isSandboxed)
    }

    @Test func thingsThatAreNotExecutablesHaveNone() throws {
        #expect(MachOEntitlements.entitlementsPlist(in: Data()) == nil)
        #expect(MachOEntitlements.entitlementsPlist(in: Data("#!/bin/sh\necho hello\n".utf8)) == nil)
        #expect(MachOEntitlements.entitlementsPlist(in: Data(repeating: 0xFF, count: 4096)) == nil)
        #expect(MachOEntitlements.read(executable: URL(fileURLWithPath: "/nonexistent/binary")) == nil)
        // A fat header that promises slices far beyond the end of the file.
        var fat = Data([0xCA, 0xFE, 0xBA, 0xBE, 0, 0, 0, 2])
        fat.append(Data(repeating: 0x7F, count: 40))
        #expect(MachOEntitlements.entitlementsPlist(in: fat) == nil)
    }

    /// Every prefix of a real binary, and the binary with bytes of its header overwritten: never a trap, and
    /// never bytes from outside the file.
    @Test func survivesTruncatedAndDamagedBinaries() throws {
        for binary in [try TestBinaries.withSection.get(), try TestBinaries.signed.get()] {
            let whole = try Data(contentsOf: binary)
            for length in stride(from: 0, to: whole.count, by: max(1, whole.count / 400)) {
                _ = MachOEntitlements.entitlementsPlist(in: whole.prefix(length))
            }
            var generator = SystemRandomNumberGenerator()
            for _ in 0..<2_000 {
                var damaged = whole
                for _ in 0..<Int.random(in: 1...8, using: &generator) {
                    // The header and the load commands are where the offsets are.
                    let index = Int.random(in: 0..<min(whole.count, 4096), using: &generator)
                    damaged[index] = UInt8.random(in: 0...255, using: &generator)
                }
                if let plist = MachOEntitlements.entitlementsPlist(in: damaged) { #expect(plist.count <= whole.count) }
            }
        }
    }

    @Test func aDataSliceThatDoesNotStartAtZeroReadsTheSame() throws {
        let whole = try Data(contentsOf: try TestBinaries.withSection.get())
        let padded = Data(repeating: 0, count: 13) + whole
        let slice = padded[13...]
        #expect(MachOEntitlements.entitlementsPlist(in: slice) == MachOEntitlements.entitlementsPlist(in: whole))
    }
}
