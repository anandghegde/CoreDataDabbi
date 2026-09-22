import DabbiTestSupport
import FixtureKit
import Foundation

/// What the two baseline suites in this target share (PRD §10): both are off unless `DABBI_PERF` is set, both
/// measure the million-row `large` fixture, and both print their numbers so `Scripts/perf.sh` shows them.
///
/// Numbers are also written as JSON when `DABBI_PERF_OUTPUT` names a file — one file per suite, its name added to
/// the one given, because two suites writing the same path would leave only the second.
enum PerfBaseline {
    static let isEnabled = ProcessInfo.processInfo.environment["DABBI_PERF"] != nil
    static let clock = ContinuousClock()

    /// The `large` fixture, preferring one `Scripts/perf.sh` has already generated at the row count it asked for:
    /// writing a million rows takes minutes, and every suite here wants the same store.
    static func largeFixture() throws -> FixtureLocation {
        let environment = ProcessInfo.processInfo.environment
        if let root = environment["DABBI_FIXTURES"],
            let existing = FixtureBuilder.existing(.large, in: URL(fileURLWithPath: root, isDirectory: true)),
            existing.manifest.entityCounts["Event"] == LargeFixture.rowCount()
        {
            return existing
        }
        return try TestFixtures.location(.large)
    }

    /// How long `body` took, in milliseconds.
    static func measure(_ body: () async throws -> Void) async rethrows -> Double {
        milliseconds(try await clock.measure { try await body() })
    }

    static func milliseconds(_ duration: Duration) -> Double {
        let parts = duration.components
        return Double(parts.seconds) * 1000 + Double(parts.attoseconds) / 1e15
    }

    static func median(_ samples: [Double]) -> Double {
        let sorted = samples.sorted()
        return sorted.isEmpty ? 0 : sorted[sorted.count / 2]
    }

    static func report(_ results: [String: Double], as name: String) throws {
        for (key, value) in results.sorted(by: { $0.key < $1.key }) {
            print("PERF \(key): \(String(format: "%.1f", value))")
        }
        guard let output = ProcessInfo.processInfo.environment["DABBI_PERF_OUTPUT"] else { return }
        let path = URL(fileURLWithPath: output)
        let destination = path.deletingPathExtension().appendingPathExtension(name).appendingPathExtension("json")
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(results).write(to: destination)
    }
}
