import DabbiBase
import DabbiTestSupport
import Foundation
import Testing

@testable import DabbiStore

@Suite struct PredicateGuardTests {
    @Test(arguments: [
        "name == 'x'",
        "name BEGINSWITH[cd] 'a' AND age BETWEEN {18, 65}",
        "NOT (email == nil) OR age IN {1, 2, 3}",
        "name MATCHES '^[A-Z].*' AND name LIKE[c] 'man*'",
        "reports.@count > 2 AND tags.@count == 0",
        "ANY tags.label == 'urgent' OR NONE tags.label == 'done'",
        "SUBQUERY(reports, $r, $r.age > 30 AND $r.name != nil).@count > 0",
        "salary * 2 > 100000 AND abs(age - 40) < 5",
        "createdAt > CAST(725846400, 'NSDate')",
        "createdAt < now()",
        "uppercase(name) == 'MANAGER 1' AND length(name) > 3",
        "sum(reports.age) > 100 AND max(reports.age) < 90",
        "TRUEPREDICATE",
        "FALSEPREDICATE",
    ])
    func allows(_ format: String) throws {
        _ = try PredicateGuard.parse(PredicateSource(format: format))
    }

    @Test(arguments: [
        "FUNCTION(name, 'uppercaseString') == 'X'",
        "FUNCTION('/tmp/x', 'stringByExpandingTildeInPath') != nil",
        "FUNCTION(FUNCTION('NSFileManager', 'class'), 'defaultManager') != nil",
        "CAST('NSFileManager', 'Class') != nil",
        "CAST(name, 'NSFileManager') != nil",
        "SUBQUERY(reports, $r, FUNCTION($r, 'valueForKey:', 'name') != nil).@count > 0",
        "age + FUNCTION(name, 'length') > 3",
        "ANY FUNCTION(self, 'valueForKeyPath:', 'tags') != nil",
    ])
    func refuses(_ format: String) {
        let error = #expect(throws: DabbiError.self) { try PredicateGuard.parse(PredicateSource(format: format)) }
        #expect(error?.code == .unsafePredicate, "\(format) → \(String(describing: error))")
    }

    @Test(arguments: ["name ==", "name = = 'x'", "(age > 3", "age >> 3", "name == %@", "name == 'unterminated", ""])
    func parseErrorsAreErrorsNotCrashes(_ format: String) {
        let error = #expect(throws: DabbiError.self) { try PredicateGuard.parse(PredicateSource(format: format)) }
        #expect(error?.code == .invalidPredicate, "\(format) → \(String(describing: error))")
        #expect(error?.recovery.isEmpty == false)
    }

    @Test func programmaticEscapesAreRefusedToo() {
        let block = NSPredicate { _, _ in true }
        #expect(throws: DabbiError.self) { try PredicateGuard.check(block) }

        let custom = NSComparisonPredicate(
            leftExpression: NSExpression(forKeyPath: "name"), rightExpression: NSExpression(forConstantValue: "x"),
            customSelector: NSSelectorFromString("isEqualToString:"))
        #expect(throws: DabbiError.self) { try PredicateGuard.check(custom) }

        let blockExpression = NSComparisonPredicate(
            leftExpression: NSExpression(block: { _, _, _ in 1 }, arguments: nil),
            rightExpression: NSExpression(forConstantValue: 1), modifier: .direct, type: .equalTo)
        #expect(throws: DabbiError.self) { try PredicateGuard.check(blockExpression) }
    }
}

@Suite struct FetchValidationTests {
    private func company() async throws -> StoreSession {
        try await StoreSession.open(storeURL: try TestFixtures.location(.company).storeURL)
    }

    @Test func unknownEntity() async throws {
        let session = try await company()
        let error = await #expect(throws: DabbiError.self) { try await session.count(FetchSpec(entity: "Nobody")) }
        #expect(error?.code == .unknownEntity)
        #expect(error?.recovery.first?.contains("Manager") == true)
        await session.close()
    }

    @Test func unknownKeyPathInAPredicate() async throws {
        let session = try await company()
        let error = await #expect(throws: DabbiError.self) {
            try await session.count(FetchSpec(entity: "Person", predicate: PredicateSource(format: "nope == 1")))
        }
        #expect(error?.code == .invalidPredicate)
        // The session survives a rejected fetch.
        #expect(try await session.count(FetchSpec(entity: "Person")) == 60)
        await session.close()
    }

    @Test(arguments: ["nope", "tags.label", "reports", "boss.nope", "name.length", ""])
    func sortsThatCannotWork(_ keyPath: String) async throws {
        let session = try await company()
        let error = await #expect(throws: DabbiError.self) {
            try await session.openPager(FetchSpec(entity: "Person", sort: [SortKey(keyPath: keyPath)]))
        }
        #expect(error?.code == .invalidSort, "\(keyPath) → \(String(describing: error))")
        await session.close()
    }

    @Test func sortingByATransformableIsRefused() async throws {
        let session = try await StoreSession.open(storeURL: try TestFixtures.location(.basic).storeURL)
        let error = await #expect(throws: DabbiError.self) {
            try await session.openPager(FetchSpec(entity: "Sample", sort: [SortKey(keyPath: "colour")]))
        }
        #expect(error?.code == .invalidSort)
        await session.close()
    }

    @Test func unsafePredicatesNeverReachCoreData() async throws {
        let session = try await company()
        let error = await #expect(throws: DabbiError.self) {
            try await session.openPager(
                FetchSpec(
                    entity: "Person", predicate: PredicateSource(format: "FUNCTION(name, 'uppercaseString') == 'X'")))
        }
        #expect(error?.code == .unsafePredicate)
        await session.close()
    }
}
