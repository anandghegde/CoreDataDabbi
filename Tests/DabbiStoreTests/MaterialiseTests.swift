import DabbiBase
import DabbiTestSupport
import FixtureKit
import Foundation
import Testing

@testable import DabbiStore

/// Reading many objects by reference, each by its own entity's layout — what the tracker does with the primary keys
/// a scan hands it (ARCHITECTURE.md §6.6).
@Suite struct MaterialiseTests {
    private func open(_ fixture: Fixture = .company) async throws -> StoreSession {
        let location = try TestFixtures.location(fixture)
        return try await StoreSession.open(storeURL: location.storeURL, modelURL: location.modelURL)
    }

    // MARK: References

    /// A reference is made from a key and an entity name, with nothing read: the scan has the keys already, and
    /// asking the store to confirm each one would undo the point of reading them from SQLite.
    @Test func makesAReferenceWithoutReadingAnything() async throws {
        let session = try await open()
        let ref = try #require(session.reference(entity: "Person", pk: 1))
        #expect(ref.entity == "Person")
        #expect(ref.pk == 1)
        #expect(ref.storeIdentifier == session.info.metadata.storeUUID)
        #expect(session.reference(entity: "Nonexistent", pk: 99) != nil, "nothing is checked against the file")
        await session.close()
    }

    @Test func fetchesEveryMatchingReference() async throws {
        let session = try await open()
        let spec = FetchSpec(entity: "Person")
        let refs = try await session.references(spec)
        #expect(refs.count == (try await session.count(spec)))
        #expect(refs.allSatisfy { $0.storeIdentifier == session.info.metadata.storeUUID })
        #expect(Set(refs.map(\.entity)) == ["Person", "Employee", "Manager"], "each row's own entity")
        await session.close()
    }

    @Test func aLimitIsARealLimit() async throws {
        let session = try await open()
        #expect(try await session.references(FetchSpec(entity: "Person"), limit: 5).count == 5)
        #expect(try await session.references(FetchSpec(entity: "Person"), limit: 0).isEmpty)
        #expect(try await session.references(FetchSpec(entity: "Person"), limit: -1).isEmpty)
        await session.close()
    }

    /// The tracker primes a view's membership this way: identities only, and one more than it can use, so that it
    /// knows whether the view is bigger than it can hold.
    @Test func fetchesTheReferencesOfAPredicateView() async throws {
        let session = try await open()
        let spec = FetchSpec(entity: "Manager", predicate: PredicateSource(format: "level > 1"))
        let refs = try await session.references(spec)
        #expect(refs.isEmpty == false)
        #expect(refs.count == (try await session.count(spec)))
        #expect(refs.allSatisfy { $0.entity == "Manager" })
        await session.close()
    }

    @Test func aPredicateFoundationRefusesIsReported() async throws {
        let session = try await open()
        let error = await #expect(throws: DabbiError.self) {
            try await session.references(FetchSpec(entity: "Person", predicate: PredicateSource(format: "((((")))
        }
        #expect(error?.code == .invalidPredicate)
        await session.close()
    }

    // MARK: Objects

    @Test func readsObjectsByTheirOwnEntitysLayout() async throws {
        let session = try await open()
        let managers = try await session.references(FetchSpec(entity: "Manager", includeSubentities: false))
        let objects = try await session.objects(managers)

        #expect(objects.count == managers.count)
        let firstRef = try #require(managers.first)
        let first = try #require(objects[firstRef])
        #expect(first.ref == firstRef)
        #expect(first.snapshot.columns.properties.contains("level"), "a Manager, not the Party whose table it is in")
        #expect(first.snapshot.columns.properties.contains("salary"), "and everything it inherits")
        #expect(first.snapshot["name"]?.isNull == false)
        #expect(first.matchesPredicate == nil, "nothing was asked")
        await session.close()
    }

    /// Mixed entities in one call, which is what a commit that touched several tables produces.
    @Test func readsSeveralEntitiesAtOnce() async throws {
        let session = try await open()
        let tags = try await session.references(FetchSpec(entity: "Tag"), limit: 3)
        let departments = try await session.references(FetchSpec(entity: "Department"), limit: 2)
        let objects = try await session.objects(tags + departments)

        #expect(objects.count == 5)
        let tag = try #require(tags.first)
        let department = try #require(departments.first)
        #expect(objects[tag]?.snapshot["label"]?.isNull == false)
        #expect(objects[department]?.snapshot["name"]?.isNull == false)
        await session.close()
    }

    /// To-many relationships come back as counts, gathered for the whole batch rather than one fetch per row.
    @Test func toManyRelationshipsComeBackAsCounts() async throws {
        let session = try await open()
        let employees = try await session.references(FetchSpec(entity: "Employee", includeSubentities: false))
        let objects = try await session.objects(employees)

        let counts = objects.values.compactMap { object -> Int? in
            guard case .toMany(let count) = object.snapshot["tags"] else { return nil }
            return count
        }
        #expect(counts.count == employees.count)
        #expect(counts.contains { $0 > 0 }, "the fixture gives every employee two tags")
        await session.close()
    }

    @Test func readsInAsManyBatchesAsItTakes() async throws {
        let session = try await open()
        let people = try await session.references(FetchSpec(entity: "Person"))
        let objects = try await session.objects(people, batchSize: 7)
        #expect(objects.count == people.count)
        #expect(Set(objects.keys) == Set(people))
        // A batch size of zero would divide by nothing; it reads in one batch instead.
        #expect(try await session.objects(people, batchSize: 0).count == people.count)
        await session.close()
    }

    /// How the tracker learns that a row it was told about has gone again: the key is simply not in the answer.
    @Test func aReferenceWithNoRowIsAbsentRatherThanAnError() async throws {
        let session = try await open()
        let tags = try await session.references(FetchSpec(entity: "Tag"), limit: 1)
        let real = try #require(tags.first)
        let ghost = try #require(session.reference(entity: "Tag", pk: 999_999))
        let unknownEntity = try #require(session.reference(entity: "NotInThisModel", pk: 1))

        let objects = try await session.objects([real, ghost, unknownEntity])
        #expect(objects.count == 1)
        #expect(objects[real] != nil)
        #expect(objects[ghost] == nil)
        #expect(objects[unknownEntity] == nil)
        await session.close()
    }

    @Test func nothingAskedIsNothingRead() async throws {
        let session = try await open()
        #expect(try await session.objects([]).isEmpty)
        await session.close()
    }

    /// The same reference twice is one read.
    @Test func duplicateReferencesAreReadOnce() async throws {
        let session = try await open()
        let tags = try await session.references(FetchSpec(entity: "Tag"), limit: 1)
        let tag = try #require(tags.first)
        let objects = try await session.objects([tag, tag, tag])
        #expect(objects.count == 1)
        await session.close()
    }

    // MARK: The tracked view's predicate (TRK-7)

    @Test func saysWhichObjectsThePredicateHolds() async throws {
        let session = try await open()
        let managers = try await session.references(FetchSpec(entity: "Manager", includeSubentities: false))
        let objects = try await session.objects(managers, matching: PredicateSource(format: "level > 1"))

        #expect(objects.count == managers.count, "every row is read; the predicate says which ones match")
        let matching = objects.values.filter { $0.matchesPredicate == true }
        #expect(matching.isEmpty == false)
        #expect(objects.values.contains { $0.matchesPredicate == false })
        let expected = try await session.count(
            FetchSpec(entity: "Manager", includeSubentities: false, predicate: PredicateSource(format: "level > 1")))
        #expect(matching.count == expected, "the same answer the store gives")
        await session.close()
    }

    /// A predicate about a property the entity does not have cannot be answered for it. Unknown is not "no": the
    /// tracker reports the row without claiming it crossed a boundary.
    @Test func anEntityThatCannotAnswerLeavesItUnknown() async throws {
        let session = try await open()
        let tags = try await session.references(FetchSpec(entity: "Tag"), limit: 2)
        let objects = try await session.objects(tags, matching: PredicateSource(format: "level > 1"))
        #expect(objects.count == 2)
        #expect(objects.values.allSatisfy { $0.matchesPredicate == nil })
        await session.close()
    }

    /// Parsed before anything is read, so a predicate that cannot be used fails as a predicate rather than as a
    /// fetch nobody can explain.
    @Test func aPredicateThatCannotBeUsedFailsBeforeAnyFetch() async throws {
        let session = try await open()
        let tags = try await session.references(FetchSpec(entity: "Tag"), limit: 1)

        let malformed = await #expect(throws: DabbiError.self) {
            try await session.objects(tags, matching: PredicateSource(format: "(((("))
        }
        #expect(malformed?.code == .invalidPredicate)

        // §6.4: a predicate that could run code is refused wherever it is used, in memory included.
        let unsafe = await #expect(throws: DabbiError.self) {
            try await session.objects(tags, matching: PredicateSource(format: "label == FUNCTION(self, 'init')"))
        }
        #expect(unsafe?.code == .unsafePredicate)
        await session.close()
    }

    @Test func aClosedSessionReadsNothing() async throws {
        let session = try await open()
        let tags = try await session.references(FetchSpec(entity: "Tag"), limit: 1)
        await session.close()
        let error = await #expect(throws: DabbiError.self) { try await session.objects(tags) }
        #expect(error?.code == .storeClosed)
    }
}
