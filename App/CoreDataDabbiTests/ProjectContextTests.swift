import DabbiKit
import FixtureKit
import Foundation
import Testing

@testable import CoreDataDabbi

@MainActor
@Suite struct ProjectContextTests {
    private func context(showing fixture: Fixture) throws -> ProjectContext {
        let context = ProjectContext()
        context.workingCopiesDirectory = try AppFixtures.scratchFolder("copies")
        context.adoptStore(at: try AppFixtures.location(fixture).storeURL)
        return context
    }

    @Test func opensTheStoreAndStartsAtTheFirstEntity() async throws {
        let context = try context(showing: .company)
        context.openStoreIfNeeded()
        guard case .opening = context.storeState else {
            Issue.record("expected the store to be opening, found \(context.storeState)")
            return
        }
        await context.whenSettled()

        #expect(context.openedStore != nil)
        #expect(context.storeURL == (try AppFixtures.location(.company).storeURL))
        // "Party" is abstract and sorts after it anyway.
        #expect(context.selectedEntity == "Department")
        let expected = try AppFixtures.location(.company).manifest.entityCounts
        #expect(context.entityCounts.mapValues(\.total) == expected)
        context.shutDown()
    }

    @Test func aProjectWithoutAStoreOpensNothing() async {
        let context = ProjectContext()
        context.openStoreIfNeeded()
        await context.whenSettled()
        guard case .none = context.storeState else {
            Issue.record("expected no store, found \(context.storeState)")
            return
        }
    }

    @Test func saysWhyAFileIsNotAStore() async throws {
        let context = try context(showing: .encrypted)
        context.openStoreIfNeeded()
        await context.whenSettled()
        guard case .failed(let error) = context.storeState else {
            Issue.record("expected a failure, found \(context.storeState)")
            return
        }
        #expect(error.code == .notSQLite)
        #expect(context.selectedEntity == nil)
    }

    @Test func startsWhereTheProjectWasLeft() async throws {
        let context = try context(showing: .company)
        context.updateSelection { $0.entity = "Tag" }
        context.openStoreIfNeeded()
        await context.whenSettled()
        #expect(context.selectedEntity == "Tag")
        context.shutDown()
    }

    @Test func reloadingKeepsThePlaceAndItsHistory() async throws {
        let context = try context(showing: .company)
        context.openStoreIfNeeded()
        await context.whenSettled()
        context.select(entity: "Employee")
        context.select(entity: "Tag")

        context.openStore()
        await context.whenSettled()
        #expect(context.selectedEntity == "Tag")
        #expect(context.navigation.canGoBack)
        context.shutDown()
    }

    @Test func anotherStoreStartsOver() async throws {
        let context = try context(showing: .company)
        context.openStoreIfNeeded()
        await context.whenSettled()
        context.select(entity: "Tag")

        var changes: [ProjectContext.Change] = []
        context.onChange = { changes.append($0) }
        context.chooseStore(at: try AppFixtures.location(.swiftData).storeURL)
        await context.whenSettled()

        #expect(changes.first == .project)
        #expect(context.storeURL == (try AppFixtures.location(.swiftData).storeURL))
        #expect(context.selectedEntity == "Stop")
        #expect(!context.navigation.canGoBack)
        context.shutDown()
    }

    @Test func readsACopyOfWhatCannotBeReadInPlace() async throws {
        let context = ProjectContext()
        context.workingCopiesDirectory = try AppFixtures.scratchFolder("copies")
        let original = try AppFixtures.location(.walOnly)
        let folder = try AppFixtures.scratchFolder("wal")
        let store = folder.appendingPathComponent(original.storeURL.lastPathComponent)
        for suffix in ["", "-wal"] {
            try FileManager.default.copyItem(
                atPath: original.storeURL.path + suffix, toPath: store.path + suffix)
        }
        context.adoptStore(at: store)
        context.openStoreIfNeeded()
        await context.whenSettled()

        let opened = try #require(context.openedStore)
        #expect(opened.isWorkingCopy)
        #expect(context.storeURL == store)
        #expect(!FileManager.default.fileExists(atPath: store.path + "-shm"))

        let status = StoreStatus(context: context)
        #expect(status.phase == .open)
        #expect(status.workingCopyDate != nil)
        #expect(status.storeURL == store)
        context.shutDown()
    }

    @Test func layoutChangesAreOnlyReportedWhenSomethingChanged() throws {
        let context = ProjectContext()
        var changes: [ProjectContext.Change] = []
        context.onChange = { changes.append($0) }

        context.updateLayout(of: "Employee") { $0.displayAttribute = "name" }
        context.updateLayout(of: "Employee") { $0.displayAttribute = "name" }
        context.updateWindow { $0.collapsedPanes = ["inspector"] }
        context.updateWindow { $0.collapsedPanes = ["inspector"] }
        #expect(changes == [.layout, .layout])

        // A layout that says nothing is not kept.
        context.updateLayout(of: "Employee") { $0.displayAttribute = nil }
        #expect(context.project.display.entities["Employee"] == nil)
    }

    @Test func knowsWhichStoreItShows() throws {
        let context = try context(showing: .basic)
        let url = try AppFixtures.location(.basic).storeURL
        #expect(context.shows(.file(FileReference(lastKnownPath: url.path))))
        #expect(!context.shows(.file(FileReference(lastKnownPath: url.path + "x"))))
        #expect(!ProjectContext().shows(.file(FileReference(lastKnownPath: url.path))))
    }
}
