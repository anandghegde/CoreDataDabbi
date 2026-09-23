@preconcurrency import CoreData
import DabbiBase
import DabbiModel
import Foundation
import Testing

@testable import DabbiQuery

@Suite struct QuickFilterTests {
    func filter(_ entity: String, in model: ModelDescription = testModel) throws -> QuickFilter {
        try #require(QuickFilter(model: model, entity: entity))
    }

    @Test func itSearchesTheEntitysOwnStringsAndNothingElse() throws {
        #expect(try filter("Author").keyPaths == ["name"], "not the URI, the UUID or anything through books")
        #expect(try filter("Book").keyPaths == ["title"], "the composite has numbers only")
        #expect(try filter("Photo").keyPaths == ["title"], "inherited from Media")
        #expect(QuickFilter(model: testModel, entity: "Writer") == nil)
    }

    @Test func compositeStringsAreSearchedAndTransientsAreNot() throws {
        let model = Self.addressModel
        // In the model's order, which is by name: the composite's elements in theirs.
        #expect(try filter("Contact", in: model).keyPaths == ["address.street", "address.city", "name"])
    }

    @Test func aTermIsLookedForInEveryStringIgnoringCaseAndDiacritics() throws {
        let quick = try filter("Contact", in: Self.addressModel)
        let ast = try #require(quick.predicate(for: "  zur "))
        let predicate = try ast.makePredicate()
        let row: [String: Any] = ["name": "Ana", "address": ["street": "Zürichstrasse", "city": "Bern"]]
        #expect(predicate.evaluate(with: row))
        #expect(!predicate.evaluate(with: ["name": "Ana", "address": ["street": "Main", "city": "Bern"]]))
        #expect(
            try ast.formatString()
                == #"address.street CONTAINS[cd] "zur" OR address.city CONTAINS[cd] "zur" OR name CONTAINS[cd] "zur""#)
    }

    @Test func anEmptyTermFiltersNothing() throws {
        let quick = try filter("Author")
        #expect(quick.predicate(for: "") == nil)
        #expect(quick.predicate(for: " \n") == nil)
        #expect(quick.narrowing(nil, by: " ") == nil)
        let applied = PredicateSource(format: "age > 3")
        #expect(quick.narrowing(applied, by: "") == applied)
    }

    @Test func anEntityWithoutStringsFindsNothing() throws {
        let model = Self.addressModel
        let quick = try filter("Reading", in: model)
        #expect(!quick.isSearchable)
        #expect(quick.predicate(for: "x") == PredicateAST.none)
        #expect(quick.predicate(for: "") == nil)
    }

    @Test func itNarrowsTheAppliedFilterRatherThanReplacingIt() throws {
        let quick = try filter("Author")
        let narrowed = try #require(quick.narrowing(PredicateSource(format: "age > 3 OR age < 1"), by: "ann"))
        #expect(narrowed.format == #"(age > 3 OR age < 1) AND (name CONTAINS[cd] "ann")"#)
        let validation = PredicateValidator(model: testModel).validate(narrowed.format, entity: "Author")
        #expect(validation.errors.isEmpty)
        #expect(quick.narrowing(nil, by: "ann")?.format == #"name CONTAINS[cd] "ann""#)
    }

    @Test func quotesAndBackslashesInATermAreLookedForAsTyped() throws {
        let quick = try filter("Author")
        let term = #"say "hi" \ 100%"#
        let narrowed = try #require(quick.narrowing(PredicateSource(format: "age > 3"), by: term))
        let parsed = NSPredicate(format: narrowed.format)
        #expect(parsed.evaluate(with: ["name": #"they say "HI" \ 100% of the time"#, "age": 4]))
        #expect(!parsed.evaluate(with: ["name": "they say hi", "age": 4]))
    }

    /// `Contact`: name, a composite `address` of street, city and a number, a transient `nickname`.
    /// `Reading`: value, taken.
    static let addressModel: ModelDescription = {
        func attribute(_ name: String, _ type: NSAttributeType, transient: Bool = false) -> NSAttributeDescription {
            let attribute = NSAttributeDescription()
            attribute.name = name
            attribute.attributeType = type
            attribute.isOptional = true
            attribute.isTransient = transient
            return attribute
        }
        let address = NSCompositeAttributeDescription()
        address.name = "address"
        address.isOptional = true
        address.elements = [
            attribute("street", .stringAttributeType), attribute("number", .integer32AttributeType),
            attribute("city", .stringAttributeType),
        ]
        let contact = NSEntityDescription()
        contact.name = "Contact"
        contact.properties = [
            attribute("name", .stringAttributeType), address,
            attribute("nickname", .stringAttributeType, transient: true),
        ]
        let reading = NSEntityDescription()
        reading.name = "Reading"
        reading.properties = [attribute("value", .doubleAttributeType), attribute("taken", .dateAttributeType)]
        let model = NSManagedObjectModel()
        model.entities = [contact, reading]
        return ModelDescription(model)
    }()
}
