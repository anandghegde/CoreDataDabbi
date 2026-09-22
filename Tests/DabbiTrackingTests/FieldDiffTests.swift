import DabbiBase
import Foundation
import Testing

@testable import DabbiTracking

/// Comparing two readings of a row (TRK-2). No store: the whole point of these is what happens when the two sides
/// were read in different shapes, which is hard to arrange and easy to get wrong.
@Suite struct FieldDiffTests {
    static let store = "6E8A2D44-6D8A-4B0A-9B3A-0C1D2E3F4A5B"

    static func ref(_ pk: Int64 = 1, entity: String = "Note") -> ObjectRef {
        ObjectRef(storeUUID: store, entity: entity, pk: pk)!
    }

    static func snapshot(_ values: [String: Value], pk: Int64 = 1, entity: String = "Note") -> ObjectSnapshot {
        let names = values.keys.sorted()
        return ObjectSnapshot(
            row: RowSnapshot(ref: ref(pk, entity: entity), values: names.map { values[$0]! }),
            columns: ColumnSet(names), generation: 1)
    }

    @Test func namesTheFieldsThatDiffer() {
        let result = FieldDiff.compare(
            Self.snapshot(["title": .string("Before"), "body": .string("Same"), "pinned": .bool(false)]),
            Self.snapshot(["title": .string("After"), "body": .string("Same"), "pinned": .bool(true)]))
        #expect(result.changed == ["title", "pinned"])
        #expect(result.compared == ["title", "body", "pinned"])
        #expect(result.isEmpty == false)
    }

    @Test func twoIdenticalReadingsDifferInNothing() {
        let row = Self.snapshot(["title": .string("Same"), "pinned": .bool(true)])
        let result = FieldDiff.compare(row, row)
        #expect(result.changed.isEmpty)
        #expect(result.compared == ["title", "pinned"])
        #expect(result.isEmpty == false, "nothing changed is not the same as nothing was compared")
    }

    /// The reason the comparison is by name. A grid page of `Person` and its sub-entities carries the union of
    /// their properties, so the same property sits at a different index there than in a reading of the row's own
    /// entity. Comparing `values[i]` to `values[i]` across the two would invent changes.
    @Test func comparesByNameNotByPosition() {
        let before = ObjectSnapshot(
            row: RowSnapshot(
                ref: Self.ref(), values: [.string("Ada"), .int(31), .string("ada@example.org")]),
            columns: ColumnSet(["name", "age", "email"]), generation: 1)
        let after = ObjectSnapshot(
            row: RowSnapshot(
                ref: Self.ref(), values: [.string("ada@example.org"), .string("Ada"), .int(32)]),
            columns: ColumnSet(["email", "name", "age"]), generation: 1)

        let result = FieldDiff.compare(before, after)
        #expect(result.changed == ["age"])
        #expect(result.compared == ["name", "age", "email"])
    }

    /// A property only one side carries is a difference in what was *read*, not in what the row holds — a page
    /// fetched lazily with three columns of twenty is the ordinary case.
    @Test func aPropertyOnlyOneSideCarriesIsNotAChange() {
        let result = FieldDiff.compare(
            Self.snapshot(["title": .string("Before")]),
            Self.snapshot(["title": .string("After"), "body": .string("New")]))
        #expect(result.changed == ["title"])
        #expect(result.compared == ["title"], "`body` was never in the before reading, so it was not compared")
    }

    @Test func nothingInCommonIsAnEmptyComparison() {
        let result = FieldDiff.compare(
            Self.snapshot(["title": .string("Before")]), Self.snapshot(["body": .string("After")]))
        #expect(result.isEmpty, "which the tracker reports as *unknown*, not as *unchanged*")
        #expect(result.changed.isEmpty)
    }

    /// Blobs travel as a summary — a page never carries the bytes — so a change that alters neither the length nor
    /// the sniffed type is invisible here. The row is still reported as changed; only the field is not marked.
    @Test func blobsAreComparedBySummary() {
        let first = BlobSummary(byteCount: 12, sniffedType: .png, isExternal: false)
        let longer = BlobSummary(byteCount: 24, sniffedType: .png, isExternal: false)
        #expect(
            FieldDiff.compare(Self.snapshot(["image": .blob(first)]), Self.snapshot(["image": .blob(longer)]))
                .changed == ["image"])
        #expect(
            FieldDiff.compare(Self.snapshot(["image": .blob(first)]), Self.snapshot(["image": .blob(first)]))
                .changed.isEmpty,
            "same length, same type: a difference in the bytes cannot be seen from here")
    }

    /// Values a row does not have read as `.null`, and a property becoming null is a change like any other.
    @Test func nullIsAValueLikeAnyOther() {
        let result = FieldDiff.compare(
            Self.snapshot(["body": .string("Something")]), Self.snapshot(["body": .null]))
        #expect(result.changed == ["body"])
    }

    /// A row snapshot and its column set, for a caller that has the two halves rather than an `ObjectSnapshot`.
    @Test func comparesRowSnapshotsToo() {
        let before = RowSnapshot(ref: Self.ref(), values: [.string("Before"), .bool(false)])
        let after = RowSnapshot(ref: Self.ref(), values: [.bool(true), .string("Before")])
        let result = FieldDiff.compare(
            before, in: ColumnSet(["title", "pinned"]), to: after, in: ColumnSet(["pinned", "title"]))
        #expect(result.changed == ["pinned"])
    }
}

/// The values and view membership the tracker holds between commits (§6.6, TRK-7).
@Suite struct PriorValuesTests {
    static func snapshot(_ pk: Int64, title: String = "Note") -> ObjectSnapshot {
        ObjectSnapshot(
            row: RowSnapshot(ref: FieldDiffTests.ref(pk), values: [.string(title)]),
            columns: ColumnSet(["title"]), generation: 1)
    }

    @Test func remembersAndForgets() {
        var values = PriorValues()
        values.remember(Self.snapshot(1, title: "One"))
        #expect(values.count == 1)
        #expect(values.snapshot(of: FieldDiffTests.ref(1))?["title"] == .string("One"))

        values.remember(Self.snapshot(1, title: "One again"))
        #expect(values.count == 1, "the same row twice is one row")
        #expect(values.snapshot(of: FieldDiffTests.ref(1))?["title"] == .string("One again"))

        values.forget(FieldDiffTests.ref(1))
        #expect(values.snapshot(of: FieldDiffTests.ref(1)) == nil)
        #expect(values.count == 0)
    }

    /// A row of values costs kilobytes where a key costs twenty bytes, so the cache is capped and the oldest
    /// arrivals go first.
    @Test func theOldestArrivalsAreEvictedFirst() {
        var values = PriorValues(limit: 3)
        for pk in Int64(1)...5 { values.remember(Self.snapshot(pk)) }
        #expect(values.count == 3)
        #expect(values.snapshot(of: FieldDiffTests.ref(1)) == nil)
        #expect(values.snapshot(of: FieldDiffTests.ref(2)) == nil)
        #expect(values.snapshot(of: FieldDiffTests.ref(5)) != nil)
    }

    /// Re-reading a row does not renew its place in the queue — it is the same row, remembered once — and a row
    /// forgotten in between leaves no gap behind.
    @Test func evictionSurvivesRowsForgottenInTheMeantime() {
        var values = PriorValues(limit: 2)
        values.remember(Self.snapshot(1))
        values.remember(Self.snapshot(2))
        values.forget(FieldDiffTests.ref(1))
        values.remember(Self.snapshot(3))
        values.remember(Self.snapshot(4))
        #expect(values.count == 2)
        #expect(values.snapshot(of: FieldDiffTests.ref(4)) != nil)
    }

    @Test func aLimitOfZeroHoldsNothing() {
        var values = PriorValues(limit: 0)
        values.remember(Self.snapshot(1))
        #expect(values.count == 0)
    }

    /// A whole page from the grid, which is where most remembered rows come from.
    @Test func remembersAPage() {
        var values = PriorValues()
        let page = RowPage(
            range: 0..<2,
            rows: [
                RowSnapshot(ref: FieldDiffTests.ref(1), values: [.string("One")]),
                RowSnapshot(ref: FieldDiffTests.ref(2), values: [.string("Two")]),
            ],
            columns: ColumnSet(["title"]), generation: 7)
        values.remember(page)
        #expect(values.count == 2)
        #expect(values.snapshot(of: FieldDiffTests.ref(2))?["title"] == .string("Two"))
        #expect(values.snapshot(of: FieldDiffTests.ref(2))?.generation == 7)
    }

    // MARK: Membership (TRK-7)

    /// Unknown is not "no". Without a complete priming, a row nobody has placed gives `nil`, and the event about
    /// it claims no transition.
    @Test func membershipIsUnknownUntilItIsKnown() {
        var values = PriorValues()
        #expect(values.matched(FieldDiffTests.ref(1)) == nil)

        values.note(FieldDiffTests.ref(1), matches: true)
        #expect(values.matched(FieldDiffTests.ref(1)) == true)
        values.note(FieldDiffTests.ref(1), matches: false)
        #expect(values.matched(FieldDiffTests.ref(1)) == false)
        values.note(FieldDiffTests.ref(1), matches: nil)
        #expect(values.matched(FieldDiffTests.ref(1)) == nil, "a row the predicate could not answer for")
        #expect(values.membershipCount == 0)
    }

    /// When priming read the whole view, a row it did not name is a row outside it — which is what makes *entered*
    /// tellable for a row that had never been read.
    @Test func aCompletePrimingMakesAbsenceMeanNonMember() {
        var values = PriorValues()
        values.noteMembers([FieldDiffTests.ref(1)], isComplete: true)
        #expect(values.matched(FieldDiffTests.ref(1)) == true)
        #expect(values.matched(FieldDiffTests.ref(2)) == false)
        #expect(values.membershipIsComplete)

        values.noteMembers([FieldDiffTests.ref(3)], isComplete: false)
        #expect(values.matched(FieldDiffTests.ref(2)) == nil, "the view outgrew what could be primed")
    }

    @Test func emptyingForgetsMembershipToo() {
        var values = PriorValues()
        values.remember(Self.snapshot(1))
        values.noteMembers([FieldDiffTests.ref(1)], isComplete: true)
        values.removeAll()
        #expect(values.count == 0)
        #expect(values.membershipCount == 0)
        #expect(values.membershipIsComplete == false)
        #expect(values.matched(FieldDiffTests.ref(1)) == nil)
    }
}
