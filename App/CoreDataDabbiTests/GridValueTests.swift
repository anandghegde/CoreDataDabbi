import DabbiKit
import Foundation
import Testing

@testable import CoreDataDabbi

@Suite struct GridValueTests {
    private let english = Locale(identifier: "en_GB")

    private func render(_ value: Value, timeZone: TimeZone = .gmt) -> GridValue {
        GridValue.render(value, timeZone: timeZone, locale: english)
    }

    @Test func tellsNilFromAnEmptyStringFromTheWordNil() {
        let null = render(.null)
        let empty = render(.string(""))
        let word = render(.string("nil"))
        #expect(null.emphasis == .absent)
        #expect(empty.emphasis == .absent)
        #expect(empty.text != null.text)
        #expect(word.emphasis == .value)
        #expect(word.text == "nil")
    }

    @Test func showsDatesInTheProjectsTimeZoneAndKeepsWhatWasStored() throws {
        let date = Date(timeIntervalSinceReferenceDate: 0)
        let utc = render(.date(date))
        let tokyo = render(.date(date), timeZone: try #require(TimeZone(identifier: "Asia/Tokyo")))
        #expect(utc.text != tokyo.text)
        let tooltip = try #require(utc.tooltip)
        #expect(tooltip.hasPrefix("2001-01-01T00:00:00Z"))
        #expect(tooltip.hasSuffix("0.0"))
    }

    @Test func foldsMultiLineTextOntoOneLine() throws {
        let value = render(.string("first\nsecond"))
        #expect(!value.text.contains("\n"))
        #expect(try #require(value.tooltip) == "first\nsecond")
    }

    @Test func summarisesBlobs() throws {
        let value = render(.blob(BlobSummary(byteCount: 2048, sniffedType: .png, isExternal: true)))
        #expect(value.text.hasPrefix("PNG"))
        // The cell rounds; the tooltip says how many bytes there are exactly.
        #expect(try #require(value.tooltip).contains(2048.formatted(.number.locale(english))))
        #expect(try #require(value.tooltip).contains("outside"))

        let unknown = render(.blob(BlobSummary(byteCount: 12, sniffedType: nil, isExternal: false)))
        #expect(!unknown.text.contains("·"))
    }

    @Test func showsCompositesInline() {
        let value = render(.composite(["longitude": .double(11), "latitude": .double(48)]))
        // Keys sorted, so that a column of them lines up.
        #expect(value.text.hasPrefix("{latitude:"))
        #expect(value.text.contains("longitude:"))
    }

    @Test func marksRelationshipsAsSomethingToFollow() throws {
        let ref = ObjectRef(entity: "Person", pk: 7, uri: URL(string: "x-coredata://S/Person/p7")!)
        let toOne = render(.toOne(ref, display: "Ada"))
        #expect(toOne.text == "Ada")
        #expect(toOne.emphasis == .reference)
        #expect(try #require(toOne.tooltip) == "Person#7")

        #expect(render(.toOne(nil, display: nil)).emphasis == .absent)
        #expect(render(.toMany(count: 0)).emphasis == .absent)
        #expect(render(.toMany(count: 3)).emphasis == .reference)
    }

    @Test func groupsLargeNumbers() {
        #expect(render(.int(1_234_567)).text == "1,234,567")
    }

    @Test func saysInWordsWhatTheDrawingSays() throws {
        // Dimmed and italic tells a reader that "nil" is not a stored word; aloud it has to be said (§8.4).
        #expect(render(.null).accessibleText == "No value")
        #expect(render(.string("")).accessibleText == "Empty text, not nil")
        #expect(render(.string("nil")).accessibleText == "nil")
        #expect(render(.toOne(nil, display: nil)).accessibleText == "No object")
        #expect(render(.toMany(count: 0)).accessibleText == "No objects")
        #expect(GridValue.notLoaded.accessibleText == "Not read yet")
        #expect(GridValue.deleted.accessibleText != GridValue.deleted.text)

        // The interpunct between a blob's type and its size is a pause on screen and a comma aloud.
        let blob = render(.blob(BlobSummary(byteCount: 2048, sniffedType: .png, isExternal: false)))
        #expect(!blob.accessibleText.contains("·"))
        #expect(blob.accessibleText.hasPrefix("PNG, "))

        // An ordinary value reads as it is written; there is nothing to add.
        #expect(render(.int(12)).accessibleText == "12")
        #expect(render(.int(12)).spoken == nil)
    }
}
