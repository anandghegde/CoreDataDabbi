@preconcurrency import CoreData
import ArgumentParser
import FixtureKit
import Foundation

/// Plays the running app in tracking tests: applies scripted mutations to a Notes store (the `history` and
/// `walOnly` fixtures) and prints each committed change as one line of JSON — the expected change set.
@main
struct Writer: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "Writer",
        abstract: "Mutates a Notes fixture store the way a running app would, and reports what it changed."
    )

    @Argument(help: "A store made from the Notes fixture model.")
    var store: String

    @Option(help: "How many transactions to commit.")
    var count = 10

    @Option(name: .customLong("interval-ms"), help: "Pause between transactions, in milliseconds.")
    var intervalMilliseconds = 200

    @Flag(help: "Open the store with persistent history tracking.")
    var history = false

    struct Change: Codable, Sendable {
        var transaction: Int
        var operation: String
        var entity: String
        var pk: Int64
    }

    func run() throws {
        let writer = try StoreWriter(
            model: NotesFixture.makeModel(),
            storeURL: URL(fileURLWithPath: store),
            options: history ? NotesFixture.historyOptions : [:],
            author: "writer"
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]

        for transaction in 0..<count {
            let changes: [Change] = try writer.context.performAndWait {
                let context = writer.context
                let request = NSFetchRequest<NSManagedObject>(entityName: "Note")
                request.sortDescriptors = [NSSortDescriptor(key: "title", ascending: true)]
                let notes = try context.fetch(request)

                // A fixed rotation: insert, update, insert, delete.
                var touched: [(String, NSManagedObject)] = []
                switch transaction % 4 {
                case 1 where !notes.isEmpty:
                    let note = notes[transaction % notes.count]
                    note.setValue("Edited in transaction \(transaction)", forKey: "body")
                    touched.append(("update", note))
                case 3 where !notes.isEmpty:
                    let note = notes[transaction % notes.count]
                    touched.append(("delete", note))
                    context.delete(note)
                default:
                    touched.append(("insert", writer.insert("Note", ["title": "Writer note \(transaction)"])))
                }
                try context.obtainPermanentIDs(for: touched.map(\.1))
                try context.save()
                return touched.map { operation, object in
                    let pk = Int64(object.objectID.uriRepresentation().lastPathComponent.dropFirst()) ?? -1
                    return Change(transaction: transaction, operation: operation, entity: "Note", pk: pk)
                }
            }
            for change in changes {
                print(String(decoding: try encoder.encode(change), as: UTF8.self))
            }
            fflush(stdout)
            Thread.sleep(forTimeInterval: Double(intervalMilliseconds) / 1000)
        }
        try writer.close()
    }
}
