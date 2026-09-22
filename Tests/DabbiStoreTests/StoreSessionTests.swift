import DabbiBase
import DabbiModel
import DabbiTestSupport
import FixtureKit
import Foundation
import Testing

@testable import DabbiStore

private func open(_ fixture: Fixture) async throws -> StoreSession {
    let location = try TestFixtures.location(fixture)
    return try await StoreSession.open(storeURL: location.storeURL, modelURL: location.modelURL)
}

/// All rows of `spec`, as `[property: Value]` in fetch order.
private func rows(_ session: StoreSession, _ spec: FetchSpec) async throws -> [[String: Value]] {
    let pager = try await session.openPager(spec)
    let page = try await session.page(pager, range: 0..<pager.count)
    await session.closePager(pager)
    return page.rows.map { row in
        Dictionary(uniqueKeysWithValues: zip(page.columns.properties, row.values))
    }
}

/// Primary keys are handed out at save time, in no promised order — so tests find rows by what they contain.
private func rows(_ session: StoreSession, _ spec: FetchSpec, by key: String) async throws -> [String: [String: Value]]
{
    var byKey: [String: [String: Value]] = [:]
    for row in try await rows(session, spec) {
        if case .string(let name) = row[key] { byKey[name] = row }
    }
    return byKey
}

@Suite struct StoreOpeningTests {
    @Test(arguments: Fixture.allCases)
    func opensWhatItShouldAndRefusesTheRest(_ fixture: Fixture) async throws {
        let location = try TestFixtures.location(fixture)
        guard location.manifest.kind == .coreDataStore else {
            let error = await #expect(throws: DabbiError.self) { try await open(fixture) }
            #expect(error?.code == (location.manifest.kind == .plainSQLite ? .notCoreData : .notSQLite))
            return
        }
        let session = try await open(fixture)
        #expect(session.info.accessMode == .readOnly)
        #expect(session.info.schemaMap.isVerified)
        let counts = try await session.entityCounts()
        #expect(
            Dictionary(uniqueKeysWithValues: counts.map { ($0.entity, $0.total) }) == location.manifest.entityCounts)
        await session.close()
    }

    @Test func openingLeavesTheStoreUntouched() async throws {
        let location = try TestFixtures.scratchCopy(.company)
        func fingerprint() throws -> [String: Data] {
            var files: [String: Data] = [:]
            for name in try FileManager.default.contentsOfDirectory(atPath: location.directory.path) {
                // The -shm is the shared memory of everyone who has the database open, readers included: the
                // first of them rebuilds the index in it. That it exists is compared; what is in it is not.
                files[name] =
                    name.hasSuffix("-shm")
                    ? Data() : try Data(contentsOf: location.directory.appendingPathComponent(name))
            }
            return files
        }
        let before = try fingerprint()
        let session = try await StoreSession.open(storeURL: location.storeURL)
        _ = try await rows(session, FetchSpec(entity: "Person"))
        await session.close()
        #expect(try fingerprint() == before)
    }

    @Test func aStoreWithoutItsModelExplainsItself() async throws {
        let location = try TestFixtures.location(.noModelCache)
        let error = await #expect(throws: DabbiError.self) { try await StoreSession.open(storeURL: location.storeURL) }
        #expect(error?.code == .modelCacheMissing)
    }

    @Test func aMissingFileIsReported() async {
        let error = await #expect(throws: DabbiError.self) {
            try await StoreSession.open(storeURL: URL(fileURLWithPath: "/nonexistent/App.sqlite"))
        }
        #expect(error?.code == .fileNotFound)
    }

    @Test func aClosedSessionRefusesEverything() async throws {
        let session = try await open(.basic)
        let pager = try await session.openPager(FetchSpec(entity: "Sample"))
        await session.close()
        await session.close()  // closing twice is fine
        for attempt: @Sendable () async throws -> Void in [
            { _ = try await session.count(FetchSpec(entity: "Sample")) },
            { _ = try await session.entityCounts() },
            { _ = try await session.openPager(FetchSpec(entity: "Sample")) },
            { _ = try await session.page(pager, range: 0..<1) },
        ] {
            let error = await #expect(throws: DabbiError.self) { try await attempt() }
            #expect(error?.code == .storeClosed)
        }
    }
}

@Suite struct PagingTests {
    @Test func defaultOrderIsPrimaryKeyOrder() async throws {
        let session = try await open(.basic)
        let pager = try await session.openPager(FetchSpec(entity: "Sample"))
        #expect(pager.count == 40)
        let page = try await session.page(pager, range: 0..<40)
        #expect(page.rows.map(\.ref.pk) == Array(1...40))
        #expect(page.rows.allSatisfy { $0.values.count == page.columns.properties.count })
        await session.close()
    }

    @Test func pagesAreSlicesOfOneList() async throws {
        let session = try await open(.company)
        let spec = FetchSpec(
            entity: "Person", sort: [SortKey(keyPath: "age", ascending: false), SortKey(keyPath: "name")])
        let pager = try await session.openPager(spec)
        let whole = try await session.page(pager, range: 0..<pager.count)
        let middle = try await session.page(pager, range: 17..<31)
        #expect(middle.range == 17..<31)
        #expect(middle.rows == Array(whole.rows[17..<31]))

        let ageIndex = try #require(whole.columns.index(of: "age"))
        let ages = whole.rows.map { row -> Int64 in if case .int(let age) = row.values[ageIndex] { age } else { -1 } }
        #expect(ages == ages.sorted(by: >))
        await session.close()
    }

    @Test func rangesAreClamped() async throws {
        let session = try await open(.basic)
        let pager = try await session.openPager(FetchSpec(entity: "Sample"))
        let tail = try await session.page(pager, range: 35..<500)
        #expect(tail.range == 35..<40 && tail.rows.count == 5)
        let beyond = try await session.page(pager, range: 100..<200)
        #expect(beyond.rows.isEmpty)
        await session.close()
    }

    @Test func aPageLargerThanOneChunkKeepsItsOrder() async throws {
        // 60 people fetched three to a chunk exercises the stitching that 200-row chunks do on big stores.
        let session = try await open(.company)
        let pager = try await session.openPager(FetchSpec(entity: "Party", sort: [SortKey(keyPath: "name")]))
        let page = try await session.page(pager, range: 0..<pager.count)
        let nameIndex = try #require(page.columns.index(of: "name"))
        let names = page.rows.map { $0.values[nameIndex].displayString() }
        #expect(names.count == 63)
        #expect(names == names.sorted())
        await session.close()
    }

    @Test func limitAndPredicateAndExactEntity() async throws {
        let session = try await open(.company)
        #expect(try await session.count(FetchSpec(entity: "Person")) == 60)
        #expect(try await session.count(FetchSpec(entity: "Person", includeSubentities: false)) == 35)
        #expect(
            try await session.count(
                FetchSpec(entity: "Employee", predicate: PredicateSource(format: "title == 'Engineer'"))) == 10)
        var limited = FetchSpec(entity: "Person")
        limited.limit = 7
        #expect(try await session.openPager(limited).count == 7)

        let exact = try await rows(session, FetchSpec(entity: "Employee", includeSubentities: false))
        #expect(exact.count == 20 && exact.allSatisfy { $0["level"] == nil })
        let all = try await session.openPager(FetchSpec(entity: "Employee"))
        #expect(all.columns.properties.contains("level"))  // what Manager adds
        await session.close()
    }

    @Test func invalidationMakesPagersStale() async throws {
        let session = try await open(.basic)
        let pager = try await session.openPager(FetchSpec(entity: "Sample"))
        await session.invalidate()
        let error = await #expect(throws: DabbiError.self) { try await session.page(pager, range: 0..<10) }
        #expect(error?.code == .stalePager)

        let fresh = try await session.openPager(FetchSpec(entity: "Sample"))
        #expect(fresh.generation == pager.generation + 1)
        #expect(try await session.page(fresh, range: 0..<10).rows.count == 10)
        await session.closePager(fresh)
        let closed = await #expect(throws: DabbiError.self) { try await session.page(fresh, range: 0..<10) }
        #expect(closed?.code == .stalePager)
        await session.close()
    }
}

@Suite struct ValueConversionTests {
    @Test func everyAttributeType() async throws {
        let session = try await open(.basic)
        let all = try await rows(session, FetchSpec(entity: "Sample"), by: "name")
        func sample(_ index: Int) throws -> [String: Value] { try #require(all["sample-\(index)"]) }
        #expect(all.count == 40)
        #expect(try sample(0)["int64Value"] == .int(.max))
        #expect(try sample(1)["int64Value"] == .int(.min))
        #expect(try sample(2)["int16Value"] == .int(50))
        #expect(try sample(2)["int32Value"] == .int(-200_000))
        #expect(try sample(2)["decimalValue"] == .decimal(Decimal(string: "2.0014")!))
        #expect(try sample(2)["doubleValue"] == .double(-4.25))
        #expect(try sample(2)["floatValue"] == .double(Double(Float(2) / 3)))
        #expect(try sample(2)["boolValue"] == .bool(true))
        #expect(try sample(3)["boolValue"] == .bool(false))
        #expect(try sample(2)["stringValue"] == .string("naïve café"))
        #expect(try sample(1)["stringValue"] == .string(""))
        #expect(try sample(3)["stringValue"] == .string("日本語のテキスト"))
        #expect(try sample(2)["urlValue"] == .url(URL(string: "https://example.org/samples/2?q=dabbi")!))
        if case .uuid = try sample(2)["uuidValue"] {} else { Issue.record("uuidValue is not a UUID") }
        if case .date(let date) = try sample(2)["dateValue"], case .date(let next) = try sample(3)["dateValue"] {
            #expect(next.timeIntervalSince(date) == 86_400.5)
        } else {
            Issue.record("dateValue is not a date")
        }
        #expect(try sample(2)["dataValue"] == .blob(BlobSummary(byteCount: 32, sniffedType: nil, isExternal: false)))
        await session.close()
    }

    @Test func unsetOptionalsAreNullAndDefaultsApply() async throws {
        let session = try await open(.basic)
        let sparse = try await rows(
            session, FetchSpec(entity: "Sample", predicate: PredicateSource(format: "name BEGINSWITH 'sparse-'")))
        #expect(sparse.count == 8)
        for row in sparse {
            for property in [
                "stringValue", "dateValue", "dataValue", "uuidValue", "urlValue", "decimalValue", "colour",
                "int32Value",
            ] {
                #expect(row[property] == .null, "\(property)")
            }
            #expect(row["boolValue"] == .bool(false) && row["int16Value"] == .int(0))  // model defaults
        }
        await session.close()
    }

    @Test func transformablesAreNeverDecoded() async throws {
        let session = try await open(.basic)
        let named = FetchSpec(entity: "Sample", predicate: PredicateSource(format: "name == 'sample-0'"))
        let first = try #require(try await rows(session, named).first)
        // Both come back as the bytes on disk: the app's own transformer (JSON here) is not available to us, and
        // the secure-coding default (a keyed archive) is never unarchived.
        let expected: [String: ContentTypeID] = ["colour": .json, "keywords": .binaryPlist]
        for (property, type) in expected {
            guard case .blob(let summary) = first[property] else {
                Issue.record("\(property) is \(String(describing: first[property]))")
                continue
            }
            #expect(summary.byteCount > 0 && summary.sniffedType == type, "\(property)")
        }
        let pager = try await session.openPager(named)
        let ref = try #require(try await session.page(pager, range: 0..<1).rows.first?.ref)
        let archive = try #require(try await session.blob(for: ref, attribute: "keywords"))
        #expect(archive.starts(with: Data("bplist00".utf8)))
        let colour = try #require(try await session.blob(for: ref, attribute: "colour"))
        #expect(String(decoding: colour, as: UTF8.self) == #"{"blue":1,"green":0.5,"red":0}"#)
        await session.close()
    }

    @Test func composites() async throws {
        let session = try await open(.composites)
        let withAddress = FetchSpec(entity: "Place", predicate: PredicateSource(format: "address.city != nil"))
        let place = try #require(try await rows(session, withAddress).first)
        guard case .composite(let address) = place["address"], case .composite(let location) = address["location"]
        else {
            Issue.record("address is \(String(describing: place["address"]))")
            return
        }
        #expect(Set(address.keys) == ["street", "city", "location"])
        #expect(Set(location.keys) == ["latitude", "longitude"])
        if case .double = location["latitude"] {
        } else {
            Issue.record("latitude is \(String(describing: location["latitude"]))")
        }

        #expect(
            try await session.count(
                FetchSpec(entity: "Place", predicate: PredicateSource(format: "address.location.latitude > -1000")))
                == 8)
        // Two places have no address at all: the whole composite is nil, not a dictionary of nils.
        let without = try await rows(
            session, FetchSpec(entity: "Place", predicate: PredicateSource(format: "address.city == nil")))
        #expect(without.count == 2 && without.allSatisfy { $0["address"] == .null })
        let sorted = try await rows(session, FetchSpec(entity: "Place", sort: [SortKey(keyPath: "address.city")]))
        let cities = sorted.compactMap { row -> String? in
            if case .composite(let address) = row["address"], case .string(let city) = address["city"] {
                city
            } else {
                nil
            }
        }
        #expect(sorted.count == 10 && cities.count == 8)
        #expect(cities == cities.sorted())
        await session.close()
    }

    /// PRJ-11: what SwiftData makes of `@Model` classes is an ordinary Core Data schema, read through the model
    /// the store caches — there is no other to be had.
    @Test func aSwiftDataStoreReadsLikeAnyOther() async throws {
        let session = try await open(.swiftData)
        #expect(session.info.modelSource == .storeCache)
        let trips = try await rows(session, FetchSpec(entity: "Trip"), by: "name")
        let trip = try #require(trips["Trip 0"])
        #expect(trip["notes"] == .string("Booked through the office.") && trips["Trip 1"]?["notes"] == .null)
        // A Codable enum is a composite of one attribute; a Codable struct one of its properties.
        #expect(trip["kind"] == .composite(["kind": .string("business")]))
        // `[String]` is a transformable: a keyed archive, never unarchived.
        guard case .blob(let tags) = trip["tags"] else {
            Issue.record("tags is \(String(describing: trip["tags"]))")
            return
        }
        #expect(tags.sniffedType == .binaryPlist)

        let stops = try await rows(session, FetchSpec(entity: "Stop"), by: "city")
        #expect(stops["City 1.1"]?["position"] == .composite(["latitude": .double(49), "longitude": .double(12)]))
        #expect(stops["City 1.1"]?["nights"] == .int(2))
        #expect(
            try await session.count(
                FetchSpec(entity: "Stop", predicate: PredicateSource(format: "trip.name == 'Trip 2'"))) == 2)
        await session.close()
    }

    @Test func derivedAttributesReadLikeAnyOther() async throws {
        let session = try await open(.derived)
        let lists = try await rows(session, FetchSpec(entity: "List"))
        let total = lists.reduce(Int64(0)) { sum, row in
            if case .int(let count) = row["itemCount"] { sum + count } else { sum }
        }
        #expect(total == 18)
        for row in lists {
            guard case .int(let derived) = row["itemCount"], case .toMany(let counted) = row["items"] else {
                Issue.record("unexpected \(row)")
                continue
            }
            #expect(Int(derived) == counted)
        }
        await session.close()
    }
}

@Suite struct RelationshipTests {
    @Test func toOneShowsTheDestinationsName() async throws {
        let session = try await open(.company)
        let employees = try await rows(session, FetchSpec(entity: "Employee", includeSubentities: false), by: "name")
        let seventh = try #require(employees["Employee 7"])
        guard case .toOne(let boss?, let display) = seventh["boss"] else {
            Issue.record("boss is \(String(describing: seventh["boss"]))")
            return
        }
        // The relationship is declared to Person; the reference names what the row really is.
        #expect(boss.entity == "Manager" && display == "Manager 2")
        #expect(seventh["department"]?.displayString() == "Department 3")

        let people = try await rows(session, FetchSpec(entity: "Person", includeSubentities: false), by: "name")
        #expect(people["Person 1"]?["boss"] == .toOne(nil, display: nil))
        #expect(people["Person 3"]?["boss"]?.displayString() == "Employee 3")
        await session.close()
    }

    @Test func toOneDisplayUsesTheFirstNameLikeAttribute() async throws {
        let session = try await open(.ordered)
        let track = try #require(try await rows(session, FetchSpec(entity: "Track")).first)
        #expect(track["playlist"]?.displayString().hasPrefix("Playlist ") == true)
        await session.close()
    }

    @Test func toManyCountsBatchedThroughTheInverse() async throws {
        let session = try await open(.company)
        let managers = try await rows(session, FetchSpec(entity: "Manager"))
        #expect(managers.map { $0["reports"] } == Array(repeating: .toMany(count: 4), count: 5))

        let departments = try await rows(session, FetchSpec(entity: "Department"))
        let staff = departments.map { row -> Int in if case .toMany(let count) = row["employees"] { count } else { -1 }
        }
        #expect(staff.reduce(0, +) == 25 && staff.allSatisfy { $0 > 0 })

        // Rows without any get zero, not a missing value; and the batch counts sub-entity rows on both sides.
        let people = try await rows(session, FetchSpec(entity: "Person"), by: "name")
        #expect(people["Person 1"]?["reports"] == .toMany(count: 0))
        #expect(people["Employee 0"]?["reports"] == .toMany(count: 1))  // Person 0
        #expect(people["Employee 2"]?["reports"] == .toMany(count: 0))
        #expect(people["Manager 4"]?["reports"] == .toMany(count: 4))
        await session.close()
    }

    @Test func toManyCountsAcrossAJoinTable() async throws {
        let session = try await open(.company)
        let employees = try await rows(session, FetchSpec(entity: "Employee", includeSubentities: false))
        #expect(employees.allSatisfy { $0["tags"] == .toMany(count: 2) })
        let tags = try await rows(session, FetchSpec(entity: "Tag"))
        let tagged = tags.reduce(0) { sum, row in
            if case .toMany(let count) = row["people"] { sum + count } else { sum }
        }
        #expect(tagged == 20 * 2 + 18)  // two per employee, one per even-numbered person
        await session.close()
    }

    @Test func orderedToManyCounts() async throws {
        let session = try await open(.ordered)
        let playlists = try await rows(session, FetchSpec(entity: "Playlist"))
        #expect(playlists.allSatisfy { $0["featured"] == .toMany(count: 3) })
        let owned = playlists.reduce(0) { sum, row in
            if case .toMany(let count) = row["tracks"] { sum + count } else { sum }
        }
        #expect(owned == 12)
        await session.close()
    }

    @Test func predicatesAndSortsFollowRelationships() async throws {
        let session = try await open(.company)
        #expect(
            try await session.count(
                FetchSpec(entity: "Employee", predicate: PredicateSource(format: "boss.name == 'Manager 2'"))) == 4)
        #expect(
            try await session.count(
                FetchSpec(
                    entity: "Person", predicate: PredicateSource(format: "ANY tags.label != nil AND reports.@count > 0")
                )) > 0)
        #expect(
            try await session.count(
                FetchSpec(
                    entity: "Department",
                    predicate: PredicateSource(format: "SUBQUERY(employees, $e, $e.age > 40).@count > 0"))) > 0)
        let sorted = try await rows(
            session,
            FetchSpec(
                entity: "Employee", includeSubentities: false,
                sort: [SortKey(keyPath: "boss.name"), SortKey(keyPath: "name")]))
        #expect(sorted.first?["boss"]?.displayString() == "Manager 0")
        #expect(sorted.last?["boss"]?.displayString() == "Manager 4")
        await session.close()
    }
}

@Suite struct SingleObjectTests {
    @Test func anObjectIsDescribedByItsOwnEntity() async throws {
        let session = try await open(.company)
        let pager = try await session.openPager(
            FetchSpec(entity: "Party", predicate: PredicateSource(format: "name == 'Manager 3'")))
        let ref = try #require(try await session.page(pager, range: 0..<1).rows.first?.ref)
        #expect(ref.entity == "Manager")

        let snapshot = try await session.object(ref)
        #expect(snapshot.row.ref == ref)
        #expect(snapshot["level"] == .int(1))  // a Manager column, although the fetch was on Party
        #expect(snapshot["name"] == .string("Manager 3"))
        #expect(snapshot["salary"] == .decimal(Decimal(string: "105000.5")!))
        #expect(snapshot["nothing"] == nil)
        await session.close()
    }

    @Test func objectsThatDoNotExist() async throws {
        let session = try await open(.company)
        let pager = try await session.openPager(FetchSpec(entity: "Tag"))
        let real = try #require(try await session.page(pager, range: 0..<1).rows.first?.ref)

        let goneURI = try #require(
            URL(string: real.uri.absoluteString.replacingOccurrences(of: "/p\(real.pk)", with: "/p99999")))
        let gone = try #require(ObjectRef(uri: goneURI))
        let missing = await #expect(throws: DabbiError.self) { try await session.object(gone) }
        #expect(missing?.code == .objectNotFound)

        let foreignURI = try #require(URL(string: "x-coredata://00000000-0000-4000-8000-000000000000/Tag/p1"))
        let foreign = await #expect(throws: DabbiError.self) {
            try await session.object(try #require(ObjectRef(uri: foreignURI)))
        }
        #expect(foreign?.code == .objectNotFound)
        await session.close()
    }

    @Test func blobsInlineAndExternal() async throws {
        let session = try await open(.externalData)
        let pager = try await session.openPager(FetchSpec(entity: "Document", sort: [SortKey(keyPath: "title")]))
        let page = try await session.page(pager, range: 0..<pager.count)  // "Document 0" … "Document 5"
        let payloadIndex = try #require(page.columns.index(of: "payload"))
        let sizes = page.rows.map { row -> Int? in
            if case .blob(let summary) = row.values[payloadIndex] { summary.byteCount } else { nil }
        }
        #expect(sizes == [512, 4_096, 150_000, 400_000, 1_200_000, nil])
        #expect(
            page.rows[4].values[payloadIndex]
                == .blob(BlobSummary(byteCount: 1_200_000, sniffedType: .png, isExternal: true)))

        // The fixture really does keep the big ones outside the database.
        let support = try TestFixtures.location(.externalData).directory.appendingPathComponent(
            ".External_SUPPORT/_EXTERNAL_DATA")
        #expect(try FileManager.default.contentsOfDirectory(atPath: support.path).isEmpty == false)

        let large = try #require(try await session.blob(for: page.rows[4].ref, attribute: "payload"))
        #expect(large.count == 1_200_000 && large.starts(with: [0x89, 0x50, 0x4E, 0x47]))
        let small = try #require(try await session.blob(for: page.rows[0].ref, attribute: "thumbnail"))
        #expect(small.count == 72)
        #expect(try await session.blob(for: page.rows[5].ref, attribute: "payload") == nil)

        let unknown = await #expect(throws: DabbiError.self) {
            try await session.blob(for: page.rows[0].ref, attribute: "nope")
        }
        #expect(unknown?.code == .unknownProperty)
        await session.close()
    }

    @Test func memoryStaysBoundedBecauseTheContextIsReset() async throws {
        let session = try await open(.externalData)
        let pager = try await session.openPager(FetchSpec(entity: "Document"))
        // Rows are values: they stay valid after the context that produced them has been emptied, again and again.
        let first = try await session.page(pager, range: 0..<pager.count)
        for _ in 0..<5 { #expect(try await session.page(pager, range: 0..<pager.count) == first) }
        await session.close()
    }
}
