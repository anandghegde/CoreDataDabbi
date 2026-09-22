import Foundation

@testable import DabbiLocator

/// Answers instead of `xcrun`, and remembers what it was asked.
final class FakeProcessRunner: ProcessRunning, @unchecked Sendable {
    private let lock = NSLock()
    private var calls: [[String]] = []
    let answer: @Sendable ([String]) throws -> ProcessResult

    init(answer: @escaping @Sendable ([String]) throws -> ProcessResult) { self.answer = answer }

    convenience init(output: String, status: Int32 = 0, error: String = "") {
        self.init { _ in
            ProcessResult(status: status, standardOutput: Data(output.utf8), standardError: Data(error.utf8))
        }
    }

    var arguments: [[String]] { lock.withLock { calls } }

    func run(_ executable: URL, arguments: [String], timeout: TimeInterval) async throws -> ProcessResult {
        lock.withLock { calls.append(arguments) }
        return try answer(arguments)
    }
}
