import AppKit
import DabbiKit
import FixtureKit
import Foundation
import Testing

@testable import CoreDataDabbi

@MainActor
@Suite struct WelcomeModelTests {
    /// What the window was asked to open, without opening anything.
    private final class Opened {
        var urls: [URL] = []
        var panels: [String] = []
    }

    private func model(recents: [URL] = [], defaults: UserDefaults = UserDefaults()) -> (WelcomeModel, Opened) {
        let opened = Opened()
        let actions = WelcomeModel.Actions(
            open: { opened.urls.append($0) },
            openDatabase: { opened.panels.append("database") },
            openProject: { opened.panels.append("project") },
            browseSimulators: { opened.panels.append("simulators") })
        return (WelcomeModel(recents: { recents }, defaults: defaults, actions: actions), opened)
    }

    @Test func listsWhatWasOpenedBeforeWithWhereItIs() throws {
        let store = try AppFixtures.location(.company).storeURL
        let project = store.deletingLastPathComponent().appendingPathComponent("Notes.dabbi")
        let gone = URL(fileURLWithPath: "/Volumes/Nowhere/Old.sqlite")
        let (model, _) = model(recents: [project, store, gone])

        #expect(model.recents.map(\.name) == ["Notes", store.lastPathComponent, "Old.sqlite"])
        #expect(model.recents.map(\.isProject) == [true, false, false])
        // A recent that has gone stays on the list and says so, as it does in the File menu.
        #expect(model.recents.map(\.isMissing) == [true, false, true])
        #expect(
            model.recents[1].folder
                == (store.deletingLastPathComponent().path as NSString)
                .abbreviatingWithTildeInPath)
    }

    @Test func opensARecentAndTheThreeWaysIn() throws {
        let store = try AppFixtures.location(.company).storeURL
        let (model, opened) = model(recents: [store])

        model.open(try #require(model.recents.first))
        model.openDatabase()
        model.openProject()
        model.browseSimulators()

        #expect(opened.urls == [store])
        #expect(opened.panels == ["database", "project", "simulators"])
    }

    @Test func opensAStoreFileDroppedOnIt() async throws {
        let store = try AppFixtures.location(.company).storeURL
        let (model, opened) = model()

        model.accept([store])
        await model.whenSettled()

        // A file is taken as it is: whether it is a store at all is the opener's to say (PRJ-15).
        #expect(opened.urls == [store])
        #expect(model.problem == nil)
    }

    @Test func findsTheStoresInsideAFolderDroppedOnIt() async throws {
        let store = try AppFixtures.location(.company).storeURL
        let (model, opened) = model()

        model.accept([store.deletingLastPathComponent()])
        #expect(model.isSearching)
        await model.whenSettled()

        // The walk resolves the symlinks on the way — the same file, spelled as the file system prefers.
        #expect(opened.urls.map { $0.resolvingSymlinksInPath() }.contains(store.resolvingSymlinksInPath()))
        #expect(model.isSearching == false)
        #expect(model.problem == nil)
    }

    @Test func saysWhenThereIsNoStoreInWhatWasDropped() async throws {
        let empty = try AppFixtures.scratchFolder("welcome-empty")
        let (model, opened) = model()

        model.accept([empty])
        await model.whenSettled()

        #expect(opened.urls.isEmpty)
        #expect(model.problem?.code == .notCoreData)
        // What to do instead, which is what an error state is for (§8.1).
        #expect(model.problem?.recovery.isEmpty == false)
    }

    @Test func aSecondDropClearsWhatTheFirstOneSaid() async throws {
        let empty = try AppFixtures.scratchFolder("welcome-empty-again")
        let store = try AppFixtures.location(.company).storeURL
        let (model, _) = model()

        model.accept([empty])
        await model.whenSettled()
        #expect(model.problem != nil)

        model.accept([store])
        await model.whenSettled()
        #expect(model.problem == nil)
    }

    @Test func remembersWhetherToShowItselfAtLaunch() {
        let defaults = UserDefaults(suiteName: "welcome-\(UUID().uuidString)")!
        let (model, _) = model(defaults: defaults)

        // Shown until the user says otherwise.
        #expect(model.showsAtLaunch)
        model.showsAtLaunch = false
        #expect(defaults.bool(forKey: WelcomeModel.showsAtLaunchKey) == false)
        #expect(WelcomeModel(recents: { [] }, defaults: defaults).showsAtLaunch == false)
    }

    @Test func showsTheWaysInAndTheRecentsInAWindow() async throws {
        let store = try AppFixtures.location(.company).storeURL
        let (model, _) = model(recents: [
            store,
            store.deletingLastPathComponent()
                .appendingPathComponent("Notes.dabbi"),
        ])
        let controller = WelcomeWindowController(model: model)
        let window = try #require(controller.window)
        window.setFrame(NSRect(x: 0, y: 0, width: 760, height: 460), display: true)
        window.orderFront(nil)
        for _ in 0..<5 { await Task.yield() }
        try await Task.sleep(for: .milliseconds(120))

        #expect(window.title == "Welcome to CoreDataDabbi")
        #expect(model.recents.count == 2)
        try await WindowSnapshot.write(window, named: "welcome")
        try await WindowSnapshot.write(window, named: "welcome-dark", appearance: .darkAqua)
        controller.close()
    }
}
