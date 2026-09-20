import Foundation
import os

/// `os.Logger`s, one category per engine module.
///
/// Rule (ARCHITECTURE.md §10): **row values are never logged.** Wrap anything derived from store content in
/// `Redacted` before it gets near a log statement; its description is a fixed placeholder.
public enum DabbiLog {
    public static let subsystem = "org.coredatadabbi"

    public enum Category: String, Sendable, CaseIterable {
        case sqlite, model, store, query, tracking, locator, content, exchange, snapshots, diagnostics, project, cli
    }

    public static func logger(_ category: Category) -> Logger {
        Logger(subsystem: subsystem, category: category.rawValue)
    }
}

/// Wraps a value that came out of a store so it cannot leak through string interpolation, `print` or logs.
public struct Redacted<Wrapped> {
    /// The wrapped value. Reading it is an explicit act; interpolating the wrapper is always safe.
    public let unredacted: Wrapped

    public init(_ value: Wrapped) {
        self.unredacted = value
    }
}

extension Redacted: Sendable where Wrapped: Sendable {}

extension Redacted: CustomStringConvertible, CustomDebugStringConvertible, CustomReflectable {
    public var description: String { "<redacted>" }
    public var debugDescription: String { "<redacted>" }
    public var customMirror: Mirror { Mirror(self, children: []) }
}
