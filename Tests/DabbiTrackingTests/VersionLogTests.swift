import DabbiBase
import Foundation
import Testing

@testable import DabbiTracking

/// The record of everything the tracker has reported (TRK-2), including the part of it that has been written to
/// disk because it no longer fits in memory.
@Suite struct VersionLogTests {
    static let store = "3C7B1E90-2A4D-4F18-8E5C-7D9A0B1C2D3E"

    static func ref(_ pk: Int64, entity: String = "Note") -> ObjectRef {
        ObjectRef(storeUUID: store, entity: entity, pk: pk)!
    }

    /// An update event with one field's worth of before and after, which is enough to tell that what comes back out
    /// of the spill file is what went in.
    static func event(_ pk: Int64, from before: String, to after: String, entity: String = "Note") -> ChangeEvent {
        func snapshot(_ title: String) -> ObjectSnapshot {
            ObjectSnapshot(
                row: RowSnapshot(ref: ref(pk, entity: entity), values: [.string(title)]),
                columns: ColumnSet(["title"]), generation: 1)
        }
        return ChangeEvent(
            object: ref(pk, entity: entity), kind: .updated, before: snapshot(before), after: snapshot(after),
            changedKeys: ["title"], at: Date(timeIntervalSinceReferenceDate: Double(pk)))
    }

    static func options(cap: Int, spillsToDisk: Bool = true) -> VersionLog.Options {
        var options = VersionLog.Options()
        options.cap = cap
        options.spillsToDisk = spillsToDisk
        return options
    }

    // MARK: In memory

    @Test func numbersVersionsFromOne() async {
        let log = VersionLog()
        let appended = await log.append([Self.event(1, from: "a", to: "b"), Self.event(2, from: "c", to: "d")])
        #expect(appended.map(\.sequence) == [1, 2])
        #expect(await log.count == 2)
        #expect(await log.nextSequenceNumber == 3)
        #expect(await log.recent().map(\.sequence) == [2, 1], "newest first, as the list shows them")
        #expect(await log.spillURL == nil, "nothing spilled, nothing written")
        await log.close()
    }

    @Test func groupsVersionsByObject() async {
        let log = VersionLog()
        await log.append([
            Self.event(1, from: "a", to: "b"), Self.event(2, from: "c", to: "d"), Self.event(1, from: "b", to: "e"),
        ])

        #expect(await log.objectCount == 2)
        let objects = await log.objects()
        #expect(objects.first?.object == Self.ref(1), "the most recently changed first")
        #expect(objects.first?.versions == 2)
        #expect(objects.first?.firstSequence == 1)
        #expect(objects.first?.latestSequence == 3)
        #expect(objects.first?.latestKind == .updated)

        let one = await log.versions(of: Self.ref(1))
        #expect(one.map(\.sequence) == [3, 1])
        #expect(one.first?.event.currentValue(of: "title") == .string("e"))
        #expect(await log.objects(newestFirst: false).first?.object == Self.ref(2))
        #expect(await log.objects(limit: 1).count == 1)
        await log.close()
    }

    /// How an export walks the log (TRK-5): forwards from a cursor, a page at a time, never holding all of it.
    @Test func pagesForwardsForAnExport() async {
        let log = VersionLog()
        await log.append((1...10).map { Self.event(Int64($0), from: "a", to: "b") })

        let first = await log.versions(from: 1, limit: 4)
        #expect(first.map(\.sequence) == [1, 2, 3, 4])
        let next = await log.versions(from: first.last!.sequence + 1, limit: 4)
        #expect(next.map(\.sequence) == [5, 6, 7, 8])
        #expect(await log.versions(from: 9, limit: 4).map(\.sequence) == [9, 10])
        #expect(await log.versions(from: 11, limit: 4).isEmpty)
        await log.close()
    }

    @Test func findsOneVersionByItsNumber() async {
        let log = VersionLog()
        await log.append([Self.event(1, from: "a", to: "b"), Self.event(2, from: "c", to: "d")])
        #expect(await log.version(2)?.object == Self.ref(2))
        #expect(await log.version(99) == nil)
        await log.close()
    }

    @Test func emptyingKeepsCountingWhereItLeftOff() async {
        let log = VersionLog()
        await log.append([Self.event(1, from: "a", to: "b")])
        await log.clear()
        #expect(await log.count == 0)
        #expect(await log.objectCount == 0)
        #expect(await log.recent().isEmpty)
        #expect(
            await log.nextSequenceNumber == 2,
            "a version the user has already seen must not come back under a number they have also seen")
        await log.close()
    }

    // MARK: Spilling to disk

    /// Past the cap, the oldest versions go to a database of our own and come back from it on demand — values,
    /// diffs and all.
    @Test func versionsPastTheCapAreWrittenToDiskAndReadBack() async throws {
        let log = VersionLog(options: Self.options(cap: 4))
        await log.append((1...10).map { Self.event(Int64($0), from: "before-\($0)", to: "after-\($0)") })

        #expect(await log.count == 10, "all of them are still accounted for")
        #expect(await log.inMemoryCount == 4)
        #expect(await log.spilledToDiskCount == 6)
        #expect(await log.droppedVersionCount == 0)
        let url = try #require(await log.spillURL)
        #expect(FileManager.default.fileExists(atPath: url.path))

        // A list long enough to cross from memory into the file, in one unbroken run.
        let recent = await log.recent(10)
        #expect(recent.map(\.sequence) == Array((1...10).reversed()))
        let oldest = try #require(recent.last)
        #expect(oldest.event.priorValue(of: "title") == .string("before-1"), "the before survived the round trip")
        #expect(oldest.event.currentValue(of: "title") == .string("after-1"))
        #expect(oldest.event.changedKeys == ["title"])

        #expect(await log.version(2)?.event.currentValue(of: "title") == .string("after-2"))
        await log.close()
        #expect(
            FileManager.default.fileExists(atPath: url.path) == false,
            "the spill holds row values, so it goes when the log does")
    }

    /// The object list is complete whatever has spilled: identities are cheap, so they stay in memory even when
    /// the versions they point at do not.
    @Test func theObjectListSurvivesASpill() async {
        let log = VersionLog(options: Self.options(cap: 2))
        for pk in Int64(1)...6 { await log.append([Self.event(pk, from: "a", to: "b")]) }

        #expect(await log.objectCount == 6)
        #expect(await log.spilledToDiskCount == 4)
        #expect(await log.objects().count == 6)
        await log.close()
    }

    @Test func oneObjectsVersionsAreGatheredFromBothSides() async {
        let log = VersionLog(options: Self.options(cap: 3))
        // Every other version is about the same row, so its history straddles the cap.
        for step in 1...8 {
            // Odd steps are about other rows, so only the even sequences belong to this one.
            let pk = step.isMultiple(of: 2) ? Int64(1) : Int64(step + 100)
            await log.append([Self.event(pk, from: "a", to: "step-\(step)")])
        }

        let versions = await log.versions(of: Self.ref(1))
        #expect(versions.count == 4)
        #expect(versions.map(\.sequence) == [8, 6, 4, 2], "newest first, across memory and the spill file")
        #expect(versions.last?.event.currentValue(of: "title") == .string("step-2"))
        await log.close()
    }

    @Test func pagingForwardsCrossesTheSpillBoundary() async {
        let log = VersionLog(options: Self.options(cap: 3))
        await log.append((1...9).map { Self.event(Int64($0), from: "a", to: "after-\($0)") })

        #expect(await log.versions(from: 1, limit: 9).map(\.sequence) == Array(1...9))
        #expect(await log.versions(from: 5, limit: 3).map(\.sequence) == [5, 6, 7])
        #expect(await log.versions(from: 7, limit: 5).map(\.sequence) == [7, 8, 9], "and past the end, not into it")
        await log.close()
    }

    /// A caller that cannot afford a file on disk gets a log that drops instead — and says how many, because a log
    /// that quietly forgets is worse than one that admits it.
    @Test func withoutASpillTheOldestAreDroppedAndCounted() async {
        let log = VersionLog(options: Self.options(cap: 3, spillsToDisk: false))
        await log.append((1...10).map { Self.event(Int64($0), from: "a", to: "b") })

        #expect(await log.inMemoryCount == 3)
        #expect(await log.spilledToDiskCount == 0)
        #expect(await log.droppedVersionCount == 7)
        #expect(await log.count == 10, "the log knows what it lost")
        #expect(await log.recent(10).map(\.sequence) == [10, 9, 8])
        #expect(await log.spillURL == nil)
        await log.close()
    }

    @Test func appendingNothingDoesNothing() async {
        let log = VersionLog()
        #expect(await log.append([]).isEmpty)
        #expect(await log.append(ChangeBatch()).isEmpty)
        #expect(await log.count == 0)
        #expect(await log.recent(0).isEmpty)
        await log.close()
    }

    @Test func appendsAWholeBatch() async {
        let log = VersionLog()
        let batch = ChangeBatch(events: [Self.event(1, from: "a", to: "b"), Self.event(2, from: "c", to: "d")])
        #expect(await log.append(batch).count == 2)
        #expect(await log.count == 2)
        await log.close()
    }
}
