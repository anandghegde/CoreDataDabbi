import AppKit
import DabbiKit
import FixtureKit
import Foundation
import Testing

@testable import CoreDataDabbi

/// The visual builder (M2-03): what it shows for the text in the bar, and what it writes back. The shapes and
/// rows themselves are the engine's (`PredicateBuilderSchemaTests`); these go through a real `NSPredicateEditor`
/// with the app's templates, which is where a row that does not read back would show.
@MainActor
@Suite struct PredicateBuilderTests {
    private func builder() async throws -> (ProjectContext, PredicateBarModel, PredicateBuilderViewController) {
        let context = try await TestProject.context(on: .company)
        let model = PredicateBarModel(context: context)
        model.follow()
        model.isShowingBuilder = true
        let builder = PredicateBuilderViewController(model: model)
        builder.loadView()
        return (context, model, builder)
    }

    /// Shows `text` in the builder, reads the editor back into the bar, and returns what the bar then says.
    private func roundTrip(
        _ text: String, model: PredicateBarModel, builder: PredicateBuilderViewController
    )
        -> String?
    {
        model.text = text
        builder.follow()
        guard let predicate = builder.editor.objectValue as? NSPredicate else { return nil }
        model.takeFromBuilder(predicate)
        return model.text
    }

    @Test(arguments: [
        #"name == "Department 1""#,
        #"name BEGINSWITH[cd] "dep""#,
        #"name IN {"a", "b, c"}"#,
        #"name == $NAME"#,
        #"organisation.name CONTAINS[c] "x" AND head == nil"#,
        #"organisation != nil"#,
        #"organisation.createdAt > CAST(700000000, "NSDate")"#,
        #"organisation.createdAt BETWEEN {CAST(700000000, "NSDate"), CAST(700086400, "NSDate")}"#,
        #"ANY employees.age > 30"#,
        #"ALL employees.salary >= 100.5"#,
        #"NONE employees.title == "CEO""#,
        #"employees.@count BETWEEN {1, 5}"#,
        #"name == "a" OR name == "b""#,
        #"(name == "a" OR name == "b") AND NOT (head == nil)"#,
        #"head.level > 2"#,
    ])
    func readsBackWhatItShows(_ text: String) async throws {
        let (context, model, builder) = try await builder()
        defer { context.shutDown() }
        guard case .rows = model.builderContent else {
            Issue.record("no rows for \(text): \(String(describing: model.builderContent))")
            return
        }
        let expected = try PredicateAST.parse(text).normalisedForBuilder()
        let written = try #require(roundTrip(text, model: model, builder: builder))
        #expect(try PredicateAST.parse(written).normalisedForBuilder() == expected, "\(text) came back as \(written)")
        #expect(builder.editor.numberOfRows > 1)
    }

    @Test func anEmptyFieldIsAnEmptyBuilder() async throws {
        let (context, model, builder) = try await builder()
        defer { context.shutDown() }
        #expect(model.builderContent == .rows(.and([]), try #require(model.schema)))
        builder.follow()
        // The root row alone, and no filter when read back.
        #expect(builder.editor.numberOfRows == 1)
        #expect(roundTrip("", model: model, builder: builder) == "")
    }

    @Test func keepsAsTextWhatItHasNoRowsFor() async throws {
        let (context, model, _) = try await builder()
        defer { context.shutDown() }
        model.text = "SUBQUERY(employees, $e, $e.age > 3).@count > 0"
        guard case .text(let reasons) = model.builderContent else {
            Issue.record("expected text, found \(String(describing: model.builderContent))")
            return
        }
        #expect(!reasons.isEmpty)

        // What does not check is not for the builder either; the reason is the field's own.
        model.text = "nope > 3"
        #expect(model.builderContent == .text([try #require(model.message)]))
    }

    @Test func writesAnEditedValueIntoTheField() async throws {
        let (context, model, builder) = try await builder()
        defer { context.shutDown() }
        model.text = #"name == "a""#
        builder.follow()
        let field = try #require(
            textFields(in: builder.editor).first { $0.isEditable && $0.stringValue == "a" })
        // What ending the edit does: the field tells the editor, which tells the builder, which writes the bar.
        field.stringValue = "b"
        field.sendAction(field.action, to: field.target)
        #expect(model.text == #"name == "b""#)
        // The builder wrote it, so it does not redraw for it: the keyboard stays in the row.
        #expect(builder.shownText == #"name == "b""#)
    }

    @Test func aNumberFieldTakesOnlyNumbers() {
        let formatter = BuilderValueFormatter(kind: .integer, isList: false)
        var object: AnyObject?
        #expect(formatter.getObjectValue(&object, for: "12", errorDescription: nil))
        #expect(formatter.getObjectValue(&object, for: "$LIMIT", errorDescription: nil))
        #expect(!formatter.getObjectValue(&object, for: "twelve", errorDescription: nil))

        let list = BuilderValueFormatter(kind: .integer, isList: true)
        #expect(list.getObjectValue(&object, for: "1, 2, 3", errorDescription: nil))
        #expect(!list.getObjectValue(&object, for: "1, two", errorDescription: nil))
    }

    @Test func offersEveryKeyPathOnceAndNamesItsControls() async throws {
        let (context, model, _) = try await builder()
        defer { context.shutDown() }
        let schema = try #require(model.schema)
        let templates = PredicateBuilderTemplates.make(for: schema) {}.compactMap { $0 as? BuilderRowTemplate }
        // Every key path is in some template, and each template's pop-ups have accessibility labels.
        let offered = Set(templates.flatMap { $0.spec.fields.map(\.keyPath) })
        #expect(offered == Set(schema.fields.map(\.keyPath)))
        for template in templates {
            // Labels (the "and" of a BETWEEN) are read out as what they say.
            let controls = template.templateViews.filter { view in
                guard let field = view as? NSTextField else { return view is NSControl }
                return field.isEditable
            }
            for view in controls {
                #expect(view.accessibilityLabel()?.isEmpty == false, "\(view) in \(template.spec.kind)")
            }
        }
    }

    private func textFields(in view: NSView) -> [NSTextField] {
        view.subviews.flatMap { subview in
            (subview as? NSTextField).map { [$0] } ?? textFields(in: subview)
        }
    }
}
