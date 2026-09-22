import Foundation
import Testing

@testable import DabbiQuery

private let completer = PredicateCompleter(model: testModel)

/// Completes with the caret at the end of `text`, which is where it is while somebody types.
private func complete(_ text: String, entity: String = "Author") -> PredicateCompletions {
    completer.completions(in: text, at: text.utf16.count, entity: entity)
}

private func words(_ text: String, entity: String = "Author") -> [String] {
    complete(text, entity: entity).items.map(\.text)
}

@Suite struct PredicateCompletionTests {

    // MARK: Key paths

    @Test func offersTheEntitysPropertiesAtTheStart() {
        let items = complete("").items
        #expect(items.contains { $0.text == "name" && $0.kind == .attribute && $0.detail == "String" })
        #expect(items.contains { $0.text == "books" && $0.kind == .relationship && $0.detail == "To-many → Book" })
        // A comparison has not started, so the words that can open one belong here too.
        #expect(items.contains { $0.text == "ANY" && $0.kind == .keyword })
    }

    @Test func filtersByTheWordBeingTypedAndReplacesOnlyIt() {
        let completions = complete("na")
        #expect(completions.items.map(\.text) == ["name"])
        #expect(completions.range == 0..<2)
    }

    @Test func aWordTypedInItsOwnCaseComesFirst() {
        // Both `name` and `NONE` begin with an `n`; the one written that way is the one being typed.
        #expect(words("n").first == "name")
        #expect(words("N").first == "NONE")
    }

    @Test func followsAToOneRelationshipIntoItsDestination() {
        let completions = completer.completions(in: "author.na", at: 9, entity: "Book")
        #expect(completions.items.map(\.text) == ["name"])
        // The path the word hangs from stays where it is.
        #expect(completions.range == 7..<9)
    }

    @Test func offersCollectionOperatorsOnlyWhereTheyBelong() {
        let throughToMany = words("books.")
        #expect(throughToMany.contains("title"))
        #expect(throughToMany.contains("@count"))
        // One value, so nothing to reduce.
        #expect(!words("birthday.").contains("@count"))
        #expect(!completer.completions(in: "author.", at: 7, entity: "Book").items.map(\.text).contains("@count"))
    }

    @Test func completesACollectionOperatorAfterTheAt() {
        let items = complete("books.@").items
        #expect(items.contains { $0.text == "count" && $0.kind == .collectionOperator })
        // Written without the `@`, which is already in the field.
        #expect(!items.contains { $0.text == "@count" })
        // The ones Core Data's SQLite store cannot run are offered, and say so (M2-01's warning, in advance).
        let sum = items.first { $0.text == "sum" }
        #expect(sum?.detail == "Not supported by SQLite stores")
    }

    @Test func completesCompositeElements() {
        #expect(
            completer.completions(in: "place.", at: 6, entity: "Book").items.map(\.text) == [
                "latitude", "longitude",
            ])
    }

    @Test func offersNothingBehindAKeyPathTheModelDoesNotHave() {
        #expect(complete("nope.").isEmpty)
        #expect(complete("books.nope.").isEmpty)
    }

    @Test func quantifiersOpenAComparisonAndNothingElse() {
        #expect(words("ANY ").contains("books"))
        #expect(!words("ANY ").contains("ANY"))
        #expect(!words("books.").contains("ANY"))
        #expect(words("age > 30 AND ").contains("name"))
        #expect(words("(").contains("name"))
    }

    // MARK: Operators

    @Test func offersTheOperatorsTheTypeOnTheLeftAllows() {
        let string = words("name ")
        #expect(string.contains("BEGINSWITH"))
        #expect(string.contains("CONTAINS"))
        #expect(string.contains("=="))

        let number = words("age ")
        #expect(!number.contains("BEGINSWITH"))
        #expect(number.contains(">="))
        #expect(number.contains("BETWEEN"))

        // Nothing is ordered about a blob, and nothing in it is searchable from here.
        #expect(words("avatar ") == ["==", "!=", "IN"])
    }

    @Test func aToManyRelationshipCanBeAskedWhatItContains() {
        #expect(words("books ").contains("CONTAINS"))
    }

    @Test func completesAHalfWrittenOperator() {
        #expect(words("name BEG") == ["BEGINSWITH"])
        #expect(words("name beg") == ["BEGINSWITH"])
    }

    @Test func offersEverythingAfterAKeyPathItCannotResolve() {
        // Mid-word, not necessarily wrong: the validator is what says a path is unknown.
        #expect(words("nope ").contains("BEGINSWITH"))
    }

    // MARK: Options, values, conjunctions

    @Test func completesTheStringOptions() {
        let items = complete("name CONTAINS[").items
        #expect(items.map(\.text) == ["c]", "cd]", "d]", "n]"])
        #expect(items.allSatisfy { $0.kind == .option })
        #expect(words("name CONTAINS[c") == ["c]", "cd]"])
    }

    @Test func offersTheConstantsThatCanBeWrittenWithoutQuotes() {
        #expect(words("age > ") == ["nil", "TRUE", "FALSE"])
        #expect(words("age > NI") == ["nil"])
        #expect(words("name IN ") == ["nil", "TRUE", "FALSE"])
    }

    @Test func joinsTwoComparisons() {
        #expect(words("age > 30 ") == ["AND", "OR"])
        #expect(words("age > 30 A") == ["AND"])
        #expect(words("name == \"a b\" ") == ["AND", "OR"])
        #expect(words("(age > 30) ") == ["AND", "OR"])
        #expect(words("name == nil ") == ["AND", "OR"])
    }

    @Test func staysOutOfStringsAndNumbers() {
        #expect(complete("name == \"an").isEmpty)
        #expect(complete("name == \"an unclosed AND ").isEmpty)
        #expect(complete("age > 30").isEmpty)
        #expect(complete("age > 30.").isEmpty)
    }

    // MARK: The caret

    @Test func readsOnlyWhatIsInFrontOfTheCaret() {
        let completions = completer.completions(in: "nam AND age > 30", at: 3, entity: "Author")
        #expect(completions.items.map(\.text) == ["name"])
        #expect(completions.range == 0..<3)
    }

    @Test func countsInUTF16LikeTheTextViewsDo() {
        let text = "name == \"🐘\" AND ag"
        let completions = completer.completions(in: text, at: text.utf16.count, entity: "Author")
        #expect(completions.items.map(\.text) == ["age"])
        #expect(completions.range == text.utf16.count - 2..<text.utf16.count)
    }

    @Test func aCaretOutsideTheTextIsClamped() {
        #expect(!completer.completions(in: "na", at: 99, entity: "Author").isEmpty)
        #expect(completer.completions(in: "na", at: -1, entity: "Author").range == 0..<0)
    }

    @Test func anEntityTheModelDoesNotHaveOffersNothing() {
        #expect(completer.completions(in: "na", at: 2, entity: "Nope").isEmpty)
    }
}
