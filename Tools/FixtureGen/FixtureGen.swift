import ArgumentParser
import FixtureKit
import Foundation

/// Generates the fixture zoo. Fixtures are never checked in; CI caches the output keyed on this tool's sources.
@main
struct FixtureGen: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "FixtureGen",
        abstract: "Generates the Core Data stores and model files the tests and the CLI smoke test run against."
    )

    @Option(name: .shortAndLong, help: "The folder to generate into. One sub-folder per fixture.")
    var output = "Fixtures"

    @Option(name: .long, parsing: .upToNextOption, help: "Generate only these fixtures.")
    var only: [String] = []

    @Flag(name: .long, help: "List the fixtures and exit.")
    var list = false

    func run() throws {
        if list {
            for fixture in Fixture.allCases { print(fixture.rawValue) }
            return
        }
        let selected = try only.isEmpty ? Fixture.allCases : only.map(Self.fixture(named:))
        let root = URL(fileURLWithPath: output, isDirectory: true)
        for fixture in selected {
            let location = try FixtureBuilder.build(fixture, in: root)
            print("\(fixture.rawValue): \(location.manifest.summary)")
        }
        print("Generated \(selected.count) fixture(s) in \(root.path)")
    }

    private static func fixture(named name: String) throws -> Fixture {
        guard let fixture = Fixture(rawValue: name) else {
            throw ValidationError(
                "Unknown fixture '\(name)'. Known: \(Fixture.allCases.map(\.rawValue).joined(separator: ", "))")
        }
        return fixture
    }
}
