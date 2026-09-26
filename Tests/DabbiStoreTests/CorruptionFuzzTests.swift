import DabbiBase
import DabbiModel
import DabbiTestSupport
import FixtureKit
import Foundation
import Testing

@testable import DabbiSQLite
@testable import DabbiStore

/// PRD §10 Reliability: no sequence of edits, undos, discards and commits leaves a store corrupted.
///
/// Each run stages random edits against a copy of a fixture — values of every type, some out of range or `nil`,
/// to-ones, inserts, deletes with their rules, links and unlinks, undo and redo, discards — and commits every
/// so often. A `DabbiError` is an answer, not a failure; anything else is a bug. After every commit that goes
/// through the file must be sound (`StoreSoundness`); after every one that is refused it must be exactly as it
/// was. At the end, the store opens afresh and holds what the last commit left.
///
/// The short variant runs three seeds per fixture in the normal suite. `Scripts/soak.sh` runs many more, longer:
/// `DABBI_FUZZ_SEEDS` and `DABBI_FUZZ_STEPS` set how many. A failure names its seed; `DABBI_FUZZ_SEED` runs that
/// seed alone and `DABBI_FUZZ_TRACE` prints its steps. Each test process builds the fixtures afresh, and which
/// rows get which primary keys can differ from one build to the next, so a seed may take a few runs to fail again.
@Suite struct CorruptionFuzzTests {
    /// Every fixture a session opens editable. Not here: `.notCoreData` and `.encrypted` do not open at all,
    /// `.large` is a million rows of the same shapes as `.basic`, and `.appBundle`, `.noModelCache`,
    /// `.versioned` and `.merged` are about finding the model — once found, it is one of these shapes again.
    static let fixtures: [Fixture] = [
        .basic, .company, .ordered, .composites, .derived, .externalData, .history, .walOnly, .swiftData,
    ]

    private static let environment = ProcessInfo.processInfo.environment
    private static let soaking = environment["DABBI_SOAK"] != nil
    static let seeds: [UInt64] =
        if let seed = environment["DABBI_FUZZ_SEED"].flatMap(UInt64.init) {
            [seed]
        } else {
            soaking ? Array(1...UInt64(environment["DABBI_FUZZ_SEEDS"].flatMap(Int.init) ?? 50)) : [1, 2, 3]
        }
    /// `DABBI_FUZZ_TRACE` prints each step to standard error: what was tried and how it went, never a value.
    static let tracing = environment["DABBI_FUZZ_TRACE"] != nil
    static let steps = environment["DABBI_FUZZ_STEPS"].flatMap(Int.init) ?? (soaking ? 400 : 80)

    @Test(arguments: fixtures)
    func randomEditsAndCommitsLeaveTheStoreSound(_ fixture: Fixture) async throws {
        for seed in Self.seeds {
            try await Fuzzer.run(fixture, seed: seed, steps: Self.steps)
        }
    }

    /// The fuzzer's own soundness check finds what it is there to find: a row that points at nothing.
    @Test func theSoundnessCheckFindsADanglingReference() async throws {
        let location = try TestFixtures.scratchCopy(.company)
        let session = try await StoreSession.open(storeURL: location.storeURL, modelURL: location.modelURL)
        let (model, schema) = (session.info.model, session.info.schemaMap)
        await session.close()
        #expect(try StoreSoundness.fileProblems(of: location.storeURL, model: model, schema: schema).isEmpty)

        // Employee.department, whose inverse Core Data keeps; the one-way Department.head it does not.
        let relationship = try #require(schema.entities["Employee"]?.relationships["department"])
        let connection = try SQLiteConnection.writable(at: location.storeURL)
        try connection.execute("UPDATE \(relationship.table) SET \(relationship.column) = 999999")
        let employeeCount = try connection.scalar(
            "SELECT count(*) FROM \(relationship.table) WHERE \(relationship.column) IS NOT NULL")?.int64
        connection.close()

        let problems = try StoreSoundness.fileProblems(of: location.storeURL, model: model, schema: schema)
        #expect(problems == ["Employee.department: \(try #require(employeeCount)) references to no row"])
    }

    /// And a primary key Core Data has not handed out, which the next insert would collide with.
    @Test func theSoundnessCheckFindsAPrimaryKeyPastItsMaximum() async throws {
        let location = try TestFixtures.scratchCopy(.basic)
        let session = try await StoreSession.open(storeURL: location.storeURL, modelURL: location.modelURL)
        let (model, schema) = (session.info.model, session.info.schemaMap)
        await session.close()

        let connection = try SQLiteConnection.writable(at: location.storeURL)
        try connection.execute("UPDATE Z_PRIMARYKEY SET Z_MAX = 1")
        connection.close()

        let problems = try StoreSoundness.fileProblems(of: location.storeURL, model: model, schema: schema)
        #expect(problems.contains { $0.contains("is past Z_MAX") })
    }
}

/// One fuzzing run: a fixture, a seed, a number of steps.
private struct Fuzzer {
    let fixture: Fixture
    let seed: UInt64
    let session: StoreSession
    let location: FixtureLocation
    let model: ModelDescription
    var random: SeededGenerator
    /// Objects to edit, by their own entity: a sample of saved rows, and what was inserted since the last commit.
    var pool: [String: [PendingObjectID]] = [:]
    /// Each entity's own count as the last commit left it.
    var expected: [String: Int] = [:]
    var commits = (succeeded: 0, refused: 0)

    private static let access = StoreAccess.editable(WriteAuthorization(author: "Fuzz"))

    static func run(_ fixture: Fixture, seed: UInt64, steps: Int) async throws {
        let location = try TestFixtures.scratchCopy(fixture)
        let session = try await StoreSession.open(
            storeURL: location.storeURL, modelURL: location.modelURL, access: access)
        var fuzzer = Fuzzer(
            fixture: fixture, seed: seed, session: session, location: location, model: session.info.model,
            random: SeededGenerator(seed: seed))
        do {
            try await fuzzer.start()
            for step in 0..<steps { try await fuzzer.step(step) }
            try await fuzzer.commit(steps)
            try await fuzzer.finish()
        } catch {
            await session.close()
            throw error
        }
    }

    private var context: String { "\(fixture) seed \(seed)" }

    /// The entities that can have objects of their own.
    private var concreteEntities: [EntityDescription] { model.entities.filter { !$0.isAbstract } }

    mutating func start() async throws {
        expected = try await StoreSoundness.counts(in: session)
        try await refillPool()
    }

    mutating func refillPool() async throws {
        pool = [:]
        for entity in concreteEntities {
            let spec = FetchSpec(entity: entity.name, includeSubentities: false)
            pool[entity.name] = try await session.references(spec, limit: 8).map(PendingObjectID.init)
        }
    }

    // MARK: - Steps

    mutating func step(_ number: Int) async throws {
        let roll = Int.random(in: 0..<100, using: &random)
        switch roll {
        case 0..<35: try await setAttribute(number)
        case 35..<45: try await setToOne(number)
        case 45..<55: try await insert(number)
        case 55..<62: try await delete(number)
        case 62..<72: try await linkOrUnlink(number)
        case 72..<80:
            try await attempt("undo", step: number) { try await session.undo() }
        case 80..<85:
            try await attempt("redo", step: number) { try await session.redo() }
        case 85..<88:
            if try await attempt("discard", step: number, { try await session.discardChanges() }) != nil {
                try await refillPool()
            }
        default:
            try await commit(number)
        }
    }

    /// Runs one operation. A `DabbiError` is the engine saying no, which is fine; anything else is recorded
    /// against the seed and the step, and names what was tried — never a value.
    @discardableResult
    func attempt<T>(_ what: String, step: Int, _ body: () async throws -> T) async throws -> T? {
        do {
            let result = try await body()
            trace(step, what, "done")
            return result
        } catch let error as DabbiError {
            trace(step, what, "refused, \(error.code)")
            return nil
        } catch let failure as FuzzFailure {
            throw failure
        } catch {
            Issue.record("\(context), step \(step), \(what): \(type(of: error)) \(error)")
            return nil
        }
    }

    func trace(_ step: Int, _ what: String, _ outcome: String) {
        guard CorruptionFuzzTests.tracing else { return }
        FileHandle.standardError.write(Data("fuzz \(context) \(step): \(what): \(outcome)\n".utf8))
    }

    private mutating func anyObject(of entities: Set<String>? = nil) -> PendingObjectID? {
        // In entity order: a dictionary's is not the same from one process to the next, and a seed must be.
        let candidates = pool.filter { entities?.contains($0.key) ?? true }.sorted { $0.key < $1.key }
            .flatMap(\.value)
        return candidates.randomElement(using: &random)
    }

    mutating func setAttribute(_ number: Int) async throws {
        guard let object = anyObject(), let entity = model.entity(named: object.entity) else { return }
        let attributes = entity.attributes.filter(Self.isEditable)
        guard let attribute = attributes.randomElement(using: &random) else { return }
        let value = randomValue(for: attribute, wild: true)
        try await attempt("set \(object).\(attribute.name)", step: number) {
            try await session.setValue(value, for: attribute.name, of: object)
        }
    }

    mutating func setToOne(_ number: Int) async throws {
        guard let object = anyObject(), let entity = model.entity(named: object.entity),
            let relationship = entity.relationships.filter({ !$0.isToMany && !$0.isTransient })
                .randomElement(using: &random)
        else { return }
        let value = Bool.random(using: &random) ? .null : toOne(relationship)
        try await attempt("set \(object).\(relationship.name) to \(value.traced)", step: number) {
            try await session.setValue(value, for: relationship.name, of: object)
        }
    }

    mutating func insert(_ number: Int) async throws {
        guard let entity = concreteEntities.randomElement(using: &random) else { return }
        guard
            let (object, _) = try await attempt(
                "insert \(entity.name)", step: number,
                {
                    try await session.insertObject(entity: entity.name)
                })
        else { return }
        pool[entity.name, default: []].append(object)
        // Mostly something that could commit: every required attribute and to-one given a value.
        guard Int.random(in: 0..<10, using: &random) < 8 else { return }
        for attribute in entity.attributes where Self.isEditable(attribute) && !attribute.isOptional {
            let value = randomValue(for: attribute, wild: false)
            try await attempt("fill \(entity.name).\(attribute.name)", step: number) {
                try await session.setValue(value, for: attribute.name, of: object)
            }
        }
        for relationship in entity.relationships where !relationship.isToMany && !relationship.isOptional {
            let value = toOne(relationship)
            try await attempt("fill \(entity.name).\(relationship.name)", step: number) {
                try await session.setValue(value, for: relationship.name, of: object)
            }
        }
    }

    mutating func delete(_ number: Int) async throws {
        guard let object = anyObject() else { return }
        try await attempt("delete \(object)", step: number) { try await session.delete([object]) }
    }

    mutating func linkOrUnlink(_ number: Int) async throws {
        guard let object = anyObject(), let entity = model.entity(named: object.entity),
            let relationship = entity.relationships.filter({ $0.isToMany && !$0.isTransient })
                .randomElement(using: &random),
            let other = anyObject(of: descendants(of: relationship.destinationEntity))
        else { return }
        let name = "\(object).\(relationship.name), \(other)"
        if Bool.random(using: &random) {
            try await attempt("link \(name)", step: number) {
                try await session.link([other], to: object, through: relationship.name)
            }
        } else {
            try await attempt("unlink \(name)", step: number) {
                try await session.unlink([other], from: object, through: relationship.name)
            }
        }
    }

    // MARK: - Commits

    /// Commits, and checks the file: sound when the commit went through, untouched when it was refused.
    mutating func commit(_ number: Int) async throws {
        let schema = session.info.schemaMap
        let before = try StoreSoundness.fingerprint(of: location.storeURL, schema: schema)
        do {
            _ = try await session.commit()
        } catch let error as DabbiError {
            commits.refused += 1
            trace(number, "commit", "refused, \(error.code)")
            let after = try StoreSoundness.fingerprint(of: location.storeURL, schema: schema)
            guard after == before else {
                throw FuzzFailure("\(context): a refused commit (\(error.code)) wrote to the file")
            }
            // A commit the model refuses stays refused until something changes; half the time, start again.
            if Bool.random(using: &random) {
                try await session.discardChanges()
                try await refillPool()
            }
            return
        } catch {
            Issue.record("\(context), step \(number), commit: \(type(of: error)) \(error)")
            return
        }
        commits.succeeded += 1
        trace(number, "commit", "done")
        let problems = try StoreSoundness.fileProblems(of: location.storeURL, model: model, schema: schema)
        guard problems.isEmpty else {
            throw FuzzFailure(
                "\(context): after commit \(commits.succeeded): \(problems.joined(separator: "; ")); the store is kept, "
                    + location.storeURL.path)
        }
        expected = try await StoreSoundness.counts(in: session)
        try await refillPool()
    }

    /// Lets go of whatever is still staged, then opens the file afresh: it must hold what the last commit left.
    func finish() async throws {
        try await session.discardChanges()
        #expect(try await StoreSoundness.counts(in: session) == expected, "\(context)")
        await session.close()
        let schema = session.info.schemaMap
        let problems = try StoreSoundness.fileProblems(of: location.storeURL, model: model, schema: schema)
        #expect(problems.isEmpty, "\(context): \(problems)")
        let reopened = try await StoreSoundness.reopen(location.storeURL, modelURL: location.modelURL)
        #expect(reopened == expected, "\(context): \(commits.succeeded) commits, \(commits.refused) refused")
        trace(CorruptionFuzzTests.steps, "finish", "\(commits.succeeded) commits, \(commits.refused) refused")
    }

    // MARK: - Values

    private static func isEditable(_ attribute: AttributeDescription) -> Bool {
        guard !attribute.isTransient, !attribute.isDerived else { return false }
        switch attribute.type {
        case .integer16, .integer32, .integer64, .decimal, .double, .float, .string, .boolean, .date, .uuid, .uri:
            return true
        case .binaryData, .transformable, .objectID, .composite, .undefined:
            return false
        }
    }

    /// A value for `attribute`. `wild` values are sometimes `nil`, sometimes out of any range the model sets,
    /// sometimes out of the type's own.
    private mutating func randomValue(for attribute: AttributeDescription, wild: Bool) -> Value {
        let roll = wild ? Int.random(in: 0..<10, using: &random) : 9
        if roll == 0 { return .null }
        let extreme = roll == 1
        switch attribute.type {
        case .integer16, .integer32, .integer64:
            return .int(
                extreme
                    ? [Int64.max, Int64.min, 70_000].randomElement(using: &random)!
                    : .random(in: 0...100, using: &random))
        case .decimal:
            return .decimal(Decimal(Int.random(in: -1000...1000, using: &random)) / 100)
        case .double, .float:
            return .double(
                extreme
                    ? [.infinity, -1e300, .nan].randomElement(using: &random)! : .random(in: 0...100, using: &random))
        case .string:
            let length = extreme ? 5000 : Int.random(in: 1...12, using: &random)
            return .string(String((0..<length).map { _ in "abcdefghij kl-é✓".randomElement(using: &random)! }))
        case .boolean:
            return .bool(.random(using: &random))
        case .date:
            return .date(Date(timeIntervalSinceReferenceDate: .random(in: 0...1_000_000_000, using: &random)))
        case .uuid:
            return .uuid(UUID())
        case .uri:
            return .url(URL(string: "https://example.com/\(Int.random(in: 0...99, using: &random))")!)
        case .binaryData, .transformable, .objectID, .composite, .undefined:
            return .null
        }
    }

    /// A destination for a to-one: a saved object or one only inserted, of the destination entity or below it.
    private mutating func toOne(_ relationship: RelationshipDescription) -> Value {
        guard let target = anyObject(of: descendants(of: relationship.destinationEntity)) else { return .null }
        if let ref = target.ref { return .toOne(ref, display: nil) }
        return .toOneInserted(target, display: nil)
    }

    private func descendants(of name: String) -> Set<String> {
        var names: Set<String> = [name]
        var queue = [name]
        while let next = queue.popLast() {
            for child in model.entity(named: next)?.subentities ?? [] where names.insert(child).inserted {
                queue.append(child)
            }
        }
        return names
    }
}

/// What the fuzzer found wrong with the file; stops the run, since nothing after it would mean anything.
extension Value {
    /// A to-one's destination, by identity: what a trace may say about a value.
    fileprivate var traced: String {
        switch self {
        case .toOne(let ref, _): ref?.description ?? "nil"
        case .toOneInserted(let object, _): object.description
        default: "nil"
        }
    }
}

struct FuzzFailure: Error, CustomStringConvertible {
    let description: String
    init(_ description: String) { self.description = description }
}
