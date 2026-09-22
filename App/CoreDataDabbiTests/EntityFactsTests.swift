import DabbiKit
import FixtureKit
import Testing

@testable import CoreDataDabbi

@MainActor
@Suite struct EntityFactsTests {
    private func facts(of entity: String) async throws -> EntityFacts {
        let model = try await TestProject.model(of: .company)
        return EntityFacts(entity: try #require(model.entity(named: entity)), in: model)
    }

    private func fact(_ label: String, in facts: [EntityFacts.Fact]) throws -> EntityFacts.Fact {
        try #require(facts.first { $0.label == label }, "no fact labelled “\(label)”")
    }

    @Test func saysWhatAnAbstractEntityIsAndWhoInheritsFromIt() async throws {
        let party = try await facts(of: "Party")
        #expect(try fact("Abstract", in: party.summary).weight == .notable)
        #expect(try fact("Subentities", in: party.summary).value == "Organisation, Person")
        // A root entity is stored in its own table, so there is nothing to point elsewhere.
        #expect(!party.summary.contains { $0.label == "Stored with" })
        // The hash is what a migration compares; showing it is the point of having it. Core Data's is 32
        // bytes, and the inspector shows it as hex.
        #expect(try fact("Version hash", in: party.summary).value.count == 64)
    }

    @Test func pointsASubentityAtTheTableItReallyLivesIn() async throws {
        let manager = try await facts(of: "Manager")
        #expect(try fact("Inherits from", in: manager.summary).value == "Employee")
        #expect(try fact("Stored with", in: manager.summary).value == "Party")
    }

    @Test func namesTheAncestorAnInheritedPropertyCameFrom() async throws {
        let manager = try await facts(of: "Manager")
        let name = try #require(manager.attributes.first { $0.name == "name" })
        #expect(name.declaredIn == "Party")
        let level = try #require(manager.attributes.first { $0.name == "level" })
        #expect(level.declaredIn == "Manager")
    }

    @Test func marksAnAttributeThatCannotBeNull() async throws {
        let party = try await facts(of: "Party")
        let name = try #require(party.attributes.first { $0.name == "name" })
        #expect(name.kind == .attribute(.string))
        #expect(name.isNotable)
        #expect(try fact("Optional", in: name.facts).value == "No")
        #expect(try fact("Default", in: name.facts).value == "")

        let createdAt = try #require(party.attributes.first { $0.name == "createdAt" })
        #expect(createdAt.summary == "Date · optional")
        #expect(!createdAt.isNotable)
    }

    @Test func spellsOutADeleteRuleThatBites() async throws {
        let department = try await facts(of: "Department")
        let employees = try #require(department.relationships.first { $0.name == "employees" })
        #expect(employees.kind == .relationship(destination: "Employee", isToMany: true))
        #expect(employees.summary == "To-many · Deny")
        #expect(try fact("Delete rule", in: employees.facts).weight == .notable)
        #expect(try fact("Inverse", in: employees.facts).value == "department")

        // Nullify is the ordinary case and says nothing worth a mark.
        let organisation = try await facts(of: "Organisation")
        let departments = try #require(organisation.relationships.first { $0.name == "departments" })
        #expect(departments.summary == "To-many · Cascade")
        #expect(departments.isNotable)
    }

    @Test func warnsAboutARelationshipWithNoInverse() async throws {
        let department = try await facts(of: "Department")
        let head = try #require(department.relationships.first { $0.name == "head" })
        #expect(head.summary == "To-one · Nullify · no inverse")
        #expect(try fact("Inverse", in: head.facts).weight == .warning)
        #expect(head.typeName == "To-one → Manager")
    }

    @Test func readsBothEndsOfAManyToMany() async throws {
        let person = try await facts(of: "Person")
        let tags = try #require(person.relationships.first { $0.name == "tags" })
        #expect(try fact("Destination", in: tags.facts).value == "Tag")
        #expect(try fact("Kind", in: tags.facts).value == "To-many")
        #expect(try fact("Inverse", in: tags.facts).value == "people")

        let tag = try await facts(of: "Tag")
        let people = try #require(tag.relationships.first { $0.name == "people" })
        #expect(try fact("Inverse", in: people.facts).value == "tags")
    }

    @Test func listsPropertiesInReadingOrderRatherThanTheModelsOwn() async throws {
        let employee = try await facts(of: "Employee")
        #expect(employee.attributes.map(\.name) == employee.attributes.map(\.name).sorted())
        #expect(employee.relationships.map(\.name) == employee.relationships.map(\.name).sorted())
        // An entity's attributes include everything it inherits: that is what its rows hold.
        #expect(employee.attributes.map(\.name) == ["age", "createdAt", "email", "name", "salary", "title"])
    }
}
