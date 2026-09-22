import DabbiBase
import Foundation

/// The entitlements the locator cares about: which shared containers an app may use (PRJ-8, PRJ-11).
public struct AppEntitlements: Sendable, Hashable, Codable {
    /// `com.apple.security.application-groups`.
    public var applicationGroups: [String]
    /// `com.apple.security.app-sandbox`: a Mac app's data lives under `~/Library/Containers`.
    public var isSandboxed: Bool

    public init(applicationGroups: [String] = [], isSandboxed: Bool = false) {
        self.applicationGroups = applicationGroups
        self.isSandboxed = isSandboxed
    }
}

/// Reads an executable's entitlements out of the file, without running `codesign`.
///
/// They are in one of two places. A signed app carries them in its code signature (`LC_CODE_SIGNATURE` → the
/// entitlements blob). An app built for the simulator is signed ad hoc without them; Xcode puts them into a
/// section of the binary instead — `__TEXT,__entitlements` — which is where the simulator's runtime looks.
/// The section is tried first, because a simulator build has both and only the section is complete.
///
/// The file is somebody's build product, not ours: every offset is checked, and a file that does not add up
/// simply has no entitlements.
public enum MachOEntitlements {
    /// A binary with more than this is not an app's main executable; the entitlements are near the start anyway.
    static let maxMappedBytes = 512 * 1024 * 1024

    public static func read(executable url: URL) -> AppEntitlements? {
        guard let data = try? Data(contentsOf: url, options: .alwaysMapped), data.count <= maxMappedBytes,
            let plist = entitlementsPlist(in: data),
            let values = try? PropertyListSerialization.propertyList(from: plist, format: nil) as? [String: Any]
        else { return nil }
        return AppEntitlements(
            applicationGroups: values["com.apple.security.application-groups"] as? [String] ?? [],
            isSandboxed: values["com.apple.security.app-sandbox"] as? Bool ?? false)
    }

    /// The main executable of an app bundle: `CFBundleExecutable`, in `Contents/MacOS` for a Mac app.
    public static func read(appBundle url: URL) -> AppEntitlements? {
        guard let info = BundleInfo(bundle: url), let executable = info.executableURL else { return nil }
        return read(executable: executable)
    }

    // MARK: Mach-O

    private static let fatMagic: UInt32 = 0xCAFE_BABE
    private static let fatMagic64: UInt32 = 0xCAFE_BABF
    private static let machMagic64: UInt32 = 0xFEED_FACF
    private static let segment64: UInt32 = 0x19
    private static let codeSignature: UInt32 = 0x1D
    private static let superBlobMagic: UInt32 = 0xFADE_0CC0
    private static let entitlementsBlobMagic: UInt32 = 0xFADE_7171
    private static let entitlementsSlot: UInt32 = 5

    static func entitlementsPlist(in file: Data) -> Data? {
        let bytes = Bytes(file)
        guard let magic = bytes.bigEndian32(at: 0) else { return nil }
        guard magic == fatMagic || magic == fatMagic64 else { return thin(bytes, at: 0) }

        // A universal binary: every slice has the same entitlements, so the first that reads wins.
        let wide = magic == fatMagic64
        guard let count = bytes.bigEndian32(at: 4), count <= 16 else { return nil }
        for index in 0..<Int(count) {
            let entry = 8 + index * (wide ? 32 : 20)
            let offset = wide ? bytes.bigEndian64(at: entry + 8) : bytes.bigEndian32(at: entry + 8).map(UInt64.init)
            if let offset, let start = Int(exactly: offset), let found = thin(bytes, at: start) { return found }
        }
        return nil
    }

    private static func thin(_ bytes: Bytes, at base: Int) -> Data? {
        guard bytes.littleEndian32(at: base) == machMagic64, let commandCount = bytes.littleEndian32(at: base + 16),
            commandCount <= 4096
        else { return nil }
        var position = base + 32
        var signature: Data?
        for _ in 0..<commandCount {
            guard let command = bytes.littleEndian32(at: position), let size = bytes.littleEndian32(at: position + 4),
                size >= 8
            else { break }
            if command == segment64, let section = entitlementsSection(bytes, segment: position, size: Int(size), base)
            {
                return section
            }
            if command == codeSignature, let offset = bytes.littleEndian32(at: position + 8),
                let length = bytes.littleEndian32(at: position + 12)
            {
                signature = signedEntitlements(bytes, at: base + Int(offset), length: Int(length))
            }
            position += Int(size)
        }
        return signature
    }

    /// `__TEXT,__entitlements` of the segment command at `segment`.
    private static func entitlementsSection(_ bytes: Bytes, segment: Int, size: Int, _ base: Int) -> Data? {
        guard bytes.name(at: segment + 8) == "__TEXT", let sectionCount = bytes.littleEndian32(at: segment + 64),
            sectionCount <= 1024, 72 + Int(sectionCount) * 80 <= size
        else { return nil }
        for index in 0..<Int(sectionCount) {
            let section = segment + 72 + index * 80
            guard bytes.name(at: section) == "__entitlements" else { continue }
            guard let length = bytes.littleEndian64(at: section + 40),
                let offset = bytes.littleEndian32(at: section + 48),
                let count = Int(exactly: length)
            else { return nil }
            return bytes.slice(at: base + Int(offset), count: count)
        }
        return nil
    }

    /// The entitlements blob of the signature's super blob. The signature is big-endian throughout.
    private static func signedEntitlements(_ bytes: Bytes, at start: Int, length: Int) -> Data? {
        guard bytes.bigEndian32(at: start) == superBlobMagic, let count = bytes.bigEndian32(at: start + 8),
            count <= 64
        else { return nil }
        for index in 0..<Int(count) {
            let entry = start + 12 + index * 8
            guard bytes.bigEndian32(at: entry) == entitlementsSlot, let offset = bytes.bigEndian32(at: entry + 4)
            else { continue }
            let blob = start + Int(offset)
            guard Int(offset) < length, bytes.bigEndian32(at: blob) == entitlementsBlobMagic,
                let blobLength = bytes.bigEndian32(at: blob + 4), blobLength >= 8
            else { return nil }
            return bytes.slice(at: blob + 8, count: Int(blobLength) - 8)
        }
        return nil
    }

    /// Bounds-checked reads: `nil` instead of a trap.
    private struct Bytes {
        let data: Data
        init(_ data: Data) { self.data = data }

        func slice(at offset: Int, count: Int) -> Data? {
            guard offset >= 0, count >= 0, count <= data.count, offset <= data.count - count else { return nil }
            return data.subdata(in: data.startIndex + offset..<data.startIndex + offset + count)
        }

        private func integer(at offset: Int, size: Int, bigEndian: Bool) -> UInt64? {
            guard let bytes = slice(at: offset, count: size) else { return nil }
            return (bigEndian ? Array(bytes) : bytes.reversed()).reduce(0) { $0 << 8 | UInt64($1) }
        }

        func bigEndian32(at offset: Int) -> UInt32? { integer(at: offset, size: 4, bigEndian: true).map(UInt32.init) }
        func bigEndian64(at offset: Int) -> UInt64? { integer(at: offset, size: 8, bigEndian: true) }
        func littleEndian32(at offset: Int) -> UInt32? {
            integer(at: offset, size: 4, bigEndian: false).map(UInt32.init)
        }
        func littleEndian64(at offset: Int) -> UInt64? { integer(at: offset, size: 8, bigEndian: false) }

        /// A segment or section name: sixteen bytes, zero-padded.
        func name(at offset: Int) -> String? {
            slice(at: offset, count: 16).map { String(decoding: $0.prefix { $0 != 0 }, as: UTF8.self) }
        }
    }
}

/// What the locator reads from an app's `Info.plist`.
struct BundleInfo {
    let bundleURL: URL
    let values: [String: Any]

    init?(bundle url: URL) {
        // iOS-style bundles are flat; Mac bundles keep everything under Contents.
        let candidates = [url.appendingPathComponent("Info.plist"), url.appendingPathComponent("Contents/Info.plist")]
        for candidate in candidates {
            guard let data = try? Data(contentsOf: candidate),
                let plist = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any]
            else { continue }
            bundleURL = url
            values = plist
            return
        }
        return nil
    }

    var bundleID: String? { values["CFBundleIdentifier"] as? String }
    var version: String? { values["CFBundleShortVersionString"] as? String ?? values["CFBundleVersion"] as? String }

    var displayName: String {
        for key in ["CFBundleDisplayName", "CFBundleName"] {
            if let name = values[key] as? String, !name.isEmpty { return name }
        }
        return bundleURL.deletingPathExtension().lastPathComponent
    }

    var executableURL: URL? {
        guard let name = values["CFBundleExecutable"] as? String, !name.isEmpty, !name.contains("/") else { return nil }
        let flat = bundleURL.appendingPathComponent(name)
        if FileManager.default.fileExists(atPath: flat.path) { return flat }
        let mac = bundleURL.appendingPathComponent("Contents/MacOS/\(name)")
        return FileManager.default.fileExists(atPath: mac.path) ? mac : nil
    }

    /// The largest file among the icons the bundle names. Apps whose icons live only in `Assets.car` have none
    /// to offer; the browser then shows a generic icon.
    var iconURL: URL? {
        var names: [String] = []
        for key in ["CFBundleIcons", "CFBundleIcons~ipad"] {
            if let icons = values[key] as? [String: Any], let primary = icons["CFBundlePrimaryIcon"] as? [String: Any] {
                names += primary["CFBundleIconFiles"] as? [String] ?? []
            }
        }
        names += values["CFBundleIconFiles"] as? [String] ?? []
        if let single = values["CFBundleIconFile"] as? String { names.append(single) }
        let prefixes = names.filter { !$0.isEmpty && !$0.contains("/") }
        guard !prefixes.isEmpty,
            let files = try? FileManager.default.contentsOfDirectory(
                at: bundleURL, includingPropertiesForKeys: [.fileSizeKey], options: [.skipsHiddenFiles])
        else { return nil }
        return
            files
            .filter { file in
                ["png", "icns"].contains(file.pathExtension.lowercased())
                    && prefixes.contains { file.lastPathComponent.hasPrefix($0) }
            }
            .max { size(of: $0) < size(of: $1) }
    }

    private func size(of url: URL) -> Int {
        (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
    }
}
