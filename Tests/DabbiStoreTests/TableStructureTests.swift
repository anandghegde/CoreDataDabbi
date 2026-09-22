import DabbiBase
import DabbiModel
import DabbiTestSupport
import FixtureKit
import Foundation
import Testing

@testable import DabbiStore

@Suite struct TableStructureTests {
    private func open(_ fixture: Fixture) async throws -> StoreSession {
        let location = try TestFixtures.location(fixture)
        return try await StoreSession.open(storeURL: location.storeURL, modelURL: location.modelURL)
    }

    @Test func readsTheTableAnEntityIsStoredIn() async throws {
        let session = try await open(.company)
        defer { Task { await session.close() } }
        let structure = try await session.structure(of: "Department")

        #expect(structure.entity == "Department")
        #expect(structure.table == "ZDEPARTMENT")
        #expect(try #require(structure.definition).hasPrefix("CREATE TABLE ZDEPARTMENT"))

        let names = structure.columns.map(\.name)
        #expect(names.contains("Z_PK"))
        #expect(names.contains("Z_ENT"))
        #expect(names.contains("ZNAME"))
        // The to-one ends of its relationships are columns on its own table.
        #expect(names.contains("ZHEAD"))
        #expect(names.contains("ZORGANISATION"))

        let pk = try #require(structure.columns.first { $0.name == "Z_PK" })
        #expect(pk.primaryKeyPosition == 1)
        #expect(pk.declaredType == "INTEGER")
        // SQLite reports an `INTEGER PRIMARY KEY` as nullable, because it is the rowid alias: what is read back
        // is never null, but the column carries no NOT NULL of its own. Shown as it is, not as it behaves.
        #expect(!pk.isNotNull)
    }

    @Test func everyEntityOfAChainSharesTheRootsTable() async throws {
        let session = try await open(.company)
        defer { Task { await session.close() } }
        let manager = try await session.structure(of: "Manager")
        let party = try await session.structure(of: "Party")

        #expect(manager.table == "ZPARTY")
        #expect(manager.entity == "Manager")  // Which entity was asked about is not forgotten.
        #expect(manager.columns == party.columns)
        // Everything the whole chain stores is in the one table, nullable for the rows that have no such thing.
        let names = Set(manager.columns.map(\.name))
        #expect(names.isSuperset(of: ["ZNAME", "ZEMAIL", "ZAGE", "ZTITLE", "ZSALARY", "ZLEVEL", "ZREGISTRATION"]))
        #expect(try #require(manager.columns.first { $0.name == "ZLEVEL" }).isNotNull == false)
    }

    @Test func findsTheJoinTableOfAManyToMany() async throws {
        let session = try await open(.company)
        defer { Task { await session.close() } }
        let structure = try await session.structure(of: "Person")

        let join = try #require(structure.joinTables["tags"])
        #expect(join.table.hasSuffix("TAGS"))
        #expect(join.columns.count == 2)
        #expect(try #require(join.definition).contains("CREATE TABLE"))
        // A to-one is a column, not a table of its own.
        #expect(structure.joinTables["boss"] == nil)
    }

    @Test func listsTheIndexesAQueryCouldUse() async throws {
        let session = try await open(.company)
        defer { Task { await session.close() } }
        let structure = try await session.structure(of: "Person")

        #expect(!structure.indexes.isEmpty)
        // Core Data indexes the foreign keys it writes.
        #expect(structure.indexes.contains { $0.columns.contains("ZBOSS") })
        #expect(structure.indexes.allSatisfy { !$0.name.isEmpty })
    }

    @Test func theScriptIsWhatTheDatabaseWasBuiltWith() async throws {
        let session = try await open(.company)
        defer { Task { await session.close() } }
        let script = try await session.structure(of: "Person").script

        #expect(script.contains("CREATE TABLE ZPARTY"))
        #expect(script.contains("CREATE INDEX"))
        #expect(script.contains("-- Person.tags"))
        #expect(script.hasSuffix(";"))
    }

    @Test func saysSoWhenThereIsNoSuchEntity() async throws {
        let session = try await open(.basic)
        defer { Task { await session.close() } }
        await #expect(throws: DabbiError.self) { try await session.structure(of: "NotAnEntity") }
    }
}
