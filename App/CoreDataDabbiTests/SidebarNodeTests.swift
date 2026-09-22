import DabbiKit
import FixtureKit
import Testing

@testable import CoreDataDabbi

@MainActor
@Suite struct SidebarNodeTests {
    private func companyModel() async throws -> ModelDescription {
        try await TestProject.model(of: .company)
    }

    @Test func nestsEntitiesByInheritance() async throws {
        let tree = SidebarNode.tree(of: try await companyModel())
        let entities = try #require(tree.first)
        #expect(entities.title == "Entities")
        // Party is the abstract root; Department and Tag stand on their own.
        #expect(entities.children.map(\.title) == ["Department", "Party", "Tag"])

        let party = try #require(entities.children.first { $0.title == "Party" })
        #expect(party.children.map(\.title) == ["Organisation", "Person"])
        let person = try #require(party.children.first { $0.title == "Person" })
        let employee = try #require(person.children.first)
        #expect(employee.title == "Employee")
        #expect(employee.children.map(\.title) == ["Manager"])
        #expect(employee.ancestors.map(\.title) == ["Person", "Party", "Entities"])
    }

    @Test func filteringKeepsWhatLeadsToAMatch() async throws {
        let tree = SidebarNode.tree(of: try await companyModel())
        let manager = SidebarNode.filter(tree, matching: "manager")
        #expect(
            manager.flatMap { $0.flattened() }.compactMap(\.entityName) == ["Party", "Person", "Employee", "Manager"])

        // A match keeps its own children, so that narrowing to a parent still shows what it can be.
        let person = SidebarNode.filter(tree, matching: "person")
        let names = person.flatMap { $0.flattened() }.compactMap(\.entityName)
        #expect(names == ["Party", "Person", "Employee", "Manager"])

        #expect(SidebarNode.filter(tree, matching: "nothing here").isEmpty)
        #expect(SidebarNode.filter(tree, matching: "  ").count == tree.count)
    }

    @Test func aGroupNeverMatchesTheFilter() async throws {
        let tree = SidebarNode.tree(of: try await companyModel())
        #expect(SidebarNode.filter(tree, matching: "Entities").isEmpty)
    }
}
