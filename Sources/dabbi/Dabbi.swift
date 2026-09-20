import ArgumentParser
import DabbiKit
import Foundation

@main
struct Dabbi: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "dabbi",
        abstract: "Inspect Core Data stores.",
        discussion: "Stores are opened read-only. Without --model, the model cached inside the store is used.",
        subcommands: [Describe.self, Query.self]
    )
}

/// What every subcommand that opens a store takes.
struct StoreOptions: ParsableArguments {
    @Argument(help: "The store's SQLite file.", completion: .file())
    var store: String

    @Option(
        name: .long, help: "A compiled model (.mom, .momd) or an app bundle to find it in.",
        completion: .file())
    var model: String?

    @Flag(name: .long, help: "Print JSON instead of text.")
    var json = false

    func openSession() async throws -> StoreSession {
        try await StoreSession.open(storeURL: Self.fileURL(store), modelURL: model.map(Self.fileURL))
    }

    private static func fileURL(_ path: String) -> URL {
        URL(fileURLWithPath: (path as NSString).expandingTildeInPath)
    }
}

/// Runs `body` with an open session, closes it afterwards, and turns engine errors into an explained failure.
func withSession(_ options: StoreOptions, _ body: (StoreSession) async throws -> Void) async throws {
    do {
        let session = try await options.openSession()
        do {
            try await body(session)
            await session.close()
        } catch {
            await session.close()
            throw error
        }
    } catch let error as DabbiError {
        FileHandle.standardError.write(Data("error: \(error.description)\n".utf8))
        throw ExitCode.failure
    }
}
