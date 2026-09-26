import DabbiBase
import DabbiKit
import DabbiTestSupport
import Foundation
import Testing

@testable import DabbiSQLite

/// EDT-10 and EDT-11: a commit to a store mirrored to CloudKit, or open in another process, goes ahead only once
/// the user has been told — and the engine refuses one that was not put to them.
@Suite struct CommitGuardsTests {
    private func name(in url: URL, pk: Int64) throws -> SQLiteValue? {
        let connection = try SQLiteConnection(readOnly: url)
        defer { connection.close() }
        return try connection.scalar("SELECT ZNAME FROM ZSAMPLE WHERE Z_PK = \(pk)")
    }

    private func backup(for session: StoreSession, _ storeURL: URL) -> PreCommitBackup {
        PreCommitBackup(
            for: session, storeURL: storeURL,
            root: TestFixtures.root.appendingPathComponent("backups-\(UUID().uuidString)"))
    }

    /// A process that holds the store open until the test is over: `tail -f`, as in the restore's tests.
    private func holder(of store: URL) async throws -> Process {
        let holder = Process()
        holder.executableURL = URL(fileURLWithPath: "/usr/bin/tail")
        holder.arguments = ["-f", store.path]
        holder.standardOutput = FileHandle.nullDevice
        try holder.run()
        for _ in 0..<100 where LiveProcesses.holding(store).isEmpty {
            try await Task.sleep(for: .milliseconds(20))
        }
        return holder
    }

    @Test func aStoreOnlyThisAppHasOpenIsClear() async throws {
        let location = try TestFixtures.scratchCopy(.basic)
        let session = try await StoreSession.open(
            storeURL: location.storeURL, modelURL: location.modelURL, access: .editable(.app))
        let guards = await CommitGuards.check(session, storeURL: location.storeURL)
        #expect(guards == .clear && guards.isClear)
        await session.close()
    }

    @Test func aStoreWithCloudKitTablesIsMirrored() async throws {
        let location = try TestFixtures.scratchCopy(.basic)
        // No fixture is made by `NSPersistentCloudKitContainer`; the probe goes by the mirroring tables' names.
        let connection = try SQLiteConnection.writable(at: location.storeURL)
        try connection.execute("CREATE TABLE ANSCKRECORDMETADATA (Z_PK INTEGER PRIMARY KEY)")
        connection.close()
        let session = try await StoreSession.open(
            storeURL: location.storeURL, modelURL: location.modelURL, access: .editable(.app))

        let guards = await CommitGuards.check(session, storeURL: location.storeURL)
        #expect(guards.mirroredToCloudKit && guards.holders.isEmpty && !guards.isClear)
        #expect(guards.refusal.code == .commitUnconfirmed)
        #expect(guards.refusal.arguments["cloudKit"] == "yes")

        let ref = try #require(try await session.references(FetchSpec(entity: "Sample"), limit: 1).first)
        try await session.setValue(.string("Mirrored"), for: "name", of: PendingObjectID(ref))
        let backup = backup(for: session, location.storeURL)
        let error = await #expect(throws: DabbiError.self) {
            try await session.commit(after: backup, acknowledging: .clear)
        }
        #expect(error?.code == .commitUnconfirmed, "passed on as it is, not as a failed preparation")
        #expect(await backup.backup == nil, "nothing is backed up for a commit that does not happen")
        #expect(try name(in: location.storeURL, pk: ref.pk) != .text("Mirrored"))

        #expect(try await session.commit(after: backup, acknowledging: guards).updated == 1)
        #expect(try name(in: location.storeURL, pk: ref.pk) == .text("Mirrored"))
        await session.close()
    }

    @Test func aStoreAnotherProcessHasOpenIsHeld() async throws {
        let location = try TestFixtures.scratchCopy(.basic)
        let session = try await StoreSession.open(
            storeURL: location.storeURL, modelURL: location.modelURL, access: .editable(.app))
        let holder = try await holder(of: location.storeURL)
        defer { holder.terminate() }

        let guards = await CommitGuards.check(session, storeURL: location.storeURL)
        #expect(!guards.mirroredToCloudKit)
        #expect(guards.holders.map(\.pid) == [holder.processIdentifier], "this process is never one of them")
        #expect(guards.holders.first?.name == "tail")
        #expect(guards.refusal.arguments["processes"]?.contains("tail") == true)

        let ref = try #require(try await session.references(FetchSpec(entity: "Sample"), limit: 1).first)
        try await session.setValue(.string("Held"), for: "name", of: PendingObjectID(ref))
        let backup = backup(for: session, location.storeURL)
        let error = await #expect(throws: DabbiError.self) {
            try await session.commit(after: backup, acknowledging: .clear)
        }
        #expect(error?.code == .commitUnconfirmed)
        #expect(try name(in: location.storeURL, pk: ref.pk) != .text("Held"))

        #expect(try await session.commit(after: backup, acknowledging: guards).updated == 1)
        #expect(try name(in: location.storeURL, pk: ref.pk) == .text("Held"))
        await session.close()
    }

    @Test func aProcessThatOpenedTheStoreSinceIsAskedAboutAfresh() async throws {
        let location = try TestFixtures.scratchCopy(.basic)
        let session = try await StoreSession.open(
            storeURL: location.storeURL, modelURL: location.modelURL, access: .editable(.app))
        let acknowledged = await CommitGuards.check(session, storeURL: location.storeURL)
        let holder = try await holder(of: location.storeURL)
        defer { holder.terminate() }

        let ref = try #require(try await session.references(FetchSpec(entity: "Sample"), limit: 1).first)
        try await session.setValue(.string("Late"), for: "name", of: PendingObjectID(ref))
        let error = await #expect(throws: DabbiError.self) {
            try await session.commit(after: backup(for: session, location.storeURL), acknowledging: acknowledged)
        }
        #expect(error?.code == .commitUnconfirmed)
        await session.close()
    }

    @Test func acknowledgingCoversCloudKitAndEveryProcessNamed() {
        let one = LiveProcess(pid: 101, name: "One")
        let two = LiveProcess(pid: 102, name: "Two")
        let cloud = CommitGuards(mirroredToCloudKit: true)
        #expect(CommitGuards.clear.covers(.clear))
        #expect(cloud.covers(.clear) && cloud.covers(cloud))
        #expect(!CommitGuards.clear.covers(cloud))
        #expect(CommitGuards(holders: [one, two]).covers(CommitGuards(holders: [two])))
        #expect(!CommitGuards(holders: [one]).covers(CommitGuards(holders: [one, two])))
        #expect(!CommitGuards(holders: [one]).covers(CommitGuards(mirroredToCloudKit: true, holders: [one])))

        let merged = CommitGuards(holders: [one]).merging(CommitGuards(mirroredToCloudKit: true, holders: [one, two]))
        #expect(merged == CommitGuards(mirroredToCloudKit: true, holders: [one, two]))
        #expect(merged.covers(cloud) && merged.covers(CommitGuards(holders: [two])))
    }
}
