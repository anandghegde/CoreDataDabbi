import DabbiKit
import DabbiTestSupport
import FixtureKit
import Foundation
import Testing

@Suite struct StoreOpenerTests {
    private func opener(devices: URL? = nil) -> StoreOpener {
        StoreOpener(
            resolver: StoreLocationResolver(devicesDirectory: devices),
            workingCopiesDirectory: TestFixtures.root.appendingPathComponent("copies-\(UUID().uuidString)"))
    }

    @Test func opensAnOrdinaryStoreInPlace() async throws {
        let location = try TestFixtures.location(.company)
        let opened = try await opener().open(storeURL: location.storeURL)
        #expect(!opened.isWorkingCopy)
        #expect(opened.session.info.url.path == location.storeURL.standardizedFileURL.path)
        await opened.close()
    }

    /// §6.2 end to end: rows in the log, no `-shm`. The user sees their data; their folder sees nothing.
    @Test func opensACopyOfAStoreThatCannotBeReadInPlace() async throws {
        let original = try TestFixtures.scratchCopy(.walOnly)
        try FileManager.default.removeItem(atPath: original.storeURL.path + "-shm")
        let before = try FileManager.default.contentsOfDirectory(atPath: original.directory.path).sorted()

        let opener = opener()
        let opened = try await opener.open(storeURL: original.storeURL)
        let copy = try #require(opened.workingCopy)
        #expect(opened.storeURL == original.storeURL)
        #expect(copy.original == original.storeURL)
        #expect(copy.url.path.hasPrefix(opener.workingCopiesDirectory.path))
        let counts = try await opened.session.entityCounts()
        #expect(
            Dictionary(uniqueKeysWithValues: counts.map { ($0.entity, $0.total) }) == original.manifest.entityCounts)

        await opened.close()
        #expect(!FileManager.default.fileExists(atPath: copy.folder.path))
        #expect(try FileManager.default.contentsOfDirectory(atPath: original.directory.path).sorted() == before)
    }

    @Test func aFolderThatCannotBeWrittenToIsNoObstacle() async throws {
        let original = try TestFixtures.scratchCopy(.walOnly)
        try FileManager.default.setAttributes([.posixPermissions: 0o555], ofItemAtPath: original.directory.path)
        defer {
            try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: original.directory.path)
        }
        let opened = try await opener().open(storeURL: original.storeURL)
        let counts = try await opened.session.entityCounts()
        #expect(counts.map(\.total).reduce(0, +) == 21)
        await opened.close()
    }

    /// A simulator store without a cached model: the app it belongs to has the model in its bundle.
    @Test func findsTheModelInTheAppNextToASimulatorStore() async throws {
        let set = try SyntheticDeviceSet()
        let device = try set.addDevice(udid: "DEVICE")
        let fixture = try TestFixtures.location(.noModelCache)
        let location = StoreLocation.simulator(
            udid: "DEVICE", bundleID: "org.example.app", container: .data, relativePath: "Documents/Model.sqlite")

        // No compiled model in the bundle — SwiftData, as far as anyone can tell: the honest error stays.
        let app = try set.install("org.example.app", name: "App", on: device)
        try SyntheticDeviceSet.place(.noModelCache, at: "Documents/Model.sqlite", in: try #require(app.dataContainer))
        let opener = opener(devices: set.root)
        let error = await #expect(throws: DabbiError.self) { try await opener.open(location) }
        #expect(error?.code == .modelCacheMissing)

        let model = try #require(fixture.modelURL)
        try FileManager.default.copyItem(at: model, to: app.bundle.appendingPathComponent(model.lastPathComponent))
        let opened = try await opener.open(location)
        #expect(opened.modelURL?.path == app.bundle.path)
        let counts = try await opened.session.entityCounts()
        #expect(Dictionary(uniqueKeysWithValues: counts.map { ($0.entity, $0.total) }) == fixture.manifest.entityCounts)
        await opened.close()
    }

    @Test func aLocationThatLeadsNowhereSaysSo() async throws {
        let set = try SyntheticDeviceSet()
        let location = StoreLocation.simulator(
            udid: "GONE", bundleID: "org.example.app", container: .data, relativePath: "Documents/Model.sqlite")
        let error = await #expect(throws: DabbiError.self) { try await opener(devices: set.root).open(location) }
        #expect(error?.code == .locationUnresolved)
    }

    @Test func aCopyDoesNotHelpWithWhatIsNotAStore() async throws {
        let opener = opener()
        let error = await #expect(throws: DabbiError.self) {
            try await opener.open(storeURL: try TestFixtures.location(.encrypted).storeURL)
        }
        #expect(error?.code == .notSQLite)
        #expect(!FileManager.default.fileExists(atPath: opener.workingCopiesDirectory.path))
    }

    @Test func sweepsUpCopiesLeftBehind() async throws {
        let opener = opener()
        let original = try TestFixtures.scratchCopy(.walOnly)
        try FileManager.default.removeItem(atPath: original.storeURL.path + "-shm")
        let opened = try await opener.open(storeURL: original.storeURL)
        await opened.session.close()  // as a crash would: the copy stays
        let folder = try #require(opened.workingCopy?.folder)
        #expect(FileManager.default.fileExists(atPath: folder.path))

        opener.removeStaleWorkingCopies(olderThan: 3_600)
        #expect(FileManager.default.fileExists(atPath: folder.path))
        opener.removeStaleWorkingCopies()
        #expect(!FileManager.default.fileExists(atPath: folder.path))
    }
}
