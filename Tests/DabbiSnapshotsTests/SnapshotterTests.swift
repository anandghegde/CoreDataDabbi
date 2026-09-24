@preconcurrency import CoreData
import DabbiBase
import DabbiModel
import DabbiSQLite
import DabbiStore
import DabbiTestSupport
import FixtureKit
import Foundation
import Testing

@testable import DabbiSnapshots

/// §7.3 and EDT-9: a snapshot is a consistent, self-contained, verified copy, taken without writing a byte next to
/// the store.
@Suite struct SnapshotterTests {
    private func emptyLibrary() -> SnapshotLibrary {
        SnapshotLibrary(root: TestFixtures.root.appendingPathComponent("library-\(UUID().uuidString)"))
    }

    /// Every file beside the store, the `-shm` by existence only: every connection rebuilds its index.
    private func fingerprint(_ folder: URL) throws -> [String: Data] {
        var files: [String: Data] = [:]
        let walk = FileManager.default.enumerator(atPath: folder.path)
        while let name = walk?.nextObject() as? String {
            guard walk?.fileAttributes?[.type] as? FileAttributeType == .typeRegular else { continue }
            files[name] = name.hasSuffix("-shm") ? Data() : try Data(contentsOf: folder.appendingPathComponent(name))
        }
        return files
    }

    @Test(arguments: [Fixture.basic, .company, .ordered, .composites, .history, .walOnly, .externalData, .swiftData])
    func aSnapshotOpensWithTheStoresRows(_ fixture: Fixture) async throws {
        let location = try TestFixtures.scratchCopy(fixture)
        let before = try fingerprint(location.directory)
        let library = emptyLibrary()

        let manifest = try await Snapshotter.take(of: location.storeURL, into: library, kind: .snapshot, name: "One")
        #expect(try fingerprint(location.directory) == before)
        #expect(manifest.kind == .snapshot)
        #expect(manifest.name == "One")
        #expect(manifest.storeFileName == location.storeURL.lastPathComponent)
        #expect(manifest.storeUUID == (try StoreMetadata.read(from: location.storeURL)).storeUUID)
        #expect(manifest.verification.comparedWithStore)

        // One self-contained file, which opens anywhere read-only.
        let copy = library.databaseURL(of: manifest)
        for suffix in StoreFiles.sideFileSuffixes {
            #expect(!FileManager.default.fileExists(atPath: copy.path + suffix))
        }
        let session = try await StoreSession.open(storeURL: copy, modelURL: location.modelURL)
        let counts = try await session.entityCounts()
        #expect(
            Dictionary(uniqueKeysWithValues: counts.map { ($0.entity, $0.total) }) == location.manifest.entityCounts)
        await session.close()
        try Snapshotter.verify(manifest, in: library)
    }

    @Test func externalDataComesAlong() async throws {
        let location = try TestFixtures.scratchCopy(.externalData)
        let library = emptyLibrary()
        let manifest = try await Snapshotter.take(of: location.storeURL, into: library, kind: .snapshot, name: "X")
        let original = try fingerprint(StoreFiles.supportFolder(of: location.storeURL))
        #expect(!original.isEmpty)
        #expect(manifest.externalFileCount == original.count)
        #expect(manifest.externalBytes == Int64(original.values.reduce(0) { $0 + $1.count }))
        #expect(try fingerprint(StoreFiles.supportFolder(of: library.databaseURL(of: manifest))) == original)

        // The copied rows find their files: every payload of the copy is the original's.
        let copy = try await StoreSession.open(storeURL: library.databaseURL(of: manifest))
        let source = try await StoreSession.open(storeURL: location.storeURL)
        let spec = FetchSpec(entity: "Document")
        for (copied, sourced) in zip(try await copy.references(spec), try await source.references(spec)) {
            let a = try await copy.blob(for: copied, attribute: "payload")
            let b = try await source.blob(for: sourced, attribute: "payload")
            #expect(a == b)
        }
        await copy.close()
        await source.close()
    }

    /// The app keeps saving throughout. The copy is still one consistent state of the store; it just cannot be
    /// compared with a store that has moved on.
    @Test func aStoreBeingWrittenIsCopiedConsistently() async throws {
        let directory = TestFixtures.root.appendingPathComponent("busy-\(UUID().uuidString)", isDirectory: true)
        let writer = try StoreWriter(
            model: NotesFixture.makeModel(), storeURL: directory.appendingPathComponent("Busy.sqlite"))
        try writer.perform { writer in
            let folder = writer.insert("Folder", ["name": "Inbox"])
            for index in 0..<2_000 { writer.insert("Note", ["title": "Note \(index)", "body": "x", "folder": folder]) }
        }
        let busy = Task.detached {
            for round in 0..<40 {
                try writer.perform { writer in
                    for index in 0..<50 { writer.insert("Note", ["title": "Round \(round).\(index)", "body": "y"]) }
                }
            }
        }
        let library = emptyLibrary()
        var manifests: [SnapshotManifest] = []
        for index in 0..<5 {
            manifests.append(
                try await Snapshotter.take(of: writer.storeURL, into: library, kind: .snapshot, name: "\(index)"))
        }
        try await busy.value
        let quiet = try await Snapshotter.take(of: writer.storeURL, into: library, kind: .snapshot, name: "quiet")
        #expect(quiet.verification.comparedWithStore)
        try writer.close()

        for manifest in manifests + [quiet] {
            try Snapshotter.verify(manifest, in: library)
            let notes = manifest.tables.first { $0.table == "ZNOTE" }?.rows ?? 0
            #expect((2_000...4_000).contains(notes))
            #expect((notes - 2_000) % 50 == 0, "a copy holds whole saves only")
        }
        #expect(quiet.tables.first { $0.table == "ZNOTE" }?.rows == 4_000)
    }

    @Test func aFailedCopyLeavesNothingBehind() async throws {
        let library = emptyLibrary()
        let missing = TestFixtures.root.appendingPathComponent("nothing-here.sqlite")
        await #expect(throws: DabbiError.self) {
            try await Snapshotter.take(of: missing, into: library, kind: .snapshot, name: "None")
        }
        let encrypted = try TestFixtures.location(.encrypted)
        let error = await #expect(throws: DabbiError.self) {
            try await Snapshotter.take(of: encrypted.storeURL, into: library, kind: .snapshot, name: "None")
        }
        #expect(error?.code == .notSQLite)
        #expect(((try? FileManager.default.contentsOfDirectory(atPath: library.root.path)) ?? []).isEmpty)
    }

    @Test func verifyNoticesADamagedSnapshot() async throws {
        let location = try TestFixtures.scratchCopy(.externalData)
        let library = emptyLibrary()
        let manifest = try await Snapshotter.take(of: location.storeURL, into: library, kind: .snapshot, name: "X")
        let copy = library.databaseURL(of: manifest)

        // An external file gone.
        let support = StoreFiles.supportFolder(of: copy)
        let walk = FileManager.default.enumerator(atPath: support.path)
        var removed = false
        while !removed, let name = walk?.nextObject() as? String {
            guard walk?.fileAttributes?[.type] as? FileAttributeType == .typeRegular else { continue }
            try FileManager.default.removeItem(at: support.appendingPathComponent(name))
            removed = true
        }
        #expect(removed)
        let missingFile = #expect(throws: DabbiError.self) { try Snapshotter.verify(manifest, in: library) }
        #expect(missingFile?.code == .snapshotUnverified)

        // Pages overwritten in the middle of the database.
        let handle = try FileHandle(forWritingTo: copy)
        try handle.seek(toOffset: 4_096)
        try handle.write(contentsOf: Data(repeating: 0xA5, count: 8_192))
        try handle.close()
        let damaged = #expect(throws: DabbiError.self) { try Snapshotter.verify(manifest, in: library) }
        #expect(damaged?.code == .snapshotUnverified || damaged?.code == .sqlite)
    }

    @Test func aManifestReadsBackAsWritten() async throws {
        let location = try TestFixtures.scratchCopy(.company)
        let library = emptyLibrary()
        let manifest = try await Snapshotter.take(
            of: location.storeURL, into: library, kind: .snapshot, name: "Company", note: "Before the rename")
        #expect(try library.manifest(manifest.id) == manifest)
        #expect(manifest.note == "Before the rename")
        #expect(!manifest.entityVersionHashes.isEmpty)
        #expect(manifest.tables.contains { $0.table == "Z_METADATA" })
    }

    @Test func aManifestFromTheFutureIsRefused() async throws {
        let location = try TestFixtures.scratchCopy(.basic)
        let library = emptyLibrary()
        let manifest = try await Snapshotter.take(of: location.storeURL, into: library, kind: .snapshot, name: "B")
        let url = library.folder(for: manifest.id).appendingPathComponent(SnapshotManifest.fileName)
        let text = try String(contentsOf: url, encoding: .utf8)
        #expect(text.contains(#""format" : 1"#))
        try text.replacingOccurrences(of: #""format" : 1"#, with: #""format" : 99"#)
            .write(to: url, atomically: true, encoding: .utf8)
        let error = #expect(throws: DabbiError.self) { try library.manifest(manifest.id) }
        #expect(error?.arguments["format"] == "99")
        #expect(library.list().isEmpty)
    }
}
