import FixtureKit
import Foundation

/// Generates fixtures on demand, once per test process, so `swift test` works on a clean clone.
public enum TestFixtures {
    private static let lock = NSLock()
    nonisolated(unsafe) private static var built: [Fixture: FixtureLocation] = [:]

    /// A folder unique to this test process, removed by the OS with the rest of the temporary directory.
    public static let root: URL = {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "CoreDataDabbiFixtures-\(ProcessInfo.processInfo.processIdentifier)", isDirectory: true)
        try? FileManager.default.removeItem(at: url)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }()

    public static func location(_ fixture: Fixture) throws -> FixtureLocation {
        try lock.withLock {
            if let location = built[fixture] { return location }
            let location = try FixtureBuilder.build(fixture, in: root)
            built[fixture] = location
            return location
        }
    }

    /// A private, writable copy of a fixture, for tests that change or damage it.
    public static func scratchCopy(_ fixture: Fixture) throws -> FixtureLocation {
        let source = try location(fixture)
        let directory = root.appendingPathComponent("scratch-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.copyItem(at: source.directory, to: directory)
        return FixtureLocation(directory: directory, manifest: source.manifest)
    }
}
