import DabbiTestSupport
import FixtureKit
import Foundation
import Testing

@testable import DabbiLocator

@Suite struct StoreSnifferTests {
    private func makeContainer() throws -> URL {
        let url = TestFixtures.root.appendingPathComponent("container-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    @Test func findsDatabasesByContentNotByName() throws {
        let container = try makeContainer()
        try SyntheticDeviceSet.place(.basic, at: "Library/Application Support/Model.sqlite", in: container)
        try SyntheticDeviceSet.place(.basic, at: "Library/Application Support/default.store", in: container)
        try SyntheticDeviceSet.place(.basic, at: "Documents/nameless", in: container)
        try SyntheticDeviceSet.place(.notCoreData, at: "Documents/cache.db", in: container)
        try SyntheticDeviceSet.place(.walOnly, at: "Documents/Live.sqlite", in: container)
        // Looks like a database by name only.
        try SyntheticDeviceSet.place(.encrypted, at: "Documents/secret.sqlite", in: container)
        try Data("not a database".utf8).write(to: container.appendingPathComponent("Documents/notes.db"))
        // A database, but not under a name a store would have.
        try SyntheticDeviceSet.place(.basic, at: "Documents/picture.png", in: container)

        let walk = StoreSniffer().databases(under: container)
        #expect(walk.isComplete)
        #expect(
            walk.databases.map { SimulatorIndex.path(of: $0, relativeTo: container) } == [
                "Documents/Live.sqlite", "Documents/cache.db", "Documents/nameless",
                "Library/Application Support/Model.sqlite", "Library/Application Support/default.store",
            ])
    }

    @Test func leavesTheSystemsFoldersAlone() throws {
        let container = try makeContainer()
        try SyntheticDeviceSet.place(.notCoreData, at: "Library/WebKit/WebsiteData/IndexedDB/db.sqlite3", in: container)
        try SyntheticDeviceSet.place(
            .notCoreData, at: "Library/HTTPStorages/org.example/httpstorages.sqlite", in: container)
        try SyntheticDeviceSet.place(.notCoreData, at: "Library/Caches/org.example/Cache.db", in: container)
        let found = StoreSniffer().databases(under: container).databases
        #expect(found.map(\.lastPathComponent) == ["Cache.db"])
    }

    @Test func stopsAtItsLimits() throws {
        let container = try makeContainer()
        try SyntheticDeviceSet.place(.notCoreData, at: "a/b/c/deep.sqlite", in: container)
        try SyntheticDeviceSet.place(.notCoreData, at: "a/shallow.sqlite", in: container)

        var sniffer = StoreSniffer()
        sniffer.maxDepth = 2
        #expect(sniffer.databases(under: container).databases.map(\.lastPathComponent) == ["shallow.sqlite"])

        sniffer = StoreSniffer()
        sniffer.maxEntries = 2
        let walk = sniffer.databases(under: container)
        #expect(!walk.isComplete)

        let nowhere = StoreSniffer().databases(under: container.appendingPathComponent("missing"))
        #expect(nowhere.databases.isEmpty)
        #expect(nowhere.isComplete)
    }

    @Test func tellsCoreDataFromPlainSQLite() throws {
        #expect(StoreSniffer.kind(of: try TestFixtures.location(.basic).storeURL) == .coreData)
        #expect(StoreSniffer.kind(of: try TestFixtures.location(.walOnly).storeURL) == .coreData)
        #expect(StoreSniffer.kind(of: try TestFixtures.location(.notCoreData).storeURL) == .plainSQLite)
        #expect(StoreSniffer.kind(of: try TestFixtures.location(.encrypted).storeURL) == nil)
    }

    /// SwiftData's traces are its schema version and the history it always tracks; history alone is not one.
    @Test func tellsAStoreSwiftDataWrote() throws {
        #expect(StoreSniffer.kind(of: try TestFixtures.location(.swiftData).storeURL) == .swiftData)
        #expect(StoreSniffer.kind(of: try TestFixtures.location(.history).storeURL) == .coreData)
    }

    /// A store whose rows — and whose schema — are still in the log, and whose `-shm` did not come along:
    /// nothing can open it where it is, but it can still be told what it is.
    @Test func recognisesAStoreItCannotOpen() throws {
        let copy = try TestFixtures.scratchCopy(.walOnly)
        try FileManager.default.removeItem(atPath: copy.storeURL.path + "-shm")
        #expect(StoreSniffer.kind(of: copy.storeURL) == nil)
        #expect(StoreSniffer.kindByContent(of: copy.storeURL) == .coreData)
        #expect(StoreSniffer.kindByContent(of: try TestFixtures.location(.notCoreData).storeURL) == .plainSQLite)
        #expect(!FileManager.default.fileExists(atPath: copy.storeURL.path + "-shm"))
    }

    @Test func theFootprintCountsTheLog() throws {
        let location = try TestFixtures.location(.walOnly)
        let main = try #require(try location.storeURL.resourceValues(forKeys: [.fileSizeKey]).fileSize)
        let footprint = StoreSniffer.footprint(of: location.storeURL)
        #expect(footprint.byteCount > Int64(main))
        #expect(footprint.modifiedAt != nil)
        #expect(StoreSniffer.footprint(of: URL(fileURLWithPath: "/nonexistent.sqlite")).byteCount == 0)
    }
}
