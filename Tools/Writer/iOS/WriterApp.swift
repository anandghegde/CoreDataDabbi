import FixtureKit
import Foundation
import UIKit

/// The iOS half of the scripted writer (M2-11): a simulator app that writes a Core Data store into its own
/// container and then mutates it on a script, so the tracker can be tested against a real app in a real
/// container rather than against a file in a temporary folder.
///
/// It is the only thing in this repository that is written for iOS, and it exists for one reason: everything
/// between an app saving and a row lighting up in the window — the simulator index, the container map, the
/// read-only open of a store another process holds open, the watcher, the scan and the log — is only proved
/// end to end by a real app in a real simulator (§11).
///
/// It is driven by its launch arguments and answers in a file, because that is what survives `simctl`:
///
///     xcrun simctl launch <udid> org.coredatadabbi.WriterApp seed
///     xcrun simctl launch <udid> org.coredatadabbi.WriterApp run --interval-ms 250
///
/// Each mode writes `Documents/writer-<mode>.json` — a `WriterScript.Report` — and then exits, so the inspecting
/// process waits for a file rather than for a console it may not be given.
@main
final class WriterAppDelegate: UIResponder, UIApplicationDelegate {
    /// Not `window`: that name is a requirement of `UIApplicationDelegate`, and a private property cannot
    /// satisfy a protocol. Nothing outside this file needs it, so it is the name that gives way.
    private var statusWindow: UIWindow?

    enum Mode: String {
        /// Make the store and commit the rows tracking starts from.
        case seed
        /// Commit `WriterScript.program`, one step per transaction.
        case run
        /// Launched by a person rather than by the test: do nothing at all.
        case idle
    }

    func application(
        _ application: UIApplication,
        didFinishLaunchingWithOptions options: [UIApplication.LaunchOptionsKey: Any]? = nil
    ) -> Bool {
        let arguments = ProcessInfo.processInfo.arguments
        let mode = arguments.dropFirst().compactMap(Mode.init(rawValue:)).first ?? .idle
        showStatus(mode)
        guard mode != .idle else { return true }

        let interval = Self.integer(named: "--interval-ms", in: arguments) ?? 250
        // Off the main thread: the script sleeps between transactions on purpose, so that each commit is
        // noticed on its own rather than debounced into its neighbours.
        DispatchQueue.global(qos: .userInitiated).async {
            let status = Self.perform(mode, intervalMilliseconds: interval)
            // The report is the app's whole answer, and it is written before this line.
            exit(status)
        }
        return true
    }

    // MARK: - Where things are

    /// The store, where a Core Data app would put it: `Library/Application Support`.
    ///
    /// Not `Documents`, which would put it beside the report the test reads back — the point of this app is to
    /// be an ordinary one for the store sniffer to find (PRJ-8).
    nonisolated static var storeURL: URL {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return support.appendingPathComponent(WriterScript.storeName)
    }

    /// Where a mode's report goes. `Documents` because the inspecting process reads it, and a store sniffer
    /// walking this container must not mistake it for a database — a `.json` is not one of its extensions.
    nonisolated static func reportURL(_ mode: Mode) -> URL {
        let documents = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        return documents.appendingPathComponent("writer-\(mode.rawValue).json")
    }

    // MARK: - Running the script

    nonisolated private static func perform(_ mode: Mode, intervalMilliseconds: Int) -> Int32 {
        let script = WriterScript(writer: "iOS simulator", intervalMilliseconds: intervalMilliseconds)
        let destination = reportURL(mode)
        // A stale report from the last run must never be read as this one's: it is taken away before the
        // store is touched, and only put back when there is something true to say.
        try? FileManager.default.removeItem(at: destination)
        do {
            let report =
                switch mode {
                case .seed: try script.seed(into: storeURL)
                case .run: try script.run(on: storeURL)
                case .idle: WriterScript.Report(storePath: storeURL.path, writer: script.writer)
                }
            try report.data.write(to: destination, options: .atomic)
            return 0
        } catch {
            let failure = ["error": String(describing: error), "store": storeURL.path]
            let data = try? JSONSerialization.data(withJSONObject: failure, options: [.prettyPrinted, .sortedKeys])
            try? data?.write(to: destination, options: .atomic)
            return 1
        }
    }

    nonisolated private static func integer(named name: String, in arguments: [String]) -> Int? {
        guard let index = arguments.firstIndex(of: name), index + 1 < arguments.count else { return nil }
        return Int(arguments[index + 1])
    }

    // MARK: - Something to look at

    /// There is no scene manifest, so the window is the app delegate's to make. Nothing reads it; it is there so
    /// that a developer who launches the app by hand sees what it is rather than a black screen.
    private func showStatus(_ mode: Mode) {
        let window = UIWindow(frame: UIScreen.main.bounds)
        let label = UILabel()
        label.numberOfLines = 0
        label.textAlignment = .center
        label.text = "CoreDataDabbi writer\n\(mode.rawValue)"
        let controller = UIViewController()
        controller.view.backgroundColor = .systemBackground
        controller.view.addSubview(label)
        label.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            label.centerXAnchor.constraint(equalTo: controller.view.centerXAnchor),
            label.centerYAnchor.constraint(equalTo: controller.view.centerYAnchor),
        ])
        window.rootViewController = controller
        window.makeKeyAndVisible()
        statusWindow = window
    }
}
