import Foundation
import Testing

@testable import DabbiQuery

/// §7.1: the builder shows what it can and hands the rest back to the text field, rather than rewriting it.
@Suite struct PredicateBuilderSupportTests {
    static let representable = [
        "age > 30",
        #"name BEGINSWITH[cd] "a""#,
        "name == nil",
        #"age > 30 AND (name == "x" OR rating < 1.5)"#,
        "NOT (age > 30)",
        "ANY books.title == \"Swift\"",
        "books.@count > 3",
        #"name IN {"a", "b"}"#,
        "age BETWEEN {10, 20}",
        "name == $NAME",
        "TRUEPREDICATE",
    ]

    static let notRepresentable = [
        #"lowercase(name) == "x""#,
        "SUBQUERY(books, $b, $b.price > 10).@count > 2",
        "FALSEPREDICATE",
    ]

    @Test(arguments: representable)
    func theBuilderCanShowThese(_ text: String) throws {
        #expect(try PredicateAST.parse(text).isBuilderRepresentable, "\(text)")
    }

    @Test(arguments: notRepresentable)
    func theBuilderCannotShowThese(_ text: String) throws {
        let ast = try PredicateAST.parse(text)
        #expect(!ast.isBuilderRepresentable, "\(text)")
        #expect(!ast.builderObstacles.isEmpty)
        #expect(ast.builderObstacles.allSatisfy { !$0.message.isEmpty })
    }

    /// A builder row starts with a key path, so a predicate written the other way round is turned around —
    /// and the operator with it, or the meaning would change.
    @Test func constantFirstComparisonsAreTurnedAround() throws {
        let ast = try PredicateAST.parse("30 < age").normalisedForBuilder()
        #expect(
            ast == .comparison(PredicateComparison(left: .keyPath("age"), op: .greaterThan, right: .constant(.int(30))))
        )
        #expect(ast.isBuilderRepresentable)
        #expect(try ast.formatString() == "age > 30")
    }

    @Test func comparingTwoKeyPathsHasNoRow() throws {
        let ast = try PredicateAST.parse("name == title")
        #expect(!ast.isBuilderRepresentable)
        #expect(ast.builderObstacles.map(\.reason) == [.rightSideIsNotAValue])
    }

    @Test func aFunctionOnTheLeftHasNoRow() throws {
        let ast = try PredicateAST.parse(#"lowercase(name) == "x""#)
        #expect(ast.builderObstacles.map(\.reason) == [.leftSideIsNotAKeyPath])
    }

    /// Only the parts that cannot be shown are reported; the rest of the tree is fine.
    @Test func obstaclesPointAtTheOffendingPartOnly() throws {
        let ast = try PredicateAST.parse(#"age > 30 AND lowercase(name) == "x""#)
        #expect(ast.builderObstacles.count == 1)
        #expect(ast.builderObstacles[0].text.contains("lowercase"))
    }

    /// What an obstacle quotes is what was typed, not Foundation's `FUNCTION(…, "valueForKeyPath:", …)`.
    @Test func obstaclesQuoteSubqueriesAsTheyAreWritten() throws {
        let ast = try PredicateAST.parse(
            "SUBQUERY(books, $b, $b.pages > 3 AND $b.title BEGINSWITH[c] \"a\").@count > 0")
        #expect(
            ast.builderObstacles.map(\.text)
                == [#"SUBQUERY(books, $b, ($b.pages > 3) AND ($b.title BEGINSWITH[c] "a")).@count"#])
    }

    /// An operator with no swapped form is left alone, because turning it around would ask a different
    /// question. The builder reports it instead.
    @Test func asymmetricOperatorsAreNeverTurnedAround() throws {
        let ast = try PredicateAST.parse(#""Swift" BEGINSWITH name"#)
        let normalised = ast.normalisedForBuilder()
        #expect(normalised == ast)
        #expect(try normalised.formatString() == #""Swift" BEGINSWITH name"#)
        #expect(normalised.builderObstacles.map(\.reason) == [.leftSideIsNotAKeyPath, .rightSideIsNotAValue])
    }

    @Test(arguments: representable + notRepresentable)
    func normalisingIsIdempotentAndStillParses(_ text: String) throws {
        let normalised = try PredicateAST.parse(text).normalisedForBuilder()
        let format = try normalised.formatString()
        #expect(try PredicateAST.parse(format) == normalised, "\(text)")
        #expect(normalised.normalisedForBuilder() == normalised, "\(text)")
    }
}
