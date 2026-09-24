import DabbiBase
import DabbiSQLite
import DabbiStore
import DabbiTestSupport
import FixtureKit
import Foundation
import Testing

@testable import DabbiSnapshots

/// §7.3: a snapshot goes back exactly as it was taken, never over a store another process has open, never from a
/// copy that does not hold up, and never without a backup of what it replaces.
@Suite struct RestorerTests {
    private func emptyLibrary(_ name: String = "library") -> SnapshotLibrary {
        SnapshotLibrary(root: TestFixtures.root.appendingPathComponent("\(name)-\(UUID().uuidString)"))
    }

    private func notes(in store: URL) throws -> Int {
        let connection = try SQLiteConnection(readOnly: store)
        defer { connection.close() }
        guard case .integer(let count) = try connection.scalar("SELECT COUNT(*) FROM ZNOTE") else { return -1 }
        return Int(count)
    }

    /// A notes store with `count` notes, closed.
    private func notesStore(_ count: Int) throws -> URL {
        let directory = TestFixtures.root.appendingPathComponent("restore-\(UUID().uuidString)", isDirectory: true)
        let writer = try StoreWriter(
            model: NotesFixture.makeModel(), storeURL: directory.appendingPathComponent("Notes.sqlite"))
        try writer.perform { writer in
            for index in 0..<count { writer.insert("Note", ["title": "Note \(index)", "body": "x"]) }
        }
        try writer.close()
        return writer.storeURL
    }

    private func add(_ count: Int, to store: URL) throws {
        let writer = try StoreWriter(model: NotesFixture.makeModel(), storeURL: store)
        try writer.perform { writer in
            for index in 0..<count { writer.insert("Note", ["title": "Later \(index)", "body": "y"]) }
        }
        try writer.close()
    }

    @Test func theSnapshotComesBackAndTheBackupUndoesIt() async throws {
        let store = try notesStore(10)
        let library = emptyLibrary()
        let backups = emptyLibrary("backups")
        let snapshot = try await Snapshotter.take(of: store, into: library, kind: .snapshot, name: "Ten")
        try add(5, to: store)
        #expect(try notes(in: store) == 15)

        let backup = try #require(
            try await Restorer.restore(snapshot, from: library, over: store, backingUpInto: backups))
        #expect(try notes(in: store) == 10)
        #expect(backup.kind == .backup && backup.name == "Before restoring")
        #expect(backups.list().map(\.id) == [backup.id])

        // The backup is what was there: restoring it undoes the restore.
        try await Restorer.restore(backup, from: backups, over: store, backingUpInto: nil)
        #expect(try notes(in: store) == 15)
        let session = try await StoreSession.open(storeURL: store)
        #expect(try await session.count(FetchSpec(entity: "Note")) == 15)
        await session.close()
    }

    /// The log holds rows the database does not have yet. Left next to the restored database, it would be played
    /// into it the next time the store was opened.
    @Test func theWriteAheadLogDoesNotSurviveTheRestore() async throws {
        let location = try TestFixtures.scratchCopy(.walOnly)
        #expect(FileManager.default.fileExists(atPath: location.storeURL.path + "-wal"))
        let library = emptyLibrary()
        let snapshot = try await Snapshotter.take(of: location.storeURL, into: library, kind: .snapshot, name: "W")

        try await Restorer.restore(snapshot, from: library, over: location.storeURL, backingUpInto: nil)
        #expect(!FileManager.default.fileExists(atPath: location.storeURL.path + "-wal"))
        #expect(!FileManager.default.fileExists(atPath: location.storeURL.path + "-shm"))
        let session = try await StoreSession.open(storeURL: location.storeURL)
        let counts = try await session.entityCounts()
        #expect(
            Dictionary(uniqueKeysWithValues: counts.map { ($0.entity, $0.total) }) == location.manifest.entityCounts)
        await session.close()
        try Snapshotter.verify(snapshot, in: library)
    }

    @Test func externalDataIsPutBackAsItWas() async throws {
        let location = try TestFixtures.scratchCopy(.externalData)
        let support = StoreFiles.supportFolder(of: location.storeURL)
        let library = emptyLibrary()
        let snapshot = try await Snapshotter.take(of: location.storeURL, into: library, kind: .snapshot, name: "E")
        let original = try FileManager.default.subpathsOfDirectory(atPath: support.path).sorted()
        try FileManager.default.removeItem(at: support)
        try FileManager.default.createDirectory(at: support, withIntermediateDirectories: true)
        try Data("stray".utf8).write(to: support.appendingPathComponent("stray"))

        try await Restorer.restore(snapshot, from: library, over: location.storeURL, backingUpInto: nil)
        #expect(try FileManager.default.subpathsOfDirectory(atPath: support.path).sorted() == original)
        let leftovers = try FileManager.default.contentsOfDirectory(atPath: location.directory.path)
        #expect(!leftovers.contains { $0.hasPrefix(".dabbi-restore-") })
    }

    @Test func aStoreAnotherProcessHasOpenIsNotReplaced() async throws {
        let store = try notesStore(3)
        let library = emptyLibrary()
        let snapshot = try await Snapshotter.take(of: store, into: library, kind: .snapshot, name: "S")
        try add(2, to: store)

        let holder = Process()
        holder.executableURL = URL(fileURLWithPath: "/usr/bin/tail")
        holder.arguments = ["-f", store.path]
        holder.standardOutput = FileHandle.nullDevice
        try holder.run()
        defer { holder.terminate() }
        var seen: [LiveProcess] = []
        for _ in 0..<100 where seen.isEmpty {
            seen = LiveProcesses.holding(store)
            if seen.isEmpty { try await Task.sleep(for: .milliseconds(20)) }
        }
        #expect(seen.map(\.pid) == [holder.processIdentifier])
        #expect(seen.first?.name == "tail")

        let backups = emptyLibrary("backups")
        let error = await #expect(throws: DabbiError.self) {
            try await Restorer.restore(snapshot, from: library, over: store, backingUpInto: backups)
        }
        #expect(error?.code == .storeInUse)
        #expect(error?.arguments["processes"]?.contains("tail") == true)
        #expect(try notes(in: store) == 5)
        #expect(backups.list().isEmpty, "nothing is backed up for a restore that does not happen")

        holder.terminate()
        holder.waitUntilExit()
        try await Restorer.restore(snapshot, from: library, over: store, backingUpInto: nil)
        #expect(try notes(in: store) == 3)
    }

    @Test func thisProcessOwnConnectionsAreNotCounted() async throws {
        let store = try notesStore(1)
        let session = try await StoreSession.open(storeURL: store)
        _ = try await session.count(FetchSpec(entity: "Note"))
        #expect(LiveProcesses.holding(store).isEmpty)
        #expect(LiveProcesses.holding(store, excluding: []).map(\.pid) == [getpid()])
        await session.close()
    }

    @Test func aSnapshotThatDoesNotHoldUpIsNotRestored() async throws {
        let store = try notesStore(4)
        let library = emptyLibrary()
        let snapshot = try await Snapshotter.take(of: store, into: library, kind: .snapshot, name: "S")
        let handle = try FileHandle(forWritingTo: library.databaseURL(of: snapshot))
        try handle.seek(toOffset: 4_096)
        try handle.write(contentsOf: Data(repeating: 0xA5, count: 8_192))
        try handle.close()
        try add(1, to: store)
        let before = try Data(contentsOf: store)

        let error = await #expect(throws: DabbiError.self) {
            try await Restorer.restore(snapshot, from: library, over: store, backingUpInto: nil)
        }
        #expect(error?.code == .snapshotUnverified || error?.code == .sqlite)
        #expect(try Data(contentsOf: store) == before)
    }
}
