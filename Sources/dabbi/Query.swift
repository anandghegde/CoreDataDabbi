import ArgumentParser
import DabbiKit
import Foundation

struct Query: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Fetch rows of an entity.",
        discussion: """
            Examples:
              dabbi query App.sqlite Person --where 'age > 30 AND name BEGINSWITH[cd] "a"' --sort name
              dabbi query App.sqlite Person --sort=-age --limit 10 --json
            """
    )

    @OptionGroup var options: StoreOptions

    @Argument(help: "The entity to fetch.")
    var entity: String

    @Option(name: .customLong("where"), help: "An NSPredicate format string.")
    var predicate: String?

    @Option(
        name: .long, parsing: .upToNextOption,
        help: "Key paths to sort by; prefix one with - for descending (write --sort=-age).")
    var sort: [String] = []

    @Option(name: .long, help: "The maximum number of rows to print.")
    var limit = 50

    @Option(name: .long, help: "The number of rows to skip.")
    var offset = 0

    @Flag(name: .long, help: "Leave out rows of sub-entities.")
    var exact = false

    func validate() throws {
        guard limit >= 1 else { throw ValidationError("--limit must be at least 1.") }
        guard offset >= 0 else { throw ValidationError("--offset must not be negative.") }
    }

    func run() async throws {
        let matching = FetchSpec(
            entity: entity,
            includeSubentities: !exact,
            predicate: predicate.map(PredicateSource.init(format:)),
            sort: sort.flatMap { $0.split(separator: ",") }.map { key in
                key.hasPrefix("-")
                    ? SortKey(keyPath: String(key.dropFirst()), ascending: false) : SortKey(keyPath: String(key))
            }
        )
        var windowed = matching
        windowed.limit = offset + limit

        try await withSession(options) { session in
            let pager = try await session.openPager(windowed)
            let page = try await session.page(pager, range: offset..<(offset + limit))
            let total = try await session.count(matching)

            if options.json {
                try Output.printJSON([
                    "entity": entity,
                    "matching": total,
                    "offset": page.range.lowerBound,
                    "columns": page.columns.properties,
                    "rows": page.rows.map { $0.jsonObject(columns: page.columns) },
                ])
                return
            }
            let rows = page.rows.map { row in [row.ref.description] + row.values.map { $0.displayString() } }
            print(Output.table(headers: ["id"] + page.columns.properties, rows: rows))
            let shown =
                page.rows.isEmpty
                ? "no rows" : "rows \(page.range.lowerBound + 1)–\(page.range.lowerBound + page.rows.count)"
            print("\n\(shown) of \(total) matching")
        }
    }
}
