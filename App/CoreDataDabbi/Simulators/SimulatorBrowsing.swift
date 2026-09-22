import DabbiKit
import Foundation

/// Where the browser gets its simulators (PRJ-8).
///
/// The app hands it a `SimulatorIndex` over the real device set; the tests hand it devices of their own, which
/// is the only way a test of what the window shows can say anything at all — this Mac's simulators are nobody's
/// to predict.
protocol SimulatorBrowsing: Sendable {
    func devices(refresh: Bool) async -> SimulatorDeviceSource.Listing
    func contents(of device: SimulatorDevice, refresh: Bool) async -> SimulatorContents
    /// UDIDs of devices whose containers changed since the last word. Never finishes while anyone listens.
    func changes() async -> AsyncStream<Set<String>>
}

extension SimulatorIndex: SimulatorBrowsing {}

/// The app's one index. It remembers every scan, so a browser opened again is instant and a project looking for
/// a device it has already seen asks nobody.
enum Simulators {
    static let index = SimulatorIndex()
}
