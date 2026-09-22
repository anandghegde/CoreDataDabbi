import FixtureKit
import Foundation

/// Generates fixtures on demand, once per test process — what `TestFixtures` is to the package's tests, which
/// the hosted tests cannot link: it would bring a second copy of the engine into the app's process.
enum AppFixtures {
    private static let lock = NSLock()
    nonisolated(unsafe) private static var built: [Fixture: FixtureLocation] = [:]

    static let root: URL = {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "CoreDataDabbiAppFixtures-\(ProcessInfo.processInfo.processIdentifier)", isDirectory: true)
        try? FileManager.default.removeItem(at: url)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        // The temporary directory is behind a symlink; the engine reports real paths.
        return url.resolvingSymlinksInPath()
    }()

    static func location(_ fixture: Fixture) throws -> FixtureLocation {
        try lock.withLock {
            if let location = built[fixture] { return location }
            let location = try FixtureBuilder.build(fixture, in: root)
            built[fixture] = location
            return location
        }
    }

    /// One generated ahead of time, where `DABBI_FIXTURES` says they are. The million-row fixture takes longer
    /// to write than everything a performance run measures put together, so it is made once and kept
    /// (`Scripts/perf.sh`).
    static func prebuilt(_ fixture: Fixture) -> FixtureLocation? {
        guard let root = ProcessInfo.processInfo.environment["DABBI_FIXTURES"] else { return nil }
        return FixtureBuilder.existing(fixture, in: URL(fileURLWithPath: root, isDirectory: true))
    }

    /// An empty folder of the test's own.
    static func scratchFolder(_ name: String = "scratch") throws -> URL {
        let url = root.appendingPathComponent("\(name)-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }
}
