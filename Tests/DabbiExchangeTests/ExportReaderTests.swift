import DabbiBase
import DabbiModel
import DabbiStore
import DabbiTestSupport
import DabbiTracking
import FixtureKit
import Foundation
import Testing

@testable import DabbiExchange

/// IMX-1, BRW-12: reading records out of a store — what a selection, a view or an entity exports as, and how far
/// relationships are followed.
@Suite struct ExportReaderTests {
    private func open(_ fixture: Fixture) async throws -> StoreSession {
        let location = try TestFixtures.location(fixture)
        return try await StoreSession.open(storeURL: location.storeURL, modelURL: location.modelURL)
    }

    private func refs(_ session: StoreSession, _ entity: String, limit: Int? = nil) async throws -> [ObjectRef] {
        try await session.references(FetchSpec(entity: entity), limit: limit)
    }

    @Test func aWholeEntityExportsEveryRowWithEveryStoredProperty() async throws {
        let session = try await open(.basic)
        defer { Task { await session.close() } }
        let reader = ExportReader(session: session)
        let source = ExportSource.fetch(FetchSpec(entity: "Sample"))

        let layout = reader.layout(for: source)
        let model = try #require(session.info.model.entity(named: "Sample"))
        // In the model's order, which is the order the grid and the inspector show.
        #expect(layout.columns.map(\.name) == ["$id", "$entity"] + model.attributes.map(\.name))
        #expect(layout.columns.count == 17)
        let records = try await reader.records(source)
        #expect(records.count == 40)
        #expect(Set(records.map(\.id)).count == 40)
        #expect(records.allSatisfy { $0.entity == "Sample" && $0.fields.count == 15 })

        // Bytes come out whole, the same as the session hands them to the inspector.
        let first = try #require(records.first)
        let ref = try #require(ObjectRef(uri: first.id))
        let bytes = try await session.blob(for: ref, attribute: "dataValue")
        #expect(first.value(at: ["dataValue"]) == bytes.map(ExportValue.data))
    }

    @Test func withoutBinaryDataABlobIsOnlySummarised() async throws {
        let session = try await open(.basic)
        defer { Task { await session.close() } }
        let reader = ExportReader(session: session, options: ExportOptions(includesBinaryData: false))
        let ref = try #require(try await refs(session, "Sample", limit: 1).first)
        let records = try await reader.records(.objects([ref], entity: "Sample"))
        guard case .blob(let summary) = records.first?.value(at: ["dataValue"]) else {
            Issue.record("expected a summary")
            return
        }
        #expect(summary.byteCount == (try await session.blob(for: ref, attribute: "dataValue"))?.count)
    }

    @Test func aSelectionExportsInItsOwnOrderAndOnlyThePickedColumns() async throws {
        let session = try await open(.basic)
        defer { Task { await session.close() } }
        let picked = Array(try await refs(session, "Sample").prefix(3).reversed())
        let reader = ExportReader(session: session, options: ExportOptions(properties: ["name", "int16Value"]))
        let source = ExportSource.objects(picked, entity: "Sample")

        // In the order they were picked in — the grid's — not the model's.
        #expect(reader.layout(for: source).columns.map(\.name) == ["$id", "$entity", "name", "int16Value"])
        let text = try await reader.text(source, as: CSVExporter.tsv())
        let lines = text.split(separator: "\n")
        #expect(lines.count == 4)
        for (line, ref) in zip(lines.dropFirst(), picked) {
            let object = try await session.object(ref)
            let expected = [
                ref.uri.absoluteString, "Sample", ValueText.text(for: object["name"]!),
                ValueText.text(for: object["int16Value"]!),
            ]
            #expect(line.split(separator: "\t", omittingEmptySubsequences: false).map(String.init) == expected)
        }
    }

    @Test func aViewKeepsItsPredicateSortAndLimit() async throws {
        let session = try await open(.basic)
        defer { Task { await session.close() } }
        let spec = FetchSpec(
            entity: "Sample", predicate: PredicateSource(format: "boolValue == YES"),
            sort: [SortKey(keyPath: "int16Value", ascending: false)], limit: 5)
        let records = try await ExportReader(session: session).records(.fetch(spec))
        #expect(records.count == 5)
        let values = records.compactMap { record -> Int64? in
            guard case .scalar(.int(let value)) = record.value(at: ["int16Value"]) else { return nil }
            return value
        }
        #expect(values == values.sorted(by: >))
    }

    @Test func compositesSpreadOverOneColumnPerElement() async throws {
        let session = try await open(.composites)
        defer { Task { await session.close() } }
        let reader = ExportReader(session: session)
        let source = ExportSource.fetch(FetchSpec(entity: "Place"))
        #expect(
            reader.layout(for: source).columns.map(\.name) == [
                "$id", "$entity", "address.street", "address.city", "address.location.latitude",
                "address.location.longitude", "name",
            ])
        let text = try await reader.text(source, as: CSVExporter())
        let rows = text.split(separator: "\r\n")
        #expect(rows.count == 11)
        // Every fourth place has no address: its cells are empty, not the empty string.
        #expect(rows.filter { $0.contains(",Place,,,,,Place ") }.count == 2)

        let json = try await reader.text(source, as: JSONExporter())
        let first = try JSONNode.parse(json)
        guard case .array(let items) = first else { Issue.record("not an array"); return }
        #expect(items.filter { $0["address"]?["location"]?["latitude"]?.scalarText != nil }.count == 8)
    }

    @Test func referencesNameEveryRelatedObjectByItsURI() async throws {
        let session = try await open(.company)
        defer { Task { await session.close() } }
        let reader = ExportReader(session: session, options: ExportOptions(relationships: .references))
        let departments = try await reader.records(.fetch(FetchSpec(entity: "Department")))
        #expect(departments.count == 4)
        for department in departments {
            guard case .objects(let employees) = department.value(at: ["employees"]),
                case .reference(_, let entity) = department.value(at: ["organisation"])
            else {
                Issue.record("missing relationships")
                continue
            }
            #expect(entity == "Organisation")
            #expect(!employees.isEmpty)
            let departmentRef = try #require(ObjectRef(uri: department.id))
            let related = try await session.related(to: departmentRef, through: "employees", limit: .max)
            #expect(employees == related.items.map { .reference($0.object.uri, entity: $0.object.entity) })
        }

        // Counts cost nothing: what the grid shows.
        let counted = try await ExportReader(session: session, options: ExportOptions(relationships: .counts))
            .records(
                .objects([try #require(departments.first.flatMap { ObjectRef(uri: $0.id) })], entity: "Department"))
        guard case .count(let count) = counted.first?.value(at: ["employees"]) else {
            Issue.record("expected a count")
            return
        }
        #expect(count > 0)

        let omitted = ExportReader(session: session, options: ExportOptions(relationships: .omitted))
        #expect(
            omitted.layout(for: .fetch(FetchSpec(entity: "Department"))).columns.map(\.name) == [
                "$id", "$entity", "name",
            ])
    }

    @Test func embeddingFollowsToItsDepthAndNeverLoops() async throws {
        let session = try await open(.company)
        defer { Task { await session.close() } }
        let reader = ExportReader(session: session, options: ExportOptions(relationships: .embedded(depth: 2)))
        let department = try #require(try await refs(session, "Department", limit: 1).first)
        let record = try #require(try await reader.records(.objects([department], entity: "Department")).first)

        guard case .objects(let employees) = record.value(at: ["employees"]),
            case .object(let employee) = employees.first
        else {
            Issue.record("employees are not embedded")
            return
        }
        // The way back to the department is a reference: it contains the employee already.
        #expect(employee.value(at: ["department"]) == .reference(department.uri, entity: "Department"))
        // Depth 2: the employee's boss is written out, and the boss's own relationships only named.
        guard case .object(let boss) = employee.value(at: ["boss"]) else {
            Issue.record("the boss is not embedded")
            return
        }
        guard case .objects(let reports) = boss.value(at: ["reports"]) else {
            Issue.record("the boss's reports are missing")
            return
        }
        #expect(reports.allSatisfy { if case .reference = $0 { true } else { false } })
        #expect(reports.contains(.reference(employee.id, entity: employee.entity)))

        // Written out, it is still JSON.
        let text = try await reader.text(.objects([department], entity: "Department"), as: JSONExporter())
        #expect(throws: Never.self) { try JSONNode.parse(text) }
    }

    @Test func aParentEntityExportsItsSubentitiesPropertiesToo() async throws {
        let session = try await open(.company)
        defer { Task { await session.close() } }
        let reader = ExportReader(session: session, options: ExportOptions(relationships: .omitted))
        let source = ExportSource.fetch(FetchSpec(entity: "Person"))
        let columns = reader.layout(for: source).columns.map(\.name)
        #expect(columns.starts(with: ["$id", "$entity", "age", "createdAt", "email", "name"]))
        #expect(columns.contains("salary") && columns.contains("level"))

        let records = try await reader.records(source)
        #expect(records.count == 60)
        // A plain person has no salary field at all rather than a null one: it is not a property of theirs.
        let person = try #require(records.first { $0.entity == "Person" })
        #expect(person.value(at: ["salary"]) == nil)
        let manager = try #require(records.first { $0.entity == "Manager" })
        #expect(manager.value(at: ["level"]) != nil)
    }

    @Test func aFileAppearsOnlyWhenTheExportIsComplete() async throws {
        let session = try await open(.basic)
        defer { Task { await session.close() } }
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let url = folder.appendingPathComponent("Samples.json")
        try Data("old".utf8).write(to: url)

        let reader = ExportReader(session: session)
        let written = try await reader.write(.fetch(FetchSpec(entity: "Sample")), as: JSONExporter(), to: url)
        #expect(written == 40)
        let text = try String(contentsOf: url, encoding: .utf8)
        #expect(text == (try await reader.text(.fetch(FetchSpec(entity: "Sample")), as: JSONExporter())))
        #expect(try FileManager.default.contentsOfDirectory(atPath: folder.path) == ["Samples.json"])

        // Cancelled, it leaves what was there and nothing beside it.
        try Data("old".utf8).write(to: url)
        let task = Task {
            try await reader.write(.fetch(FetchSpec(entity: "Sample")), as: CSVExporter(), to: url)
        }
        task.cancel()
        _ = await task.result
        #expect(try Data(contentsOf: url) == Data("old".utf8))
        #expect(try FileManager.default.contentsOfDirectory(atPath: folder.path) == ["Samples.json"])
    }
}

/// TRK-5: a tracked session written out, one record per version.
@Suite struct TrackedSessionExportTests {
    private func snapshot(_ ref: ObjectRef, _ values: [String: Value]) -> ObjectSnapshot {
        let names = values.keys.sorted()
        return ObjectSnapshot(
            row: RowSnapshot(ref: ref, values: names.map { values[$0]! }), columns: ColumnSet(names), generation: 0)
    }

    private func log() async -> (VersionLog, ObjectRef) {
        let ref = ObjectRef(entity: "Note", pk: 7, uri: URL(string: "x-coredata://F00D/Note/p7")!)
        let log = VersionLog(
            options: {
                var options = VersionLog.Options(); options.spillsToDisk = false; return options
            }())
        let at = Date(timeIntervalSince1970: 1000)
        await log.append([
            ChangeEvent(
                object: ref, kind: .inserted, after: snapshot(ref, ["title": .string("A"), "body": .null]), at: at),
            ChangeEvent(
                object: ref, kind: .updated, before: snapshot(ref, ["title": .string("A"), "body": .null]),
                after: snapshot(ref, ["title": .string("B"), "body": .null]), changedKeys: ["title"],
                history: HistoryInfo(transactionNumber: 12, author: "Writer", timestamp: at), at: at),
            ChangeEvent(
                object: ref, kind: .deleted, before: snapshot(ref, ["title": .string("B"), "body": .null]), at: at),
        ])
        return (log, ref)
    }

    @Test func everyVersionBecomesARecordOldestFirst() async throws {
        let (log, ref) = await log()
        var export = TrackedSessionExport(log: log)
        export.batchSize = 2
        var records: [ExportRecord] = []
        let count = try await export.read { records.append($0) }
        #expect(count == 3)
        #expect(
            records.map { $0.value(at: ["kind"]) } == ["inserted", "updated", "deleted"].map { .scalar(.string($0)) })
        #expect(records.allSatisfy { $0.id == ref.uri })
        // An update keeps what changed; the rest is the same on both sides.
        #expect(records[1].value(at: ["before"]) == .composite([ExportField("title", .scalar(.string("A")))]))
        #expect(records[1].value(at: ["after"]) == .composite([ExportField("title", .scalar(.string("B")))]))
        #expect(records[1].value(at: ["author"]) == .scalar(.string("Writer")))
        #expect(records[2].value(at: ["after"]) == ExportValue.nothing)
    }

    @Test func versionsInHandExportTheSameAsTheLog() async throws {
        let (log, _) = await log()
        let fromLog = try await TrackedSessionExport(log: log).text(as: JSONExporter())
        let versions = await log.versions(from: 0)
        let fromHand = try await TrackedSessionExport(versions: versions.reversed()).text(as: JSONExporter())
        #expect(fromHand == fromLog)
    }

    @Test func itWritesAsCSVAndAsJSON() async throws {
        let (log, ref) = await log()
        let export = TrackedSessionExport(log: log)
        let csv = try await export.text(as: CSVExporter())
        let lines = csv.split(separator: "\r\n")
        #expect(lines.count == 4)
        #expect(
            lines[0]
                == "sequence,noticed,saved,kind,$id,$entity,changed,author,context,transaction,transition,before,after,links"
        )
        #expect(lines[2].contains(",updated,\(ref.uri.absoluteString),Note,title,Writer,,12,,"))
        #expect(lines[2].contains(#""{""title"":""A""}""#))

        let json = try JSONNode.parse(try await export.text(as: JSONExporter()))
        guard case .array(let items) = json else { Issue.record("not an array"); return }
        #expect(items.count == 3)
        #expect(items[0]["after"]?["title"] == .string("A"))
        #expect(items[1]["transaction"] == .number("12"))
    }
}
