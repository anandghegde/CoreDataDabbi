@preconcurrency import CoreData
import Foundation

/// Fixtures whose point is *where the model comes from*.
enum ModelFileFixtures {
    // MARK: Versioned .momd

    static func makeArticlesV1() -> NSManagedObjectModel {
        model([entity("Article", [attribute("title", .stringAttributeType)])], identifier: "articles-1")
    }

    static func makeArticlesV2() -> NSManagedObjectModel {
        let article = entity(
            "Article",
            [
                attribute("title", .stringAttributeType),
                attribute("subtitle", .stringAttributeType),
            ])
        let author = entity("Author", [attribute("name", .stringAttributeType)])
        relate(author, "articles", .toMany, article, inverse: "author", .toOne)
        return model([article, author], identifier: "articles-2")
    }

    /// The store is on version 1; the `.momd`'s current version is 2.
    static func buildVersioned(in directory: URL) throws -> FixtureManifest {
        let v1 = makeArticlesV1()
        try ModelFiles.writeMOMD(
            versions: [("Articles", v1), ("Articles 2", makeArticlesV2())], current: "Articles 2",
            to: directory.appendingPathComponent("Articles.momd"))
        try writeArticles(model: v1, to: directory.appendingPathComponent("Articles.sqlite"), count: 7)
        return FixtureManifest(
            fixture: .versioned,
            summary: "A versioned model whose current version is newer than the store.",
            store: "Articles.sqlite",
            model: "Articles.momd",
            entityCounts: ["Article": 7]
        )
    }

    private static func writeArticles(model: NSManagedObjectModel, to url: URL, count: Int) throws {
        let writer = try StoreWriter(model: model, storeURL: url)
        try writer.perform { writer in
            for index in 0..<count { writer.insert("Article", ["title": "Article \(index)"]) }
        }
        try writer.close()
    }

    // MARK: Merged models

    static func makeCustomers() -> NSManagedObjectModel {
        model([entity("Customer", [attribute("name", .stringAttributeType)])], identifier: "customers-1")
    }

    static func makeBilling() -> NSManagedObjectModel {
        let invoice = entity(
            "Invoice",
            [
                attribute("number", .stringAttributeType),
                attribute("total", .decimalAttributeType),
            ])
        return model([invoice], identifier: "billing-1")
    }

    /// The app merges two models, so the store's entities are the union of two files. The model cache is removed
    /// to make the files the only way in.
    static func buildMerged(in directory: URL) throws -> FixtureManifest {
        let customers = makeCustomers()
        let billing = makeBilling()
        let models = directory.appendingPathComponent("Models", isDirectory: true)
        try ModelFiles.writeMOM(customers, to: models.appendingPathComponent("Customers.mom"))
        try ModelFiles.writeMOM(billing, to: models.appendingPathComponent("Billing.mom"))

        guard let merged = NSManagedObjectModel(byMerging: [customers, billing]) else {
            throw FixtureError("The Customers and Billing models could not be merged.")
        }
        let storeURL = directory.appendingPathComponent("Merged.sqlite")
        let writer = try StoreWriter(model: merged, storeURL: storeURL)
        try writer.perform { writer in
            for index in 0..<5 { writer.insert("Customer", ["name": "Customer \(index)"]) }
            for index in 0..<9 {
                writer.insert(
                    "Invoice", ["number": "INV-\(100 + index)", "total": NSDecimalNumber(string: "\(index * 10).99")])
            }
        }
        try writer.close()
        try RawSQLite.execute("DROP TABLE IF EXISTS Z_MODELCACHE", at: storeURL)

        return FixtureManifest(
            fixture: .merged,
            summary: "A store made from two merged models, each in its own file; no model cache.",
            store: "Merged.sqlite",
            model: "Models",
            requiresModel: true,
            entityCounts: ["Customer": 5, "Invoice": 9]
        )
    }

    // MARK: App bundle

    /// `Sample.app` holds a versioned model (the store is on the older version) and an unrelated model in a
    /// framework. The store has no model cache, so the bundle is the only way in.
    static func buildAppBundle(in directory: URL) throws -> FixtureManifest {
        let contents = directory.appendingPathComponent("Sample.app/Contents", isDirectory: true)
        let resources = contents.appendingPathComponent("Resources", isDirectory: true)
        let framework = contents.appendingPathComponent("Frameworks/Shared.framework/Resources", isDirectory: true)

        let v1 = makeArticlesV1()
        try ModelFiles.writeMOMD(
            versions: [("Articles", v1), ("Articles 2", makeArticlesV2())], current: "Articles 2",
            to: resources.appendingPathComponent("Articles.momd"))
        try ModelFiles.writeMOM(makeCustomers(), to: framework.appendingPathComponent("Customers.mom"))

        let info: [String: Any] = [
            "CFBundleIdentifier": "org.coredatadabbi.fixtures.sample",
            "CFBundleName": "Sample",
            "CFBundlePackageType": "APPL",
            "CFBundleShortVersionString": "1.0",
        ]
        try PropertyListSerialization.data(fromPropertyList: info, format: .xml, options: 0)
            .write(to: contents.appendingPathComponent("Info.plist"))

        let storeURL = directory.appendingPathComponent("Data/Sample.sqlite")
        try writeArticles(model: v1, to: storeURL, count: 4)
        try RawSQLite.execute("DROP TABLE IF EXISTS Z_MODELCACHE", at: storeURL)

        return FixtureManifest(
            fixture: .appBundle,
            summary: "A fake app bundle with models in Resources and Frameworks; the store has no model cache.",
            store: "Data/Sample.sqlite",
            model: "Sample.app",
            requiresModel: true,
            entityCounts: ["Article": 4]
        )
    }

    // MARK: No model cache

    static func buildNoModelCache(in directory: URL) throws -> FixtureManifest {
        let model = NotesFixture.makeModel()
        try ModelFiles.writeMOM(model, to: directory.appendingPathComponent("Notes.mom"))
        let storeURL = directory.appendingPathComponent("NoCache.sqlite")
        let writer = try StoreWriter(model: model, storeURL: storeURL)
        try writer.perform { writer in
            let folder = writer.insert("Folder", ["name": "Archive"])
            for index in 0..<6 { writer.insert("Note", ["title": "Old note \(index)", "folder": folder]) }
        }
        try writer.close()
        try RawSQLite.execute("DROP TABLE IF EXISTS Z_MODELCACHE", at: storeURL)

        return FixtureManifest(
            fixture: .noModelCache,
            summary: "A store without a cached model, as older OS versions wrote them, next to its .mom.",
            store: "NoCache.sqlite",
            model: "Notes.mom",
            requiresModel: true,
            entityCounts: ["Folder": 1, "Note": 6]
        )
    }
}

/// Files that are not Core Data stores at all.
enum ForeignFixtures {
    static func buildNotCoreData(in directory: URL) throws -> FixtureManifest {
        try RawSQLite.execute(
            """
            CREATE TABLE users (id INTEGER PRIMARY KEY, name TEXT NOT NULL, joined REAL);
            CREATE TABLE orders (id INTEGER PRIMARY KEY, user_id INTEGER REFERENCES users(id), total REAL);
            INSERT INTO users (name, joined) VALUES ('ada', 1.5), ('grace', 2.5), ('edsger', 3.5);
            INSERT INTO orders (user_id, total) VALUES (1, 9.99), (1, 19.5), (3, 4.25);
            """,
            at: directory.appendingPathComponent("Plain.sqlite"))
        return FixtureManifest(
            fixture: .notCoreData,
            summary: "A plain SQLite database that is not a Core Data store.",
            kind: .plainSQLite,
            store: "Plain.sqlite"
        )
    }

    static func buildEncrypted(in directory: URL) throws -> FixtureManifest {
        var random = SeededGenerator(seed: 14)
        try random.data(count: 4096 * 8).write(to: directory.appendingPathComponent("Encrypted.sqlite"))
        return FixtureManifest(
            fixture: .encrypted,
            summary: "High-entropy bytes with a .sqlite extension — what an encrypted database looks like.",
            kind: .notSQLite,
            store: "Encrypted.sqlite"
        )
    }
}
