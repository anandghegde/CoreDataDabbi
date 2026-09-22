import ArgumentParser
import ContentFuzzKit
import DabbiContent
import Foundation

/// `swift run -c release ContentFuzz --iterations 1000000`
///
/// The plan asked for a libFuzzer target; Xcode's toolchains do not ship the libFuzzer runtime, and a fuzzer
/// contributors cannot run is not one. This is seeded mutation fuzzing instead: slower to find deep bugs, but
/// it runs anywhere `swift run` does. The input being decoded is always on disk, so after a crash it is
/// `<work>/last-input.bin`.
@main
struct ContentFuzz: ParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Mutation-fuzzes the content decoders; exits non-zero on a violation (a crash speaks for itself).")

    @Option(help: "How many inputs to try.")
    var iterations = 100_000

    @Option(help: "The random seed. A run is reproducible from its seed and iteration count.")
    var seed: UInt64 = 0xDABB1

    @Option(help: "A directory of extra seed files (real-world blobs are the best ones).")
    var corpus: String?

    @Option(help: "Where the current input and any findings are written.")
    var work = ".build/content-fuzz"

    @Option(help: "Decode this one file, as a crash reproducer, and print the report.")
    var reproduce: String?

    func run() throws {
        if let reproduce {
            let data = try Data(contentsOf: URL(fileURLWithPath: reproduce))
            let report = ContentRegistry.standard.decode(data, limits: Campaign.tightLimits)
            print("type: \(report.type?.rawValue ?? "—"), wrappers: \(report.wrappers.map(\.rawValue))")
            for issue in report.issues { print("issue [\(issue.decoder.rawValue)]: \(issue.error.message)") }
            if case .tree(let node, _, _) = report.content { print("\(node.nodeCount) nodes") }
            return
        }

        let directory = URL(fileURLWithPath: work, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let current = directory.appendingPathComponent("last-input.bin")

        var campaign = Campaign()
        if let corpus {
            let files = try FileManager.default.contentsOfDirectory(
                at: URL(fileURLWithPath: corpus, isDirectory: true), includingPropertiesForKeys: nil)
            for file in files.sorted(by: { $0.path < $1.path }) {
                if let data = try? Data(contentsOf: file), !data.isEmpty, data.count <= 64 * 1024 {
                    campaign.seeds.append((file.lastPathComponent, data))
                }
            }
        }
        print("\(campaign.seeds.count) seeds, \(iterations) iterations, seed \(seed)")

        let started = Date()
        let outcome = campaign.run(iterations: iterations, seed: seed) { iteration, input in
            // Not atomic: a rename per input would halve the speed, and a torn file is still a lead.
            try? input.write(to: current)
            if iteration > 0, iteration % 10_000 == 0 {
                let rate = Double(iteration) / Date().timeIntervalSince(started)
                print("  \(iteration) inputs, \(Int(rate))/s")
            }
        }

        for (path, count) in outcome.tally.sorted(by: { $0.value > $1.value }) {
            print("  \(String(count).padding(toLength: 9, withPad: " ", startingAt: 0))\(path)")
        }
        let violations = outcome.violations
        for (number, violation) in violations.enumerated() {
            let file = directory.appendingPathComponent("violation-\(number).bin")
            try violation.input.write(to: file)
            print("VIOLATION \(violation) → \(file.path)")
        }
        print("done: \(violations.count) violation(s) in \(Int(Date().timeIntervalSince(started))) s")
        if !violations.isEmpty { throw ExitCode.failure }
    }
}
