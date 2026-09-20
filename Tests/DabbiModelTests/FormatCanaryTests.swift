import DabbiBase
import DabbiSQLite
import DabbiTestSupport
import FixtureKit
import Foundation
import Testing

@testable import DabbiModel

/// What this OS's Core Data writes, checked against what `SchemaMap` and `FormatProbe` assume (ARCHITECTURE.md,
/// Appendix A). A failure here after an OS update means the on-disk conventions moved, not that a test is stale.
@Suite struct FormatCanaryTests {
    private func model(of location: FixtureLocation, _ connection: SQLiteConnection) throws -> ModelDescription {
        try ModelLoader.resolve(storeURL: location.storeURL, modelURL: location.modelURL, connection: connection)
            .description
    }

    private func open(_ fixture: Fixture) throws -> (SQLiteConnection, SchemaMap, FixtureLocation) {
        let location = try TestFixtures.location(fixture)
        let connection = try SQLiteConnection(readOnly: location.storeURL)
        return (
            connection, try SchemaMap.build(model: try model(of: location, connection), connection: connection),
            location
        )
    }

    @Test func everyFixtureMapsCompletely() throws {
        for fixture in Fixture.allCases {
            guard try TestFixtures.location(fixture).manifest.kind == .coreDataStore else { continue }
            let (connection, map, location) = try open(fixture)
            #expect(map.isVerified, "\(fixture): \(map.unverified)")
            // The map is only worth something if it finds the rows: count each entity through it, sub-entities
            // included, the way the manifest does.
            let model = try model(of: location, connection)
            for (entity, expected) in location.manifest.entityCounts {
                let entityMap = try #require(map.entities[entity], "\(fixture).\(entity)")
                let numbers = model.entityAndDescendants(of: entity).compactMap { map.entities[$0.name]?.entityNumber }
                #expect(numbers.count == model.entityAndDescendants(of: entity).count, "\(fixture).\(entity)")
                let counted = try connection.scalar(
                    "SELECT count(*) FROM \(SQLiteConnection.quoteIdentifier(entityMap.table)) "
                        + "WHERE Z_ENT IN (\(numbers.map(String.init).joined(separator: ", ")))")
                #expect(counted?.int64 == Int64(expected), "\(fixture).\(entity)")
            }
        }
    }

    @Test func entityNumbersFollowTheHierarchyAlphabetically() throws {
        let (connection, map, _) = try open(.company)
        let numbers = map.entities.mapValues(\.entityNumber)
        #expect(
            numbers == [
                "Department": 1, "Party": 2, "Organisation": 3, "Person": 4, "Employee": 5, "Manager": 6, "Tag": 7,
            ])
        #expect(Set(map.entities.values.filter { $0.table == "ZPARTY" }.map(\.entity)).count == 5)
        #expect(try connection.scalar("SELECT count(*) FROM ZPARTY WHERE Z_ENT = 6")?.int64 == 5)
        #expect(try connection.scalar("SELECT count(*) FROM ZPARTY WHERE Z_ENT IN (4, 5, 6)")?.int64 == 60)
        #expect(try connection.scalar("SELECT count(*) FROM ZPARTY WHERE Z_ENT = 2")?.int64 == 0)  // abstract
    }

    @Test func toOneColumns() throws {
        let (connection, map, _) = try open(.company)
        let boss = try #require(map.entities["Employee"]?.relationships["boss"])
        #expect(boss.storage == .foreignKey && boss.table == "ZPARTY" && boss.column == "ZBOSS")
        // Person has sub-entities, so the destination's entity rides along.
        #expect(boss.entityColumn == "Z4_BOSS")
        let destinations = try connection.query("SELECT DISTINCT Z4_BOSS FROM ZPARTY WHERE ZBOSS IS NOT NULL")
        #expect(Set(destinations.compactMap { $0[0].int64 }).isSubset(of: [4, 5, 6]))

        // Manager has none, so there is no such column.
        let head = try #require(map.entities["Department"]?.relationships["head"])
        #expect(head.column == "ZHEAD" && head.entityColumn == nil)

        let reports = try #require(map.entities["Person"]?.relationships["reports"])
        #expect(reports.storage == .inverseForeignKey && reports.table == "ZPARTY" && reports.column == "ZBOSS")
    }

    @Test func manyToManyJoinTable() throws {
        let (connection, map, _) = try open(.company)
        let tags = try #require(map.entities["Person"]?.relationships["tags"])
        #expect(tags.storage == .joinTable && tags.table == "Z_4TAGS")
        #expect(tags.sourceColumn == "Z_4PEOPLE" && tags.column == "Z_7TAGS")
        let people = try #require(map.entities["Tag"]?.relationships["people"])
        #expect(people.table == "Z_4TAGS" && people.sourceColumn == "Z_7TAGS" && people.column == "Z_4PEOPLE")
        // Sub-entities inherit the very same table.
        #expect(map.entities["Manager"]?.relationships["tags"] == tags)
        #expect(try connection.columnNames(ofTable: "Z_4TAGS").sorted() == ["Z_4PEOPLE", "Z_7TAGS"])
    }

    @Test func orderedRelationships() throws {
        let (connection, map, _) = try open(.ordered)
        let tracks = try #require(map.entities["Playlist"]?.relationships["tracks"])
        #expect(tracks.storage == .inverseForeignKey && tracks.table == "ZTRACK")
        #expect(tracks.column == "ZPLAYLIST" && tracks.orderColumn == "Z_FOK_PLAYLIST")
        #expect(
            try connection.scalar("SELECT count(*) FROM ZTRACK WHERE ZPLAYLIST IS NOT NULL AND Z_FOK_PLAYLIST IS NULL")?
                .int64 == 0)

        let featured = try #require(map.entities["Playlist"]?.relationships["featured"])
        #expect(featured.storage == .joinTable && featured.table == "Z_1FEATURED")
        #expect(featured.orderColumn == "Z_FOK_2FEATURED")
        // The unordered side of the same table has no order of its own.
        #expect(map.entities["Track"]?.relationships["featuredIn"]?.orderColumn == nil)
    }

    @Test func compositesFlattenToLeafColumns() throws {
        let (connection, map, _) = try open(.composites)
        let attributes = try #require(map.entities["Place"]?.attributes)
        #expect(
            attributes.mapValues(\.column) == [
                "name": "ZNAME", "address.street": "ZSTREET", "address.city": "ZCITY",
                "address.location.latitude": "ZLATITUDE", "address.location.longitude": "ZLONGITUDE",
            ])
        #expect(try connection.columnNames(ofTable: "ZPLACE").contains("ZADDRESS") == false)
    }

    @Test func derivedAttributesAreRealColumns() throws {
        let (connection, map, _) = try open(.derived)
        #expect(map.entities["List"]?.attributes["itemCount"]?.column == "ZITEMCOUNT")
        #expect(map.entities["Item"]?.attributes["listName"]?.column == "ZLISTNAME")
        #expect(try connection.scalar("SELECT sum(ZITEMCOUNT) FROM ZLIST")?.int64 == 18)
    }

    @Test func bookkeepingColumnsAndTables() throws {
        let (connection, _, _) = try open(.basic)
        #expect(try connection.columnNames(ofTable: "ZSAMPLE").prefix(3) == ["Z_PK", "Z_ENT", "Z_OPT"])
        #expect(try connection.columnNames(ofTable: "Z_PRIMARYKEY") == ["Z_ENT", "Z_NAME", "Z_SUPER", "Z_MAX"])
        let probe = try FormatProbe.probe(connection)
        #expect(probe.kind == .coreData && probe.hasModelCache && probe.hasOptimisticLockColumn)
        #expect(!probe.hasHistory && !probe.hasCloudKitMirroring)
        #expect(probe.otherTables.isEmpty)
        #expect(Set(probe.coreDataTables).isSuperset(of: ["ZSAMPLE", "Z_METADATA", "Z_MODELCACHE", "Z_PRIMARYKEY"]))
    }

    @Test func historyTables() throws {
        let (connection, map, _) = try open(.history)
        let probe = try FormatProbe.probe(connection)
        #expect(probe.hasHistory)
        #expect(Set(probe.coreDataTables).isSuperset(of: ["ACHANGE", "ATRANSACTION", "ATRANSACTIONSTRING"]))
        #expect(probe.otherTables.isEmpty)
        #expect(map.isVerified)
        #expect(try connection.scalar("SELECT count(*) FROM ATRANSACTION")?.int64 ?? 0 > 0)
    }

    @Test func aPlainDatabaseIsNotCoreData() throws {
        let location = try TestFixtures.location(.notCoreData)
        let probe = try FormatProbe.probe(try SQLiteConnection(readOnly: location.storeURL))
        #expect(probe.kind == .plainSQLite)
        #expect(probe.coreDataTables.isEmpty && !probe.otherTables.isEmpty)
        let error = FormatProbe.notCoreDataError(at: location.storeURL)
        #expect(error.code == .notCoreData)
    }

    @Test func recognisesCoreDataTableNames() {
        for name in ["ZPERSON", "Z_PRIMARYKEY", "Z_4TAGS", "ACHANGE", "ATRANSACTION", "ANSCKEXPORTEDOBJECT"] {
            #expect(FormatProbe.isCoreDataTable(name), "\(name)")
        }
        for name in ["users", "sqlite_sequence", "zebra", "Account"] {
            #expect(!FormatProbe.isCoreDataTable(name), "\(name)")
        }
    }

    @Test func aModelThatDoesNotFitIsReportedNotGuessed() throws {
        // The Notes model against the company store: nothing lines up, and the map must say so.
        let connection = try SQLiteConnection(readOnly: try TestFixtures.location(.company).storeURL)
        let notes = try ModelLoader.loadModel(at: try #require(try TestFixtures.location(.noModelCache).modelURL))
        let map = try SchemaMap.build(model: ModelDescription(notes), connection: connection)
        #expect(!map.isVerified)
        #expect(!map.unverified.isEmpty)
    }
}
