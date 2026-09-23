import DabbiKit
import FixtureKit
import Foundation
import Testing

/// Drives the scripted writer app (`Tools/Writer/iOS`) in an iOS simulator, for the end-to-end tests next door.
///
/// The writer is launched by `simctl` and answers in a file, because `simctl launch` hands back a process ID and
/// nothing else: a console it may not be given is not something to build a test on. Each mode writes
/// `Documents/writer-<mode>.json` — a `WriterScript.Report`, the same type the macOS writer prints — and exits,
/// so both halves of M2-11 are checked against one account of what was written.
///
/// The simulator's container is an ordinary folder on this Mac, so the store the app writes is a file the
/// inspecting process can open directly. That is the whole point: no part of this test pretends.
struct SimulatorWriter: Sendable {
    /// Matches `App/Config/WriterApp.xcconfig`.
    static let bundleID = "org.coredatadabbi.WriterApp"

    /// The built `WriterApp.app`, named by the environment because building it needs Xcode and a simulator SDK,
    /// which `swift test` has neither of. `Scripts/e2e.sh` builds it and sets this.
    static var appBundle: URL? {
        guard let path = ProcessInfo.processInfo.environment["DABBI_WRITER_APP"], !path.isEmpty else { return nil }
        return URL(fileURLWithPath: path, isDirectory: true)
    }

    /// Off unless somebody has built the app: an engine test run must not need Xcode.
    static var isEnabled: Bool { appBundle != nil }

    static let disabledReason: Comment = "set DABBI_WRITER_APP to a built WriterApp.app (see Scripts/e2e.sh)"

    let udid: String
    /// The app's data container, as a path on this Mac.
    let container: URL

    /// Where the app put its store: `Library/Application Support`, where a Core Data app puts one.
    var storeURL: URL {
        container.appendingPathComponent("Library/Application Support/\(WriterScript.storeName)")
    }

    var storeDirectory: URL { storeURL.deletingLastPathComponent() }

    func reportURL(_ mode: String) -> URL {
        container.appendingPathComponent("Documents/writer-\(mode).json")
    }

    // MARK: - Installing

    /// Boots a device, installs a fresh copy of the writer and returns a handle on its container.
    ///
    /// Fresh, because the container is the test's fixture: an install wipes it, so every test starts from an
    /// empty one and seeds it itself rather than inheriting whatever the last test left.
    static func install() async throws -> SimulatorWriter {
        guard let app = appBundle else { throw SimulatorWriterError.notConfigured }
        let udid = try await device()
        // Boots it if it is not booted, waits if it is still booting, and says so if it cannot.
        try await simctl(["bootstatus", udid, "-b"], timeout: 600)
        _ = try? await simctl(["uninstall", udid, bundleID])
        try await simctl(["install", udid, app.path])
        let container = try await simctl(["get_app_container", udid, bundleID, "data"])
        guard !container.isEmpty else { throw SimulatorWriterError.noContainer(udid) }
        return SimulatorWriter(udid: udid, container: URL(fileURLWithPath: container, isDirectory: true))
    }

    func uninstall() async {
        _ = try? await Self.simctl(["uninstall", udid, Self.bundleID])
    }

    /// Which simulator to use: the one CI names, else one that is already booted, else the newest iOS device
    /// there is. Found through the engine's own device source, which is the thing the app uses.
    private static func device() async throws -> String {
        if let named = ProcessInfo.processInfo.environment["DABBI_WRITER_UDID"], !named.isEmpty { return named }
        let devices = await SimulatorDeviceSource().listing().devices.filter(\.isAvailable)
        if let booted = devices.first(where: { $0.state == .booted }) { return booted.udid }
        let candidates = devices.filter { $0.runtimeID.contains("iOS") }
        guard
            let newest = candidates.max(by: {
                $0.runtimeID.compare($1.runtimeID, options: .numeric) == .orderedAscending
            })
        else { throw SimulatorWriterError.noDevice }
        return newest.udid
    }

    // MARK: - Running the script

    /// Seeds the store and waits for the app to say it is done — what the tracker starts from.
    @discardableResult
    func seed() async throws -> WriterScript.Report {
        try await launch("seed")
        return try await report("seed")
    }

    /// Starts `WriterScript.program`. Returns as soon as the app is launched, so the caller can be watching the
    /// store while it is written to — which is the whole test.
    func startRun(intervalMilliseconds: Int) async throws {
        try await launch("run", ["--interval-ms", String(intervalMilliseconds)])
    }

    private func launch(_ mode: String, _ arguments: [String] = []) async throws {
        try await Self.simctl(["launch", udid, Self.bundleID, mode] + arguments)
    }

    /// Waits for a mode's report to appear and reads it.
    ///
    /// A report that will not decode is the app's failure note — it writes one instead of the report when the
    /// script throws — and is handed on as the error, because "could not decode" is not worth reading and the
    /// note says what actually went wrong.
    func report(_ mode: String, timeout: Duration = .seconds(120)) async throws -> WriterScript.Report {
        let url = reportURL(mode)
        let deadline = ContinuousClock.now.advanced(by: timeout)
        repeat {
            if let data = try? Data(contentsOf: url) {
                do { return try WriterScript.Report.decode(data) } catch {
                    throw SimulatorWriterError.writerFailed(mode, String(decoding: data, as: UTF8.self))
                }
            }
            try await Task.sleep(for: .milliseconds(50))
        } while ContinuousClock.now < deadline
        throw SimulatorWriterError.noReport(mode, url.path)
    }

    // MARK: - simctl

    @discardableResult
    static func simctl(_ arguments: [String], timeout: TimeInterval = 300) async throws -> String {
        let result = try await ProcessRunner().run(
            URL(fileURLWithPath: "/usr/bin/xcrun"), arguments: ["simctl"] + arguments, timeout: timeout)
        guard result.succeeded else {
            throw SimulatorWriterError.simctl(arguments.joined(separator: " "), result.errorSummary)
        }
        return String(decoding: result.standardOutput, as: UTF8.self)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

enum SimulatorWriterError: Error, CustomStringConvertible {
    case notConfigured
    case noDevice
    case noContainer(String)
    case simctl(String, String)
    case noReport(String, String)
    case writerFailed(String, String)

    var description: String {
        switch self {
        case .notConfigured: "DABBI_WRITER_APP is not set"
        case .noDevice: "no iOS simulator is available on this machine"
        case .noContainer(let udid): "the writer has no data container on \(udid)"
        case .simctl(let command, let error): "simctl \(command) failed: \(error)"
        case .noReport(let mode, let path):
            "the writer never wrote its \(mode) report at \(path) — it may have crashed on launch"
        case .writerFailed(let mode, let note): "the writer failed in \(mode) mode: \(note)"
        }
    }
}
