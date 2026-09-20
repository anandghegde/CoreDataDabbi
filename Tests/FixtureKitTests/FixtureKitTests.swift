import DabbiTestSupport
import Foundation
import Testing

@testable import FixtureKit

@Suite struct FixtureKitTests {
    @Test(arguments: Fixture.allCases)
    func buildsWithAManifestThatCanBeReadBack(_ fixture: Fixture) throws {
        let location = try TestFixtures.location(fixture)
        #expect(FileManager.default.fileExists(atPath: location.storeURL.path))
        if let model = location.modelURL { #expect(FileManager.default.fileExists(atPath: model.path)) }
        #expect(location.manifest.fixture == fixture)
        #expect(!location.manifest.summary.isEmpty)
        #expect(location.manifest.requiresModel == false || location.manifest.model != nil)
        #expect((location.manifest.kind == .coreDataStore) == !location.manifest.entityCounts.isEmpty)

        let reread = try #require(FixtureBuilder.existing(fixture, in: TestFixtures.root))
        #expect(reread.manifest == location.manifest)
    }

    @Test func rebuildingReplacesWhatWasThere() throws {
        let root = TestFixtures.root.appendingPathComponent("rebuild-\(UUID().uuidString)", isDirectory: true)
        let first = try FixtureBuilder.build(.ordered, in: root)
        let stray = first.directory.appendingPathComponent("stray.txt")
        try Data("left over".utf8).write(to: stray)
        let second = try FixtureBuilder.build(.ordered, in: root)
        #expect(second.manifest == first.manifest)
        #expect(!FileManager.default.fileExists(atPath: stray.path))
        #expect(FixtureBuilder.existing(.basic, in: root) == nil)
    }

    @Test func theGeneratorIsDeterministic() {
        var first = SeededGenerator(seed: 42)
        var second = SeededGenerator(seed: 42)
        var other = SeededGenerator(seed: 43)
        let values = (0..<8).map { _ in first.next() }
        #expect(values == (0..<8).map { _ in second.next() })
        #expect(values != (0..<8).map { _ in other.next() })
        #expect(Set(values).count == 8)

        #expect(first.uuid() == second.uuid())
        #expect(first.data(count: 33) == second.data(count: 33))
        #expect(first.data(count: 33).count == 33)
        #expect(first.data(count: 0).isEmpty)
        // Version 4, RFC 4122 variant — so the UUIDs look like the ones apps really store.
        let uuid = first.uuid().uuid
        #expect(uuid.6 & 0xF0 == 0x40 && uuid.8 & 0xC0 == 0x80)
    }

    @Test func theEncryptedFixtureHasNoSQLiteHeader() throws {
        let head = try Data(contentsOf: try TestFixtures.location(.encrypted).storeURL).prefix(16)
        #expect(head != Data("SQLite format 3\0".utf8))
        let plain = try Data(contentsOf: try TestFixtures.location(.notCoreData).storeURL).prefix(16)
        #expect(plain == Data("SQLite format 3\0".utf8))
    }

    @Test func theWALOnlyFixtureKeepsItsRowsOutOfTheMainFile() throws {
        let location = try TestFixtures.location(.walOnly)
        let wal = URL(fileURLWithPath: location.storeURL.path + "-wal")
        let size = try #require(try FileManager.default.attributesOfItem(atPath: wal.path)[.size] as? Int)
        #expect(size > 0)
    }
}
