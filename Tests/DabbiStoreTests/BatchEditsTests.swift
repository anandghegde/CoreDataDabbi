import DabbiBase
import DabbiSQLite
import DabbiTestSupport
import FixtureKit
import Foundation
import Testing

@testable import DabbiStore

/// EDT-4, EDT-6, EDT-7: batch edits with their preview, binary content, and composite elements — each one step
/// of the staged edits.
@Suite struct BatchEditsTests {
    private let access = StoreAccess.editable(WriteAuthorization(author: "Tests"))

    private func open(_ fixture: Fixture) async throws -> (StoreSession, FixtureLocation) {
        let location = try TestFixtures.scratchCopy(fixture)
        let session = try await StoreSession.open(
            storeURL: location.storeURL, modelURL: location.modelURL, access: access)
        return (session, location)
    }

    private func staged(_ session: StoreSession, _ ref: ObjectRef, _ property: String) async throws -> Value? {
        try await session.stagedObject(PendingObjectID(ref))[property]
    }

    private let samples = FetchSpec(entity: "Sample", sort: [SortKey(keyPath: "name")])

    // MARK: Batch edits

    @Test func batchUpdateSetsEveryScalarTypeOnTheSelectionAsOneEdit() async throws {
        let (session, _) = try await open(.basic)
        let refs = try await session.references(samples, limit: 3)
        let objects = refs.map(PendingObjectID.init)
        let date = Date(timeIntervalSince1970: 1_000_000)
        let uuid = UUID()
        let values: [(String, Value)] = [
            ("int16Value", .int(7)), ("int32Value", .int(-5)), ("int64Value", .int(1 << 40)),
            ("decimalValue", .decimal(Decimal(string: "1.25")!)), ("doubleValue", .double(2.5)),
            ("floatValue", .double(0.5)), ("stringValue", .string("batch")), ("boolValue", .bool(true)),
            ("dateValue", .date(date)), ("urlValue", .url(URL(string: "https://example.org")!)),
        ]
        for (property, value) in values {
            try await session.batchEdit(.set(value), attribute: property, entity: "Sample", target: .objects(objects))
        }
        for ref in refs {
            for (property, value) in values { #expect(try await staged(session, ref, property) == value) }
        }
        // A UUID is unique here: one object only.
        let (changed, changes) = try await session.batchEdit(
            .set(.uuid(uuid)), attribute: "uuidValue", entity: "Sample", target: .objects([objects[0]]))
        #expect(changed == 1)
        #expect(changes.undoActionName == "Batch Update uuidValue")
        #expect(changes.count(of: .updated) == 3)

        // Each batch is one step back.
        try await session.undo()
        try await session.undo()
        #expect(try await staged(session, refs[0], "urlValue") != .url(URL(string: "https://example.org")!))
        #expect(try await staged(session, refs[0], "dateValue") == .date(date))

        // Values are read as the attribute's type; one that is not refuses the whole batch.
        let refused = await #expect(throws: DabbiError.self) {
            try await session.batchEdit(
                .set(.string("x")), attribute: "int32Value", entity: "Sample", target: .objects(objects))
        }
        #expect(refused?.code == .invalidValue)
        let binary = await #expect(throws: DabbiError.self) {
            try await session.batchEdit(
                .set(.string("x")), attribute: "dataValue", entity: "Sample", target: .objects(objects))
        }
        #expect(binary?.code == .invalidValue)
        await session.close()
    }

    @Test func thePreviewCountsWhatWouldChangeAndShowsASampleWithoutStagingIt() async throws {
        let (session, _) = try await open(.basic)
        // All 40 rows; the 8 sparse ones have no string value, and 32 do.
        let preview = try await session.batchPreview(
            .set(.string("plain")), attribute: "stringValue", entity: "Sample", target: .fetch(samples),
            sampleSize: 3)
        #expect(preview.matched == 40)
        // Six rows in each strings cycle of 6 hold "plain" already; they would not change.
        let alreadyPlain = (0..<40).filter { $0 % 5 != 4 && $0 % 6 == 0 }.count
        #expect(preview.changing == 40 - alreadyPlain)
        #expect(preview.samples.count == 3)
        #expect(preview.samples.allSatisfy { $0.after == .string("plain") && $0.before != $0.after })
        #expect(preview.samples.first?.label?.hasPrefix("s") == true)
        #expect(try await session.pendingChanges().changes.isEmpty)
        #expect(try await session.pendingChanges().undoActionName.isEmpty)

        let (changed, _) = try await session.batchEdit(
            .set(.string("plain")), attribute: "stringValue", entity: "Sample", target: .fetch(samples))
        #expect(changed == preview.changing)
        // Nothing left to change.
        let again = try await session.batchPreview(
            .set(.string("plain")), attribute: "stringValue", entity: "Sample", target: .fetch(samples))
        #expect(again.changing == 0 && again.samples.isEmpty)
        await session.close()
    }

    @Test func findAndReplaceWorksOnPlainTextAndRegularExpressions() async throws {
        let (session, _) = try await open(.basic)
        let sparse = FetchSpec(entity: "Sample", predicate: PredicateSource(format: "name BEGINSWITH 'sparse'"))
        let all = FetchSpec(entity: "Sample")

        let plain = FindReplace(find: "SPARSE", replacement: "thin", ignoresCase: true)
        let preview = try await session.batchPreview(
            .replace(plain), attribute: "name", entity: "Sample", target: .fetch(all), sampleSize: 1)
        #expect(preview.matched == 40)
        #expect(preview.changing == 8)
        #expect(preview.samples.first.map { ($0.before, $0.after) }.map { "\($0.0)|\($0.1)" } != nil)
        if let sample = preview.samples.first, case .string(let before) = sample.before,
            case .string(let after) = sample.after
        {
            #expect(before.hasPrefix("sparse-") && after == before.replacingOccurrences(of: "sparse", with: "thin"))
        }
        // Case matters unless it is ignored.
        let exact = try await session.batchPreview(
            .replace(FindReplace(find: "SPARSE", replacement: "thin")), attribute: "name", entity: "Sample",
            target: .fetch(all))
        #expect(exact.changing == 0)

        let regex = FindReplace(find: #"^sample-(\d+)$"#, replacement: "row $1", isRegularExpression: true)
        let (changed, _) = try await session.batchEdit(
            .replace(regex), attribute: "name", entity: "Sample", target: .fetch(all))
        #expect(changed == 32)
        #expect(
            try await session.count(FetchSpec(entity: "Sample", predicate: PredicateSource(format: "name == 'row 12'")))
                == 1)
        #expect(try await session.count(sparse) == 8)

        let bad = await #expect(throws: DabbiError.self) {
            try await session.batchPreview(
                .replace(FindReplace(find: "(", replacement: "", isRegularExpression: true)), attribute: "name",
                entity: "Sample", target: .fetch(all))
        }
        #expect(bad?.code == .invalidValue)
        let notText = await #expect(throws: DabbiError.self) {
            try await session.batchEdit(
                .replace(plain), attribute: "int32Value", entity: "Sample", target: .fetch(all))
        }
        #expect(notText?.code == .invalidValue)
        await session.close()
    }

    @Test func nullifyEmptiesAnAttributeAndCountsOnlyWhatHadAValue() async throws {
        let (session, location) = try await open(.basic)
        let all = FetchSpec(entity: "Sample")
        let preview = try await session.batchPreview(
            .nullify, attribute: "dataValue", entity: "Sample", target: .fetch(all))
        #expect(preview.changing == 32)
        #expect(preview.samples.allSatisfy { $0.after == .null })
        let (changed, _) = try await session.batchEdit(
            .nullify, attribute: "dataValue", entity: "Sample", target: .fetch(all))
        #expect(changed == 32)
        #expect(
            try await session.count(FetchSpec(entity: "Sample", predicate: PredicateSource(format: "dataValue != nil")))
                == 0)

        _ = try await session.commit()
        let connection = try SQLiteConnection(readOnly: location.storeURL)
        defer { connection.close() }
        #expect(try connection.scalar("SELECT COUNT(*) FROM ZSAMPLE WHERE ZDATAVALUE IS NOT NULL") == .integer(0))
        await session.close()
    }

    @Test func aBatchCoversObjectsOnlyInsertedAndRefusesAReadOnlyStore() async throws {
        let (session, _) = try await open(.basic)
        let (inserted, _) = try await session.insertObject(entity: "Sample")
        let (changed, _) = try await session.batchEdit(
            .set(.int(3)), attribute: "int32Value", entity: "Sample", target: .objects([inserted]))
        #expect(changed == 1)
        #expect(try await session.stagedObject(inserted)["int32Value"] == .int(3))
        let preview = try await session.batchPreview(
            .set(.int(4)), attribute: "int32Value", entity: "Sample", target: .fetch(FetchSpec(entity: "Sample")))
        #expect(preview.matched == 41)
        await session.close()

        let location = try TestFixtures.scratchCopy(.basic)
        let readOnly = try await StoreSession.open(storeURL: location.storeURL, modelURL: location.modelURL)
        let refused = await #expect(throws: DabbiError.self) {
            try await readOnly.batchEdit(
                .nullify, attribute: "name", entity: "Sample", target: .fetch(FetchSpec(entity: "Sample")))
        }
        #expect(refused != nil)
        await readOnly.close()
    }

    // MARK: Binary content

    @Test func binaryContentIsReplacedSavedAndClearedIncludingExternalStorage() async throws {
        let (session, location) = try await open(.externalData)
        let spec = FetchSpec(entity: "Document", sort: [SortKey(keyPath: "title")])
        let refs = try await session.references(spec)
        let small = PendingObjectID(refs[0])
        let large = PendingObjectID(refs[4])

        // Replaced from a file, large enough to go outside the database.
        let file = location.directory.appendingPathComponent("payload.bin")
        let bytes = Data((0..<600_000).map { UInt8(truncatingIfNeeded: $0 &* 31) })
        try bytes.write(to: file)
        let changes = try await session.setData(contentsOf: file, for: "payload", of: small)
        #expect(changes.undoActionName == "Replace payload")
        #expect(try await session.stagedData(of: small, attribute: "payload") == bytes)

        // Saved: the external one reads through to its file.
        let external = try #require(try await session.stagedData(of: large, attribute: "payload"))
        #expect(external.count == 1_200_000)

        // Cleared.
        try await session.setData(nil, for: "payload", of: large)
        #expect(try await session.stagedData(of: large, attribute: "payload") == nil)

        _ = try await session.commit()
        await session.close()
        let reopened = try await StoreSession.open(storeURL: location.storeURL, modelURL: location.modelURL)
        #expect(try await reopened.blob(for: refs[0], attribute: "payload") == bytes)
        #expect(try await reopened.blob(for: refs[4], attribute: "payload") == nil)
        await reopened.close()
    }

    @Test func onlyABinaryAttributeTakesBytes() async throws {
        let (session, _) = try await open(.basic)
        let ref = try #require(try await session.references(samples, limit: 1).first)
        let object = PendingObjectID(ref)
        let text = await #expect(throws: DabbiError.self) {
            try await session.setData(Data([1]), for: "name", of: object)
        }
        #expect(text?.code == .invalidValue)
        // A transformable's bytes are an archive: it can be emptied, not given other bytes.
        let archive = await #expect(throws: DabbiError.self) {
            try await session.setData(Data([1]), for: "keywords", of: object)
        }
        #expect(archive?.code == .invalidValue)
        try await session.setData(nil, for: "keywords", of: object)
        #expect(try await session.stagedData(of: object, attribute: "keywords") == nil)
        let missing = await #expect(throws: DabbiError.self) {
            try await session.setData(
                contentsOf: URL(fileURLWithPath: "/nonexistent/file"), for: "dataValue", of: object)
        }
        #expect(missing?.code == .invalidValue)
        await session.close()
    }

    // MARK: Composites

    @Test func aCompositeElementIsEditedAndTheOthersKeepTheirValues() async throws {
        let (session, location) = try await open(.composites)
        let places = try await session.references(FetchSpec(entity: "Place", sort: [SortKey(keyPath: "name")]))
        let first = PendingObjectID(places[0])  // Place 0: Mumbai
        let empty = PendingObjectID(places[3])  // Place 3: no address

        let changes = try await session.setElement(.string("Nagpur"), at: "address.city", of: first)
        #expect(changes.undoActionName == "Edit address.city")
        try await session.setElement(.double(21.1), at: "address.location.latitude", of: first)
        guard case .composite(let address) = try await session.stagedObject(first)["address"],
            case .composite(let position) = address["location"]
        else {
            Issue.record("no address")
            return
        }
        #expect(address["city"] == .string("Nagpur"))
        #expect(address["street"] == .string("1 Tiffin Lane"))
        #expect(position["latitude"] == .double(21.1))
        #expect(position["longitude"] == .double(72.8))

        // A place with no address gets one, with only the element given.
        try await session.setElement(.string("Goa"), at: "address.city", of: empty)
        guard case .composite(let made) = try await session.stagedObject(empty)["address"] else {
            Issue.record("no address")
            return
        }
        #expect(made["city"] == .string("Goa"))
        #expect(made["street"] == .null)

        // Elements are typed like attributes.
        let wrong = await #expect(throws: DabbiError.self) {
            try await session.setElement(.string("north"), at: "address.location.latitude", of: first)
        }
        #expect(wrong?.code == .invalidValue)
        let unknown = await #expect(throws: DabbiError.self) {
            try await session.setElement(.string("x"), at: "address.country", of: first)
        }
        #expect(unknown?.code == .unknownProperty)
        let notComposite = await #expect(throws: DabbiError.self) {
            try await session.setElement(.string("x"), at: "name.first", of: first)
        }
        #expect(notComposite?.code == .unknownProperty)

        try await session.undo()
        _ = try await session.commit()
        await session.close()
        let reopened = try await StoreSession.open(storeURL: location.storeURL, modelURL: location.modelURL)
        #expect(
            try await reopened.count(
                FetchSpec(entity: "Place", predicate: PredicateSource(format: "address.city == 'Nagpur'"))) == 1)
        #expect(
            try await reopened.count(
                FetchSpec(entity: "Place", predicate: PredicateSource(format: "address.city == 'Goa'"))) == 0)
        await reopened.close()
    }
}
