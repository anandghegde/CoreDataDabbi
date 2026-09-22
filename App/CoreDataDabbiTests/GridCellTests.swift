import AppKit
import DabbiKit
import Testing

@testable import CoreDataDabbi

/// What a cell of the grid is to someone who is not looking at it (PRD §8.4).
@MainActor
@Suite struct GridCellTests {
    private let english = Locale(identifier: "en_GB")

    private func cell(showing value: Value, column: String = "Name", trailing: Bool = false) -> GridCellView {
        let cell = GridCellView()
        cell.show(GridValue.render(value, timeZone: .gmt, locale: english), trailing: trailing, column: column)
        return cell
    }

    @Test func namesTheColumnAndSaysWhatTheDrawingMeans() throws {
        let cell = cell(showing: .null)
        #expect(cell.isAccessibilityElement())
        #expect(cell.accessibilityRole() == .staticText)
        // A cell out of its row says nothing about which field it holds, so the column says it.
        #expect(cell.accessibilityLabel() == "Name")
        #expect(cell.accessibilityValue() as? String == "No value")
        // The label inside would otherwise be read out a second time, saying the same thing.
        #expect(try #require(cell.textField).isAccessibilityElement() == false)
    }

    @Test func readsAnOrdinaryValueAsItIsWritten() throws {
        let cell = cell(showing: .int(12), column: "Age", trailing: true)
        #expect(cell.accessibilityValue() as? String == "12")
        #expect(try #require(cell.textField).alignment == .right)
    }

    @Test func doesNotLeanOnColourAloneForSomethingToFollow() throws {
        let ref = ObjectRef(entity: "Person", pk: 7, uri: try #require(URL(string: "x-coredata://S/Person/p7")))
        let cell = cell(showing: .toOne(ref, display: "Ada"), column: "Head")
        let attributed = try #require(cell.textField).attributedStringValue
        // The link colour, which AppKit keeps legible against text in both appearances.
        #expect(attributed.attribute(.foregroundColor, at: 0, effectiveRange: nil) as? NSColor == .linkColor)
        // Underlined where the system says colour is not to be relied on, and only there.
        let underlined = attributed.attribute(.underlineStyle, at: 0, effectiveRange: nil) != nil
        #expect(underlined == NSWorkspace.shared.accessibilityDisplayShouldDifferentiateWithoutColor)

        #expect(cell.accessibilityValue() as? String == "Ada")
        #expect(cell.toolTip == "Person#7")
    }

    @Test func saysThatAPageHasNotArrivedRatherThanNothingAtAll() throws {
        let cell = GridCellView()
        cell.show(.notLoaded, trailing: false, column: "Name")
        #expect(try #require(cell.textField).stringValue.isEmpty)
        #expect(cell.accessibilityValue() as? String == "Not read yet")
    }

    @Test func saysNothingRatherThanAnEmptyLabelWhereThereIsNoColumnTitle() {
        let cell = cell(showing: .int(7), column: "")
        #expect(cell.accessibilityLabel() == nil)
        #expect(cell.accessibilityValue() as? String == "7")
    }
}
