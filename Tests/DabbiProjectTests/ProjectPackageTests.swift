import DabbiBase
import Foundation
import Testing

@testable import DabbiProject

/// A folder unique to one test, removed when the test is over.
private final class Scratch {
    let url: URL

    init() throws {
        url = FileManager.default.temporaryDirectory
            .appendingPathComponent("DabbiProjectTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    }

    deinit { try? FileManager.default.removeItem(at: url) }

    func file(_ name: String) -> URL { url.appendingPathComponent(name) }
}

private func json(_ url: URL) throws -> [String: Any] {
    try #require(try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
}

private func fullProject() -> Project {
    Project(
        store: .simulator(
            udid: "6F1C2A3B-0000-4000-8000-000000000001", bundleID: "com.example.Notes",
            container: .group("group.com.example.notes"),
            relativePath: "Library/Application Support/default.store"),
        model: .file(FileReference(lastKnownPath: "/Applications/Notes.app")),
        accessMode: .editable,
        display: DisplayPreferences(
            timeZone: .custom("Europe/Amsterdam"),
            entities: [
                "Person": EntityLayout(
                    columns: [
                        ColumnLayout(property: ColumnLayout.objectIDColumn, isHidden: true),
                        ColumnLayout(property: "name", width: 180),
                    ],
                    sort: [SortKey(keyPath: "name"), SortKey(keyPath: "age", ascending: false)],
                    filter: PredicateSource(format: #"age > 30 AND name BEGINSWITH[cd] "a""#),
                    displayAttribute: "name")
            ]))
}

@Suite struct ProjectCodingTests {
    @Test(arguments: [
        StoreLocation.file(FileReference(lastKnownPath: "/tmp/App.sqlite")),
        .simulator(udid: "U", bundleID: "com.example.App", container: .data, relativePath: "Library/App.sqlite"),
        .macApp(bundleID: "com.example.Mac", container: .group("group.example"), relativePath: "Data/App.sqlite"),
        .container(FileReference(lastKnownPath: "/tmp/App.xcappdata"), relativePath: "AppData/Library/App.sqlite"),
        .devicePull(deviceID: "00008110-000A", bundleID: "com.example.App", relativePath: "Documents/App.sqlite"),
    ])
    func everyStoreLocationRoundTrips(_ location: StoreLocation) throws {
        let data = try ProjectJSON.encoder().encode(location)
        #expect(try ProjectJSON.decoder().decode(StoreLocation.self, from: data) == location)
        #expect(location.fileName == "App.sqlite" || location.fileName == "App.xcappdata")
    }

    @Test func storeLocationsAreFlatAndCarryTheirKind() throws {
        let location = StoreLocation.simulator(
            udid: "U", bundleID: "com.example.App", container: .group("group.example"), relativePath: "a/b.sqlite")
        let object = try #require(
            try JSONSerialization.jsonObject(with: ProjectJSON.encoder().encode(location)) as? [String: Any])
        #expect(object["kind"] as? String == "simulator")
        #expect(object["udid"] as? String == "U")
        #expect((object["container"] as? [String: Any])?["group"] as? String == "group.example")
    }

    @Test func aFullProjectRoundTrips() throws {
        let project = fullProject()
        let data = try ProjectJSON.encoder().encode(project)
        #expect(try ProjectJSON.decoder().decode(Project.self, from: data) == project)
    }

    @Test func everythingHasADefault() throws {
        let project = try ProjectJSON.decoder().decode(Project.self, from: Data("{}".utf8))
        #expect(project.schemaVersion == Project.currentSchemaVersion)
        #expect(project.store == nil)
        #expect(project.model == .storeCache)
        #expect(project.accessMode == .readOnly)
        #expect(project.localStatePlacement == .inPackage)
        #expect(project.display == DisplayPreferences())

        let column = try ProjectJSON.decoder().decode(ColumnLayout.self, from: Data(#"{"property": "name"}"#.utf8))
        #expect(column == ColumnLayout(property: "name"))
        #expect(try ProjectJSON.decoder().decode(LocalState.self, from: Data("{}".utf8)) == LocalState())
    }

    /// The grid's filter is part of the layout (§7.1, M2-02): it is written as the user typed it, and a project
    /// from before it existed decodes without one.
    @Test func anEntitysFilterIsWrittenAsText() throws {
        let layout = EntityLayout(filter: PredicateSource(format: "age > 30"))
        let object = try #require(
            try JSONSerialization.jsonObject(with: ProjectJSON.encoder().encode(layout)) as? [String: Any])
        #expect((object["filter"] as? [String: Any])?["format"] as? String == "age > 30")

        let decoder = ProjectJSON.decoder()
        #expect(try decoder.decode(EntityLayout.self, from: Data(#"{"sort": []}"#.utf8)).filter == nil)
        #expect(try decoder.decode(EntityLayout.self, from: ProjectJSON.encoder().encode(layout)) == layout)
    }

    @Test func timeZones() throws {
        #expect(TimeZoneChoice.utc.timeZone.secondsFromGMT() == 0)
        #expect(TimeZoneChoice.custom("Asia/Kolkata").timeZone.identifier == "Asia/Kolkata")
        #expect(TimeZoneChoice.custom("Nowhere/Land").timeZone == .gmt)
        let encoded = try ProjectJSON.encoder().encode([TimeZoneChoice.utc, .local, .custom("Asia/Kolkata")])
        let compact = String(decoding: encoded, as: UTF8.self).filter { !$0.isWhitespace }
        #expect(compact == #"["utc","local","Asia/Kolkata"]"#)
    }

    @Test func outputIsStable() throws {
        let project = fullProject()
        #expect(try ProjectJSON.data(ProjectJSON.tree(project)) == ProjectJSON.data(ProjectJSON.tree(project)))
        let text = String(decoding: try ProjectJSON.data(ProjectJSON.tree(project)), as: UTF8.self)
        #expect(text.hasSuffix("}\n"))
        #expect(text.contains("/Applications/Notes.app"))  // no `\/`
    }
}

@Suite struct ProjectPackageTests {
    @Test func aPackageRoundTripsThroughAFolder() throws {
        let scratch = try Scratch()
        let url = scratch.file("Notes.dabbi")
        var package = ProjectPackage(project: fullProject())
        package.local.window.frame = "10 20 1200 800 0 0 1728 1079"
        package.local.window.collapsedPanes = ["inspector", "content"]
        package.local.selection.entity = "Person"
        package.local.bookmarks[UUID()] = Data([1, 2, 3])
        try package.write(to: url)

        #expect(FileManager.default.fileExists(atPath: url.appendingPathComponent("project.json").path))
        #expect(FileManager.default.fileExists(atPath: url.appendingPathComponent("local/state.json").path))
        #expect(try ProjectPackage.read(at: url) == package)
    }

    @Test func whatThisVersionDoesNotKnowSurvivesASave() throws {
        let scratch = try Scratch()
        let url = scratch.file("Future.dabbi")
        try FileManager.default.createDirectory(
            at: url.appendingPathComponent("predicates"), withIntermediateDirectories: true)
        try Data(#"{"name": "Adults"}"#.utf8).write(to: url.appendingPathComponent("predicates/adults.json"))
        try Data(
            """
            {
              "schemaVersion": 1,
              "id": "0B5F3C6E-1111-4222-8333-444455556666",
              "accessMode": "readOnly",
              "theme": "solarized",
              "display": {
                "timeZone": "local",
                "rowHeight": 22,
                "entities": { "Person": { "columns": [], "pinned": ["name"] } }
              }
            }
            """.utf8
        ).write(to: url.appendingPathComponent("project.json"))

        var package = try ProjectPackage.read(at: url)
        #expect(package.project.display.timeZone == .local)
        package.project.display.timeZone = .utc
        package.project.display.entities["Person"]?.displayAttribute = "name"
        try package.write(to: url)

        let saved = try json(url.appendingPathComponent("project.json"))
        let display = try #require(saved["display"] as? [String: Any])
        let person = try #require((display["entities"] as? [String: Any])?["Person"] as? [String: Any])
        #expect(saved["theme"] as? String == "solarized")
        #expect(display["rowHeight"] as? Int == 22)
        #expect(display["timeZone"] as? String == "utc")
        #expect(person["pinned"] as? [String] == ["name"])
        #expect(person["displayAttribute"] as? String == "name")
        #expect(FileManager.default.fileExists(atPath: url.appendingPathComponent("predicates/adults.json").path))
    }

    @Test func aKnownKeyThatWasClearedStaysCleared() throws {
        let scratch = try Scratch()
        let url = scratch.file("Cleared.dabbi")
        try ProjectPackage(project: fullProject()).write(to: url)

        var package = try ProjectPackage.read(at: url)
        package.project.store = nil
        try package.write(to: url)
        #expect(try json(url.appendingPathComponent("project.json"))["store"] == nil)
        #expect(try ProjectPackage.read(at: url).project.store == nil)
    }

    @Test func localStateCanLiveOutsideThePackage() throws {
        let scratch = try Scratch()
        let (url, external) = (scratch.file("Shared.dabbi"), scratch.file("Local"))
        var package = ProjectPackage(project: fullProject())
        package.local.selection.entity = "Person"
        try package.write(to: url)
        #expect(FileManager.default.fileExists(atPath: url.appendingPathComponent("local").path))

        package.project.localStatePlacement = .applicationSupport
        try package.write(to: url, externalLocalRoot: external)
        #expect(!FileManager.default.fileExists(atPath: url.appendingPathComponent("local").path))
        let state = external.appendingPathComponent("\(package.project.id.uuidString)/state.json")
        #expect(FileManager.default.fileExists(atPath: state.path))

        #expect(try ProjectPackage.read(at: url, externalLocalRoot: external) == package)
        // On a machine that has never seen the project there is no local state, and that is fine.
        let elsewhere = try ProjectPackage.read(at: url, externalLocalRoot: scratch.file("Nowhere"))
        #expect(elsewhere.project == package.project)
        #expect(elsewhere.local == LocalState())
    }

    @Test func damagedLocalStateDoesNotStopAProjectFromOpening() throws {
        let scratch = try Scratch()
        let url = scratch.file("Damaged.dabbi")
        try ProjectPackage(project: fullProject()).write(to: url)
        try Data("not json".utf8).write(to: url.appendingPathComponent("local/state.json"))
        #expect(try ProjectPackage.read(at: url).local == LocalState())
    }

    @Test func anUnchangedProjectIsNotRewritten() throws {
        let package = ProjectPackage(project: fullProject())
        let wrapper = try package.fileWrapper()
        let before = try #require(wrapper.fileWrappers?["project.json"])
        let again = try package.fileWrapper(updating: wrapper)
        #expect(again === wrapper)
        #expect(again.fileWrappers?["project.json"] === before)

        var changed = package
        changed.project.accessMode = .readOnly
        #expect(try changed.fileWrapper(updating: wrapper).fileWrappers?["project.json"] !== before)
    }

    @Test func errorsExplainThemselves() throws {
        let scratch = try Scratch()
        let url = scratch.file("Broken.dabbi")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)

        var error = #expect(throws: DabbiError.self) { try ProjectPackage.read(at: url) }
        #expect(error?.code == .projectUnreadable)

        try Data(#"{"schemaVersion": 99}"#.utf8).write(to: url.appendingPathComponent("project.json"))
        error = #expect(throws: DabbiError.self) { try ProjectPackage.read(at: url) }
        #expect(error?.code == .projectTooNew)
        #expect(error?.arguments["schemaVersion"] == "99")

        try Data(#"{"store": {"kind": "teleport"}}"#.utf8).write(to: url.appendingPathComponent("project.json"))
        error = #expect(throws: DabbiError.self) { try ProjectPackage.read(at: url) }
        #expect(error?.code == .projectUnreadable)
        #expect(error?.diagnosis.first?.contains("store.kind") == true)

        error = #expect(throws: DabbiError.self) { try ProjectPackage.read(at: scratch.file("Missing.dabbi")) }
        #expect(error?.code == .projectUnreadable)
    }

    @Test func migrationsRunOneVersionAtATime() throws {
        let old = JSONValue.object(["schemaVersion": .int(1), "database": .string("App.sqlite")])
        let steps: [Int: ProjectMigrations.Step] = [
            1: { tree in
                guard case .object(var members) = tree else { return tree }
                members["storePath"] = members.removeValue(forKey: "database")
                return .object(members)
            },
            2: { $0.merging(.object(["migratedTwice": .bool(true)])) },
        ]
        let migrated = try ProjectMigrations.migrate(old, steps: steps, to: 3)
        #expect(migrated["schemaVersion"] == .int(3))
        #expect(migrated["storePath"] == .string("App.sqlite"))
        #expect(migrated["database"] == nil)
        #expect(migrated["migratedTwice"] == .bool(true))

        #expect(throws: DabbiError.self) { try ProjectMigrations.migrate(old, steps: [:], to: 2) }
    }
}

@Suite struct BookmarkTests {
    @Test func aReferenceFollowsTheFileWhenItMoves() throws {
        let scratch = try Scratch()
        let original = scratch.file("App.sqlite")
        try Data("store".utf8).write(to: original)

        var local = LocalState()
        let reference = local.remember(original)
        #expect(reference.lastKnownPath == original.standardizedFileURL.path)
        var resolved = try #require(local.resolve(reference))
        #expect(resolved.origin == .bookmark)
        #expect(!resolved.needsRefresh)

        let moved = scratch.file("Renamed.sqlite")
        try FileManager.default.moveItem(at: original, to: moved)
        resolved = try #require(local.resolve(reference))
        #expect(resolved.url.lastPathComponent == "Renamed.sqlite")
        #expect(resolved.needsRefresh)
    }

    @Test func withoutABookmarkTheLastKnownPathIsTried() throws {
        let scratch = try Scratch()
        let file = scratch.file("App.sqlite")
        try Data("store".utf8).write(to: file)

        // A project from another machine: the reference is there, its bookmark is not.
        let reference = FileReference(lastKnownPath: file.path)
        let resolved = try #require(LocalState().resolve(reference))
        #expect(resolved.origin == .lastKnownPath)
        #expect(resolved.needsRefresh)

        try FileManager.default.removeItem(at: file)
        #expect(LocalState().resolve(reference) == nil)
    }

    @Test func unusedBookmarksArePruned() throws {
        var local = LocalState()
        let store = local.remember(URL(fileURLWithPath: "/tmp/does-not-exist.sqlite"))
        let scratch = try Scratch()
        let model = local.remember(scratch.url)
        let stray = local.remember(scratch.url)
        #expect(local.bookmarks[store.bookmarkID] == nil)  // nothing to bookmark
        #expect(local.bookmarks[stray.bookmarkID] != nil)

        local.pruneBookmarks(keeping: Project(store: .file(store), model: .file(model)))
        #expect(Set(local.bookmarks.keys) == [model.bookmarkID])
    }
}

@Suite struct JSONValueTests {
    @Test func scalarsKeepTheirKind() throws {
        let data = Data(#"{"a": true, "b": 1, "c": 1.5, "d": "x", "e": null, "f": [1, "two"], "g": {}}"#.utf8)
        let value = try ProjectJSON.decoder().decode(JSONValue.self, from: data)
        #expect(
            value
                == .object([
                    "a": .bool(true), "b": .int(1), "c": .double(1.5), "d": .string("x"), "e": .null,
                    "f": .array([.int(1), .string("two")]), "g": .emptyObject,
                ]))
        #expect(try ProjectJSON.decoder().decode(JSONValue.self, from: ProjectJSON.data(value)) == value)
    }

    @Test func subtractingAndMergingAreInverse() {
        let raw = JSONValue.object([
            "known": .int(1), "unknown": .string("kept"),
            "nested": .object(["known": .bool(true), "extra": .array([.int(1)])]),
            "list": .array([.object(["extra": .int(1)])]),
        ])
        let known = JSONValue.object([
            "known": .int(1), "nested": .object(["known": .bool(true)]), "list": .array([.emptyObject]),
        ])
        let unknown = raw.subtracting(known)
        #expect(unknown == .object(["unknown": .string("kept"), "nested": .object(["extra": .array([.int(1)])])]))

        let edited = JSONValue.object(["known": .int(2), "nested": .object(["known": .bool(false)])])
        #expect(
            edited.merging(unknown)
                == .object([
                    "known": .int(2), "unknown": .string("kept"),
                    "nested": .object(["known": .bool(false), "extra": .array([.int(1)])]),
                ]))
    }
}

@Suite struct SavedPredicateTests {
    private func adults(id: UUID = UUID()) -> SavedPredicate {
        SavedPredicate(
            id: id, name: "Adults", entity: "Person", predicate: PredicateSource(format: "age >= 18"),
            columns: [ColumnLayout(property: "name", width: 120)], sort: [SortKey(keyPath: "age", ascending: false)])
    }

    @Test func eachPredicateIsAFileOfItsOwn() throws {
        let scratch = try Scratch()
        let url = scratch.file("Saved.dabbi")
        let first = adults()
        let second = SavedPredicate(name: "Everyone", entity: "Person", predicate: nil)
        try ProjectPackage(project: fullProject(), predicates: [first, second]).write(to: url)

        let file = try json(url.appendingPathComponent("predicates/\(first.id.uuidString).json"))
        #expect(file["name"] as? String == "Adults")
        #expect(file["entity"] as? String == "Person")
        #expect((file["predicate"] as? [String: Any])?["format"] as? String == "age >= 18")
        let everyone = try json(url.appendingPathComponent("predicates/\(second.id.uuidString).json"))
        #expect(everyone["predicate"] == nil, "no predicate is every row, and says nothing")

        let read = try ProjectPackage.read(at: url)
        #expect(Set(read.predicates) == [first, second])
    }

    @Test func aProjectWithoutPredicatesHasNoFolderForThem() throws {
        let wrapper = try ProjectPackage(project: fullProject()).fileWrapper()
        #expect(wrapper.fileWrappers?["predicates"] == nil)
    }

    @Test func aDeletedPredicateTakesItsFileWithIt() throws {
        let scratch = try Scratch()
        let url = scratch.file("Deleted.dabbi")
        let (kept, gone) = (adults(), SavedPredicate(name: "Old", entity: "Person", predicate: nil))
        try ProjectPackage(project: fullProject(), predicates: [kept, gone]).write(to: url)

        var package = try ProjectPackage.read(at: url)
        package.predicates.removeAll { $0.id == gone.id }
        // Added and deleted again without the project being read in between: known by its name, not its reading.
        let brief = SavedPredicate(name: "Brief", entity: "Person", predicate: nil)
        package.predicates.append(brief)
        try package.write(to: url)
        package.predicates.removeAll { $0.id == brief.id }
        try package.write(to: url)

        let names = try FileManager.default.contentsOfDirectory(atPath: url.appendingPathComponent("predicates").path)
        #expect(names == ["\(kept.id.uuidString).json"])
    }

    @Test func aFileItCannotReadIsLeftAlone() throws {
        let scratch = try Scratch()
        let url = scratch.file("Mixed.dabbi")
        let predicate = adults()
        try ProjectPackage(project: fullProject(), predicates: [predicate]).write(to: url)
        let folder = url.appendingPathComponent("predicates")
        // A hand-named file, one from the future with a key this version does not know, and one that is damaged.
        try Data(#"{"id": "\#(predicate.id.uuidString)", "name": "Twin", "entity": "Person"}"#.utf8)
            .write(to: folder.appendingPathComponent("twin.json"))
        let future = UUID()
        try Data(
            #"{"id": "\#(future.uuidString)", "name": "Future", "entity": "Person", "chart": "bar"}"#.utf8
        ).write(to: folder.appendingPathComponent("future.json"))
        try Data("not json".utf8).write(to: folder.appendingPathComponent("\(UUID().uuidString).json"))

        var package = try ProjectPackage.read(at: url)
        #expect(package.predicates.count == 2, "a second file claiming an ID already read is not a predicate")
        package.predicates = package.predicates.map { saved in
            var saved = saved
            saved.name += "!"
            return saved
        }
        try package.write(to: url)

        #expect(try FileManager.default.contentsOfDirectory(atPath: folder.path).count == 4)
        let rewritten = try json(folder.appendingPathComponent("future.json"))
        #expect(rewritten["name"] as? String == "Future!", "written back to the file it came from")
        #expect(rewritten["chart"] as? String == "bar")
    }

    @Test func itsLayoutIsItsColumnsSortAndItself() {
        var predicate = adults()
        #expect(predicate.layout.filter == PredicateSource(format: "age >= 18"))
        #expect(predicate.layout.displayAttribute == nil)
        predicate.layout = EntityLayout(sort: [SortKey(keyPath: "name")], filter: nil, displayAttribute: "name")
        #expect(predicate.sort == [SortKey(keyPath: "name")])
        #expect(predicate.columns.isEmpty)
        #expect(predicate.predicate == nil)
    }

    @Test func namesAreMadeUniqueTheWayTheFinderDoesIt() {
        #expect(SavedPredicate.uniqueName("Adults", among: []) == "Adults")
        #expect(SavedPredicate.uniqueName("Adults", among: ["adults"]) == "Adults 2")
        #expect(SavedPredicate.uniqueName("Adults", among: ["Adults", "Adults 2"]) == "Adults 3")
    }
}
