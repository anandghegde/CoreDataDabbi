import DabbiBase
import DabbiTestSupport
import FixtureKit
import Foundation
import Testing

@testable import DabbiLocator

/// PRJ-12: where a lost store may be now.
@Suite struct StoreLocationRepairerTests {
    private let path = "Library/Application Support/Model.sqlite"

    private func simulator(_ udid: String, _ path: String? = nil, container: AppContainer = .data) -> StoreLocation {
        .simulator(udid: udid, bundleID: "org.example.app", container: container, relativePath: path ?? self.path)
    }

    @Test func theSameAppOnAnotherSimulatorIsSuggestedWhenTheFirstIsGone() throws {
        let set = try SyntheticDeviceSet()
        let phone = try set.addDevice(udid: "PHONE", name: "iPhone 16")
        let pad = try set.addDevice(udid: "PAD", name: "iPad Pro")
        let bare = try set.addDevice(udid: "BARE")
        try set.install("org.example.other", name: "Other", on: bare)
        for device in [phone, pad] {
            let app = try set.install("org.example.app", name: "App", on: device)
            try SyntheticDeviceSet.place(.basic, at: path, in: try #require(app.dataContainer))
        }
        let repairer = StoreLocationRepairer(devicesDirectory: set.root)

        let repairs = repairer.suggestions(for: simulator("DELETED"))
        #expect(Set(repairs.compactMap(\.device?.udid)) == ["PHONE", "PAD"])
        #expect(repairs.allSatisfy { $0.reason == .otherDevice })
        let onPhone = try #require(repairs.first { $0.device?.udid == "PHONE" })
        #expect(onPhone.location == simulator("PHONE"))
        #expect(onPhone.device?.name == "iPhone 16")
        #expect(try StoreLocationResolver(devicesDirectory: set.root).resolve(simulator("PHONE")) == onPhone.url)
    }

    @Test func aStoreTheAppMovedWithinItsContainerComesFirst() throws {
        let set = try SyntheticDeviceSet()
        let phone = try set.addDevice(udid: "PHONE")
        let pad = try set.addDevice(udid: "PAD")
        let here = try #require(try set.install("org.example.app", name: "App", on: phone).dataContainer)
        try SyntheticDeviceSet.place(.basic, at: "Documents/Model.sqlite", in: here)
        try SyntheticDeviceSet.place(.basic, at: "Library/Caches/Cache.sqlite", in: here)
        let there = try #require(try set.install("org.example.app", name: "App", on: pad).dataContainer)
        try SyntheticDeviceSet.place(.basic, at: path, in: there)

        let repairs = StoreLocationRepairer(devicesDirectory: set.root).suggestions(for: simulator("PHONE"))
        #expect(
            repairs.map(\.location) == [
                simulator("PHONE", "Documents/Model.sqlite"), simulator("PAD"),
                simulator("PHONE", "Library/Caches/Cache.sqlite"),
            ], "same name on the same device, then the same path elsewhere, then whatever else the app keeps")
        #expect(repairs.map(\.reason) == [.elsewhereInContainer, .otherDevice, .elsewhereInContainer])
    }

    @Test func groupStoresAreLookedForInTheSameGroup() throws {
        let set = try SyntheticDeviceSet()
        let phone = try set.addDevice(udid: "PHONE")
        try set.install("org.example.app", name: "App", on: phone)
        let group = try set.addGroup("group.org.example", on: phone)
        try SyntheticDeviceSet.place(.basic, at: path, in: group)
        let lost = simulator("GONE", container: .group("group.org.example"))

        let repairs = StoreLocationRepairer(devicesDirectory: set.root).suggestions(for: lost)
        #expect(repairs.map(\.location) == [simulator("PHONE", container: .group("group.org.example"))])
    }

    @Test func nothingIsSuggestedWhereThereIsNothing() throws {
        let set = try SyntheticDeviceSet()
        let phone = try set.addDevice(udid: "PHONE")
        try set.install("org.example.app", name: "App", on: phone)
        try set.addDevice(udid: "OLD", isDeleted: true)
        let repairer = StoreLocationRepairer(devicesDirectory: set.root)
        #expect(repairer.suggestions(for: simulator("PHONE")).isEmpty, "the app has no store anywhere")
        #expect(
            repairer.suggestions(for: .macApp(bundleID: "org.example.app", container: .data, relativePath: path))
                .isEmpty)
    }

    @Test func aFileIsLookedForNextToWhereItWas() throws {
        let folder = TestFixtures.root.appendingPathComponent("repair-\(UUID().uuidString)", isDirectory: true)
        let other = try SyntheticDeviceSet.place(.basic, at: "Renamed.sqlite", in: folder)
        try SyntheticDeviceSet.place(.basic, at: "Nested/Deeper.sqlite", in: folder)
        try Data("not a database".utf8).write(to: folder.appendingPathComponent("Notes.sqlite"))
        let lost = StoreLocation.file(
            FileReference(lastKnownPath: folder.appendingPathComponent("Model.sqlite").path))

        let repairs = StoreLocationRepairer(devicesDirectory: folder).suggestions(for: lost)
        #expect(repairs.map(\.url.lastPathComponent) == [other.lastPathComponent])
        #expect(repairs.first?.location == nil, "a file is adopted by whoever keeps the bookmarks")
        #expect(repairs.first?.reason == .sameFolder)
    }
}
