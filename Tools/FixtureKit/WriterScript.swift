@preconcurrency import CoreData
import Foundation

/// What the writer does to a store, and what it therefore expects the tracker to report (PRD §11, M2-11).
///
/// The same script runs in both writers — the macOS CLI and the iOS simulator app — so that the end-to-end test
/// asserts one thing rather than two: the `VersionLog` against the script's own account of what it committed.
/// Neither writer decides anything itself; the program below is the whole of it.
///
/// Rows are named rather than numbered. A title is the one handle that means the same thing in the writing
/// process and in the inspecting one: primary keys are the store's to give out, and the script learns them only
/// after Core Data has assigned them — which is exactly what the report carries back.
public struct WriterScript: Sendable {
    /// The store the script writes, inside whichever container the writer runs in.
    public static let storeName = "Writer.sqlite"
    /// Folders the seed creates, in order. `Step.move` indexes into this.
    public static let folderNames = ["Inbox", "Archive"]

    // MARK: - The program

    public enum Step: Sendable, Hashable, Codable {
        /// A new `Note`, in `folder`, pinned or not.
        case insert(title: String, pinned: Bool = false, folder: Int = 0)
        /// A new `body` on an existing note: an ordinary field change.
        case edit(title: String)
        /// `pinned = true` — the note enters a view filtered on `pinned == YES` (TRK-7).
        case pin(title: String)
        /// `pinned = false` — it leaves that view.
        case unpin(title: String)
        /// A different `folder`: a to-one held as a foreign key, so it is an update of the note's own row.
        case move(title: String, folder: Int)
        case delete(title: String)
    }

    /// What one transaction did to one object.
    public struct Change: Sendable, Hashable, Codable {
        public enum Operation: String, Sendable, Hashable, Codable {
            case inserted, updated, deleted
        }

        /// The transaction's position in the script, counted from zero.
        public var transaction: Int
        public var operation: Operation
        public var entity: String
        /// The row's `Z_PK`, as the writing process's store gave it out. This is what an `ObjectRef` carries.
        public var pk: Int64
        public var title: String
        /// Whether the row satisfies `pinned == YES` after this transaction. `nil` for a delete: it satisfies
        /// nothing any more.
        public var pinned: Bool?

        public init(
            transaction: Int, operation: Operation, entity: String, pk: Int64, title: String, pinned: Bool?
        ) {
            self.transaction = transaction
            self.operation = operation
            self.entity = entity
            self.pk = pk
            self.title = title
            self.pinned = pinned
        }
    }

    /// The writer's account of a run, written where the inspecting process can read it.
    public struct Report: Sendable, Hashable, Codable {
        /// Absolute path of the store in the writing process. On a simulator that is a path inside the device's
        /// data container, which the reader resolves for itself — it is here to be compared, not followed.
        public var storePath: String
        /// Which of the two writers produced this.
        public var writer: String
        /// The seed's inserts, in order. These are the rows already there when tracking starts, so nothing here
        /// should reach the log.
        public var seeded: [Change]
        /// What the script committed, in order. One `VersionLog` version each, in this order.
        public var changes: [Change]
        /// How many transactions the script committed.
        public var transactions: Int

        public init(
            storePath: String, writer: String, seeded: [Change] = [], changes: [Change] = [], transactions: Int = 0
        ) {
            self.storePath = storePath
            self.writer = writer
            self.seeded = seeded
            self.changes = changes
            self.transactions = transactions
        }

        public var data: Data {
            get throws {
                let encoder = JSONEncoder()
                encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
                return try encoder.encode(self)
            }
        }

        public static func decode(_ data: Data) throws -> Report {
            try JSONDecoder().decode(Report.self, from: data)
        }
    }

    // MARK: - The two programs

    /// The rows the store starts with: five notes across two folders, two of them pinned.
    ///
    /// The seed is committed before tracking begins, so the tracker primes over it and every one of these rows
    /// has a known prior value. That is what makes a field diff in the log meaningful rather than *unknown*.
    public static let seedTitles = (0..<5).map { "Seed \($0)" }
    public static let seedPinned: Set<String> = ["Seed 1", "Seed 3"]

    /// The script, as committed one step per transaction.
    ///
    /// It is fixed rather than generated: an end-to-end test that cannot be read off the page is one nobody can
    /// tell a bug from a change in. Between them the steps cover every shape the tracker has to report — an
    /// insert, an update of a row that was primed, an update of a row the tracker only learnt about while it was
    /// running, a relationship change, a delete of a row that was there at the start, a delete of a row that was
    /// not, and four crossings of a `pinned == YES` view in both directions.
    public static let program: [Step] = [
        .insert(title: "Writer 0", pinned: false, folder: 0),
        .edit(title: "Seed 0"),
        .pin(title: "Seed 0"),
        .insert(title: "Writer 1", pinned: true, folder: 1),
        .unpin(title: "Seed 1"),
        .move(title: "Seed 2", folder: 1),
        .edit(title: "Writer 0"),
        .pin(title: "Seed 2"),
        .delete(title: "Seed 3"),
        .delete(title: "Writer 1"),
    ]

    /// The predicate the saved-predicate half of M2's exit criterion is about.
    public static let pinnedView = "pinned == YES"

    // MARK: - Running it

    /// Pause between transactions. Each one has to be noticed on its own: the watcher coalesces a burst by
    /// design (§6.6), and a script whose commits all land inside one debounce window would be asserting that.
    public var intervalMilliseconds: Int
    /// Which writer this is, for the report.
    public var writer: String

    public init(writer: String, intervalMilliseconds: Int = 250) {
        self.writer = writer
        self.intervalMilliseconds = intervalMilliseconds
    }

    /// Makes the store and commits the seed. Two transactions, neither of them news.
    public func seed(into storeURL: URL) throws -> Report {
        if FileManager.default.fileExists(atPath: storeURL.path) { try Self.removeStore(at: storeURL) }
        let store = try StoreWriter(model: NotesFixture.makeModel(), storeURL: storeURL, author: writer)
        defer { try? store.close() }

        let seeded: [Change] = try store.context.performAndWait {
            let folders = Self.folderNames.map { store.insert("Folder", ["name": $0]) }
            try store.context.save()

            let notes = Self.seedTitles.enumerated().map { index, title in
                store.insert(
                    "Note",
                    [
                        "title": title,
                        "body": "Body of \(title)",
                        "pinned": Self.seedPinned.contains(title),
                        "folder": folders[index % folders.count],
                        "modifiedAt": Date(timeIntervalSince1970: 1_700_000_000 + Double(index) * 60),
                    ])
            }
            try store.context.obtainPermanentIDs(for: notes)
            try store.context.save()
            return notes.map {
                Change(
                    transaction: -1, operation: .inserted, entity: "Note", pk: Self.primaryKey(of: $0),
                    title: $0.value(forKey: "title") as? String ?? "",
                    pinned: $0.value(forKey: "pinned") as? Bool)
            }
        }
        return Report(storePath: storeURL.path, writer: writer, seeded: seeded, transactions: 2)
    }

    /// Runs `program` against a store the seed already made, one transaction per step.
    ///
    /// `report` is called with each change as it is committed, so a front end can print a running account; the
    /// same changes are in the returned report.
    public func run(
        _ program: [Step] = WriterScript.program, on storeURL: URL, report: (Change) -> Void = { _ in }
    ) throws -> Report {
        let store = try StoreWriter(model: NotesFixture.makeModel(), storeURL: storeURL, author: writer)
        defer { try? store.close() }

        var changes: [Change] = []
        for (index, step) in program.enumerated() {
            let committed = try Self.commit(step, number: index, on: store)
            changes.append(contentsOf: committed)
            committed.forEach(report)
            if intervalMilliseconds > 0 { Thread.sleep(forTimeInterval: Double(intervalMilliseconds) / 1000) }
        }
        return Report(storePath: storeURL.path, writer: writer, changes: changes, transactions: program.count)
    }

    // MARK: - One step

    private static func commit(_ step: Step, number: Int, on store: StoreWriter) throws -> [Change] {
        try store.context.performAndWait {
            let context = store.context
            let change: Change

            switch step {
            case .insert(let title, let pinned, let folder):
                let note = store.insert(
                    "Note",
                    [
                        "title": title, "body": "Written in transaction \(number)", "pinned": pinned,
                        "folder": try self.folder(named: folderNames[folder], in: context),
                        "modifiedAt": Date(),
                    ])
                try context.obtainPermanentIDs(for: [note])
                try context.save()
                change = self.change(number, .inserted, note)

            case .edit(let title):
                let note = try self.note(titled: title, in: context)
                note.setValue("Rewritten in transaction \(number)", forKey: "body")
                note.setValue(Date(), forKey: "modifiedAt")
                try context.save()
                change = self.change(number, .updated, note)

            case .pin(let title), .unpin(let title):
                let note = try self.note(titled: title, in: context)
                if case .pin = step {
                    note.setValue(true, forKey: "pinned")
                } else {
                    note.setValue(false, forKey: "pinned")
                }
                try context.save()
                change = self.change(number, .updated, note)

            case .move(let title, let folder):
                let note = try self.note(titled: title, in: context)
                note.setValue(try self.folder(named: folderNames[folder], in: context), forKey: "folder")
                try context.save()
                change = self.change(number, .updated, note)

            case .delete(let title):
                let note = try self.note(titled: title, in: context)
                // Read before the delete: afterwards the object is a fault over a row that is gone.
                let pk = primaryKey(of: note)
                context.delete(note)
                try context.save()
                change = Change(
                    transaction: number, operation: .deleted, entity: "Note", pk: pk, title: title, pinned: nil)
            }
            return [change]
        }
    }

    private static func change(_ number: Int, _ operation: Change.Operation, _ note: NSManagedObject) -> Change {
        Change(
            transaction: number, operation: operation, entity: "Note", pk: primaryKey(of: note),
            title: note.value(forKey: "title") as? String ?? "", pinned: note.value(forKey: "pinned") as? Bool)
    }

    private static func note(titled title: String, in context: NSManagedObjectContext) throws -> NSManagedObject {
        try one("Note", where: NSPredicate(format: "title == %@", title), in: context)
    }

    private static func folder(named name: String, in context: NSManagedObjectContext) throws -> NSManagedObject {
        try one("Folder", where: NSPredicate(format: "name == %@", name), in: context)
    }

    private static func one(
        _ entity: String, where predicate: NSPredicate, in context: NSManagedObjectContext
    ) throws -> NSManagedObject {
        let request = NSFetchRequest<NSManagedObject>(entityName: entity)
        request.predicate = predicate
        request.fetchLimit = 1
        guard let object = try context.fetch(request).first else {
            throw WriterScriptError.rowNotFound(entity: entity, predicate: predicate.predicateFormat)
        }
        return object
    }

    /// The row's `Z_PK`, which a permanent object ID spells as the last component of its URI: `p17`.
    public static func primaryKey(of object: NSManagedObject) -> Int64 {
        Int64(object.objectID.uriRepresentation().lastPathComponent.dropFirst()) ?? -1
    }

    /// Deletes a store and its companions, so a run starts where the last one did.
    public static func removeStore(at url: URL) throws {
        for suffix in ["", "-wal", "-shm"] {
            let file = URL(fileURLWithPath: url.path + suffix)
            if FileManager.default.fileExists(atPath: file.path) { try FileManager.default.removeItem(at: file) }
        }
        let support = url.deletingLastPathComponent()
            .appendingPathComponent(".\(url.deletingPathExtension().lastPathComponent)_SUPPORT", isDirectory: true)
        if FileManager.default.fileExists(atPath: support.path) { try FileManager.default.removeItem(at: support) }
    }
}

public enum WriterScriptError: Error, CustomStringConvertible {
    case rowNotFound(entity: String, predicate: String)

    public var description: String {
        switch self {
        case .rowNotFound(let entity, let predicate): "No \(entity) matching \(predicate)."
        }
    }
}
