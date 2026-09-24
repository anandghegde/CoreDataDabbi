import AppKit
import DabbiKit

/// Quitting the apps that have a store open, so that a snapshot can be put back in its place (§7.3).
///
/// Only what can be asked to quit is: a simulator app, through `simctl terminate`, which is how Xcode stops one;
/// a Mac app, through `NSRunningApplication.terminate()`, which lets it save. A process that is neither — a
/// command-line `sqlite3`, another tool — is named, and left for the user to stop.
enum StoreHolders {
    /// Whether ``quit(_:of:devicesDirectory:)`` has a way to quit any of `holders`.
    @MainActor
    static func canQuit(_ holders: [LiveProcess], of location: StoreLocation?) -> Bool {
        if case .simulator = location { return true }
        return holders.contains { NSRunningApplication(processIdentifier: $0.pid) != nil }
    }

    /// Asks the holders to quit, and waits a few seconds for them to let go of the store.
    ///
    /// - Throws: ``DabbiError`` `.storeInUse` naming whoever still has it open, or what `simctl` said.
    @MainActor
    static func quit(
        _ holders: [LiveProcess], of location: StoreLocation?, store: URL, devicesDirectory: URL?
    ) async throws {
        if case .simulator(let udid, let bundleID, _, _) = location {
            try await SimulatorDeviceSource(devicesDirectory: devicesDirectory).terminate(bundleID, on: udid)
        }
        for holder in holders {
            NSRunningApplication(processIdentifier: holder.pid)?.terminate()
        }
        try await waitUntilFree(store)
    }

    /// Returns once nobody else has `store` open, or throws who still does after `timeout`.
    static func waitUntilFree(_ store: URL, timeout: Duration = .seconds(5)) async throws {
        let clock = ContinuousClock()
        let deadline = clock.now + timeout
        while true {
            let holders = await Task.detached { LiveProcesses.holding(store) }.value
            if holders.isEmpty { return }
            guard clock.now < deadline else { throw LiveProcesses.inUse(store, by: holders) }
            try await Task.sleep(for: .milliseconds(100))
        }
    }
}
