import DabbiKit
import FixtureKit
import Foundation
import Testing

@testable import CoreDataDabbi

@MainActor
@Suite struct ContentModelTests {
    /// A context on the basic fixture, sitting on one row of `Sample` with `property` clicked.
    private func model(
        reading property: String, ofRowNamed name: String = "sample-0"
    ) async throws -> (
        ProjectContext, ContentModel
    ) {
        let context = try await TestProject.context(on: .basic)
        let session = try #require(context.session)
        let handle = try await session.openPager(FetchSpec(entity: "Sample"))
        let page = try await session.page(handle, range: 0..<handle.count)
        let nameColumn = try #require(page.columns.index(of: "name"))
        let row = try #require(page.rows.first { $0.values[nameColumn].displayString(timeZone: .gmt) == name })
        await session.closePager(handle)

        context.show(BrowseLocation(entity: "Sample"))
        context.focus(on: row.ref)
        context.focus(onProperty: property)
        let model = ContentModel(context: context)
        model.refresh()
        await model.whenSettled()
        return (context, model)
    }

    @Test func saysSoWhenNoCellHasBeenClicked() async throws {
        let context = try await TestProject.context(on: .basic)
        defer { context.shutDown() }
        let model = ContentModel(context: context)
        model.refresh()
        await model.whenSettled()
        guard case .noField = model.state else {
            Issue.record("expected no field, got \(model.state)")
            return
        }
        #expect(model.field == nil)
    }

    @Test func readsAStringAsText() async throws {
        let (context, model) = try await model(reading: "stringValue")
        defer { context.shutDown() }
        guard case .ready(let field, let report) = model.state else {
            Issue.record("expected a decoded field, got \(model.state)")
            return
        }
        #expect(field.property == "stringValue")
        #expect(field.typeName == AttributeType.string.displayName)
        #expect(report.type == .text)
        #expect(report.byteCount == 5)  // "plain"
        guard case .text(let text, _) = report.content else {
            Issue.record("expected text, got \(report.content)")
            return
        }
        #expect(text == "plain")
        #expect(ContentText.text(of: report, mode: .text) == "plain")
    }

    @Test func unpacksATransformableIntoATreeWithoutMakingAnObject() async throws {
        let (context, model) = try await model(reading: "keywords")
        defer { context.shutDown() }
        guard case .ready(_, let report) = model.state else {
            Issue.record("expected a decoded field, got \(model.state)")
            return
        }
        // Core Data's default transformer writes a keyed archive; the viewer reads it as a description.
        #expect(report.type == .keyedArchive)
        guard case .tree(let root, _, _) = report.content else {
            Issue.record("expected a tree, got \(report.content)")
            return
        }
        #expect(root.className?.contains("Array") == true)
        let values = root.children.compactMap(\.value)
        #expect(values.contains("alpha"))
        #expect(values.contains("row-0"))
        // The outline is what the Text mode shows for a tree that had no source text of its own.
        #expect(ContentText.text(of: report, mode: .text).contains("alpha"))
    }

    @Test func fallsBackToHexForBytesNothingRecognises() async throws {
        let (context, model) = try await model(reading: "dataValue")
        defer { context.shutDown() }
        guard case .ready(_, let report) = model.state else {
            Issue.record("expected a decoded field, got \(model.state)")
            return
        }
        #expect(report.type == nil)
        #expect(report.content == .opaque)
        #expect(report.byteCount == 16)
        #expect(report.payload.count == 16)
        #expect(report.sha256.count == 64)
        // Hex is what every field has, whatever else it turns out to be (CNT-5).
        let hex = HexDump.text(of: report.payload)
        #expect(hex.hasPrefix("00000000  "))
    }

    @Test func readsAURIAsALink() async throws {
        let (context, model) = try await model(reading: "urlValue")
        defer { context.shutDown() }
        guard case .ready(_, let report) = model.state else {
            Issue.record("expected a decoded field, got \(model.state)")
            return
        }
        guard case .link(let url) = report.content else {
            Issue.record("expected a link, got \(report.content)")
            return
        }
        #expect(url.absoluteString == "https://example.org/samples/0?q=dabbi")
    }

    @Test func hasNothingToDecodeForANumber() async throws {
        let (context, model) = try await model(reading: "int64Value")
        defer { context.shutDown() }
        guard case .plain(_, let value) = model.state else {
            Issue.record("expected a plain value, got \(model.state)")
            return
        }
        // The stored number, not a localised rendering of it: this pane is about what is in the file.
        #expect(value == String(Int64.max))
    }

    @Test func saysSoWhenTheFieldIsNull() async throws {
        // Every fifth row of the fixture leaves its optional attributes unset.
        let (context, model) = try await model(reading: "stringValue", ofRowNamed: "sparse-4")
        defer { context.shutDown() }
        guard case .empty(_, let reason) = model.state else {
            Issue.record("expected an empty field, got \(model.state)")
            return
        }
        #expect(reason.localizedStandardContains("null"))
    }

    @Test func takesTheUsersWordOverTheMagicBytes() async throws {
        let (context, model) = try await model(reading: "stringValue")
        defer { context.shutDown() }
        model.decode(as: .json)
        await model.whenSettled()
        guard case .ready(_, let report) = model.state else {
            Issue.record("expected a decoded field, got \(model.state)")
            return
        }
        // "plain" is not JSON: the forced decoder fails and says why, rather than quietly falling back.
        #expect(model.forcedType == .json)
        #expect(report.type == nil)
        #expect(report.issues.contains { $0.decoder == .json })
        // And the way back is still open.
        model.decode(as: nil)
        await model.whenSettled()
        guard case .ready(_, let again) = model.state else {
            Issue.record("expected a decoded field, got \(model.state)")
            return
        }
        #expect(again.type == .text)
        #expect(model.forcedType == nil)
    }

    @Test func forgetsTheFieldWhenTheEntityChanges() async throws {
        let (context, model) = try await model(reading: "stringValue")
        defer { context.shutDown() }
        #expect(context.focusedProperty == "stringValue")
        context.select(entity: "Sample")
        // The same entity: nothing to forget.
        #expect(context.focusedProperty == "stringValue")

        context.show(BrowseLocation(entity: "Other"))
        #expect(context.focusedProperty == nil)
        model.refresh()
        await model.whenSettled()
        guard case .noField = model.state else {
            Issue.record("expected no field, got \(model.state)")
            return
        }
    }
}
