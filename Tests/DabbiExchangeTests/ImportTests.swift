import DabbiBase
import DabbiModel
import DabbiStore
import DabbiTestSupport
import FixtureKit
import Foundation
import Testing

@testable import DabbiExchange

/// IMX-2 – IMX-4: files parsed into tables, columns mapped onto properties, cells coerced into values.
@Suite struct ImportTableTests {
    @Test func csvReadsQuotesSeparatorsAndLineBreaksInsideFields() throws {
        let text =
            "\u{FEFF}name,note,count\r\n\"Ada, Countess\",\"said \"\"hi\"\"\r\nthen left\",3\r\nplain,,\r\n\r\n\"\",x,4"
        let table = try ImportTable.csv(text)
        #expect(table.columns == ["name", "note", "count"])
        #expect(table.rows.map(\.line) == [2, 4, 6])
        #expect(table.rows[0].cells["name"] == .string("Ada, Countess"))
        #expect(table.rows[0].cells["note"] == .string("said \"hi\"\r\nthen left"))
        // Empty and unquoted is no value; quoted, the empty string.
        #expect(table.rows[1].cells["note"] == .null)
        #expect(table.rows[2].cells["name"] == .string(""))
    }

    @Test func csvTakesAnySeparatorAndGuessesItFromTheHeader() throws {
        #expect(ImportTable.guessSeparator("a;b;c\n1,5;2;3") == ";")
        #expect(ImportTable.guessSeparator("a\tb\n") == "\t")
        #expect(ImportTable.guessSeparator("single") == ",")
        let table = try ImportTable.csv("a;b\n1;2\n3", separator: ";")
        #expect(table.rows[0].cells == ["a": .string("1"), "b": .string("2")])
        // A short record has no cell for the columns it does not reach.
        #expect(table.rows[1].cells == ["a": .string("3")])
    }

    @Test func csvThatIsNotCSVSaysWhere() {
        do {
            _ = try ImportTable.csv("a,b\n1,2\n\"never closed")
            Issue.record("an open quote is refused")
        } catch let error as DabbiError {
            #expect(error.code == .importUnreadable)
            #expect(error.message.contains("line 3"))
        } catch {
            Issue.record("unexpected error")
        }
        #expect(throws: DabbiError.self) { try ImportTable.csv("a,a\n1,2") }
        #expect(throws: DabbiError.self) { try ImportTable.csv("a,,c\n1,2,3") }
    }

    @Test func jsonReadsAnArrayOfObjectsWithColumnsInFirstSeenOrder() throws {
        let table = try ImportTable.json(#"[{"b": 1, "a": "x"}, {"c": null, "a": {"k": true}}]"#)
        #expect(table.columns == ["b", "a", "c"])
        #expect(table.rows.map(\.line) == [1, 2])
        #expect(table.rows[1].cells["a"] == .object([("k", .bool(true))]))
        #expect(table.rows[1].cells["b"] == nil)
        #expect(try ImportTable.json(#"{"a": 1}"#).rows.count == 1)
        #expect(throws: DabbiError.self) { try ImportTable.json("[1, 2]") }
        #expect(throws: DabbiError.self) { try ImportTable.json("[{") }
    }

    // MARK: Mapping

    private func model(_ fixture: Fixture) async throws -> ModelDescription {
        let location = try TestFixtures.location(fixture)
        let session = try await StoreSession.open(storeURL: location.storeURL, modelURL: location.modelURL)
        let model = session.info.model
        await session.close()
        return model
    }

    @Test func columnsAreMappedByTheNamesAnExportGivesThem() async throws {
        let model = try await model(.basic)
        let sample = try #require(model.entity(named: "Sample"))
        let table = ImportTable(columns: ["$id", "$entity", "name", "colour", "dataValue", "unknown"], rows: [])
        let mapping = ImportMapping.automatic(for: table, entity: sample)
        #expect(
            mapping.columns.map(\.target) == [
                .id, .ignored, .attribute(["name"]), .ignored, .attribute(["dataValue"]), .ignored,
            ])
        // Transformables are not offered: only the app can check their bytes.
        #expect(!ImportMapping.targets(for: sample, model: model).contains(.attribute(["colour"])))

        let composites = try await self.model(.composites)
        let entity = try #require(composites.entities.first { $0.attributes.contains { $0.type == .composite } })
        let composite = try #require(entity.attributes.first { $0.type == .composite })
        let element = try #require(composite.compositeElements?.first)
        let dotted = ImportMapping.automatic(
            for: ImportTable(columns: ["\(composite.name).\(element.name)"], rows: []), entity: entity)
        #expect(dotted.columns.map(\.target) == [.attribute([composite.name, element.name])])
    }

    @Test func cellsAreCoercedAndWhatCannotBeIsTheRowsIssue() async throws {
        let model = try await model(.basic)
        let table = try ImportTable.csv(
            "$id,name,int16Value,dateValue,dataValue,boolValue\n"
                + "x-coredata://F/Sample/p1,Ada,12,2026-09-24T15:30:00Z,AAEC,yes\n"
                + "x-coredata://F/Sample/p2,,twelve,soon,!!,\n")
        let sample = try #require(model.entity(named: "Sample"))
        let mapping = ImportMapping.automatic(for: table, entity: sample)
        let rows = mapping.rows(from: table, model: model)
        #expect(rows[0].id == URL(string: "x-coredata://F/Sample/p1"))
        #expect(rows[0].issues.isEmpty)
        #expect(rows[0].values["int16Value"] == .value(.int(12)))
        #expect(rows[0].values["dataValue"] == .data(Data([0, 1, 2])))
        #expect(rows[0].values["boolValue"] == .value(.bool(true)))
        #expect(rows[0].values["dateValue"] == .value(.date(Date(timeIntervalSince1970: 1_790_263_800))))
        // An unquoted empty cell is no value, even for a string.
        #expect(rows[1].values["name"] == .value(.null))
        #expect(rows[1].issues.map(\.property) == ["int16Value", "dateValue", "dataValue"])
        #expect(rows[1].issues[0].message == "This is not a whole number.")

        let column = try #require(mapping.columns.first { $0.name == "int16Value" })
        #expect(mapping.coerce(table.rows[0], column: column, model: model) == .value(.value(.int(12))))
        #expect(ImportValue.data(Data(count: 2048)).previewText() == "2 KB")
    }

    @Test func relationshipCellsHoldURIsOrKeys() async throws {
        let model = try await model(.company)
        let employee = try #require(model.entity(named: "Employee"))
        let table = try ImportTable.json(
            #"""
            [{"tags": [{"$ref": "x-coredata://F/Tag/p1", "$entity": "Tag"}, "x-coredata://F/Tag/p2"],
              "department": {"$count": 1}, "boss": null},
             {"tags": "tag-1|tag-2", "department": {"name": "Department 1"}}]
            """#)
        var mapping = ImportMapping.automatic(for: table, entity: employee)
        #expect(
            mapping.columns.map(\.target) == [
                .relationship("tags"), .relationship("department"), .relationship("boss"),
            ])
        let rows = mapping.rows(from: table, model: model)
        let first = try #require(URL(string: "x-coredata://F/Tag/p1"))
        let second = try #require(URL(string: "x-coredata://F/Tag/p2"))
        #expect(rows[0].values["tags"] == .references([.uri(first), .uri(second)]))
        // A count says nothing about which objects: the relationship is left as it is.
        #expect(rows[0].values["department"] == nil)
        #expect(rows[0].values["boss"] == .references([]))

        #expect(ImportMapping.targets(for: employee, model: model).contains(.relationshipKey("tags", key: "label")))
        mapping.columns = [
            .init("tags", .relationshipKey("tags", key: "label")),
            .init("department", .relationshipKey("department", key: "name")),
        ]
        let keyed = mapping.rows(from: table, model: model)
        #expect(
            keyed[1].values["tags"]
                == .references([.key(["label": .string("tag-1")]), .key(["label": .string("tag-2")])]))
        #expect(keyed[1].values["department"] == .references([.key(["name": .string("Department 1")])]))
        #expect(ImportMapping.name(of: .relationshipKey("tags", key: "label")) == "tags by label")
    }
}

/// IMX-2: what is exported imports back as it was — over the fixture zoo, as CSV and as JSON.
@Suite struct ImportRoundTripTests {
    private let access = StoreAccess.editable(WriteAuthorization(author: "Tests"))

    /// The Core Data stores of the zoo, but the large one, which would only make the test slow.
    static let fixtures = Fixture.allCases.filter { fixture in
        fixture != .large && (try? TestFixtures.location(fixture).manifest.kind) == .coreDataStore
    }

    @Test(arguments: fixtures)
    func everyEntityImportsBackUnchanged(_ fixture: Fixture) async throws {
        let location = try TestFixtures.scratchCopy(fixture)
        let session = try await StoreSession.open(
            storeURL: location.storeURL, modelURL: location.modelURL, access: access)
        defer { Task { await session.close() } }
        let model = session.info.model
        var checked = 0
        for entity in model.entities where !entity.isAbstract {
            let source = ExportSource.fetch(FetchSpec(entity: entity.name, includeSubentities: false))
            let reader = ExportReader(session: session)
            let exported: [(ImportTable.Format, String)] = [
                (.json, try await reader.text(source, as: JSONExporter())),
                (.csv, try await reader.text(source, as: CSVExporter())),
            ]
            for (format, text) in exported {
                let table = try format == .json ? ImportTable.json(text) : ImportTable.csv(text)
                guard !table.rows.isEmpty else { continue }
                let rows = ImportMapping.automatic(for: table, entity: entity).rows(from: table, model: model)
                let (report, changes) = try await session.importRows(
                    rows, into: entity.name, options: ImportOptions(upsert: true))
                let failed = report.failed.map { "\($0.line): \($0.issues)" }
                #expect(failed.isEmpty, "\(fixture) \(entity.name) \(format): \(failed.prefix(3))")
                #expect(
                    report.rows.allSatisfy { $0.outcome == .unchanged },
                    "\(fixture) \(entity.name) \(format): \(Set(report.rows.map(\.outcome)))")
                #expect(changes.isEmpty, "\(fixture) \(entity.name) \(format): \(changes.changes.prefix(2))")
                checked += 1
            }
        }
        #expect(checked > 0)
    }

    @Test func rowsExportedFromOneStoreAreInsertedIntoAnother() async throws {
        let source = try TestFixtures.location(.company)
        let from = try await StoreSession.open(storeURL: source.storeURL, modelURL: source.modelURL)
        defer { Task { await from.close() } }
        let text = try await ExportReader(session: from, options: ExportOptions(relationships: .omitted))
            .text(.fetch(FetchSpec(entity: "Tag")), as: CSVExporter())

        let copy = try TestFixtures.scratchCopy(.company)
        let into = try await StoreSession.open(storeURL: copy.storeURL, modelURL: copy.modelURL, access: access)
        defer { Task { await into.close() } }
        let model = into.info.model
        let table = try ImportTable.csv(text)
        let rows = ImportMapping.automatic(for: table, entity: try #require(model.entity(named: "Tag")))
            .rows(from: table, model: model)
        // Without upsert every row is a new object: the same labels twice over, once committed.
        let (report, changes) = try await into.importRows(rows, into: "Tag")
        #expect(report.count(.inserted) == 8 && changes.count(of: .inserted) == 8)
        #expect(try await into.commit().inserted == 8)
        #expect(try await into.references(FetchSpec(entity: "Tag")).count == 16)
    }
}
