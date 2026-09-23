import ArgumentParser
import FixtureKit
import Foundation

/// Plays the running app in tracking tests: applies `WriterScript` to a Notes store and reports what it changed.
///
/// The Mac half of the writer (M0-08). Its iOS-simulator twin is `Tools/Writer/iOS`, and both run the same
/// `WriterScript`, so what the end-to-end test asserts is one script's account of itself, not two.
@main
struct Writer: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "Writer",
        abstract: "Mutates a Notes store the way a running app would, and reports what it changed.",
        subcommands: [Seed.self, Run.self],
        defaultSubcommand: Run.self
    )

    struct Options: ParsableArguments {
        @Argument(help: "The store to write. Made by `seed`, which overwrites whatever is there.")
        var store: String

        @Option(help: "Where to write the JSON report. Standard output when not given.")
        var report: String?

        @Option(name: .customLong("interval-ms"), help: "Pause between transactions, in milliseconds.")
        var intervalMilliseconds = 250

        var storeURL: URL { URL(fileURLWithPath: store) }

        func script() -> WriterScript {
            WriterScript(writer: "macOS", intervalMilliseconds: intervalMilliseconds)
        }

        func emit(_ report: WriterScript.Report) throws {
            let data = try report.data
            if let path = self.report {
                try data.write(to: URL(fileURLWithPath: path), options: .atomic)
            } else {
                FileHandle.standardOutput.write(data)
                FileHandle.standardOutput.write(Data("\n".utf8))
            }
        }
    }

    /// Makes the store and commits the rows the tracker primes over.
    struct Seed: ParsableCommand {
        static let configuration = CommandConfiguration(
            commandName: "seed", abstract: "Creates the store and commits the rows tracking starts from.")

        @OptionGroup var options: Options

        func run() throws {
            try options.emit(try options.script().seed(into: options.storeURL))
        }
    }

    /// Commits the script, one transaction per step.
    struct Run: ParsableCommand {
        static let configuration = CommandConfiguration(
            commandName: "run", abstract: "Commits the script against a seeded store, one step per transaction.")

        @OptionGroup var options: Options

        @Flag(help: "Print each change as a line of JSON as it is committed.")
        var follow = false

        func run() throws {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.sortedKeys]
            let report = try options.script().run(on: options.storeURL) { change in
                guard follow, let line = try? encoder.encode(change) else { return }
                FileHandle.standardError.write(line)
                FileHandle.standardError.write(Data("\n".utf8))
            }
            try options.emit(report)
        }
    }
}
