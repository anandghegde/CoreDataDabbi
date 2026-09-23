import DabbiBase
import DabbiModel
import Foundation
import Testing

@testable import DabbiQuery

@Suite struct FetchTemplatePlanTests {
    func plan(_ format: String?, entity: String? = "Author", limit: Int = 0) -> FetchTemplatePlan {
        FetchTemplatePlan(
            template: FetchRequestTemplate(
                name: "Test", entity: entity, predicateFormat: format, sort: [SortKey(keyPath: "name")],
                fetchLimit: limit),
            model: testModel)
    }

    @Test func variablesAreTypedByWhatTheyAreComparedWith() {
        let found = plan("name BEGINSWITH[cd] $PREFIX AND age > $MIN AND birthday < $BEFORE AND identifier == $ID")
            .variables
        #expect(found.map(\.name) == ["PREFIX", "MIN", "BEFORE", "ID"], "in the order the predicate asks")
        #expect(found.map(\.kind) == [.string, .integer, .date, .uuid])
        #expect(found.map(\.keyPath) == ["name", "age", "birthday", "identifier"])
        #expect(found.allSatisfy { $0.arity == .single })
    }

    @Test func aVariableOnTheLeftIsReadTheSameWay() {
        #expect(plan("$MIN < age").variables == [FetchTemplateVariable(name: "MIN", keyPath: "age", kind: .integer)])
    }

    @Test func inTakesAListAndBetweenAPair() {
        let found = plan("name IN $NAMES AND age BETWEEN $RANGE AND rating BETWEEN {$LOW, $HIGH}").variables
        #expect(found.map(\.arity) == [.list, .pair, .single, .single])
        #expect(found.map(\.kind) == [.string, .integer, .decimal, .decimal])
    }

    @Test func aSubqueryIteratorIsNotAVariable() {
        let found = plan("SUBQUERY(books, $b, $b.pages > $PAGES).@count > 0").variables
        #expect(found.map(\.name) == ["PAGES"])
        #expect(found[0].kind == .string, "a key path on the iterator says nothing the prompt can use")
    }

    @Test func aVariableMentionedTwiceIsAskedForOnce() {
        let found = plan("name == $X OR age == $X").variables
        #expect(found == [FetchTemplateVariable(name: "X", keyPath: "name", kind: .string)])
    }

    @Test func aRelationshipGivesNoTypeToType() {
        let found = FetchTemplatePlan(
            template: FetchRequestTemplate(name: "T", entity: "Book", predicateFormat: "author == $WHO"),
            model: testModel
        ).variables
        #expect(found == [FetchTemplateVariable(name: "WHO", keyPath: "author", kind: .string)])
    }

    @Test func whatStopsATemplateFromRunningIsSaid() {
        #expect(plan("age > 3").isRunnable)
        #expect(plan(nil).isRunnable, "no predicate is every row")
        #expect(plan("age > 3", entity: "Writer").problems == ["There is no entity named “Writer” in the model."])
        #expect(plan("age > 3", entity: nil).entity == nil)
        #expect(!plan("age > 3", entity: nil).isRunnable)
    }

    @Test func limitAndSortComeFromTheTemplate() {
        #expect(plan(nil).limit == nil)
        #expect(plan(nil, limit: 25).limit == 25)
        #expect(plan(nil).sort == [SortKey(keyPath: "name")])
    }

    @Test func valuesGoIntoThePredicate() throws {
        let plan = plan("name BEGINSWITH[cd] $PREFIX AND age > $MIN")
        let source = try plan.predicate(with: ["PREFIX": .string("Jo"), "MIN": .int(30)])
        #expect(try source?.ast() == PredicateAST.parse("name BEGINSWITH[cd] \"Jo\" AND age > 30"))
        #expect(try self.plan(nil).predicate(with: [:]) == nil)
    }

    @Test func listsAndPairsGoInAsCollections() throws {
        let plan = plan("name IN $NAMES AND age BETWEEN $RANGE")
        let source = try plan.predicate(with: [
            "NAMES": .array([.string("a"), .string("b")]), "RANGE": .array([.int(1), .int(9)]),
        ])
        #expect(try source?.ast() == PredicateAST.parse("name IN {\"a\", \"b\"} AND age BETWEEN {1, 9}"))
    }

    @Test func aSubqueryKeepsItsIterator() throws {
        let source = try plan("SUBQUERY(books, $b, $b.pages > $PAGES).@count > 0").predicate(with: [
            "PAGES": .string("x")
        ])
        #expect(source?.format.contains("$b") == true, "\(source?.format ?? "")")
        #expect(source?.format.contains("$PAGES") == false)
    }

    @Test func aMissingOrWrongValueIsRefused() {
        let plan = plan("age > $MIN")
        #expect(throws: DabbiError.self) { try plan.predicate(with: [:]) }
        #expect(throws: DabbiError.self) { try plan.predicate(with: ["MIN": .string("old")]) }
        #expect(throws: DabbiError.self) { try self.plan("age > 3", entity: "Writer").predicate(with: [:]) }
    }
}

@Suite struct FetchTemplateVariableTests {
    @Test func textIsReadAsTheVariablesKind() {
        #expect(FetchTemplateVariable(name: "N", kind: .integer).value(from: "42") == .int(42))
        #expect(FetchTemplateVariable(name: "N", kind: .integer).value(from: "forty") == nil)
        #expect(FetchTemplateVariable(name: "N", kind: .integer).value(from: "$N") == nil)
        #expect(FetchTemplateVariable(name: "S").value(from: " $N ") == .string(" $N "), "text is taken as typed")
        #expect(FetchTemplateVariable(name: "B", kind: .boolean).value(from: "Yes") == .bool(true))
        #expect(FetchTemplateVariable(name: "B", kind: .boolean).value(from: "maybe") == nil)
        let id = UUID()
        #expect(FetchTemplateVariable(name: "U", kind: .uuid).value(from: id.uuidString) == .uuid(id))
    }

    @Test func datesAreISO8601() {
        let variable = FetchTemplateVariable(name: "D", kind: .date)
        #expect(variable.value(from: "2026-09-23T10:00:00Z") == .date(Date(timeIntervalSince1970: 1_790_157_600)))
        #expect(variable.value(from: "2026-09-23") != nil)
        #expect(variable.value(from: "yesterday") == nil)
    }

    @Test func listsAndPairs() {
        let list = FetchTemplateVariable(name: "L", kind: .integer, arity: .list)
        #expect(list.value(from: "1, 2, 3") == .array([.int(1), .int(2), .int(3)]))
        #expect(list.value(from: "1, two") == nil)
        #expect(list.value(from: "") == nil, "an empty list is no row at all")
        #expect(!list.accepts(.array([])))
        let pair = FetchTemplateVariable(name: "P", kind: .integer, arity: .pair)
        #expect(pair.value(from: "1, 2") == .array([.int(1), .int(2)]))
        #expect(pair.value(from: "1, 2, 3") == nil)
        let names = FetchTemplateVariable(name: "L", arity: .list)
        #expect(names.value(from: "a, \"b, c\", $d") == .array([.string("a"), .string("b, c"), .string("$d")]))
    }

    @Test func acceptsHoldsLiteralsToTheSameRule() {
        let date = FetchTemplateVariable(name: "D", kind: .date)
        #expect(date.accepts(.date(.now)))
        #expect(!date.accepts(.string("now")))
        #expect(!date.accepts(.array([.date(.now)])))
        let pair = FetchTemplateVariable(name: "P", kind: .integer, arity: .pair)
        #expect(pair.accepts(.array([.int(1), .int(2)])))
        #expect(!pair.accepts(.array([.int(1)])))
        #expect(!pair.accepts(.int(1)))
    }
}
