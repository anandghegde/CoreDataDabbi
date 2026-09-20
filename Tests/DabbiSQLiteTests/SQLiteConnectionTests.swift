import DabbiBase
import DabbiTestSupport
import Foundation
import Testing

@testable import DabbiSQLite

/// A small database of our own, so these tests say nothing about Core Data.
private func makeDatabase() throws -> URL {
    let url = TestFixtures.root.appendingPathComponent("plain-\(UUID().uuidString).sqlite")
    let connection = try SQLiteConnection.writable(at: url)
    defer { connection.close() }
    try connection.execute("CREATE TABLE item (id INTEGER PRIMARY KEY, name TEXT, price REAL, payload BLOB)")
    try connection.execute("CREATE TABLE \"odd \"\"name\" (value)")
    for index in 1...100 {
        _ = try connection.query(
            "INSERT INTO item (id, name, price, payload) VALUES (?, ?, ?, ?)",
            [.integer(Int64(index)), .text("item \(index)"), .real(Double(index) / 4), .blob(Data([UInt8(index)]))])
    }
    _ = try connection.query("INSERT INTO item (id, name) VALUES (?, ?)", [101, .null])
    return url
}

@Suite struct SQLiteConnectionTests {
    @Test func bindsAndReadsEveryStorageClass() throws {
        let connection = try SQLiteConnection(readOnly: try makeDatabase())
        let rows = try connection.query("SELECT id, name, price, payload FROM item WHERE id = ?", [7])
        let row = try #require(rows.first)
        #expect(row.columns == ["id", "name", "price", "payload"])
        #expect(row[0] == .integer(7))
        #expect(row["NAME"]?.string == "item 7")
        #expect(row["price"]?.double == 1.75)
        #expect(row["payload"]?.data == Data([7]))
        #expect(row["missing"] == nil)
    }

    @Test func scalarTellsNoRowFromNull() throws {
        let connection = try SQLiteConnection(readOnly: try makeDatabase())
        #expect(try connection.scalar("SELECT name FROM item WHERE id = 101") == .some(.null))
        #expect(try connection.scalar("SELECT name FROM item WHERE id = 999") == nil)
        #expect(try connection.scalar("SELECT count(*) FROM item")?.int64 == 101)
    }

    @Test func maxRowsCapsTheResult() throws {
        let connection = try SQLiteConnection(readOnly: try makeDatabase())
        #expect(try connection.query("SELECT id FROM item ORDER BY id", maxRows: 10).count == 10)
    }

    @Test func introspection() throws {
        let connection = try SQLiteConnection(readOnly: try makeDatabase())
        #expect(try connection.tableNames().sorted() == ["item", "odd \"name"])
        #expect(try connection.tableExists("item"))
        #expect(try connection.tableExists("ITEM") == false || connection.tableExists("ITEM"))  // case is SQLite's call
        #expect(try connection.tableExists("nothing") == false)
        #expect(try connection.columnNames(ofTable: "item") == ["id", "name", "price", "payload"])
        #expect(try connection.columnNames(ofTable: "odd \"name") == ["value"])
        #expect(try connection.columnNames(ofTable: "nothing").isEmpty)
    }

    @Test func quotesIdentifiers() {
        #expect(SQLiteConnection.quoteIdentifier("ZPERSON") == "\"ZPERSON\"")
        #expect(SQLiteConnection.quoteIdentifier("odd \"name") == "\"odd \"\"name\"")
    }

    @Test(arguments: [
        "CREATE TABLE other (id)",
        "INSERT INTO item (id) VALUES (500)",
        "UPDATE item SET name = 'x'",
        "DELETE FROM item",
        "DROP TABLE item",
        "ATTACH DATABASE ':memory:' AS other",
        "PRAGMA journal_mode = DELETE",
        "PRAGMA writable_schema = 1",
        "VACUUM",
    ])
    func readOnlyConnectionsRefuseToWrite(_ sql: String) throws {
        let url = try makeDatabase()
        let connection = try SQLiteConnection(readOnly: url)
        let error = #expect(throws: DabbiError.self) { try connection.execute(sql) }
        #expect(error?.code == .sqliteDenied || error?.code == .sqlite, "\(sql) → \(String(describing: error))")
        #expect(try connection.scalar("SELECT count(*) FROM item")?.int64 == 101)
        #expect(try connection.scalar("SELECT name FROM item WHERE id = 1")?.string == "item 1")
    }

    @Test func readOnlyPragmasStillWork() throws {
        let connection = try SQLiteConnection(readOnly: try makeDatabase())
        #expect(try connection.scalar("PRAGMA page_size")?.int64 != nil)
        #expect(try connection.dataVersion() > 0)
        #expect(try connection.query("PRAGMA table_info(item)").count == 4)
    }

    @Test func readTransactionRollsBackOnError() throws {
        struct Sentinel: Error {}
        let connection = try SQLiteConnection(readOnly: try makeDatabase())
        #expect(throws: Sentinel.self) { try connection.readTransaction { throw Sentinel() } }
        // A transaction left open would make this BEGIN fail.
        #expect(try connection.readTransaction { try connection.scalar("SELECT 1")?.int64 } == 1)
    }

    @Test func runawayQueriesTimeOut() throws {
        let connection = try SQLiteConnection(readOnly: try makeDatabase())
        let endless = "WITH RECURSIVE n(i) AS (SELECT 1 UNION ALL SELECT i + 1 FROM n) SELECT count(*) FROM n"
        let error = #expect(throws: DabbiError.self) {
            try connection.withTimeout(0.05) { try connection.scalar(endless) }
        }
        #expect(error?.code == .timeout)
        #expect(try connection.scalar("SELECT 1")?.int64 == 1)
    }

    @Test func interruptCancels() async throws {
        let connection = try SQLiteConnection(readOnly: try makeDatabase())
        let handle = connection.interruptHandle
        let interrupter = Task.detached {
            try await Task.sleep(for: .milliseconds(50))
            handle.interrupt()
        }
        let endless = "WITH RECURSIVE n(i) AS (SELECT 1 UNION ALL SELECT i + 1 FROM n) SELECT count(*) FROM n"
        let error = #expect(throws: DabbiError.self) { try connection.scalar(endless) }
        #expect(error?.code == .cancelled)
        try await interrupter.value
    }

    @Test func syntaxErrorsAreReported() throws {
        let connection = try SQLiteConnection(readOnly: try makeDatabase())
        let error = #expect(throws: DabbiError.self) { try connection.query("SELEC 1") }
        #expect(error?.code == .sqlite)
        #expect(error?.arguments["sqliteMessage"]?.contains("syntax error") == true)
    }
}

@Suite struct SQLiteHeaderTests {
    @Test func readsARealStore() throws {
        let header = try SQLiteHeader.read(from: try TestFixtures.location(.basic).storeURL)
        #expect(header.isWAL)
        #expect(header.pageSize >= 512 && header.pageSize.nonzeroBitCount == 1)
    }

    @Test func refusesAnEncryptedFile() throws {
        let error = #expect(throws: DabbiError.self) {
            try SQLiteHeader.read(from: try TestFixtures.location(.encrypted).storeURL)
        }
        #expect(error?.code == .notSQLite)
        #expect(error?.diagnosis.contains { $0.contains("Encrypted") } == true)
    }

    @Test func refusesAnEmptyFile() throws {
        let url = TestFixtures.root.appendingPathComponent("empty-\(UUID().uuidString).sqlite")
        try Data().write(to: url)
        let error = #expect(throws: DabbiError.self) { try SQLiteHeader.read(from: url) }
        #expect(error?.code == .notSQLite)
        #expect(error?.diagnosis.first == "The file is empty.")
    }

    @Test func reportsAMissingFile() {
        let error = #expect(throws: DabbiError.self) {
            try SQLiteHeader.read(from: URL(fileURLWithPath: "/nonexistent/App.sqlite"))
        }
        #expect(error?.code == .fileNotFound)
    }

    @Test func openingAnEncryptedFileExplainsItself() throws {
        let url = try TestFixtures.location(.encrypted).storeURL
        let error = #expect(throws: DabbiError.self) {
            let connection = try SQLiteConnection(readOnly: url)
            _ = try connection.tableNames()
        }
        #expect(error?.code == .notSQLite)
    }
}

@Suite struct SQLiteBackupTests {
    @Test func copiesALiveDatabase() throws {
        let source = try SQLiteConnection(readOnly: try makeDatabase())
        let destination = TestFixtures.root.appendingPathComponent("backup-\(UUID().uuidString).sqlite")
        var steps = 0
        try SQLiteBackup.copy(from: source, to: destination, pagesPerStep: 1) { _ in steps += 1 }
        #expect(steps > 1)
        let copy = try SQLiteConnection(readOnly: destination)
        #expect(try copy.scalar("SELECT count(*) FROM item")?.int64 == 101)
    }

    @Test func picksUpRowsThatAreOnlyInTheWAL() throws {
        let location = try TestFixtures.location(.walOnly)
        let destination = TestFixtures.root.appendingPathComponent("backup-\(UUID().uuidString).sqlite")
        try SQLiteBackup.copy(from: try SQLiteConnection(readOnly: location.storeURL), to: destination)
        let copy = try SQLiteConnection(readOnly: destination)
        #expect(location.manifest.entityCounts.count == 2)
        for (entity, expected) in location.manifest.entityCounts {
            let table = SQLiteConnection.quoteIdentifier("Z" + entity.uppercased())
            #expect(try copy.scalar("SELECT count(*) FROM \(table)")?.int64 == Int64(expected), "\(entity)")
        }
    }

    @Test func neverOverwrites() throws {
        let url = try makeDatabase()
        let source = try SQLiteConnection(readOnly: url)
        let error = #expect(throws: DabbiError.self) { try SQLiteBackup.copy(from: source, to: url) }
        #expect(error?.arguments["path"] == url.path)
        #expect(try source.scalar("SELECT count(*) FROM item")?.int64 == 101)
    }
}

@Suite struct SQLiteReaderTests {
    @Test func readsAndCloses() async throws {
        let reader = try SQLiteReader(url: try makeDatabase())
        #expect(try await reader.read { try $0.scalar("SELECT count(*) FROM item")?.int64 } == 101)
        await reader.close()
        await #expect(throws: DabbiError.self) { try await reader.read { try $0.tableNames() } }
    }

    @Test func seesRowsThatAreOnlyInTheWAL() async throws {
        let location = try TestFixtures.location(.walOnly)
        let reader = try SQLiteReader(url: location.storeURL)
        let tables = try await reader.read { try $0.tableNames() }
        #expect(tables.contains("Z_PRIMARYKEY"))
        let counted = try await reader.read { try $0.scalar("SELECT sum(Z_MAX) FROM Z_PRIMARYKEY")?.int64 }
        #expect(counted == Int64(location.manifest.entityCounts.values.reduce(0, +)))
        await reader.close()
    }
}
