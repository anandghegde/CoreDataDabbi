import Foundation

/// The fixture zoo. Every fixture is generated in code — no binaries in git.
public enum Fixture: String, CaseIterable, Sendable, Codable {
    /// One entity with an attribute of every type, validation rules, an index, a constraint and a template.
    case basic
    /// Abstract root, three levels of inheritance, self to-one, one-to-many, many-to-many, one-way to-one.
    case company
    /// Ordered one-to-many and ordered many-to-many relationships.
    case ordered
    /// Composite attributes, one nested in another.
    case composites
    /// Derived attributes.
    case derived
    /// Binary attributes with external storage, some values large enough to be written as files.
    case externalData
    /// Persistent history tracking on, several transactions by different authors.
    case history
    /// Copied while open: all rows still live in the write-ahead log.
    case walOnly
    /// A `.momd` whose *current* version is newer than the store.
    case versioned
    /// A store made from two merged models, each in its own `.mom`.
    case merged
    /// A fake `.app` with models in `Resources/` and `Frameworks/`; the store has no model cache.
    case appBundle
    /// A store without `Z_MODELCACHE`, next to its `.mom`.
    case noModelCache
    /// A plain SQLite database that is not a Core Data store.
    case notCoreData
    /// High-entropy bytes with a `.sqlite` extension — what an encrypted database looks like.
    case encrypted
    /// Many rows of one entity: 20,000 by default, as many as `DABBI_LARGE_ROWS` says for the perf baselines.
    case large
    /// Written by SwiftData from `@Model` classes, under SwiftData's default file name.
    case swiftData
}

public struct FixtureManifest: Sendable, Hashable, Codable {
    public enum Kind: String, Sendable, Codable {
        case coreDataStore, plainSQLite, notSQLite
    }

    public var fixture: Fixture
    public var summary: String
    public var kind: Kind
    /// Path of the store, relative to the fixture's directory.
    public var store: String
    /// Path of a model file, model folder or app bundle to pass as the model, relative to the directory.
    public var model: String?
    /// `true` when the store cannot be opened without `model`.
    public var requiresModel: Bool
    /// Rows per entity, sub-entities included.
    public var entityCounts: [String: Int]

    public init(
        fixture: Fixture,
        summary: String,
        kind: Kind = .coreDataStore,
        store: String,
        model: String? = nil,
        requiresModel: Bool = false,
        entityCounts: [String: Int] = [:]
    ) {
        self.fixture = fixture
        self.summary = summary
        self.kind = kind
        self.store = store
        self.model = model
        self.requiresModel = requiresModel
        self.entityCounts = entityCounts
    }
}

/// A generated fixture on disk.
public struct FixtureLocation: Sendable, Hashable {
    public let directory: URL
    public let manifest: FixtureManifest

    public init(directory: URL, manifest: FixtureManifest) {
        self.directory = directory
        self.manifest = manifest
    }

    public var storeURL: URL { directory.appendingPathComponent(manifest.store) }
    public var modelURL: URL? { manifest.model.map { directory.appendingPathComponent($0) } }
}

public enum FixtureBuilder {
    public static let manifestName = "manifest.json"

    /// Generates `fixture` into `<root>/<fixture>/`, replacing what is there.
    @discardableResult
    public static func build(_ fixture: Fixture, in root: URL) throws -> FixtureLocation {
        let directory = root.appendingPathComponent(fixture.rawValue, isDirectory: true)
        try? FileManager.default.removeItem(at: directory)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

        let manifest: FixtureManifest =
            switch fixture {
            case .basic: try BasicFixture.build(in: directory)
            case .company: try CompanyFixture.build(in: directory)
            case .ordered: try OrderedFixture.build(in: directory)
            case .composites: try CompositesFixture.build(in: directory)
            case .derived: try DerivedFixture.build(in: directory)
            case .externalData: try ExternalDataFixture.build(in: directory)
            case .history: try NotesFixture.buildHistory(in: directory)
            case .walOnly: try NotesFixture.buildWALOnly(in: directory)
            case .versioned: try ModelFileFixtures.buildVersioned(in: directory)
            case .merged: try ModelFileFixtures.buildMerged(in: directory)
            case .appBundle: try ModelFileFixtures.buildAppBundle(in: directory)
            case .noModelCache: try ModelFileFixtures.buildNoModelCache(in: directory)
            case .notCoreData: try ForeignFixtures.buildNotCoreData(in: directory)
            case .encrypted: try ForeignFixtures.buildEncrypted(in: directory)
            case .large: try LargeFixture.build(in: directory)
            case .swiftData: try SwiftDataFixture.build(in: directory)
            }

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(manifest).write(to: directory.appendingPathComponent(manifestName))
        return FixtureLocation(directory: directory, manifest: manifest)
    }

    /// The fixture previously generated into `root`, if its manifest is there.
    public static func existing(_ fixture: Fixture, in root: URL) -> FixtureLocation? {
        let directory = root.appendingPathComponent(fixture.rawValue, isDirectory: true)
        guard let data = try? Data(contentsOf: directory.appendingPathComponent(manifestName)),
            let manifest = try? JSONDecoder().decode(FixtureManifest.self, from: data)
        else { return nil }
        return FixtureLocation(directory: directory, manifest: manifest)
    }
}
