import Foundation
import Testing

@testable import DabbiQuery

/// M2-03 (PRD-1, PRD-2): what the builder offers is generated from the model, and what it shows reads back out as
/// the predicate it was given.
@Suite struct PredicateBuilderSchemaTests {
    let author = BuilderSchema(model: testModel, entity: "Author")
    let book = BuilderSchema(model: testModel, entity: "Book")

    // MARK: What is offered

    @Test func anEntityOffersItsAttributesWithTheirKinds() throws {
        let kinds = Dictionary(uniqueKeysWithValues: author.fields.map { ($0.keyPath, $0.kind) })
        #expect(kinds["name"] == .string)
        #expect(kinds["age"] == .integer)
        #expect(kinds["rating"] == .decimal)
        #expect(kinds["birthday"] == .date)
        #expect(kinds["identifier"] == .uuid)
        #expect(kinds["homepage"] == .uri)
        // No value to type, but "is there one" is still a question.
        #expect(kinds["avatar"] == .presence)
        #expect(kinds["settings"] == .presence)
        // In the model's order, which is by name; relationships come after.
        #expect(
            author.fields.prefix(8).map(\.keyPath) == [
                "age", "avatar", "birthday", "homepage", "identifier", "name", "rating", "settings",
            ])
        #expect(author.fields[8].keyPath == "books.@count")
    }

    /// PRD-2: through a to-many, a row needs a quantifier; `@count` does not, and is never nil.
    @Test func throughAToManyEveryRowIsQuantified() throws {
        let title = try #require(author.field(for: "books.title"))
        #expect(title.isQuantified)
        #expect(title.quantifiers == [.any, .all, .notAny])
        #expect(!title.offersNilChecks)

        let count = try #require(author.field(for: "books.@count"))
        #expect(count.kind == .integer)
        #expect(!count.isQuantified)
        #expect(!count.offersNilChecks)
    }

    /// PRD-2: composite attributes are not rows, their elements are — including through a relationship.
    @Test func compositeElementsAreRowsAndTheCompositeIsNot() throws {
        #expect(book.field(for: "place") == nil)
        #expect(book.field(for: "place.latitude")?.kind == .decimal)
        #expect(book.field(for: "place.longitude")?.isQuantified == false)
        #expect(author.field(for: "books.place.latitude")?.isQuantified == true)
    }

    @Test func toOneRelationshipsAreFollowedAndCanBeCheckedForNil() throws {
        let relationship = try #require(book.field(for: "author"))
        #expect(relationship.kind == .presence)
        #expect(relationship.operators == [.isNil, .isNotNil])
        #expect(book.field(for: "author.name")?.kind == .string)
        #expect(book.field(for: "author.name")?.isQuantified == false)
        #expect(book.field(for: "author.books.@count") == nil, "the walk does not go back the way it came")
    }

    /// One quantifier per row is what a row can say, so a second to-many is not entered.
    @Test func aSecondToManyIsNotEntered() {
        #expect(author.field(for: "books.tags.label") == nil)
        #expect(author.field(for: "books.tags.@count") == nil)
        #expect(book.field(for: "tags.label")?.isQuantified == true)
    }

    @Test func depthAndWidthAreBounded() {
        let shallow = BuilderSchema(model: testModel, entity: "Book", relationshipDepth: 0)
        #expect(shallow.field(for: "author") != nil)
        #expect(shallow.field(for: "author.name") == nil)
        let narrow = BuilderSchema(model: testModel, entity: "Author", fieldLimit: 3)
        #expect(narrow.fields.map(\.keyPath) == ["age", "avatar", "birthday"])
    }

    @Test func inheritedAttributesAreOffered() {
        let photo = BuilderSchema(model: testModel, entity: "Photo")
        #expect(photo.fields.map(\.keyPath) == ["title", "width"])
    }

    @Test func operatorsFollowTheKind() throws {
        let name = try #require(author.field(for: "name"))
        #expect(name.operators.contains(.compare(.beginsWith)))
        #expect(!name.operators.contains(.compare(.lessThan)))
        #expect(name.operators.suffix(2) == [.isNil, .isNotNil])
        #expect(name.kind.acceptsStringOptions)

        let birthday = try #require(author.field(for: "birthday"))
        #expect(birthday.operators.contains(.compare(.between)))
        #expect(!birthday.operators.contains(.compare(.contains)))
        #expect(!birthday.kind.acceptsStringOptions)
    }

    // MARK: Round trips

    static let authorRows = [
        "age > 30",
        #"name BEGINSWITH[cd] "a""#,
        #"name CONTAINS[c] "a""#,
        #"name ENDSWITH[d] "a""#,
        "name == nil",
        "avatar != nil",
        #"ANY books.title == "Swift""#,
        "ALL books.pages > 100",
        #"NONE books.title CONTAINS[c] "x""#,
        "books.@count > 3",
        #"name IN {"a", "b, c"}"#,
        "age BETWEEN {10, 20}",
        "name == $NAME",
        "age IN $AGES",
        "age BETWEEN {$LOW, $HIGH}",
        "rating <= 1.5",
        "NOT (age > 30)",
        #"NOT (age > 30 OR name == "x")"#,
        #"age > 30 AND (name == "x" OR rating < 1.5)"#,
        #"age > 30 OR (name == "x" AND NOT (ANY books.pages < 10))"#,
        "30 < age",
        "TRUEPREDICATE",
    ]

    /// What the builder is given, it hands back: the editor's shape parses to the same predicate, and every row
    /// writes back the comparison it was read from.
    @Test(arguments: authorRows)
    func theBuilderShowsItAndGivesItBack(_ text: String) throws {
        let ast = try PredicateAST.parse(text)
        guard case .rows(let shaped) = author.presentation(of: ast) else {
            Issue.record("\(text) should have rows: \(author.presentation(of: ast))")
            return
        }
        let readBack = PredicateAST(try shaped.makePredicate()).normalisedForBuilder()
        #expect(readBack == ast.normalisedForBuilder(), "\(text)")

        for comparison in shaped.rowNodes {
            let row = try #require(author.row(for: comparison), "\(comparison)")
            #expect(row.predicate == comparison)
        }
    }

    /// The editor raises on any other shape, so the root is always a group and a negation is always a None group
    /// (`NOT (OR …)`) or a `NONE` row.
    @Test func theRootIsAlwaysAGroup() throws {
        #expect(author.presentation(of: try .parse("age > 30")) == .rows(.and([try .parse("age > 30")])))
        #expect(author.presentation(of: .all) == .rows(.and([])))
        let negated = try PredicateAST.parse("NOT (age > 30)")
        #expect(author.presentation(of: negated) == .rows(.not(.or([try .parse("age > 30")]))))
        let none = try PredicateAST.parse("NONE books.pages > 3")
        #expect(author.presentation(of: none) == .rows(.and([none])))
        #expect(author.row(for: none)?.quantifier == .notAny)
    }

    /// A key path deeper than the menus reach still gets its row.
    @Test func aDeeperKeyPathIsAddedForThePredicateThatUsesIt() throws {
        let ast = try PredicateAST.parse("author.books.@count > 2")
        #expect(book.field(for: "author.books.@count") == nil)
        guard case .rows = book.presentation(of: ast) else {
            Issue.record("no rows for \(ast)")
            return
        }
        #expect(book.including(ast).field(for: "author.books.@count")?.kind == .integer)
    }

    @Test func datesAndUUIDsAndURLsRoundTrip() throws {
        let date = Date(timeIntervalSinceReferenceDate: 700_000_000)
        let uuid = UUID()
        let url = try #require(URL(string: "https://example.com/a"))
        let asts: [PredicateAST] = [
            .comparison(
                PredicateComparison(left: .keyPath("birthday"), op: .greaterThan, right: .constant(.date(date)))),
            .comparison(
                PredicateComparison(
                    left: .keyPath("birthday"), op: .between,
                    right: .aggregate([.constant(.date(date)), .constant(.date(date.addingTimeInterval(60)))]))),
            .comparison(PredicateComparison(left: .keyPath("identifier"), op: .equal, right: .constant(.uuid(uuid)))),
            .comparison(PredicateComparison(left: .keyPath("homepage"), op: .notEqual, right: .constant(.url(url)))),
        ]
        for ast in asts {
            let row = try #require(author.row(for: ast), "\(ast)")
            #expect(row.predicate == ast)
            #expect(author.presentation(of: ast) == .rows(.and([ast])))
        }
    }

    // MARK: What stays text

    static let notShown: [(String, BuilderObstacle.Reason)] = [
        (#"books.title == "x""#, .needsQuantifier),
        ("name == 5", .noEditorForRow),
        (#"name ==[n] "x""#, .noEditorForRow),
        (#"name > "a""#, .noEditorForRow),
        ("ANY age > 3", .noEditorForRow),
        ("ALL books.@count > 3", .noEditorForRow),
        ("books.@sum.pages > 3", .keyPathNotOffered),
        ("missing == 1", .keyPathNotOffered),
        ("books == nil", .keyPathNotOffered),
        (#"name IN {"a", 1}"#, .noEditorForRow),
    ]

    @Test(arguments: notShown)
    func theseStayText(_ text: String, _ reason: BuilderObstacle.Reason) throws {
        let ast = try PredicateAST.parse(text)
        guard case .custom(let obstacles) = author.presentation(of: ast) else {
            Issue.record("\(text) should stay text")
            return
        }
        #expect(obstacles.map(\.reason) == [reason], "\(text)")
        #expect(obstacles.allSatisfy { !$0.message.isEmpty })
    }

    /// Only the offending row is named, and the obstacles of M2-01 still come first.
    @Test func obstaclesNameTheOffendingRowOnly() throws {
        let ast = try PredicateAST.parse(#"age > 3 AND books.title == "x""#)
        guard case .custom(let obstacles) = author.presentation(of: ast) else {
            Issue.record("should stay text")
            return
        }
        #expect(obstacles.count == 1)
        #expect(obstacles[0].text.contains("books.title"))

        let function = try PredicateAST.parse(#"lowercase(name) == "x""#)
        #expect(author.presentation(of: function) == .custom(function.builderObstacles))
    }

    // MARK: Typed values

    @Test func typedValuesAreReadByKind() {
        #expect(BuilderValueKind.integer.value(from: " 42 ") == .literal(.int(42)))
        #expect(BuilderValueKind.integer.value(from: "") == .literal(.int(0)))
        #expect(BuilderValueKind.decimal.value(from: "1.25") == .literal(.double(1.25)))
        #expect(BuilderValueKind.decimal.value(from: "1,25") == nil)
        #expect(BuilderValueKind.integer.value(from: "twelve") == nil)
        #expect(BuilderValueKind.string.value(from: "  padded ") == .literal(.string("  padded ")))
        #expect(BuilderValueKind.string.value(from: "$NAME") == .variable("NAME"))
        #expect(BuilderValueKind.integer.value(from: "$MIN_AGE") == .variable("MIN_AGE"))
        #expect(BuilderValueKind.string.value(from: "$1 off") == .literal(.string("$1 off")))
        let uuid = UUID()
        #expect(BuilderValueKind.uuid.value(from: uuid.uuidString.lowercased()) == .literal(.uuid(uuid)))
        #expect(BuilderValueKind.uuid.value(from: "not-a-uuid") == nil)
        #expect(BuilderValueKind.uri.value(from: "x-coredata://a/b") != nil)
        #expect(BuilderValueKind.uri.value(from: "no scheme") == nil)
    }

    @Test(arguments: [
        BuilderValue.literal(.int(-7)), .literal(.double(2.5)), .literal(.double(3)), .literal(.string("a b")),
        .variable("X"), .literal(.uuid(UUID())),
    ])
    func whatIsShownReadsBackAsTheSameValue(_ value: BuilderValue) {
        let kind: BuilderValueKind =
            switch value {
            case .literal(.int), .literal(.double), .variable: .decimal
            case .literal(.uuid): .uuid
            default: .string
            }
        let back = kind.value(from: kind.text(for: value))
        // A whole double is shown without its ".0" and reads back as an integer, which compares the same.
        if case .literal(.double(3)) = value {
            #expect(back == .literal(.int(3)))
        } else {
            #expect(back == value)
        }
    }

    @Test func listsAreCommaSeparatedWithQuotesForAwkwardStrings() {
        let strings: [BuilderValue] = [
            .literal(.string("plain")), .literal(.string("a, b")), .literal(.string(#"say "hi""#)),
            .literal(.string(" padded")), .literal(.string("$notAVariable")), .variable("V"),
        ]
        let text = BuilderValueKind.string.listText(for: strings)
        #expect(text == #"plain, "a, b", "say \"hi\"", " padded", "$notAVariable", $V"#)
        #expect(BuilderValueKind.string.values(fromList: text) == strings)

        #expect(
            BuilderValueKind.integer.values(fromList: "1, 2,3") == [
                .literal(.int(1)), .literal(.int(2)), .literal(.int(3)),
            ])
        #expect(BuilderValueKind.integer.values(fromList: "1, x") == nil)
        #expect(BuilderValueKind.integer.values(fromList: #""1""#) == nil, "quotes make a string")
        #expect(BuilderValueKind.string.values(fromList: #""open"#) == nil)
        #expect(BuilderValueKind.string.values(fromList: #""a" b"#) == nil)
        #expect(BuilderValueKind.string.values(fromList: "  ") == [])
    }
}

extension PredicateAST {
    /// The rows of an editor-shaped tree: its comparisons, with a `NONE` row kept whole.
    fileprivate var rowNodes: [PredicateAST] {
        switch self {
        case .and(let subs), .or(let subs): subs.flatMap(\.rowNodes)
        case .not(.comparison): [self]
        case .not(let inner): inner.rowNodes
        case .comparison: [self]
        case .all, .none, .custom: []
        }
    }
}
