import Foundation
import Testing

@testable import DabbiQuery

private let validator = PredicateValidator(model: testModel)

private func validate(_ text: String, entity: String = "Author") -> PredicateValidation {
    validator.validate(text, entity: entity)
}

@Suite struct KeyPathResolutionTests {
    let resolver = KeyPathResolver(model: testModel)

    func target(_ keyPath: String, in entity: String = "Author") throws -> ResolvedKeyPath {
        try resolver.resolve(keyPath, in: entity).get()
    }

    @Test func attributesResolveToTheirType() throws {
        #expect(try target("name").typeGroup == .string)
        #expect(try target("age").typeGroup == .number)
        #expect(try target("rating").typeGroup == .number)
        #expect(try target("birthday").typeGroup == .date)
        #expect(try target("identifier").typeGroup == .uuid)
        #expect(try target("homepage").typeGroup == .uri)
        #expect(try target("avatar").typeGroup == .binary)
        #expect(try target("settings").typeGroup == .transformable)
    }

    @Test func relationshipsAreWalkedThrough() throws {
        #expect(try target("books").isCollection)
        #expect(try target("books.title").typeGroup == .string)
        #expect(try target("author.name", in: "Book").typeGroup == .string)
        #expect(try !target("author.name", in: "Book").isCollection)
    }

    /// Anything read through a to-many names many values, however far the path goes on.
    @Test func toManyKeepsTheCollectionFlagDownThePath() throws {
        #expect(try target("books.tags.label").isCollection)
        #expect(try target("books.author.name").isCollection)
    }

    @Test func countReducesACollectionToANumber() throws {
        let count = try target("books.@count")
        #expect(!count.isCollection)
        #expect(count.typeGroup == .number)
    }

    /// S3: a composite attribute's elements are addressable.
    @Test func compositeElementsResolve() throws {
        #expect(try target("place.latitude", in: "Book").typeGroup == .number)
        let failure = resolver.resolve("place.altitude", in: "Book")
        guard case .failure(let error) = failure else {
            Issue.record("expected a failure")
            return
        }
        #expect(error.reason == .unknownCompositeElement(attribute: "place"))
    }

    @Test func inheritedAttributesAreVisibleOnTheSubentity() throws {
        #expect(try target("title", in: "Photo").typeGroup == .string)
        #expect(try target("width", in: "Photo").typeGroup == .number)
    }

    @Test func unknownPropertiesFailWithCandidates() {
        guard case .failure(let error) = resolver.resolve("nmae", in: "Author") else {
            Issue.record("expected a failure")
            return
        }
        #expect(error.reason == .unknownProperty(entity: "Author"))
        #expect(error.keyPath == "nmae")
        #expect(error.suggestions == ["name"])
        #expect(error.candidates.contains("books"))
    }

    @Test func aPathCannotContinuePastAnAttribute() {
        guard case .failure(let error) = resolver.resolve("name.length", in: "Author") else {
            Issue.record("expected a failure")
            return
        }
        #expect(error.reason == .notTraversable(kind: "String"))
    }

    @Test func candidatesAfterACollectionIncludeTheOperators() throws {
        let after = resolver.candidates(after: try target("books"))
        #expect(after.contains("title"))
        #expect(after.contains("@count"))
        let afterToOne = resolver.candidates(after: try target("author", in: "Book"))
        #expect(afterToOne.contains("name"))
        #expect(!afterToOne.contains("@count"))
    }
}

@Suite struct PredicateValidationTests {
    @Test func aGoodPredicateHasNoDiagnostics() {
        let result = validate(#"age > 30 AND name BEGINSWITH[cd] "a""#)
        #expect(result.isValid)
        #expect(result.diagnostics.isEmpty)
    }

    @Test func unknownKeyPathsAreErrorsAndAreListed() {
        let result = validate("nmae == \"x\" AND books.titel == \"y\"")
        #expect(!result.isValid)
        #expect(result.missingKeyPaths == ["nmae", "books.titel"])
        #expect(result.errors.count == 2)
        #expect(result.errors[0].suggestions == ["name"])
        #expect(result.errors[1].keyPath == "books.titel")
    }

    /// The SQLite store cannot compare "one of many" without being told which, so this is an error, not a style
    /// note: the fetch would raise.
    @Test func aBareToManyKeyPathNeedsAQuantifier() {
        let result = validate(#"books.title == "Swift""#)
        #expect(!result.isValid)
        #expect(result.errors[0].keyPath == "books.title")
        #expect(result.errors[0].suggestions.contains(#"ANY books.title == …"#))
    }

    @Test func quantifiersOnASingleValueAreAWarning() {
        let result = validate("ANY age > 30")
        #expect(result.isValid)
        #expect(result.warnings.count == 1)
        #expect(result.warnings[0].message.contains("ANY"))
    }

    @Test func quantifiedToManyPathsArePlain() {
        #expect(validate(#"ANY books.title == "Swift""#).diagnostics.isEmpty)
        #expect(validate("ALL books.price > 10").diagnostics.isEmpty)
        #expect(validate("NONE books.price > 10").diagnostics.isEmpty)
        #expect(validate("books.@count > 3").diagnostics.isEmpty)
    }

    @Test func onlyCountIsSupportedByTheStore() {
        let result = validate("books.@sum > 3")
        #expect(result.isValid)
        #expect(result.warnings.count == 1)
        #expect(result.warnings[0].message.contains("@count"))
    }

    @Test func comparingTextWithANumberIsAWarning() {
        let result = validate("name == 30")
        #expect(result.isValid)
        #expect(result.warnings.count == 1)
        #expect(result.warnings[0].keyPath == "name")
    }

    /// Core Data stores booleans as numbers and UUIDs are usually typed as text, so neither is worth a warning.
    @Test func forgivingComparisonsStaySilent() {
        #expect(validate("age == 30").diagnostics.isEmpty)
        #expect(validate("rating > 1").diagnostics.isEmpty)
        #expect(validate(#"identifier == "8E2F-…""#).diagnostics.isEmpty)
        #expect(validate(#"homepage BEGINSWITH "https""#).diagnostics.isEmpty)
    }

    @Test func transformableAttributesCannotBeCompared() {
        let result = validate(#"settings == "x""#)
        #expect(result.warnings.count == 1)
        #expect(result.warnings[0].message.contains("archive"))
    }

    @Test func inAndBetweenNeedACollection() {
        #expect(validate(#"name IN {"a", "b"}"#).diagnostics.isEmpty)
        #expect(validate("age BETWEEN {10, 20}").diagnostics.isEmpty)
        #expect(!validate(#"name IN "a""#).isValid)
        #expect(!validate("age BETWEEN {10, 20, 30}").isValid)
    }

    @Test func stringOptionsOnANumericOperatorAreAWarning() {
        let result = validate("age >[cd] 30")
        #expect(result.isValid)
        #expect(result.warnings.count == 1)
        #expect(result.warnings[0].message.contains("[cd]"))
    }

    @Test func subqueryIteratorsAreBoundToTheirEntity() {
        #expect(validate("SUBQUERY(books, $b, $b.price > 10).@count > 2").diagnostics.isEmpty)
        let bad = validate("SUBQUERY(books, $b, $b.cost > 10).@count > 2")
        #expect(!bad.isValid)
        #expect(bad.missingKeyPaths == ["cost"])
        // The iterator is not something the user has to supply a value for.
        #expect(bad.substitutionVariables.isEmpty)
    }

    @Test func substitutionVariablesAreCollected() {
        let result = validate("name == $NAME AND age > $MIN_AGE")
        #expect(result.substitutionVariables == ["MIN_AGE", "NAME"])
        #expect(result.isValid)
    }

    @Test func syntaxErrorsComeBackAsDiagnostics() {
        let result = validate("age >")
        #expect(!result.isValid)
        #expect(!result.errors[0].message.isEmpty)
    }

    @Test func anUnknownEntityIsAnError() {
        #expect(!validate("age > 30", entity: "Nope").isValid)
    }

    @Test func functionsAreWalkedForKeyPaths() {
        #expect(validate(#"lowercase(name) == "x""#).diagnostics.isEmpty)
        #expect(validate(#"lowercase(nmae) == "x""#).missingKeyPaths == ["nmae"])
    }
}
