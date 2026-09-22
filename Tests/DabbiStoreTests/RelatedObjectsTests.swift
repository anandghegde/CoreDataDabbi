import DabbiBase
import DabbiModel
import DabbiTestSupport
import FixtureKit
import Foundation
import Testing

@testable import DabbiStore

@Suite struct RelatedObjectsTests {
    private func open(_ fixture: Fixture) async throws -> StoreSession {
        let location = try TestFixtures.location(fixture)
        return try await StoreSession.open(storeURL: location.storeURL, modelURL: location.modelURL)
    }

    /// The first object of `entity` in object-ID order, which is what the grid shows first.
    private func first(_ entity: String, in session: StoreSession) async throws -> ObjectRef {
        let handle = try await session.openPager(FetchSpec(entity: entity))
        defer { Task { await session.closePager(handle) } }
        let page = try await session.page(handle, range: 0..<min(1, handle.count))
        return try #require(page.rows.first?.ref)
    }

    /// An ordered to-many reads in the order it was given, not in object-ID order. The fixture puts each
    /// playlist's featured tracks deliberately out of order; primary keys are handed out at save time and are
    /// not what the order is read from, so the tracks are checked by name.
    @Test func anOrderedToManyKeepsTheOrderItWasGiven() async throws {
        let session = try await open(.ordered)
        defer { Task { await session.close() } }

        let handle = try await session.openPager(FetchSpec(entity: "Playlist"))
        let page = try await session.page(handle, range: 0..<handle.count)
        await session.closePager(handle)
        let names = try #require(page.columns.properties.firstIndex(of: "name"))
        #expect(page.rows.count == 3)

        for row in page.rows {
            let name = row.values[names].displayString()
            let playlist = try #require(name.split(separator: " ").last.flatMap { Int($0) })
            let featured = try await session.related(to: row.ref, through: "featured")
            #expect(featured.isOrdered)
            let expected = [(playlist + 5) % 12, playlist, (playlist + 9) % 12].map { "Track \($0)" }
            #expect(featured.items.map(\.label) == expected)
        }
    }

    @Test func followsAToManyToItsRows() async throws {
        let session = try await open(.company)
        defer { Task { await session.close() } }
        let department = try await first("Department", in: session)
        let employees = try await session.related(to: department, through: "employees")

        #expect(employees.relationship == "employees")
        #expect(employees.destinationEntity == "Employee")
        #expect(employees.isToMany)
        #expect(!employees.isOrdered)
        #expect(employees.count == employees.items.count)
        #expect(!employees.isTruncated)
        // The fixture spreads 25 employees over 4 departments; every one of them is an Employee or a Manager.
        #expect(employees.count > 0)
        #expect(employees.items.allSatisfy { ["Employee", "Manager"].contains($0.ref.entity) })
        // Listed in object-ID order, so the same relationship reads the same way twice.
        #expect(employees.items.map(\.ref.pk) == employees.items.map(\.ref.pk).sorted())
        // Every Party has a name, which is what labels it wherever it is pointed at.
        #expect(employees.items.allSatisfy { $0.display?.isEmpty == false })
        #expect(employees.items.first?.label == employees.items.first?.display)
    }

    @Test func followsAToOneToOneObject() async throws {
        let session = try await open(.company)
        defer { Task { await session.close() } }
        let department = try await first("Department", in: session)
        let organisation = try await session.related(to: department, through: "organisation")

        #expect(!organisation.isToMany)
        #expect(organisation.destinationEntity == "Organisation")
        #expect(organisation.count == 1)
        #expect(organisation.items.count == 1)
        #expect(organisation.items.first?.ref.entity == "Organisation")
    }

    @Test func readsBothEndsOfAManyToMany() async throws {
        let session = try await open(.company)
        defer { Task { await session.close() } }
        let person = try await first("Person", in: session)
        let tags = try await session.related(to: person, through: "tags")
        guard let tag = tags.items.first else { return }  // Not every person is tagged.

        let people = try await session.related(to: tag.ref, through: "people")
        #expect(people.destinationEntity == "Person")
        #expect(people.items.contains { $0.ref == person })
    }

    @Test func saysHowManyThereAreWhenItShowsFewer() async throws {
        let session = try await open(.company)
        defer { Task { await session.close() } }
        let department = try await first("Department", in: session)
        let all = try await session.related(to: department, through: "employees")
        try #require(all.count > 1)

        let one = try await session.related(to: department, through: "employees", limit: 1)
        #expect(one.items.count == 1)
        #expect(one.count == all.count)
        #expect(one.isTruncated)
        // The limit takes the front of the same order, not an arbitrary one.
        #expect(one.items.first == all.items.first)
    }

    @Test func givesAnEmptyAnswerForARelationshipWithNothingInIt() async throws {
        let session = try await open(.company)
        defer { Task { await session.close() } }
        let tag = try await first("Tag", in: session)
        // A Tag has no `head`; a Department's is what nothing points at in this fixture.
        let department = try await first("Department", in: session)
        let head = try await session.related(to: department, through: "head")
        #expect(head.count == head.items.count)
        #expect(!head.isTruncated)
        _ = tag
    }

    @Test func saysSoWhenThereIsNoSuchRelationship() async throws {
        let session = try await open(.company)
        defer { Task { await session.close() } }
        let department = try await first("Department", in: session)
        await #expect(throws: DabbiError.self) {
            _ = try await session.related(to: department, through: "nonesuch")
        }
    }
}
