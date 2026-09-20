@preconcurrency import CoreData
import Foundation
import SQLite3

/// Plays the part of the app: a read-write Core Data stack that fills a store.
///
/// `@unchecked Sendable`: a fixture is written by one thread, start to finish; the context's queue does the rest.
public final class StoreWriter: @unchecked Sendable {
    public let storeURL: URL
    public let context: NSManagedObjectContext
    private let coordinator: NSPersistentStoreCoordinator
    private var store: NSPersistentStore?

    public init(
        model: NSManagedObjectModel,
        storeURL: URL,
        options: [String: Any] = [:],
        author: String? = nil
    ) throws {
        FixtureTransformers.register()
        try FileManager.default.createDirectory(
            at: storeURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        self.storeURL = storeURL
        coordinator = NSPersistentStoreCoordinator(managedObjectModel: model)
        store = try coordinator.addPersistentStore(
            type: .sqlite, configuration: nil, at: storeURL, options: options)
        context = NSManagedObjectContext(.privateQueue)
        context.persistentStoreCoordinator = coordinator
        context.transactionAuthor = author
    }

    /// Inserts an object and sets `values` through KVC. Must be called inside `perform`.
    @discardableResult
    public func insert(_ entity: String, _ values: [String: Any?] = [:]) -> NSManagedObject {
        let object = NSEntityDescription.insertNewObject(forEntityName: entity, into: context)
        for (key, value) in values { object.setValue(value, forKey: key) }
        return object
    }

    /// Runs `body` on the context's queue and saves.
    public func perform(author: String? = nil, _ body: (StoreWriter) throws -> Void) throws {
        try withoutActuallyEscaping(body) { body in
            nonisolated(unsafe) let body = body
            try context.performAndWait {
                if let author { context.transactionAuthor = author }
                try body(self)
                if context.hasChanges { try context.save() }
            }
        }
    }

    /// Copies the store and its `-wal` / `-shm` companions *while it is open*, so the copy's rows still live in
    /// the write-ahead log — the state a running app's store is usually in.
    public func copyLiveFiles(to destination: URL) throws {
        try FileManager.default.createDirectory(
            at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
        for suffix in ["", "-wal", "-shm"] {
            let source = URL(fileURLWithPath: storeURL.path + suffix)
            guard FileManager.default.fileExists(atPath: source.path) else { continue }
            try FileManager.default.copyItem(at: source, to: URL(fileURLWithPath: destination.path + suffix))
        }
    }

    /// Closes the store. SQLite checkpoints the write-ahead log, leaving a single file.
    public func close() throws {
        context.performAndWait { context.reset() }
        if let store {
            try coordinator.remove(store)
            self.store = nil
        }
    }
}

/// Transformers the fixture "app" uses. The inspecting process never has these — which is the point.
public enum FixtureTransformers {
    public static let colourName = NSValueTransformerName("FixtureColourTransformer")

    public static func register() {
        if ValueTransformer(forName: colourName) == nil {
            ValueTransformer.setValueTransformer(ColourTransformer(), forName: colourName)
        }
    }

    /// Stores a `[String: Double]` of colour components as JSON.
    final class ColourTransformer: ValueTransformer {
        override class func transformedValueClass() -> AnyClass { NSData.self }
        override class func allowsReverseTransformation() -> Bool { true }

        override func transformedValue(_ value: Any?) -> Any? {
            guard let components = value as? [String: Double] else { return nil }
            return try? JSONSerialization.data(withJSONObject: components, options: [.sortedKeys])
        }

        override func reverseTransformedValue(_ value: Any?) -> Any? {
            guard let data = value as? Data else { return nil }
            return try? JSONSerialization.jsonObject(with: data)
        }
    }
}

/// SplitMix64 — fixtures must come out the same on every machine and every run.
struct SeededGenerator: RandomNumberGenerator {
    private var state: UInt64

    init(seed: UInt64) { state = seed }

    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }

    mutating func uuid() -> UUID {
        let high = next()
        let low = next()
        var bytes = withUnsafeBytes(of: high.bigEndian, Array.init) + withUnsafeBytes(of: low.bigEndian, Array.init)
        bytes[6] = (bytes[6] & 0x0F) | 0x40
        bytes[8] = (bytes[8] & 0x3F) | 0x80
        return UUID(
            uuid: (
                bytes[0], bytes[1], bytes[2], bytes[3], bytes[4], bytes[5], bytes[6], bytes[7],
                bytes[8], bytes[9], bytes[10], bytes[11], bytes[12], bytes[13], bytes[14], bytes[15]
            ))
    }

    mutating func data(count: Int) -> Data {
        var data = Data(capacity: count)
        while data.count < count {
            withUnsafeBytes(of: next()) { data.append(contentsOf: $0.prefix(count - data.count)) }
        }
        return data
    }
}

/// 2024-01-01T00:00:00Z — the epoch all fixture dates are offsets from.
let fixtureEpoch = Date(timeIntervalSince1970: 1_704_067_200)

enum RawSQLite {
    /// Runs SQL against a database file with a plain read-write connection.
    static func execute(_ sql: String, at url: URL) throws {
        var db: OpaquePointer?
        guard sqlite3_open_v2(url.path, &db, SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE, nil) == SQLITE_OK else {
            let message = db.map { String(cString: sqlite3_errmsg($0)) } ?? "out of memory"
            sqlite3_close_v2(db)
            throw FixtureError("Cannot open \(url.lastPathComponent): \(message)")
        }
        defer { sqlite3_close_v2(db) }
        var errorMessage: UnsafeMutablePointer<CChar>?
        guard sqlite3_exec(db, sql, nil, nil, &errorMessage) == SQLITE_OK else {
            let message = errorMessage.map { String(cString: $0) } ?? "unknown error"
            sqlite3_free(errorMessage)
            throw FixtureError("SQL failed in \(url.lastPathComponent): \(message)")
        }
    }
}

public struct FixtureError: Error, CustomStringConvertible, Sendable {
    public let description: String
    public init(_ description: String) { self.description = description }
}
