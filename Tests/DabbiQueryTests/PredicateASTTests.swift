import DabbiBase
import Foundation
import Testing

@testable import DabbiQuery

/// Text → AST → `NSPredicate` → text, for every shape the parser can produce. The AST is the one source of
/// truth (ARCHITECTURE.md §6.5), so the round trip has to be lossless for every one of them.
@Suite struct PredicateRoundTripTests {
    static let predicates = [
        "age > 30",
        "age >= 30 AND age <= 40",
        "name == nil",
        "name != nil",
        #"name BEGINSWITH[cd] "a""#,
        #"name CONTAINS[c] "swift""#,
        #"title MATCHES "^A.*""#,
        #"title LIKE[cd] "*swift*""#,
        #"name IN {"a", "b", "c"}"#,
        "age BETWEEN {10, 20}",
        "NOT (age > 30)",
        #"age > 30 AND (name == "x" OR rating < 1.5)"#,
        "ANY books.title == \"Swift\"",
        "ALL books.price > 10",
        "NONE books.price > 10",
        "books.@count > 3",
        "SUBQUERY(books, $b, $b.price > 10).@count > 2",
        #"lowercase(name) == "x""#,
        "TRUEPREDICATE",
        "FALSEPREDICATE",
        #"name == $NAME"#,
        "birthday < CAST(0.0, \"NSDate\")",
        "SELF == nil",
    ]

    @Test(arguments: predicates)
    func textSurvivesTheRoundTrip(_ text: String) throws {
        let ast = try PredicateAST.parse(text)
        let format = try ast.formatString()
        // Parsing the rendered text must give back the same tree, which is what makes the builder and the text
        // field interchangeable.
        #expect(try PredicateAST.parse(format) == ast)
        // And the rendered text must mean the same thing to Cocoa as the original did.
        #expect(try PredicateAST.parse(format).formatString() == format)
    }

    @Test func trueAndFalsePredicatesGetTheirOwnCases() throws {
        #expect(try PredicateAST.parse("TRUEPREDICATE") == .all)
        #expect(try PredicateAST.parse("FALSEPREDICATE") == .none)
    }

    @Test func comparisonPartsAreReadOut() throws {
        let ast = try PredicateAST.parse(#"name BEGINSWITH[cd] "a""#)
        guard case .comparison(let comparison) = ast else {
            Issue.record("expected a comparison, got \(ast)")
            return
        }
        #expect(comparison.left == .keyPath("name"))
        #expect(comparison.op == .beginsWith)
        #expect(comparison.right == .constant(.string("a")))
        #expect(comparison.modifier == .direct)
        #expect(comparison.options == [.caseInsensitive, .diacriticInsensitive])
        #expect(comparison.options.suffix == "[cd]")
    }

    @Test func noneBecomesNotAny() throws {
        let ast = try PredicateAST.parse("NONE books.price > 10")
        guard case .not(.comparison(let comparison)) = ast else {
            Issue.record("expected NOT of a comparison, got \(ast)")
            return
        }
        #expect(comparison.modifier == .any)
    }

    @Test func literalKindsAreKept() throws {
        guard case .comparison(let int) = try PredicateAST.parse("age > 30"),
            case .comparison(let double) = try PredicateAST.parse("rating > 1.5"),
            case .comparison(let bool) = try PredicateAST.parse("SELF == YES"),
            case .comparison(let null) = try PredicateAST.parse("name == nil")
        else {
            Issue.record("expected four comparisons")
            return
        }
        #expect(int.right == .constant(.int(30)))
        #expect(double.right == .constant(.double(1.5)))
        #expect(bool.right == .constant(.bool(true)))
        #expect(null.right == .constant(.null))
    }

    @Test func subqueryKeepsItsIteratorAndPredicate() throws {
        let ast = try PredicateAST.parse("SUBQUERY(books, $b, $b.price > 10).@count > 2")
        guard case .comparison(let comparison) = ast,
            case .keyPathOn(.subquery(let collection, let variable, let inner), let keyPath) = comparison.left
        else {
            Issue.record("expected @count on a subquery, got \(ast)")
            return
        }
        #expect(collection == .keyPath("books"))
        #expect(variable == "b")
        #expect(keyPath == "@count")
        guard case .comparison(let innerComparison) = inner else {
            Issue.record("expected a comparison inside the subquery")
            return
        }
        #expect(innerComparison.left == .keyPathOn(.variable("b"), keyPath: "price"))
    }

    @Test func emptyTextIsRefused() {
        #expect(throws: DabbiError.self) { try PredicateAST.parse("   ") }
    }

    @Test func syntaxErrorsAreRefused() {
        #expect(throws: DabbiError.self) { try PredicateAST.parse("age >") }
        #expect(throws: DabbiError.self) { try PredicateAST.parse("((age > 1)") }
    }

    /// The guard runs on the way in — an AST can never hold a custom selector.
    @Test func unsafeTextIsRefused() {
        #expect(throws: DabbiError.self) { try PredicateAST.parse("FUNCTION(self, 'doSomething')") }
        #expect(throws: DabbiError.self) { try PredicateAST.parse(#"CAST(name, "NSFileManager") != nil"#) }
    }

    /// And on the way out, because an AST can also arrive from a project file somebody edited by hand.
    @Test func unsafeASTsAreRefusedWhenBuilt() {
        let ast = PredicateAST.custom("FUNCTION(self, 'doSomething') == 1")
        #expect(throws: DabbiError.self) { try ast.makePredicate() }
    }

    @Test func sourceRoundTripsThroughFetchSpec() throws {
        let source = PredicateSource(format: "age > 30")
        let ast = try source.ast()
        #expect(
            ast == .comparison(PredicateComparison(left: .keyPath("age"), op: .greaterThan, right: .constant(.int(30))))
        )
        #expect(try ast.source().format == "age > 30")
    }

    @Test func nestingFlattens() throws {
        let ast = try PredicateAST.parse("a > 1 AND (b > 2 AND c > 3)")
        #expect(ast.simplified.comparisons.count == 3)
        guard case .and(let subs) = ast.simplified else {
            Issue.record("expected a flat AND, got \(ast.simplified)")
            return
        }
        #expect(subs.count == 3)
    }

    @Test func singleChildCompoundsCollapse() {
        #expect(PredicateAST.and([.all]).simplified == .all)
        #expect(PredicateAST.and([]).simplified == .all)
        #expect(PredicateAST.or([]).simplified == .none)
    }
}
