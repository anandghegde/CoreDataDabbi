import DabbiBase
import Foundation
import Testing

@testable import DabbiLocator

@Suite struct ProcessRunnerTests {
    private let shell = URL(fileURLWithPath: "/bin/sh")

    @Test func collectsBothStreamsAndTheStatus() async throws {
        let result = try await ProcessRunner().run(
            shell, arguments: ["-c", "echo out; echo err >&2; exit 3"], timeout: 10)
        #expect(result.status == 3)
        #expect(!result.succeeded)
        #expect(String(decoding: result.standardOutput, as: UTF8.self) == "out\n")
        #expect(result.errorSummary == "err")
    }

    /// More than a pipe's buffer on both streams at once: a runner that reads one after the other hangs here.
    @Test func drainsLargeOutputOnBothStreams() async throws {
        let script = "head -c 3000000 /dev/zero; head -c 3000000 /dev/zero >&2"
        let result = try await ProcessRunner().run(shell, arguments: ["-c", script], timeout: 30)
        #expect(result.succeeded)
        #expect(result.standardOutput.count == 3_000_000)
        #expect(result.standardError.count == 3_000_000)
    }

    @Test func outputBeyondTheLimitIsDropped() async throws {
        var runner = ProcessRunner()
        runner.maxOutputBytes = 10_000
        let result = try await runner.run(shell, arguments: ["-c", "head -c 3000000 /dev/zero"], timeout: 30)
        #expect(result.standardOutput.count == 10_000)
    }

    @Test func aToolThatIsNotThereIsUnavailable() async throws {
        let error = await #expect(throws: DabbiError.self) {
            try await ProcessRunner().run(URL(fileURLWithPath: "/nonexistent/tool"), arguments: [], timeout: 5)
        }
        #expect(error?.code == .toolUnavailable)
    }

    @Test func aToolThatHangsIsEndedAtTheDeadline() async throws {
        let started = Date()
        let error = await #expect(throws: DabbiError.self) {
            try await ProcessRunner().run(URL(fileURLWithPath: "/bin/sleep"), arguments: ["30"], timeout: 0.3)
        }
        #expect(error?.code == .timeout)
        #expect(Date().timeIntervalSince(started) < 10)
    }

    @Test func cancellingTheTaskEndsTheProcess() async throws {
        let started = Date()
        let task = Task {
            try await ProcessRunner().run(URL(fileURLWithPath: "/bin/sleep"), arguments: ["30"], timeout: 60)
        }
        try await Task.sleep(for: .milliseconds(200))
        task.cancel()
        let error = await #expect(throws: DabbiError.self) { try await task.value }
        #expect(error?.code == .cancelled)
        #expect(Date().timeIntervalSince(started) < 10)
    }

    @Test func aTaskCancelledBeforeItStartsRunsNothingForLong() async throws {
        let task = Task {
            try? await Task.sleep(for: .seconds(60))
            return try await ProcessRunner().run(URL(fileURLWithPath: "/bin/sleep"), arguments: ["30"], timeout: 60)
        }
        task.cancel()
        let started = Date()
        await #expect(throws: DabbiError.self) { try await task.value }
        #expect(Date().timeIntervalSince(started) < 10)
    }
}
