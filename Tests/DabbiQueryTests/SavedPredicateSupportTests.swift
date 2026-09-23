import DabbiBase
import Foundation
import Testing

@testable import DabbiQuery

@Suite struct SavedPredicateCheckTests {
    let validator = PredicateValidator(model: testModel)

    func check(_ format: String?, entity: String = "Author", sort: [SortKey] = []) -> SavedPredicateCheck {
        validator.check(entity: entity, predicate: format.map(PredicateSource.init(format:)), sort: sort)
    }

    @Test func aPredicateThatStillFitsIsFine() {
        #expect(check("age > 30 AND ANY books.title BEGINSWITH[cd] \"a\"", sort: [SortKey(keyPath: "name")]) == .fine)
        #expect(check(nil) == .fine, "no predicate is every row, and every model has those")
    }

    @Test func missingKeyPathsAreNamedRatherThanRefused() {
        let result = check(
            "nickname == \"x\" OR age > 3", sort: [SortKey(keyPath: "shoeSize"), SortKey(keyPath: "age")])
        #expect(!result.isUsable)
        #expect(!result.isMissingEntity)
        #expect(result.missingKeyPaths == ["nickname", "shoeSize"])
        #expect(result.problems.count == 2)
        #expect(result.problems[1].contains("shoeSize"))
    }

    @Test func aKeyPathMissingFromBothIsNamedOnce() {
        let result = check("nickname == \"x\"", sort: [SortKey(keyPath: "nickname")])
        #expect(result.missingKeyPaths == ["nickname"])
    }

    @Test func aMissingEntityIsSaidPlainly() {
        let result = check("age > 3", entity: "Writer")
        #expect(result.isMissingEntity)
        #expect(result.problems == ["There is no entity named “Writer” in the model."])
    }
}

@Suite struct SavedPredicateNamingTests {
    func name(_ format: String?, entity: String = "Author") -> String {
        SavedPredicateNaming.defaultName(for: format.map(PredicateSource.init(format:)), entity: entity)
    }

    @Test func theFirstConditionNamesIt() {
        #expect(name("age > 30 AND name BEGINSWITH[cd] \"a\"") == "age > 30")
        #expect(name("(rating < 2 OR rating > 4) AND age > 3") == "rating < 2")
        #expect(name("ANY books.title == \"Emma\"") == "ANY books.title == \"Emma\"")
    }

    @Test func aNegationKeepsItsNot() {
        #expect(name("NOT name == \"x\"") == "NOT name == \"x\"")
    }

    @Test func withoutAConditionTheEntityNamesIt() {
        #expect(name(nil) == "Author")
        #expect(name("TRUEPREDICATE") == "Author")
        #expect(name("not a predicate ((") == "Author")
    }

    @Test func aLongConditionIsShortened() {
        let long = name("name == \"\(String(repeating: "a", count: 80))\"")
        #expect(long.count == SavedPredicateNaming.maximumLength)
        #expect(long.hasSuffix("…"))
    }
}

@Suite struct StarterPredicateTests {
    @Test func aNewPredicateStartsOnTheNameOrTitle() throws {
        #expect(BuilderSchema(model: testModel, entity: "Author").preferredField?.keyPath == "name")
        #expect(BuilderSchema(model: testModel, entity: "Book").preferredField?.keyPath == "title")
        #expect(BuilderSchema(model: testModel, entity: "Tag").preferredField == nil)
    }

    @Test func theStarterRowIsOneTheBuilderCanShow() throws {
        let schema = BuilderSchema(model: testModel, entity: "Author")
        let starter = try #require(schema.starterPredicate)
        #expect(try starter.formatString() == #"name CONTAINS[cd] """#)
        guard case .rows = schema.presentation(of: starter) else {
            Issue.record("the builder has no row for its own starter")
            return
        }
    }
}
