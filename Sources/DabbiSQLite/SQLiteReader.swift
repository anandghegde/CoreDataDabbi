import DabbiBase
import Foundation

/// The actor a `SQLiteConnection` lives in.
///
/// All raw reads of a store go through `read`, whose body is synchronous: whatever it does — including a read
/// transaction — is finished when the call returns, so no transaction is ever held across an `await`.
public actor SQLiteReader {
    public nonisolated let url: URL
    /// Interrupts the statement that is currently running, from any isolation. Wire this to task cancellation.
    public nonisolated let interruptHandle: SQLiteInterruptHandle

    private let connection: SQLiteConnection

    public init(url: URL, options: SQLiteConnection.Options = .init()) throws {
        let connection = try SQLiteConnection(readOnly: url, options: options)
        self.connection = connection
        self.url = url
        self.interruptHandle = connection.interruptHandle
    }

    /// Runs `body` with the connection. If the calling task is cancelled meanwhile, the running statement is
    /// interrupted and `body` fails with `.cancelled`.
    public func read<T: Sendable>(_ body: @Sendable (SQLiteConnection) throws -> T) async throws -> T {
        let handle = interruptHandle
        return try await withTaskCancellationHandler {
            try body(connection)
        } onCancel: {
            handle.interrupt()
        }
    }

    public func close() {
        connection.close()
    }
}
