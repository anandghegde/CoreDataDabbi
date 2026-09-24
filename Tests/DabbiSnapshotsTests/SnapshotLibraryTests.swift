import DabbiBase
import DabbiTestSupport
import FixtureKit
import Foundation
import Testing

@testable import DabbiSnapshots

/// Listing, naming and retention (§7.3, EDT-9), and the once-per-session backup the commit pipeline asks for.
@Suite struct SnapshotLibraryTests {
    private func emptyLibrary() -> SnapshotLibrary {
        SnapshotLibrary(root: TestFixtures.root.appendingPathComponent("library-\(UUID().uuidString)"))
    }

    private func folders(in library: SnapshotLibrary) -> [String] {
        ((try? FileManager.default.contentsOfDirectory(atPath: library.root.path)) ?? []).sorted()
    }

    @Test func listsNewestFirstAndKeepsNamesAndNotes() async throws {
        let store = try TestFixtures.scratchCopy(.basic).storeURL
        let library = emptyLibrary()
        let first = try await Snapshotter.take(of: store, into: library, kind: .snapshot, name: "First")
        let second = try await Snapshotter.take(of: store, into: library, kind: .backup, name: "Second")
        #expect(library.list().map(\.id) == [second.id, first.id])

        let renamed = try library.update(first.id, name: "Empty cart", note: "For the checkout screenshots")
        #expect(renamed.name == "Empty cart")
        #expect(renamed.note == "For the checkout screenshots")
        #expect(library.list().last == renamed)
        // What is copied does not change with the name.
        try Snapshotter.verify(renamed, in: library)

        try library.delete(second.id)
        #expect(library.list().map(\.id) == [first.id])
        let gone = #expect(throws: DabbiError.self) { try library.manifest(second.id) }
        #expect(gone?.code == .snapshotNotFound)
    }

    @Test func retentionRemovesOldBackupsOnly() async throws {
        let store = try TestFixtures.scratchCopy(.basic).storeURL
        let library = emptyLibrary()
        let kept = try await Snapshotter.take(of: store, into: library, kind: .snapshot, name: "Keep me")
        var backups: [SnapshotManifest] = []
        for index in 0..<4 {
            backups.append(try await Snapshotter.take(of: store, into: library, kind: .backup, name: "B\(index)"))
        }

        let removed = library.prune(.init(keepBackups: 2))
        #expect(Set(removed.map(\.id)) == Set(backups.prefix(2).map(\.id)))
        #expect(Set(library.list().map(\.id)) == Set([kept.id, backups[2].id, backups[3].id]))

        // By age, the newest backup is kept however old it is; a snapshot is never touched.
        let later = Date().addingTimeInterval(3_600)
        library.prune(.init(keepBackups: 10, maxBackupAge: 60), now: later)
        #expect(Set(library.list().map(\.id)) == Set([kept.id, backups[3].id]))
        library.prune(.init(keepBackups: 0), now: later)
        #expect(Set(library.list().map(\.id)) == Set([kept.id, backups[3].id]))
    }

    @Test func aHalfTakenCopyIsNeverListedAndIsSwept() async throws {
        let store = try TestFixtures.scratchCopy(.basic).storeURL
        let library = emptyLibrary()
        let taken = try await Snapshotter.take(of: store, into: library, kind: .snapshot, name: "Whole")
        let abandoned = library.stagingFolder(for: UUID())
        try FileManager.default.createDirectory(at: abandoned, withIntermediateDirectories: true)
        try Data("half".utf8).write(to: abandoned.appendingPathComponent("Basic.sqlite"))

        #expect(library.list().map(\.id) == [taken.id])
        library.sweepStaging()
        #expect(folders(in: library) == [taken.id.uuidString])
    }

    // MARK: Pre-commit backup (EDT-9)

    @Test func theFirstCommitOfASessionIsBackedUpOnce() async throws {
        let store = try TestFixtures.scratchCopy(.history).storeURL
        let library = emptyLibrary()
        let backup = PreCommitBackup(store: store, library: library, retention: .init(keepBackups: 3))
        #expect(await backup.backup == nil)

        // Two commits asking at once wait for the same copy.
        async let a = backup.ensure()
        async let b = backup.ensure()
        let (first, second) = try await (a, b)
        #expect(first.id == second.id)
        #expect(first.kind == .backup)
        #expect(first.name == "Before editing")
        #expect(try await backup.ensure().id == first.id)
        #expect(library.list().map(\.id) == [first.id])
    }

    @Test func eachSessionTakesItsOwnBackupWithinTheRetention() async throws {
        let store = try TestFixtures.scratchCopy(.basic).storeURL
        let library = emptyLibrary()
        let snapshot = try await Snapshotter.take(of: store, into: library, kind: .snapshot, name: "Mine")
        var ids: [UUID] = []
        for _ in 0..<4 {
            let session = PreCommitBackup(store: store, library: library, retention: .init(keepBackups: 2))
            ids.append(try await session.ensure().id)
        }
        #expect(Set(ids).count == 4)
        #expect(Set(library.list().map(\.id)) == Set([snapshot.id] + ids.suffix(2)))
    }

    @Test func aFailedBackupIsTriedAgain() async throws {
        let location = try TestFixtures.scratchCopy(.basic)
        let hidden = location.storeURL.appendingPathExtension("away")
        try FileManager.default.moveItem(at: location.storeURL, to: hidden)
        let library = emptyLibrary()
        let backup = PreCommitBackup(store: location.storeURL, library: library)
        await #expect(throws: DabbiError.self) { try await backup.ensure() }
        #expect(await backup.backup == nil)
        #expect(folders(in: library).isEmpty)

        try FileManager.default.moveItem(at: hidden, to: location.storeURL)
        let manifest = try await backup.ensure()
        #expect(await backup.backup == manifest)
    }

    @Test func backupsAreKeptPerStore() {
        let root = URL(fileURLWithPath: "/backups")
        let store = URL(fileURLWithPath: "/data/Model.sqlite")
        let byUUID = PreCommitBackup.library(forStoreUUID: "8C1D-44", at: store, under: root)
        #expect(byUUID.root.lastPathComponent == "8C1D-44")
        // The same store at another path — a reinstall moved the container — keeps its backups.
        #expect(
            PreCommitBackup.library(
                forStoreUUID: "8C1D-44", at: URL(fileURLWithPath: "/elsewhere/M.sqlite"), under: root)
                == byUUID)

        let byPath = PreCommitBackup.library(forStoreUUID: nil, at: store, under: root)
        #expect(byPath.root.lastPathComponent.hasPrefix("path-"))
        #expect(PreCommitBackup.library(forStoreUUID: "", at: store, under: root) == byPath)
        #expect(PreCommitBackup.library(forStoreUUID: "../x", at: store, under: root) == byPath)
        #expect(
            PreCommitBackup.library(forStoreUUID: nil, at: URL(fileURLWithPath: "/data/Other.sqlite"), under: root)
                != byPath)
    }
}
