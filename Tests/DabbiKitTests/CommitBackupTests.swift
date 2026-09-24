import DabbiBase
import DabbiKit
import DabbiSQLite
import DabbiTestSupport
import Foundation
import Testing

/// M3's exit criterion: every commit is preceded by a verified backup (EDT-9).
@Suite struct CommitBackupTests {
    private func name(in url: URL, pk: Int64) throws -> SQLiteValue? {
        let connection = try SQLiteConnection(readOnly: url)
        defer { connection.close() }
        return try connection.scalar("SELECT ZNAME FROM ZSAMPLE WHERE Z_PK = \(pk)")
    }

    @Test func theFirstCommitIsBackedUpAsTheStoreWasBeforeIt() async throws {
        let location = try TestFixtures.scratchCopy(.basic)
        let session = try await StoreSession.open(
            storeURL: location.storeURL, modelURL: location.modelURL, access: .editable(.app))
        let root = TestFixtures.root.appendingPathComponent("backups-\(UUID().uuidString)")
        let backup = PreCommitBackup(for: session, storeURL: location.storeURL, root: root)
        let ref = try #require(try await session.references(FetchSpec(entity: "Sample"), limit: 1).first)
        let original = try name(in: location.storeURL, pk: ref.pk)

        try await session.setValue(.string("First"), for: "name", of: PendingObjectID(ref))
        #expect(try await session.commit(after: backup).updated == 1)
        try await session.setValue(.string("Second"), for: "name", of: PendingObjectID(ref))
        #expect(try await session.commit(after: backup).updated == 1)

        let manifest = try #require(await backup.backup)
        #expect(backup.library.list().map(\.id) == [manifest.id])
        #expect(try name(in: backup.library.databaseURL(of: manifest), pk: ref.pk) == original)
        #expect(try name(in: location.storeURL, pk: ref.pk) == .text("Second"))
        await session.close()
    }

    @Test func noBackupNoCommit() async throws {
        let location = try TestFixtures.scratchCopy(.basic)
        let session = try await StoreSession.open(
            storeURL: location.storeURL, modelURL: location.modelURL, access: .editable(.app))
        // A backup of a file that is not there cannot be taken.
        let backup = PreCommitBackup(
            store: location.storeURL.appendingPathExtension("missing"),
            library: SnapshotLibrary(root: TestFixtures.root.appendingPathComponent("backups-\(UUID().uuidString)")))
        let ref = try #require(try await session.references(FetchSpec(entity: "Sample"), limit: 1).first)
        try await session.setValue(.string("Never"), for: "name", of: PendingObjectID(ref))

        let error = await #expect(throws: DabbiError.self) { try await session.commit(after: backup) }
        #expect(error?.code == .commitPreparationFailed)
        #expect(try name(in: location.storeURL, pk: ref.pk) != .text("Never"))
        await session.close()
    }
}
