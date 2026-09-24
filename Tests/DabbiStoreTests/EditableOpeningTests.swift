@preconcurrency import CoreData
import DabbiBase
import DabbiSQLite
import DabbiTestSupport
import FixtureKit
import Foundation
import Testing

@testable import DabbiStore

/// EDT-1 and EDT-5: what opening a store editable does, and — as much as matters before staged edits exist —
/// what a save through such a session leaves behind.
@Suite struct EditableOpeningTests {
    private let access = StoreAccess.editable(WriteAuthorization(author: "Tests"))

    /// Every file beside the store, external data included, the `-shm` by existence only: every connection
    /// rebuilds its index.
    private func fingerprint(_ location: FixtureLocation) throws -> [String: Data] {
        var files: [String: Data] = [:]
        let root = location.directory
        guard let walk = FileManager.default.enumerator(at: root, includingPropertiesForKeys: [.isRegularFileKey])
        else { return files }
        for case let url as URL in walk
        where (try url.resourceValues(forKeys: [.isRegularFileKey])).isRegularFile == true {
            let name = String(url.path.dropFirst(root.path.count))
            files[name] = name.hasSuffix("-shm") ? Data() : try Data(contentsOf: url)
        }
        return files
    }

    private func modelCache(of url: URL) throws -> Data? {
        let connection = try SQLiteConnection(readOnly: url)
        defer { connection.close() }
        return try connection.scalar("SELECT Z_CONTENT FROM Z_MODELCACHE")?.data
    }

    /// Changes one attribute of the first `entity` row and commits it.
    private func save(
        _ session: StoreSession, entity: String, key: String, value: String
    ) async throws {
        let ref = try #require(try await session.references(FetchSpec(entity: entity), limit: 1).first)
        try await session.setValue(.string(value), for: key, of: PendingObjectID(ref))
        _ = try await session.commit()
    }

    @Test(arguments: [Fixture.basic, .company, .history, .composites, .externalData])
    func openingEditableChangesNothingByItself(_ fixture: Fixture) async throws {
        let location = try TestFixtures.scratchCopy(fixture)
        let before = try fingerprint(location)
        let session = try await StoreSession.open(
            storeURL: location.storeURL, modelURL: location.modelURL, access: access)
        #expect(session.info.accessMode == .editable)
        let counts = try await session.entityCounts()
        #expect(
            Dictionary(uniqueKeysWithValues: counts.map { ($0.entity, $0.total) }) == location.manifest.entityCounts)
        await session.close()
        #expect(try fingerprint(location) == before)
    }

    /// EDT-5: a store that records history goes on recording it, and our saves are ours.
    @Test func savesAreRecordedUnderTheAuthorizationsAuthor() async throws {
        let location = try TestFixtures.scratchCopy(.history)
        let session = try await StoreSession.open(storeURL: location.storeURL, access: access)
        let before = try await session.historyTransactions()
        try await save(session, entity: "Note", key: "body", value: "Edited")
        let after = try await session.historyTransactions()
        #expect(after.count == before.count + 1)
        #expect(after.last?.author == "Tests")
        await session.close()
    }

    /// The model the session writes through is the sanitised one — its custom classes and transformer names
    /// replaced (ADR-09). A save must not put that model in the app's store in place of its own.
    @Test func aSaveLeavesTheCachedModelAlone() async throws {
        let location = try TestFixtures.scratchCopy(.basic)
        let cached = try modelCache(of: location.storeURL)
        #expect(cached != nil)
        let session = try await StoreSession.open(storeURL: location.storeURL, access: access)
        try await save(session, entity: "Sample", key: "stringValue", value: "Edited")
        await session.close()
        #expect(try modelCache(of: location.storeURL) == cached)

        let reopened = try await StoreSession.open(storeURL: location.storeURL)
        #expect(reopened.info.probe.hasHistory == false)
        await reopened.close()
    }

    /// A store kept on a rollback journal by its app stays on one; Core Data left to itself switches it to WAL.
    @Test func aRollbackJournalStoreStaysOne() async throws {
        let location = try TestFixtures.scratchCopy(.basic)
        try SQLiteConnection.consolidate(ownedCopyAt: location.storeURL)
        #expect(try SQLiteHeader.read(from: location.storeURL).isWAL == false)

        let session = try await StoreSession.open(storeURL: location.storeURL, access: access)
        try await save(session, entity: "Sample", key: "stringValue", value: "Edited")
        await session.close()
        #expect(try SQLiteHeader.read(from: location.storeURL).isWAL == false)
        #expect(!FileManager.default.fileExists(atPath: location.storeURL.path + "-wal"))
    }

    @Test func aWALStoreStaysOne() async throws {
        let location = try TestFixtures.scratchCopy(.basic)
        #expect(try SQLiteHeader.read(from: location.storeURL).isWAL)
        let session = try await StoreSession.open(storeURL: location.storeURL, access: access)
        try await save(session, entity: "Sample", key: "stringValue", value: "Edited")
        await session.close()
        #expect(try SQLiteHeader.read(from: location.storeURL).isWAL)
    }

    @Test func aFileThatCannotBeWrittenIsRefusedAndStillReads() async throws {
        let location = try TestFixtures.scratchCopy(.company)
        let files = FileManager.default
        try files.setAttributes([.posixPermissions: 0o444], ofItemAtPath: location.storeURL.path)
        defer { try? files.setAttributes([.posixPermissions: 0o644], ofItemAtPath: location.storeURL.path) }

        let error = await #expect(throws: DabbiError.self) {
            try await StoreSession.open(storeURL: location.storeURL, access: access)
        }
        #expect(error?.code == .storeNotWritable)
        #expect(error?.diagnosis == ["\(location.storeURL.lastPathComponent) cannot be written to."])

        let session = try await StoreSession.open(storeURL: location.storeURL)
        #expect(session.info.accessMode == .readOnly)
        await session.close()
    }

    @Test func aFolderThatCannotBeWrittenIsRefused() async throws {
        let location = try TestFixtures.scratchCopy(.company)
        let files = FileManager.default
        try files.setAttributes([.posixPermissions: 0o555], ofItemAtPath: location.directory.path)
        defer { try? files.setAttributes([.posixPermissions: 0o755], ofItemAtPath: location.directory.path) }

        let error = await #expect(throws: DabbiError.self) {
            try await StoreSession.open(storeURL: location.storeURL, access: access)
        }
        #expect(error?.code == .storeNotWritable)
        #expect(error?.recovery.first == "Copy the store to a folder you can write to, and open the copy.")
    }
}
