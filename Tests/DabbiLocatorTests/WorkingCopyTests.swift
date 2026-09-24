import DabbiBase
import DabbiSQLite
import DabbiTestSupport
import FixtureKit
import Foundation
import Testing

@testable import DabbiLocator

@Suite struct WorkingCopyTests {
    private func workFolder() -> URL {
        TestFixtures.root.appendingPathComponent("working-\(UUID().uuidString)", isDirectory: true)
    }

    private func listing(_ folder: URL) throws -> [String] {
        try FileManager.default.contentsOfDirectory(atPath: folder.path).sorted()
    }

    /// The case the whole thing exists for (§6.2): rows in the log, no `-shm`, nothing can open it in place.
    @Test func makesAStoreThatCannotBeOpenedInPlaceReadable() throws {
        let original = try TestFixtures.scratchCopy(.walOnly)
        try FileManager.default.removeItem(atPath: original.storeURL.path + "-shm")
        let before = try listing(original.directory)
        let failure = try #require(
            #expect(throws: DabbiError.self) { try SQLiteConnection(readOnly: original.storeURL) })
        #expect(failure.code == .readOnlyLocation)
        #expect(WorkingCopy.helps(with: failure))

        let copy = try WorkingCopy.make(of: original.storeURL, in: workFolder())
        #expect(copy.original == original.storeURL)
        #expect(copy.url.lastPathComponent == original.storeURL.lastPathComponent)

        let connection = try SQLiteConnection(readOnly: copy.url)
        for (entity, expected) in original.manifest.entityCounts {
            let table = SQLiteConnection.quoteIdentifier("Z" + entity.uppercased())
            #expect(try connection.scalar("SELECT count(*) FROM \(table)")?.int64 == Int64(expected), "\(entity)")
        }
        connection.close()
        // One self-contained file, and nothing new next to the user's store.
        #expect(try listing(copy.folder) == [copy.url.lastPathComponent])
        #expect(try listing(original.directory) == before)

        copy.remove()
        #expect(!FileManager.default.fileExists(atPath: copy.folder.path))
    }

    @Test func takesTheExternalDataAlong() throws {
        let original = try TestFixtures.location(.externalData)
        let support = StoreFiles.supportFolder(of: original.storeURL)
        try #require(FileManager.default.fileExists(atPath: support.path))
        let copy = try WorkingCopy.make(of: original.storeURL, in: workFolder())
        let copied = StoreFiles.supportFolder(of: copy.url)
        #expect(try listing(copied) == (try listing(support)))
    }

    @Test func otherFailuresAreNotItsBusiness() throws {
        let encrypted = try TestFixtures.location(.encrypted).storeURL
        let failure = try #require(#expect(throws: DabbiError.self) { try SQLiteConnection(readOnly: encrypted) })
        #expect(!WorkingCopy.helps(with: failure))
        #expect(!WorkingCopy.helps(with: CocoaError(.fileNoSuchFile)))
    }

    @Test func leavesNothingBehindWhenItFails() throws {
        let folder = workFolder()
        #expect(throws: DabbiError.self) {
            try WorkingCopy.make(of: URL(fileURLWithPath: "/nonexistent/Model.sqlite"), in: folder)
        }
        #expect(throws: DabbiError.self) {
            try WorkingCopy.make(of: try TestFixtures.location(.encrypted).storeURL, in: folder)
        }
        #expect((try? listing(folder)) ?? [] == [])
    }
}

@Suite struct SwiftDataConventionsTests {
    @Test func aSchemaVersionAndHistoryAreSwiftDatasTraces() {
        func looks(_ identifiers: [String], history: Bool = true) -> Bool {
            SwiftDataConventions.looksWrittenBySwiftData(modelVersionIdentifiers: identifiers, tracksHistory: history)
        }
        #expect(looks(["1.0.0"]))
        #expect(looks(["12.3.45"]))
        #expect(!looks(["1.0.0"], history: false))
        // What Xcode's model editor and hand-made models leave behind.
        #expect(!looks([]))
        #expect(!looks([""]))
        #expect(!looks(["notes-1"]))
        #expect(!looks(["1.0"]))
        #expect(!looks(["1.0.0-beta"]))
        #expect(!looks(["1..0"]))
        #expect(!looks(["1.0.0", "Model 2"]))
    }

    @Test func anAppWithoutACompiledModelIsTakenForSwiftData() throws {
        let set = try SyntheticDeviceSet()
        let device = try set.addDevice()
        let swifty = try set.install("org.example.swifty", name: "Swifty", on: device)
        #expect(SwiftDataConventions.shipsNoModel(swifty.bundle))

        // A model in a framework of the app counts as the app's.
        let classic = try set.install("org.example.classic", name: "Classic", on: device)
        let model = try #require(try TestFixtures.location(.noModelCache).modelURL)
        let framework = classic.bundle.appendingPathComponent("Frameworks/Core.framework", isDirectory: true)
        try FileManager.default.createDirectory(at: framework, withIntermediateDirectories: true)
        try FileManager.default.copyItem(at: model, to: framework.appendingPathComponent(model.lastPathComponent))
        #expect(!SwiftDataConventions.shipsNoModel(classic.bundle))
    }

    @Test func looksForTheDefaultStoreInTheGroupFirst() throws {
        let set = try SyntheticDeviceSet()
        let device = try set.addDevice()
        let installed = try set.install(
            "org.example.swifty", name: "Swifty", on: device, executable: try TestBinaries.withSection.get())
        let group = try set.addGroup(TestBinaries.groups[0], on: device)
        let app = try #require(ContainerMap(deviceData: device.data).apps().first)

        let places = SwiftDataConventions.defaultStoreLocations(of: app)
        #expect(places.map(\.container) == [.group(TestBinaries.groups[0]), .data])
        #expect(places.allSatisfy { $0.relativePath == "Library/Application Support/default.store" })
        #expect(SwiftDataConventions.defaultStores(of: app).isEmpty)

        let inData = try SyntheticDeviceSet.place(
            .basic, at: "Library/Application Support/default.store", in: try #require(installed.dataContainer))
        #expect(SwiftDataConventions.defaultStores(of: app).map(\.path) == [inData.path])
        let inGroup = try SyntheticDeviceSet.place(.basic, at: "Library/Application Support/default.store", in: group)
        #expect(SwiftDataConventions.defaultStores(of: app).map(\.path) == [inGroup.path, inData.path])
    }
}
