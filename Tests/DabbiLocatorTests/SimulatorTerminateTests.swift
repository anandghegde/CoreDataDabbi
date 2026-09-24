import DabbiBase
import Foundation
import Testing

@testable import DabbiLocator

/// §7.3: before a snapshot goes back, the app that uses the store can be quit through `simctl terminate`.
@Suite struct SimulatorTerminateTests {
    private let udid = "5A6E3F0C-0000-4000-8000-000000000001"

    @Test func asksSimctlToQuitTheAppOnTheDevice() async throws {
        let runner = FakeProcessRunner(output: "")
        try await SimulatorDeviceSource(runner: runner).terminate("com.example.Notes", on: udid)
        #expect(runner.arguments == [["simctl", "terminate", udid, "com.example.Notes"]])
    }

    @Test func namesADeviceSetOfItsOwn() async throws {
        let set = URL(fileURLWithPath: "/tmp/devices-\(UUID().uuidString)")
        let runner = FakeProcessRunner(output: "")
        try await SimulatorDeviceSource(devicesDirectory: set, runner: runner).terminate("a.b", on: udid)
        #expect(runner.arguments == [["simctl", "--set", set.path, "terminate", udid, "a.b"]])
    }

    @Test func anAppThatIsNotRunningIsAlreadyQuit() async throws {
        let runner = FakeProcessRunner(
            output: "", status: 164,
            error: "An error was encountered processing the command (code=164):\nfound nothing to terminate")
        try await SimulatorDeviceSource(runner: runner).terminate("a.b", on: udid)
    }

    @Test func anyOtherFailureSaysWhatSimctlSaid() async throws {
        let runner = FakeProcessRunner(output: "", status: 148, error: "Invalid device: \(udid)")
        let error = await #expect(throws: DabbiError.self) {
            try await SimulatorDeviceSource(runner: runner).terminate("a.b", on: udid)
        }
        #expect(error?.code == .toolFailed)
        #expect(error?.diagnosis == ["Invalid device: \(udid)"])
    }
}
