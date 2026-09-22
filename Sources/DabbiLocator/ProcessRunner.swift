import DabbiBase
import Foundation

/// What a finished process left behind.
public struct ProcessResult: Sendable, Hashable {
    public var status: Int32
    public var standardOutput: Data
    public var standardError: Data

    public init(status: Int32, standardOutput: Data = Data(), standardError: Data = Data()) {
        self.status = status
        self.standardOutput = standardOutput
        self.standardError = standardError
    }

    public var succeeded: Bool { status == 0 }

    /// The last lines of standard error, for a diagnosis. Tools' messages, never store content.
    public var errorSummary: String {
        String(decoding: standardError.suffix(2_000), as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

/// Runs the developer tools the locator leans on (`simctl`, later `devicectl`). A protocol so that the tests
/// can stand in for an Xcode that is not there, or that answers with something unexpected.
public protocol ProcessRunning: Sendable {
    /// - Throws: `.toolUnavailable` when the executable cannot be started, `.timeout` when it outlives `timeout`.
    ///   An exit status other than 0 is a result, not an error: what it means is the caller's to say.
    func run(_ executable: URL, arguments: [String], timeout: TimeInterval) async throws -> ProcessResult
}

/// `Process`, with the three things every caller would otherwise get wrong: both pipes are drained while the
/// process runs (a tool that fills a 64 KB pipe buffer otherwise blocks forever), there is always a deadline,
/// and cancelling the task ends the process.
public struct ProcessRunner: ProcessRunning {
    /// Output beyond this is dropped: `simctl list -j` is some hundred kilobytes, and nothing is a gigabyte.
    public var maxOutputBytes = 64 * 1024 * 1024

    public init() {}

    public static let xcrun = URL(fileURLWithPath: "/usr/bin/xcrun")

    public func run(_ executable: URL, arguments: [String], timeout: TimeInterval) async throws -> ProcessResult {
        let run = Run(executable: executable, arguments: arguments, timeout: timeout, maxOutputBytes: maxOutputBytes)
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                run.start(continuation)
            }
        } onCancel: {
            run.cancel()
        }
    }

    /// One process from start to finish. The lock guards what the pipes' threads, the termination handler, the
    /// deadline and a cancellation all touch.
    private final class Run: @unchecked Sendable {
        private let process = Process()
        private let timeout: TimeInterval
        private let maxOutputBytes: Int
        private let lock = NSLock()
        private var continuation: CheckedContinuation<ProcessResult, any Error>?
        private var ending: DabbiError.Code?

        init(executable: URL, arguments: [String], timeout: TimeInterval, maxOutputBytes: Int) {
            self.timeout = timeout
            self.maxOutputBytes = maxOutputBytes
            process.executableURL = executable
            process.arguments = arguments
            process.standardInput = FileHandle.nullDevice
        }

        func start(_ continuation: CheckedContinuation<ProcessResult, any Error>) {
            let output = Pipe()
            let error = Pipe()
            process.standardOutput = output
            process.standardError = error

            lock.lock()
            self.continuation = continuation
            let cancelledBeforeStart = ending != nil
            lock.unlock()
            guard !cancelledBeforeStart else { return finish(.failure(Self.error(.cancelled, process))) }

            let drained = DispatchGroup()
            let collected = Collected()
            let limit = maxOutputBytes
            for (pipe, isError) in [(output, false), (error, true)] {
                drained.enter()
                DispatchQueue.global(qos: .utility).async {
                    collected.set(Self.drain(pipe.fileHandleForReading, limit: limit), isError: isError)
                    drained.leave()
                }
            }

            process.terminationHandler = { [self] process in
                drained.notify(queue: .global(qos: .utility)) { [self] in
                    lock.lock()
                    let ending = ending
                    lock.unlock()
                    if let ending { return finish(.failure(Self.error(ending, process))) }
                    finish(
                        .success(
                            ProcessResult(
                                status: process.terminationStatus, standardOutput: collected.output,
                                standardError: collected.error)))
                }
            }

            do {
                try process.run()
            } catch let failure {
                // Nothing will close the pipes' writing ends for us, and the readers wait for that.
                try? output.fileHandleForWriting.close()
                try? error.fileHandleForWriting.close()
                return finish(.failure(Self.unavailable(process, underlying: failure)))
            }
            // A cancellation that came while the process was starting found nothing to terminate.
            lock.lock()
            let endedWhileStarting = ending != nil
            lock.unlock()
            if endedWhileStarting { process.terminate() }
            DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + timeout) { [self] in end(.timeout) }
        }

        func cancel() { end(.cancelled) }

        private func end(_ code: DabbiError.Code) {
            lock.lock()
            if ending == nil { ending = code }
            lock.unlock()
            if process.isRunning { process.terminate() }
        }

        private func finish(_ result: Result<ProcessResult, any Error>) {
            lock.lock()
            let continuation = continuation
            self.continuation = nil
            lock.unlock()
            continuation?.resume(with: result)
        }

        private static func drain(_ handle: FileHandle, limit: Int) -> Data {
            var data = Data()
            while let chunk = try? handle.read(upToCount: 64 * 1024), !chunk.isEmpty {
                if data.count < limit { data.append(chunk.prefix(limit - data.count)) }
            }
            return data
        }

        private static func error(_ code: DabbiError.Code, _ process: Process) -> DabbiError {
            let tool = process.executableURL?.lastPathComponent ?? "The tool"
            return code == .timeout
                ? DabbiError(.timeout, "\(tool) did not answer in time.", arguments: ["tool": tool])
                : DabbiError(.cancelled, "\(tool) was cancelled.", arguments: ["tool": tool])
        }

        private static func unavailable(_ process: Process, underlying: any Error) -> DabbiError {
            let path = process.executableURL?.path ?? ""
            return DabbiError(
                .toolUnavailable, "\((path as NSString).lastPathComponent) could not be started.",
                arguments: ["path": path], diagnosis: ["Tried to run \(path)."],
                recovery: ["Install Xcode or its command-line tools, and check `xcode-select -p`."],
                underlying: underlying)
        }
    }

    private final class Collected: @unchecked Sendable {
        private let lock = NSLock()
        private var _output = Data()
        private var _error = Data()

        func set(_ data: Data, isError: Bool) {
            lock.lock()
            defer { lock.unlock() }
            if isError { _error = data } else { _output = data }
        }

        var output: Data { lock.withLock { _output } }
        var error: Data { lock.withLock { _error } }
    }
}
