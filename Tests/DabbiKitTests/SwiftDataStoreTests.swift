import DabbiKit
import DabbiTestSupport
import FixtureKit
import Foundation
import Testing

/// PRJ-11 from the outside in: a store SwiftData wrote, found in a simulator, opened and looked into.
@Suite struct SwiftDataStoreTests {
    @Test func isFoundOpenedAndItsArraysAreReadable() async throws {
        let set = try SyntheticDeviceSet()
        let device = try set.addDevice(udid: "SWIFTDATA-1", name: "iPhone 16", runtime: SyntheticDeviceSet.iOS18)
        let app = try set.install("org.example.trips", name: "Trips", on: device)
        let data = try #require(app.dataContainer)
        try SyntheticDeviceSet.place(.swiftData, at: "Library/Application Support/default.store", in: data)

        let contents = SimulatorIndex.scan(device.simulatorDevice)
        let candidate = try #require(contents.apps.first?.stores.first)
        #expect(candidate.kind == .swiftData)

        let opener = StoreOpener(
            resolver: StoreLocationResolver(devicesDirectory: set.root),
            workingCopiesDirectory: TestFixtures.root.appendingPathComponent("copies-\(UUID().uuidString)"))
        let opened = try await opener.open(candidate.location)
        #expect(!opened.isWorkingCopy && opened.session.info.modelSource == .storeCache)

        // `tags: [String]` is an NSArray in a keyed archive. Our own parser reads it; nothing is unarchived.
        let spec = FetchSpec(entity: "Trip", predicate: PredicateSource(format: "name == 'Trip 1'"))
        let pager = try await opened.session.openPager(spec)
        let ref = try #require(try await opened.session.page(pager, range: 0..<1).rows.first?.ref)
        let bytes = try #require(try await opened.session.blob(for: ref, attribute: "tags"))
        let report = ContentRegistry.standard.decode(
            bytes, hint: ContentHint(storage: .transformable, attributeName: "tags"))
        #expect(report.type == .keyedArchive && report.issues.isEmpty)
        guard case .tree(let root, _, _) = report.content else {
            Issue.record("tags decoded as \(report.content)")
            return
        }
        let outline = root.outline()
        #expect(outline.contains("tag-1") && outline.contains("shared"))
        await opened.close()
    }
}
