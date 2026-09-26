import DabbiBase
import DabbiTestSupport
import FixtureKit
import Foundation
import Testing

@testable import DabbiStore

/// PRD §10 Reliability: an editing session and another process's writer, at the same store for hours, leave it
/// sound and holding what each of them committed.
///
/// The writer is `WriterScript` — the same Notes store the tracker's end-to-end test writes — on a thread of its
/// own, committing one step at a time to notes it owns: inserts, edits, pins, moves and deletes of its "Writer n"
/// notes, and edits of the seed's. The session edits the body and pin of any note, its own or not, and inserts,
/// edits and deletes notes of its own ("Dabbi n"), committing every so often. A commit refused over a conflict is
/// settled at random, `.mine` or `.theirs`, and tried again; one Core Data refuses because a save landed after the
/// conflict check is tried again too.
///
/// At the end, and every few minutes of the long run, the file is sound (`StoreSoundness`). At the end the
/// session's notes are exactly the ones it committed, with the values it committed, the writer's are exactly the
/// ones it has not deleted, and no commit took longer than `commitBudget`.
///
/// The short variant runs for a few seconds in the normal suite. `Scripts/soak.sh` runs it for
/// `DABBI_SOAK_MINUTES` (180 by default).
@Suite struct SoakTests {
    private static let environment = ProcessInfo.processInfo.environment
    static let duration: Duration =
        environment["DABBI_SOAK"] != nil
        ? .seconds(60 * (environment["DABBI_SOAK_MINUTES"].flatMap(Int.init) ?? 180)) : .seconds(3)
    /// How often the long run checks the file while both are still at it.
    static let checkEvery: Duration = .seconds(300)
    /// The longest a commit may take — a few notes, on a store of a few dozen — writer or no writer.
    static let commitBudget: Duration = .seconds(10)

    @Test func anEditingSessionAndAWriterLeaveTheStoreSound() async throws {
        let directory = TestFixtures.root.appendingPathComponent("soak-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let storeURL = directory.appendingPathComponent(WriterScript.storeName)
        let seeded = try WriterScript(writer: "writer").seed(into: storeURL)

        let writer = Writer(storeURL: storeURL, titles: seeded.seeded.map(\.title))
        let session = try await StoreSession.open(
            storeURL: storeURL, access: .editable(WriteAuthorization(author: "Soak")))
        var editor = try await Editor(session: session, random: SeededGenerator(seed: 1))
        let (model, schema) = (session.info.model, session.info.schemaMap)

        writer.start()
        let clock = ContinuousClock()
        let end = clock.now.advanced(by: Self.duration)
        var nextCheck = clock.now.advanced(by: Self.checkEvery)
        do {
            while clock.now < end {
                try await editor.step()
                if clock.now >= nextCheck {
                    let problems = try StoreSoundness.fileProblems(of: storeURL, model: model, schema: schema)
                    #expect(problems.isEmpty, "\(problems)")
                    nextCheck = clock.now.advanced(by: Self.checkEvery)
                }
            }
        } catch {
            await writer.stop()
            await session.close()
            throw error
        }
        let written = await writer.stop()
        try await editor.commitUntilDone()
        await session.close()

        #expect(written.failures.isEmpty, "the writer failed: \(written.failures)")
        #expect(editor.slowest < Self.commitBudget, "the slowest commit took \(editor.slowest)")
        #expect(try StoreSoundness.fileProblems(of: storeURL, model: model, schema: schema).isEmpty)

        // What is in the file, read afresh.
        let reader = try await StoreSession.open(storeURL: storeURL)
        let refs = try await reader.references(FetchSpec(entity: "Note"))
        let notes = try await reader.objects(refs).values.map(\.snapshot)
        await reader.close()
        var mine: [String: Editor.Note] = [:]
        var theirs: Set<String> = []
        for note in notes {
            guard case .string(let title)? = note["title"] else {
                Issue.record("a note without a title")
                continue
            }
            if title.hasPrefix(Editor.prefix) {
                mine[title] = Editor.Note(body: note["body"] ?? .null, pinned: note["pinned"] ?? .null)
            } else {
                theirs.insert(title)
            }
        }
        #expect(mine == editor.committed.mapValues(\.note))
        #expect(theirs == written.live)
        #expect(
            try await StoreSoundness.reopen(storeURL, modelURL: nil)["Note"] == mine.count + theirs.count,
            "\(editor.commits) commits, \(written.steps) writer steps")
    }
}

/// The session's side: random staged edits, and commits that are settled and tried again until they go through.
private struct Editor {
    static let prefix = "Dabbi "

    struct Note: Hashable {
        var body: Value
        var pinned: Value
    }

    /// A note of the session's own, as staged or as committed, and how to reach it.
    struct Own {
        var object: PendingObjectID
        var note: Note
    }

    let session: StoreSession
    var random: SeededGenerator
    let folders: [ObjectRef]
    /// The session's notes as the last commit left them, by title.
    var committed: [String: Own] = [:]
    /// And as staged now.
    var staged: [String: Own] = [:]
    /// Every note there is, the writer's included, as last looked up.
    var everyNote: [ObjectRef] = []
    var inserted = 0
    var commits = 0
    var slowest: Duration = .zero

    init(session: StoreSession, random: SeededGenerator) async throws {
        self.session = session
        self.random = random
        folders = try await session.references(FetchSpec(entity: "Folder"))
        try #require(!folders.isEmpty)
    }

    mutating func step() async throws {
        let roll = Int.random(in: 0..<100, using: &random)
        switch roll {
        case 0..<5: everyNote = try await session.references(FetchSpec(entity: "Note"))
        case 5..<35: try await editAnyNote()
        case 35..<50: try await insert()
        case 50..<70: try await editOwn()
        case 70..<78: try await deleteOwn()
        case 78..<80:
            _ = try await session.discardChanges()
            staged = committed
        default: try await commitUntilDone()
        }
    }

    /// A body or a pin, on a note that may be the writer's — and may be gone by the time the edit is made.
    private mutating func editAnyNote() async throws {
        guard let ref = everyNote.randomElement(using: &random) else { return }
        let edit = Bool.random(using: &random) ? ("body", Value.string("Edited")) : ("pinned", .bool(true))
        do {
            try await session.setValue(edit.1, for: edit.0, of: PendingObjectID(ref))
        } catch let error as DabbiError where error.code == .objectNotFound {
            // The writer deleted it.
        }
        // Whether the note is its own or the writer's, the edit counts when it is the session's own note.
        if let title = staged.first(where: { $0.value.object == PendingObjectID(ref) })?.key {
            if edit.0 == "body" { staged[title]?.note.body = edit.1 } else { staged[title]?.note.pinned = edit.1 }
        }
    }

    private mutating func insert() async throws {
        inserted += 1
        let title = "\(Self.prefix)\(inserted)"
        let folder = folders.randomElement(using: &random)!
        let pinned = Value.bool(Bool.random(using: &random))
        let (object, _) = try await session.insertObject(entity: "Note")
        try await session.setValue(.string(title), for: "title", of: object)
        try await session.setValue(.string("Body of \(title)"), for: "body", of: object)
        try await session.setValue(pinned, for: "pinned", of: object)
        try await session.setValue(.toOne(folder, display: nil), for: "folder", of: object)
        staged[title] = Own(object: object, note: Note(body: .string("Body of \(title)"), pinned: pinned))
    }

    private mutating func editOwn() async throws {
        guard let title = staged.keys.sorted().randomElement(using: &random), let own = staged[title] else { return }
        if Bool.random(using: &random) {
            let body = Value.string("Body \(Int.random(in: 0..<1000, using: &random))")
            try await session.setValue(body, for: "body", of: own.object)
            staged[title]?.note.body = body
        } else {
            let pinned = Value.bool(own.note.pinned != .bool(true))
            try await session.setValue(pinned, for: "pinned", of: own.object)
            staged[title]?.note.pinned = pinned
        }
    }

    private mutating func deleteOwn() async throws {
        guard let title = staged.keys.sorted().randomElement(using: &random), let own = staged[title] else { return }
        try await session.delete([own.object])
        staged[title] = nil
    }

    /// Commits what is staged, settling conflicts and trying again until it goes through.
    mutating func commitUntilDone() async throws {
        var failures = 0
        while true {
            let clock = ContinuousClock()
            let start = clock.now
            do {
                let summary = try await session.commit()
                slowest = max(slowest, clock.now - start)
                commits += 1
                for (title, own) in staged {
                    if let ref = summary.insertedRefs[own.object] { staged[title]?.object = PendingObjectID(ref) }
                }
                committed = staged
                return
            } catch let error as DabbiError where error.code == .commitConflict {
                // Either a row the writer saved since it was edited here, or a save of the writer's that landed
                // between the commit's comparison and its own: then there is nothing to choose, only to retry.
                slowest = max(slowest, clock.now - start)
                failures += 1
                if failures > 50 { throw error }
                let conflicts = try await session.commitConflicts()
                var choices: [PendingObjectID: CommitConflict.Choice] = [:]
                for conflict in conflicts {
                    // The writer never touches the session's notes: every conflict is over one of the writer's.
                    #expect(!staged.values.contains { $0.object == conflict.object })
                    choices[conflict.object] = Bool.random(using: &random) ? .mine : .theirs
                }
                try await session.resolveConflicts(choices)
            } catch let error as DabbiError where error.code == .commitFailed {
                // The store was busy with the writer's save. The next attempt tries again.
                failures += 1
                if failures > 50 { throw error }
            }
        }
    }
}

/// The writer's side: `WriterScript`, one step per transaction, on a thread of its own.
private final class Writer: @unchecked Sendable {
    struct Outcome: Sendable {
        /// The writer's notes that are still there.
        var live: Set<String>
        var steps: Int
        /// Saves Core Data refused because the session had saved the same row since the writer read it — the
        /// writer's own merge policy is the error one. Expected now and then; the step simply did not happen.
        var lostRaces: Int
        var failures: [String]
    }

    private let storeURL: URL
    private let lock = NSLock()
    private var stopping = false
    private var outcome: Outcome
    private var done: CheckedContinuation<Void, Never>?
    private var finished = false
    private let seedTitles: [String]

    init(storeURL: URL, titles: [String]) {
        self.storeURL = storeURL
        seedTitles = titles
        outcome = Outcome(live: Set(titles), steps: 0, lostRaces: 0, failures: [])
    }

    func start() {
        let thread = Thread { [self] in
            run()
            lock.withLock {
                finished = true
                done?.resume()
                done = nil
            }
        }
        thread.name = "soak writer"
        thread.start()
    }

    /// Stops the writer and waits for its last step.
    @discardableResult
    func stop() async -> Outcome {
        lock.withLock { stopping = true }
        await withCheckedContinuation { continuation in
            lock.withLock {
                if finished { continuation.resume() } else { done = continuation }
            }
        }
        return lock.withLock { outcome }
    }

    private func run() {
        var random = SeededGenerator(seed: 2)
        let script = WriterScript(writer: "writer", intervalMilliseconds: 0)
        var inserted = 0
        while !lock.withLock({ stopping }) {
            let live = lock.withLock { outcome.live }
            let own = live.subtracting(seedTitles).sorted()
            let any = live.sorted()
            let step: WriterScript.Step
            switch Int.random(in: 0..<100, using: &random) {
            case 0..<25 where own.count < 30:
                inserted += 1
                step = .insert(
                    title: "Writer \(inserted)", pinned: Bool.random(using: &random),
                    folder: Int.random(in: 0..<WriterScript.folderNames.count, using: &random))
            case 25..<35 where !own.isEmpty: step = .delete(title: own.randomElement(using: &random)!)
            case 35..<55: step = .pin(title: any.randomElement(using: &random)!)
            case 55..<75: step = .unpin(title: any.randomElement(using: &random)!)
            case 75..<85:
                step = .move(
                    title: any.randomElement(using: &random)!,
                    folder: Int.random(in: 0..<WriterScript.folderNames.count, using: &random))
            default: step = .edit(title: any.randomElement(using: &random)!)
            }
            do {
                _ = try script.run([step], on: storeURL)
                lock.withLock {
                    outcome.steps += 1
                    switch step {
                    case .insert(let title, _, _): outcome.live.insert(title)
                    case .delete(let title): outcome.live.remove(title)
                    default: break
                    }
                }
            } catch let error as NSError where error.domain == NSCocoaErrorDomain && error.code == 133020 {
                lock.withLock { outcome.lostRaces += 1 }
            } catch {
                // What failed, never the row: a title is the writer's own, but the error may quote values.
                lock.withLock { outcome.failures.append("\(type(of: error)) \((error as NSError).code)") }
            }
            Thread.sleep(forTimeInterval: Double(Int.random(in: 5..<40, using: &random)) / 1000)
        }
    }
}
