import AppKit
import DabbiKit
import FixtureKit
import Testing

@testable import CoreDataDabbi

@MainActor
@Suite struct ProjectDocumentTests {
    @Test func aStoreOpensAsAnUntitledProject() throws {
        let store = try AppFixtures.location(.basic).storeURL
        let controller = try #require(DocumentController.current)
        #expect(try controller.typeForContents(of: store) == DocumentController.storeTypeIdentifier)

        let made = try controller.makeDocument(withContentsOf: store, ofType: DocumentController.storeTypeIdentifier)
        let document = try #require(made as? ProjectDocument)
        #expect(document.fileURL == nil)
        #expect(document.displayName == store.lastPathComponent)
        #expect(document.context.shows(.file(FileReference(lastKnownPath: store.path))))
        #expect(!document.isDocumentEdited)
        document.close()
    }

    @Test func projectsAreToldFromStoresByTheirExtension() throws {
        let controller = try #require(DocumentController.current)
        let project = URL(fileURLWithPath: "/tmp/Some.dabbi")
        #expect(try controller.typeForContents(of: project) == ProjectPackage.typeIdentifier)
        let nameless = URL(fileURLWithPath: "/tmp/data")
        #expect(try controller.typeForContents(of: nameless) == DocumentController.storeTypeIdentifier)
    }

    @Test func savesAndReadsBackWhatTheProjectSays() throws {
        let store = try AppFixtures.location(.company).storeURL
        let document = try ProjectDocument(type: ProjectPackage.typeIdentifier)
        document.context.adoptStore(at: store)
        document.context.updateLayout(of: "Employee") {
            $0.columns = [ColumnLayout(property: "name", width: 180), ColumnLayout(property: "salary", isHidden: true)]
        }
        document.context.updateSelection { $0.entity = "Tag" }
        document.context.updateWindow { $0.dividers["main"] = [240, 900] }

        let folder = try AppFixtures.scratchFolder("project")
        let url = folder.appendingPathComponent("Company.dabbi")
        try document.write(to: url, ofType: ProjectPackage.typeIdentifier)

        let read = try ProjectDocument(contentsOf: url, ofType: ProjectPackage.typeIdentifier)
        #expect(read.context.project == document.context.project)
        #expect(read.context.local.selection.entity == "Tag")
        #expect(read.context.local.window.dividers["main"] == [240, 900])
        #expect(read.context.shows(.file(FileReference(lastKnownPath: store.path))))
        // Reading a project opens nothing: that is the window's doing.
        guard case .none = read.context.storeState else {
            Issue.record("a project that was only read opened its store")
            return
        }
        document.close()
        read.close()
    }

    @Test func anUntitledProjectNeverAsksToBeKept() throws {
        let document = try ProjectDocument(type: ProjectPackage.typeIdentifier)
        document.context.updateWindow { $0.collapsedPanes = ["bottom"] }
        document.context.select(entity: "Anything")
        document.context.chooseStore(at: try AppFixtures.location(.basic).storeURL)
        #expect(!document.isDocumentEdited)
        document.close()
    }

    @Test func aSavedProjectSavesItsLayoutAlong() throws {
        let document = try ProjectDocument(type: ProjectPackage.typeIdentifier)
        document.context.adoptStore(at: try AppFixtures.location(.basic).storeURL)
        let url = try AppFixtures.scratchFolder("project").appendingPathComponent("Basic.dabbi")
        try document.write(to: url, ofType: ProjectPackage.typeIdentifier)
        document.fileURL = url

        document.context.updateWindow { $0.collapsedPanes = ["bottom"] }
        #expect(document.isDocumentEdited)
        document.close()
    }
}
