import DabbiKit
import FixtureKit
import Foundation
import Testing

@testable import CoreDataDabbi

/// The predicate bar's half of M2-02: what the field says about what is typed, and what applying it does to the
/// project. The field itself is a window's business (`ProjectWindowTests`).
@MainActor
@Suite struct PredicateBarModelTests {
    private func bar() async throws -> (ProjectContext, PredicateBarModel) {
        let context = try await TestProject.context(on: .company)
        let model = PredicateBarModel(context: context)
        model.follow()
        return (context, model)
    }

    @Test func startsEmptyOnTheEntityTheGridShows() async throws {
        let (context, model) = try await bar()
        #expect(model.entity == "Department")
        #expect(model.status == .empty)
        #expect(model.message == nil)
        #expect(!model.isFiltering)
        // Nothing typed and nothing applied: there is nothing to do.
        #expect(!model.canApply)
        #expect(model.isApplied)
        context.shutDown()
    }

    @Test func appliesWhatItChecked() async throws {
        let (context, model) = try await bar()
        model.text = "  name == \"Department 1\"  "
        #expect(model.status == .valid([]))
        #expect(model.canApply)

        model.apply()
        // What is applied is what was checked, not the stray spaces around it.
        #expect(model.text == "name == \"Department 1\"")
        #expect(context.layout(of: "Department").filter == PredicateSource(format: "name == \"Department 1\""))
        #expect(model.isFiltering)
        #expect(model.isApplied)
        #expect(!model.canApply)
        context.shutDown()
    }

    @Test func refusesWhatTheModelDoesNotHave() async throws {
        let (context, model) = try await bar()
        model.text = "nope > 3"
        guard case .invalid(let diagnostic) = model.status else {
            Issue.record("expected an error, found \(model.status)")
            context.shutDown()
            return
        }
        #expect(diagnostic.keyPath == "nope")
        #expect(model.isShowingError)
        #expect(model.message == diagnostic.message)
        #expect(!model.canApply)

        // Applying it anyway does nothing: a predicate that cannot be checked never reaches a fetch.
        model.apply()
        #expect(context.layout(of: "Department").filter == nil)
        context.shutDown()
    }

    @Test func saysWhatIsWrongWithHalfAPredicate() async throws {
        let (context, model) = try await bar()
        model.text = "name =="
        #expect(model.isShowingError)
        #expect(model.message != nil)
        #expect(!model.suggestions.isEmpty)

        // A predicate that could run arbitrary code is refused here as well as at the fetch (`PredicateGuard`).
        model.text = "FUNCTION(name, 'lowercaseString') == \"a\""
        #expect(model.isShowingError)
        context.shutDown()
    }

    @Test func aWarningSaysSoWithoutStandingInTheWay() async throws {
        let (context, model) = try await bar()
        // The left side holds text and the right side is a number: it runs, and it is probably not meant.
        model.text = "name == 30"
        guard case .valid(let warnings) = model.status, let warning = warnings.first else {
            Issue.record("expected a warning, found \(model.status)")
            context.shutDown()
            return
        }
        #expect(warning.severity == .warning)
        #expect(model.message == warning.message)
        #expect(!model.isShowingError)
        #expect(model.canApply)
        context.shutDown()
    }

    @Test func eachEntityKeepsItsOwnFilter() async throws {
        let (context, model) = try await bar()
        model.text = "name == \"Department 1\""
        model.apply()

        context.select(entity: "Employee")
        model.follow()
        #expect(model.entity == "Employee")
        #expect(model.text == "")

        // Typing is not applying: the loop runs on every change in the window and must leave the field alone.
        model.text = "age > 30"
        model.follow()
        #expect(model.text == "age > 30")

        context.select(entity: "Department")
        model.follow()
        #expect(model.text == "name == \"Department 1\"")
        #expect(model.isApplied)
        context.shutDown()
    }

    @Test func aFilterChangedElsewhereReachesTheField() async throws {
        let (context, model) = try await bar()
        context.setFilter(PredicateSource(format: "name != nil"), of: "Department")
        model.follow()
        #expect(model.text == "name != nil")
        #expect(model.isApplied)
        context.shutDown()
    }

    @Test func revertsAndClears() async throws {
        let (context, model) = try await bar()
        model.text = "name == \"Department 1\""
        model.apply()

        model.text = "name == \"Department 2\""
        #expect(model.canApply)
        model.revert()
        #expect(model.text == "name == \"Department 1\"")
        #expect(model.isApplied)

        model.clear()
        #expect(model.text == "")
        #expect(context.layout(of: "Department").filter == nil)
        #expect(!model.isFiltering)
        context.shutDown()
    }

    @Test func completesAgainstTheEntityTheGridShows() async throws {
        let (context, model) = try await bar()
        let completions = model.completions(in: "na", at: 2)
        #expect(completions.range == 0..<2)
        #expect(completions.items.map(\.text) == ["name"])

        context.select(entity: "Employee")
        model.follow()
        #expect(model.completions(in: "sal", at: 3).items.map(\.text) == ["salary"])
        context.shutDown()
    }

    @Test func saysNothingWithoutAStore() {
        let context = ProjectContext()
        let model = PredicateBarModel(context: context)
        model.follow()
        model.text = "name == \"a\""
        #expect(model.entity == nil)
        #expect(model.status == .empty)
        #expect(model.completions(in: "na", at: 2).isEmpty)
        model.apply()
        #expect(!model.isFiltering)
    }
}
