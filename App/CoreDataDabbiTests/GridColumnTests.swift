import DabbiKit
import FixtureKit
import Testing

@testable import CoreDataDabbi

@MainActor
@Suite struct GridColumnTests {
    private func columns(
        of entity: String, reading properties: [String], layout: EntityLayout = EntityLayout()
    ) async throws -> [GridColumn] {
        let model = try await TestProject.model(of: .company)
        return GridColumn.columns(
            for: try #require(model.entity(named: entity)), in: model, reading: ColumnSet(properties),
            layout: layout)
    }

    @Test func startsWithTheObjectIDAndNamesTheEntityOnlyWhenItCanVary() async throws {
        let person = try await columns(of: "Person", reading: ["name", "age"])
        #expect(person.map(\.property) == [ColumnLayout.objectIDColumn, ColumnLayout.entityColumn, "name", "age"])

        // A Tag is only ever a Tag; a column saying so would be a column of one word.
        let tag = try await columns(of: "Tag", reading: ["label"])
        #expect(tag.map(\.property) == [ColumnLayout.objectIDColumn, "label"])
    }

    @Test func describesPropertiesTheSubentitiesAdd() async throws {
        let columns = try await columns(of: "Person", reading: ["name", "salary", "boss", "department"])
        let salary = try #require(columns.first { $0.property == "salary" })
        // Declared by Employee, shown in the Person grid because a Person row can be one.
        #expect(salary.typeName == AttributeType.decimal.displayName)
        #expect(salary.isTrailing)
        #expect(salary.isSortable)

        let boss = try #require(columns.first { $0.property == "boss" })
        #expect(boss.typeName == "To-one → Person")
        #expect(!boss.isSortable)
        #expect(!boss.isTrailing)
    }

    @Test func leavesOutWhatTheModelDoesNotDescribe() async throws {
        let tag = try await columns(of: "Tag", reading: ["label", "whatIsThis"])
        #expect(!tag.contains { $0.property == "whatIsThis" })
    }

    @Test func nothingButAnAttributeCanBeSortedBy() async throws {
        let person = try await columns(of: "Person", reading: ["name", "age", "tags", "boss"])
        #expect(person.filter(\.isSortable).map(\.property) == ["name", "age"])
        #expect(person.first?.isSortable == false)  // The object ID column.
    }

    @Test func putsRememberedColumnsFirstAndKeepsNewOnesVisible() async throws {
        let layout = EntityLayout(columns: [
            ColumnLayout(property: "age", width: 60),
            ColumnLayout(property: "name", width: 200, isHidden: true),
            ColumnLayout(property: "gone", width: 90),
        ])
        let tag = try await columns(of: "Tag", reading: ["label"], layout: layout)
        // Nothing the layout names exists on a Tag; it is left exactly as the model has it.
        #expect(tag.map(\.property) == [ColumnLayout.objectIDColumn, "label"])

        let person = try await columns(of: "Person", reading: ["name", "age", "email"], layout: layout)
        #expect(person.map(\.property) == ["age", "name", ColumnLayout.objectIDColumn, "$entity", "email"])
        #expect(person.first?.width == 60)
        #expect(person[1].isHidden)
        // An attribute added since the layout was saved keeps its place rather than disappearing.
        #expect(person.last?.property == "email")
        #expect(person.last?.isHidden == false)
    }

    @Test func savesAndReadsBackTheSameLayout() async throws {
        var arranged = try await columns(of: "Person", reading: ["name", "age", "email"])
        arranged[2].isHidden = true
        arranged[3].width = 321
        arranged.swapAt(0, 4)
        let restored = try await columns(
            of: "Person", reading: ["name", "age", "email"],
            layout: EntityLayout(columns: GridColumn.layout(of: arranged)))
        #expect(restored == arranged)
    }

    @Test func readsOnlyTheColumnsOnScreen() async throws {
        var person = try await columns(of: "Person", reading: ["name", "age", "email"])
        #expect(person.columnSet.properties == ["name", "age", "email"])

        let name = try #require(person.firstIndex { $0.property == "name" })
        person[name].isHidden = true
        #expect(person.columnSet.properties == ["age", "email"])
        #expect(person.visible.count == person.count - 1)
    }
}
