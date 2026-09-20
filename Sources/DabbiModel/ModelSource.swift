@preconcurrency import CoreData
import DabbiBase
import Foundation

/// Where the model a store is browsed with came from. Shown next to the store so nobody has to guess (PRJ-5).
public enum ModelSource: Sendable, Hashable, Codable {
    /// One or more `.mom` files the user pointed at. Several files mean they were merged.
    case userSelected([URL])
    /// Found by scanning an app bundle. Several files mean the store's entities are the union of these models.
    case appBundle(URL, models: [URL])
    /// The copy of the model Core Data caches inside the store (`Z_MODELCACHE`).
    case storeCache

    public var summary: String {
        switch self {
        case .userSelected(let files):
            files.count == 1
                ? "Model file \(files[0].lastPathComponent)"
                : "Merged from \(files.count) model files"
        case .appBundle(let bundle, let models):
            models.count == 1
                ? "\(models[0].lastPathComponent) in \(bundle.lastPathComponent)"
                : "Merged from \(models.count) models in \(bundle.lastPathComponent)"
        case .storeCache:
            "Model cached in the store"
        }
    }
}

/// A model as loaded, with its description and origin.
///
/// `@unchecked Sendable`: `model` is never mutated after loading. The sanitiser works on a copy, and
/// a coordinator only ever sees that copy.
public struct LoadedModel: @unchecked Sendable {
    /// The model as the app defines it — unsanitised. Treat as immutable.
    public let model: NSManagedObjectModel
    public let source: ModelSource
    public let description: ModelDescription

    public init(model: NSManagedObjectModel, source: ModelSource) {
        self.model = model
        self.source = source
        self.description = ModelDescription(model)
    }
}

/// The parts of a persistent store's metadata the engine uses.
public struct StoreMetadata: Sendable, Hashable, Codable {
    /// Entity name → version hash of the model the store was last saved with.
    public var entityVersionHashes: [String: Data]
    public var modelVersionIdentifiers: [String]
    public var storeUUID: String?
    public var storeType: String?

    public init(
        entityVersionHashes: [String: Data],
        modelVersionIdentifiers: [String] = [],
        storeUUID: String? = nil,
        storeType: String? = nil
    ) {
        self.entityVersionHashes = entityVersionHashes
        self.modelVersionIdentifiers = modelVersionIdentifiers
        self.storeUUID = storeUUID
        self.storeType = storeType
    }

    init(_ metadata: [String: Any]) {
        self.init(
            entityVersionHashes: metadata[NSStoreModelVersionHashesKey] as? [String: Data] ?? [:],
            modelVersionIdentifiers: (metadata[NSStoreModelVersionIdentifiersKey] as? [Any] ?? [])
                .map { String(describing: $0) },
            storeUUID: metadata[NSStoreUUIDKey] as? String,
            storeType: metadata[NSStoreTypeKey] as? String
        )
    }

    /// The dictionary shape Core Data's compatibility APIs expect.
    var coreDataDictionary: [String: Any] {
        var dictionary: [String: Any] = [NSStoreModelVersionHashesKey: entityVersionHashes]
        if let storeUUID { dictionary[NSStoreUUIDKey] = storeUUID }
        if let storeType { dictionary[NSStoreTypeKey] = storeType }
        return dictionary
    }

    /// Reads the metadata of the SQLite store at `url` without loading the store.
    public static func read(from url: URL) throws -> StoreMetadata {
        do {
            let metadata = try objcGuarded("The store's metadata could not be read.", code: .storeOpenFailed) {
                try NSPersistentStoreCoordinator.metadataForPersistentStore(
                    type: .sqlite, at: url, options: [NSReadOnlyPersistentStoreOption: true])
            }
            return StoreMetadata(metadata)
        } catch let error as DabbiError {
            throw error
        } catch {
            throw DabbiError(
                .notCoreData,
                "This database does not look like a Core Data store.",
                arguments: ["path": url.path],
                diagnosis: ["Core Data could not read store metadata from \(url.lastPathComponent)."],
                underlying: error
            )
        }
    }
}
