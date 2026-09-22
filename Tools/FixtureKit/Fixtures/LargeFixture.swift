@preconcurrency import CoreData
import Foundation

/// `Source` ⟷ `Event`, and a lot of events: what opening, scrolling and sorting are measured on (PRD §10).
///
/// How many is up to the environment. Twenty thousand is enough for the tests that only need "more than a few
/// pages" and takes about a second to write; the performance baselines ask for the million the PRD names
/// (`Scripts/perf.sh`).
public enum LargeFixture {
    public static let rowCountVariable = "DABBI_LARGE_ROWS"
    public static let defaultRowCount = 20_000
    static let sources = 16
    static let kinds = ["launch", "login", "sync", "purchase", "crash", "share", "search", "logout"]

    public static func rowCount(
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> Int {
        environment[rowCountVariable].flatMap(Int.init).map { max(1, $0) } ?? defaultRowCount
    }

    static func makeModel() -> NSManagedObjectModel {
        let source = entity("Source", [attribute("name", .stringAttributeType, optional: false, defaultValue: "")])
        let event = entity(
            "Event",
            [
                attribute("sequence", .integer64AttributeType, optional: false, defaultValue: 0),
                attribute("name", .stringAttributeType),
                attribute("kind", .stringAttributeType),
                attribute("detail", .stringAttributeType),
                attribute("code", .integer32AttributeType),
                attribute("value", .doubleAttributeType),
                attribute("amount", .decimalAttributeType),
                attribute("flagged", .booleanAttributeType, defaultValue: false),
                // Random, and deliberately without an index: sorting by it is the slow case worth measuring.
                attribute("timestamp", .dateAttributeType),
                attribute("identifier", .UUIDAttributeType),
                attribute("link", .URIAttributeType),
                attribute("payload", .binaryDataAttributeType),
            ])
        relate(source, "events", .toMany, event, inverse: "source", .toOne)
        return model([source, event], identifier: "large-1")
    }

    static func build(in directory: URL) throws -> FixtureManifest {
        let rows = rowCount()
        let writer = try StoreWriter(model: makeModel(), storeURL: directory.appendingPathComponent("Large.sqlite"))
        var sourceIDs: [NSManagedObjectID] = []
        try writer.perform { writer in
            let objects = (0..<sources).map { writer.insert("Source", ["name": "Source \($0)"]) }
            try writer.context.obtainPermanentIDs(for: objects)
            sourceIDs = objects.map(\.objectID)
        }

        var random = SeededGenerator(seed: 0x1A26E)
        let batch = 10_000
        for start in stride(from: 0, to: rows, by: batch) {
            try writer.perform { writer in
                // Saved batches are of no further use; without this a million objects stay in memory.
                writer.context.reset()
                let sourceObjects = sourceIDs.map { writer.context.object(with: $0) }
                for index in start..<min(start + batch, rows) {
                    let code = Int32(truncatingIfNeeded: random.next() % 100_000)
                    writer.insert(
                        "Event",
                        [
                            "sequence": Int64(index),
                            "name": "Event \(index)",
                            "kind": kinds[Int(random.next() % UInt64(kinds.count))],
                            "detail": "Recorded by the fixture generator, code \(code), in batch \(start / batch)",
                            "code": code,
                            "value": Double(random.next() % 1_000_000) / 1000,
                            "amount": NSDecimalNumber(
                                mantissa: random.next() % 10_000_000, exponent: -2, isNegative: false),
                            "flagged": index % 7 == 0,
                            "timestamp": fixtureEpoch.addingTimeInterval(Double(random.next() % 31_536_000)),
                            "identifier": random.uuid(),
                            "link": URL(string: "https://example.org/events/\(index)"),
                            "payload": index % 5 == 0 ? random.data(count: 24) : nil,
                            "source": sourceObjects[index % sources],
                        ])
                }
            }
        }
        try writer.close()

        return FixtureManifest(
            fixture: .large,
            summary: "\(rows) events from \(sources) sources: paging and performance baselines.",
            store: "Large.sqlite",
            entityCounts: ["Source": sources, "Event": rows]
        )
    }
}
