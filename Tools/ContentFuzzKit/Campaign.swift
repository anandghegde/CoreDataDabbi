import DabbiContent
import Foundation

/// A fuzzing run: mutate, decode, check what must hold for any input whatever.
///
/// A crash is the finding this exists for, and a crashed process reports nothing — so `willDecode` sees every
/// input first, and the command-line tool writes it to disk before the decoders get it.
public struct Campaign {
    public struct Violation: Sendable, Hashable, CustomStringConvertible {
        public var iteration: Int
        public var seedName: String
        public var what: String
        public var input: Data

        public var description: String { "#\(iteration) (from \(seedName), \(input.count) bytes): \(what)" }
    }

    public struct Outcome: Sendable {
        public var violations: [Violation] = []
        /// How many inputs ended up as what ("json", "gzip → binaryPlist", "—"): a campaign whose inputs all
        /// end up as hex is not testing the parsers.
        public var tally: [String: Int] = [:]
    }

    public var seeds: [(name: String, data: Data)]
    public var limits: DecodeLimits
    /// Longer than this for one input is a finding: inputs are at most 64 KB.
    public var slowness: Duration = .seconds(5)
    public var registry = ContentRegistry.standard

    public init(seeds: [(name: String, data: Data)] = Corpus.seeds(), limits: DecodeLimits = Campaign.tightLimits) {
        self.seeds = seeds
        self.limits = limits
    }

    /// Small enough that the limits themselves get exercised by 64 KB inputs.
    public static var tightLimits: DecodeLimits {
        var limits = DecodeLimits()
        limits.maxNodes = 2_000
        limits.maxInflatedBytes = 256 * 1024
        limits.maxStructuredBytes = 128 * 1024
        return limits
    }

    public func run(
        iterations: Int, seed: UInt64, willDecode: (Int, Data) -> Void = { _, _ in }
    ) -> Outcome {
        var outcome = Outcome()
        guard !seeds.isEmpty else { return outcome }
        var mutator = Mutator(seed: seed)
        var pool = seeds
        let clock = ContinuousClock()

        for iteration in 0..<iterations {
            // Half from the seeds, so that the formats whose mutants rarely survive keep getting their turn.
            let parent =
                Bool.random(using: &mutator.random)
                ? seeds[Int.random(in: 0..<seeds.count, using: &mutator.random)]
                : pool[Int.random(in: 0..<pool.count, using: &mutator.random)]
            let input = mutator.mutate(parent.data, others: seeds.map(\.data))
            willDecode(iteration, input)

            var report: ContentReport?
            let elapsed = clock.measure { report = registry.decode(input, limits: limits) }
            guard let report else { continue }

            let path = (report.wrappers + [report.type ?? "—"]).map(\.rawValue).joined(separator: " → ")
            outcome.tally[path, default: 0] += 1
            for problem in Self.check(report, of: input, limits: limits) {
                outcome.violations.append(
                    Violation(iteration: iteration, seedName: parent.name, what: problem, input: input))
            }
            if elapsed > slowness {
                outcome.violations.append(
                    Violation(iteration: iteration, seedName: parent.name, what: "took \(elapsed)", input: input))
            }
            // Without coverage to go by, "still decodes as something structured" is the sign of an input worth
            // mutating further: it got past the header checks.
            if case .tree = report.content, pool.count < 512, iteration % 4 == 0 {
                pool.append((parent.name, input))
            }
        }
        return outcome
    }

    /// What must hold for the report of any input.
    public static func check(_ report: ContentReport, of input: Data, limits: DecodeLimits) -> [String] {
        var problems: [String] = []
        if report.byteCount != input.count { problems.append("byteCount \(report.byteCount) ≠ \(input.count)") }
        if report.wrappers.count > limits.maxWrapDepth + 1 { problems.append("\(report.wrappers.count) wrappers") }
        if report.payload.count > max(input.count, limits.maxInflatedBytes) {
            problems.append("payload of \(report.payload.count) bytes")
        }
        if (report.type == nil) != (report.content == .opaque) { problems.append("type and content disagree") }
        if case .tree(let node, _, _) = report.content {
            // A budget of one per node; a dictionary with archived keys shows three nodes for one, and every
            // level may add a “truncated” marker on the way out.
            let bound = limits.maxNodes * 3 + limits.maxTreeDepth * 4 + 16
            let count = node.nodeCount
            if count > bound { problems.append("a tree of \(count) nodes (limit \(limits.maxNodes))") }
        }
        return problems
    }
}
