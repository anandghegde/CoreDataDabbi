import DabbiKit
import FixtureKit
import Testing

@testable import CoreDataDabbi

@MainActor
@Suite struct RelationshipsModelTests {
    /// A panel over the company fixture, with the grid's selection on the first row of `entity`.
    private func model(
        on entity: String, in fixture: Fixture = .company
    ) async throws -> (ProjectContext, RelationshipsModel) {
        let context = try await TestProject.context(on: fixture)
        let session = try #require(context.session)
        let handle = try await session.openPager(FetchSpec(entity: entity))
        let page = try await session.page(handle, range: 0..<min(1, handle.count))
        let ref = try #require(page.rows.first?.ref)
        await session.closePager(handle)

        context.show(BrowseLocation(entity: entity))
        context.focus(on: ref)
        let model = RelationshipsModel(context: context)
        model.refresh()
        await model.whenSettled()
        return (context, model)
    }

    private func rows(of model: RelationshipsModel) throws -> [RelationshipsModel.Row] {
        guard case .ready(_, let rows) = model.state else {
            Issue.record("the panel read nothing: \(model.state)")
            throw DabbiError(.internal, "no rows")
        }
        return rows
    }

    @Test func listsEveryRelationshipOfTheSelectedRowWithItsCount() async throws {
        let (context, model) = try await self.model(on: "Department")
        defer { context.shutDown() }

        let rows = try rows(of: model)
        #expect(rows.map(\.id) == ["employees", "head", "organisation"])
        let employees = try #require(rows.first { $0.id == "employees" })
        #expect(employees.count > 0)
        #expect(employees.summary == "To-many → Employee")
        // The counts come from the object's own row, which the grid has already shown.
        let organisation = try #require(rows.first { $0.id == "organisation" })
        #expect(organisation.count == 1)
        #expect(organisation.display?.isEmpty == false)
        #expect(organisation.summary.hasPrefix("To-one → Organisation"))
    }

    @Test func saysWhenARelationshipHasNoInverse() async throws {
        let (context, model) = try await self.model(on: "Department")
        defer { context.shutDown() }

        // Department.head points at a Manager that does not point back (REL-2).
        let head = try #require(try rows(of: model).first { $0.id == "head" })
        #expect(head.summary == "To-one → Manager · no inverse")
        #expect(head.count == 1)
        #expect(head.display?.hasPrefix("Manager") == true)
    }

    @Test func followsTheFirstRelationshipThatHasSomethingInIt() async throws {
        let (context, model) = try await self.model(on: "Department")
        defer { context.shutDown() }

        #expect(model.selected == "employees")
        let related = try #require(model.related)
        #expect(related.relationship == "employees")
        #expect(!related.items.isEmpty)
        #expect(related.items.allSatisfy { ["Employee", "Manager"].contains($0.object.entity) })
        #expect(model.relatedError == nil)
    }

    @Test func readsAnotherRelationshipWhenOneIsChosen() async throws {
        let (context, model) = try await self.model(on: "Department")
        defer { context.shutDown() }

        model.select("organisation")
        await model.whenSettled()
        let related = try #require(model.related)
        #expect(related.relationship == "organisation")
        #expect(related.items.count == 1)
        #expect(related.items.first?.object.entity == "Organisation")
        // The choice is the project's, so the panel opens on the same relationship next time.
        #expect(context.local.selection.relationship == "organisation")
    }

    @Test func showsARelatedObjectWithoutMovingTheGrid() async throws {
        let (context, model) = try await self.model(on: "Department")
        defer { context.shutDown() }

        let source = try #require(context.navigation.current?.focus)
        let item = try #require(model.related?.items.first)
        model.selectItem(item.object)

        // The inspector and the content viewer follow the panel; the grid stays on the row it had (REL-1).
        #expect(context.inspectedRef == item.ref)
        #expect(context.navigation.current?.focus == source)
        #expect(context.navigation.current?.entity == "Department")

        // Letting go of it gives them the grid's row back.
        model.selectItem(nil)
        #expect(context.inspectedRef == source)
    }

    @Test func jumpsTheGridToARelatedObjectAndRemembersTheWayThere() async throws {
        let (context, model) = try await self.model(on: "Department")
        defer { context.shutDown() }

        let label = try #require(model.sourceLabel)
        #expect(label.hasPrefix("Department"))
        let item = try #require(model.related?.items.first)
        model.reveal(try #require(item.ref))

        #expect(context.navigation.current?.entity == item.object.entity)
        #expect(context.navigation.current?.focus == item.ref)
        #expect(context.inspectedRef == item.ref)
        #expect(context.navigation.current?.trail == [label, "employees"])
        // And it is somewhere to come back from.
        #expect(context.navigation.canGoBack)
        context.goBack()
        #expect(context.navigation.current?.entity == "Department")
        #expect(context.navigation.current?.trail.isEmpty == true)
    }

    @Test func growsTheTrailWhileTheDrillingGoesOn() async throws {
        let (context, model) = try await self.model(on: "Department")
        defer { context.shutDown() }

        let department = try #require(model.sourceLabel)
        let employee = try #require(model.related?.items.first)
        model.reveal(try #require(employee.ref))
        model.refresh()
        await model.whenSettled()

        // From the employee, back to the department it belongs to: a third crumb, not a new trail.
        model.select("department")
        await model.whenSettled()
        let back = try #require(model.related?.items.first)
        model.reveal(try #require(back.ref))
        #expect(context.navigation.current?.trail == [department, "employees", "department"])

        // The first crumb names where the drilling started, and clicking it goes back there.
        context.goBack(toTrailLength: 0)
        #expect(context.navigation.current?.entity == "Department")
        #expect(context.navigation.current?.trail.isEmpty == true)
    }

    @Test func startsAFreshTrailWhenTheDrillingStartsSomewhereElse() async throws {
        let (context, model) = try await self.model(on: "Department")
        defer { context.shutDown() }

        let item = try #require(model.related?.items.first)
        model.reveal(try #require(item.ref))
        #expect(context.navigation.current?.trail.count == 2)

        // The sidebar is not a relationship: landing on an entity leaves no trail behind it.
        context.select(entity: "Tag")
        #expect(context.navigation.current?.trail.isEmpty == true)
    }

    @Test func readsTheOrderOfAnOrderedRelationship() async throws {
        let (context, model) = try await self.model(on: "Playlist", in: .ordered)
        defer { context.shutDown() }

        let rows = try rows(of: model)
        let tracks = try #require(rows.first { $0.relationship.isOrdered })
        #expect(tracks.summary.contains("ordered"))
        model.select(tracks.id)
        await model.whenSettled()

        let related = try #require(model.related)
        #expect(related.isOrdered)
        #expect(related.items.count == related.count)
        // The stored order, which is the one the panel numbers. The fixture gives each playlist its featured
        // tracks out of order deliberately, and the labels say which they are: the object IDs the store hands
        // out are its own business and differ from one build of the fixture to the next.
        let playlist = try #require(model.sourceLabel?.split(separator: " ").last.flatMap { Int($0) })
        let featured = [(playlist + 5) % 12, playlist, (playlist + 9) % 12]
        #expect(related.items.map(\.label) == featured.map { "Track \($0)" })
    }

    @Test func hasNothingToShowWhenNoRowIsSelected() async throws {
        let context = try await TestProject.context(on: .company)
        defer { context.shutDown() }
        context.focus(on: nil)

        let model = RelationshipsModel(context: context)
        model.refresh()
        await model.whenSettled()
        guard case .noObject = model.state else {
            Issue.record("the panel read something with nothing selected: \(model.state)")
            return
        }
        #expect(model.related == nil)
    }
}
