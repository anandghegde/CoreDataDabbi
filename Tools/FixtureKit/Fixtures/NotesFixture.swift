@preconcurrency import CoreData
import Foundation

/// A small `Folder` ⟷ `Note` model, used wherever the interesting part is the store's state, not its schema.
public enum NotesFixture {
    public static func makeModel() -> NSManagedObjectModel {
        let folder = entity("Folder", [attribute("name", .stringAttributeType)])
        let note = entity(
            "Note",
            [
                attribute("title", .stringAttributeType),
                attribute("body", .stringAttributeType),
                attribute("pinned", .booleanAttributeType, defaultValue: false),
                attribute("modifiedAt", .dateAttributeType),
            ])
        relate(folder, "notes", .toMany, note, inverse: "folder", .toOne, deleteRule: .cascadeDeleteRule)
        return model([folder, note], identifier: "notes-1")
    }

    public static var historyOptions: [String: Any] { [NSPersistentHistoryTrackingKey: true] }

    /// The same shape, with two of `Note`'s attributes marked to survive the row being deleted.
    ///
    /// A separate model rather than a flag on `makeModel()`: the preservation flag is part of an entity's version
    /// hash, and the other fixtures built from the Notes model are about other things.
    public static func makeHistoryModel() -> NSManagedObjectModel {
        let folder = entity("Folder", [attribute("name", .stringAttributeType)])
        let note = entity(
            "Note",
            [
                attribute("title", .stringAttributeType, preserved: true),
                attribute("body", .stringAttributeType),
                attribute("pinned", .booleanAttributeType, defaultValue: false),
                attribute("modifiedAt", .dateAttributeType, preserved: true),
            ])
        relate(folder, "notes", .toMany, note, inverse: "folder", .toOne, deleteRule: .cascadeDeleteRule)
        return model([folder, note], identifier: "notes-history-1")
    }

    /// Five transactions by two authors: inserts, updates and a delete, with tombstones on the delete.
    static func buildHistory(in directory: URL) throws -> FixtureManifest {
        let writer = try StoreWriter(
            model: makeHistoryModel(), storeURL: directory.appendingPathComponent("History.sqlite"),
            options: historyOptions)
        writer.context.name = "fixture-writer"

        var folders: [NSManagedObject] = []
        var notes: [NSManagedObject] = []
        try writer.perform(author: "app") { writer in
            folders = (0..<2).map { writer.insert("Folder", ["name": "Folder \($0)"]) }
        }
        try writer.perform(author: "app") { writer in
            notes = (0..<10).map { index in
                writer.insert(
                    "Note",
                    [
                        "title": "Note \(index)",
                        "body": "Body of note \(index)",
                        "folder": folders[index % 2],
                        "modifiedAt": fixtureEpoch.addingTimeInterval(Double(index) * 60),
                    ])
            }
        }
        try writer.perform(author: "sync") { _ in
            for note in notes.prefix(3) { note.setValue(true, forKey: "pinned") }
        }
        try writer.perform(author: "app") { writer in
            notes[0].setValue("Note 0 (edited)", forKey: "title")
            writer.context.delete(notes[9])
        }
        try writer.perform(author: "sync") { writer in
            writer.insert("Note", ["title": "Note from sync", "folder": folders[1]])
        }
        try writer.close()

        return FixtureManifest(
            fixture: .history,
            summary: """
                Persistent history tracking on; five transactions by the authors app and sync, \
                with two of Note's attributes preserved in history on deletion.
                """,
            store: "History.sqlite",
            entityCounts: ["Folder": 2, "Note": 10]
        )
    }

    /// The store is copied while the writer still has it open, so the rows are in `-wal`, not in the main file.
    static func buildWALOnly(in directory: URL) throws -> FixtureManifest {
        let scratch = directory.appendingPathComponent("scratch", isDirectory: true)
        let writer = try StoreWriter(model: makeModel(), storeURL: scratch.appendingPathComponent("Live.sqlite"))
        try writer.perform { writer in
            let folder = writer.insert("Folder", ["name": "Inbox"])
            for index in 0..<20 {
                writer.insert("Note", ["title": "Live note \(index)", "body": "Still in the WAL", "folder": folder])
            }
        }
        try writer.copyLiveFiles(to: directory.appendingPathComponent("WALOnly.sqlite"))
        try writer.close()
        try FileManager.default.removeItem(at: scratch)

        return FixtureManifest(
            fixture: .walOnly,
            summary: "Copied while open: every row still lives in the write-ahead log.",
            store: "WALOnly.sqlite",
            entityCounts: ["Folder": 1, "Note": 20]
        )
    }
}
