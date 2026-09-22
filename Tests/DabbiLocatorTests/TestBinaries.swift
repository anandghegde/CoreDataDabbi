import DabbiTestSupport
import Foundation

/// Small executables with known entitlements, built once per test process with the toolchain that built the
/// tests. Real Mach-O files from the real linker and the real `codesign`: the reader is only worth something
/// if it reads what those two write.
enum TestBinaries {
    static let groups = ["group.org.coredatadabbi.tests", "group.org.coredatadabbi.other"]

    /// Entitlements in `__TEXT,__entitlements`, the way Xcode builds for the simulator. Universal, when the
    /// toolchain can build both slices.
    static let withSection = Result { try build("section", universal: true, signed: false) }
    /// Entitlements in the code signature, the way everything else is signed.
    static let signed = Result { try build("signed", universal: false, signed: true) }
    static let plain = Result { try build("plain", universal: false, signed: false, entitled: false) }

    private static func build(_ name: String, universal: Bool, signed: Bool, entitled: Bool = true) throws -> URL {
        let folder = TestFixtures.root.appendingPathComponent("binaries-\(name)", isDirectory: true)
        try? FileManager.default.removeItem(at: folder)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let source = folder.appendingPathComponent("main.c")
        try Data("int main(void) { return 0; }\n".utf8).write(to: source)
        let entitlements = folder.appendingPathComponent("entitlements.plist")
        let plist: [String: Any] = [
            "com.apple.security.application-groups": groups, "com.apple.security.app-sandbox": true,
            "application-identifier": "TEAMID.org.coredatadabbi.tests",
        ]
        try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0).write(to: entitlements)
        let binary = folder.appendingPathComponent(name)

        var arguments = ["clang", source.path, "-o", binary.path]
        if entitled, !signed {
            arguments += ["-Wl,-sectcreate,__TEXT,__entitlements,\(entitlements.path)"]
        }
        if universal {
            // Both slices when the SDK has them; a toolchain that cannot is no reason to fail the suite.
            if (try? run(arguments + ["-arch", "arm64", "-arch", "x86_64"])) == nil { try run(arguments) }
        } else {
            try run(arguments)
        }
        if signed {
            try run(["codesign", "--force", "--sign", "-", "--entitlements", entitlements.path, binary.path])
        }
        return binary
    }

    struct ToolFailure: Error, CustomStringConvertible {
        let description: String
    }

    private static func run(_ arguments: [String]) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/xcrun")
        process.arguments = arguments
        let errors = Pipe()
        process.standardError = errors
        process.standardOutput = FileHandle.nullDevice
        try process.run()
        let message = errors.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            throw ToolFailure(description: "\(arguments.prefix(2)): \(String(decoding: message, as: UTF8.self))")
        }
    }
}
