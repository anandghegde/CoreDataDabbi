@preconcurrency import CoreData
import DabbiBase
import DabbiSQLite
import Foundation

/// Finds a model for a store without the app's code (ARCHITECTURE.md §6.3).
public enum ModelLoader {
    /// The cap on an inflated model cache. Real models are kilobytes; this only stops decompression bombs.
    public static let maxCachedModelBytes = 64 * 1024 * 1024

    // MARK: Resolution pipeline

    /// Resolves the model for the store behind `connection`. First success wins:
    ///
    /// 1. `modelURL`, when given — a `.mom`, a `.momd`, or an app bundle / folder to scan. A model the user chose
    ///    that does not match the store is an error, never a silent fallback.
    /// 2. The model cached in the store.
    public static func resolve(
        storeURL: URL,
        modelURL: URL?,
        connection: SQLiteConnection
    ) throws -> LoadedModel {
        guard let modelURL else {
            return LoadedModel(model: try cachedModel(in: connection), source: .storeCache)
        }
        let metadata = try StoreMetadata.read(from: storeURL)
        let files = try modelFiles(at: modelURL)
        let isBundleScan = !["mom", "momd"].contains(modelURL.pathExtension.lowercased())
        guard let match = try firstMatch(among: files, for: metadata) else {
            throw DabbiError(
                .modelIncompatible,
                "No model in \(modelURL.lastPathComponent) matches this store.",
                arguments: ["model": modelURL.path, "store": storeURL.path],
                diagnosis: [
                    "\(files.count) model file(s) were tried, alone and merged.",
                    "The store was saved with a different version of the model.",
                ],
                recovery: [
                    "Choose the model version the store was saved with.",
                    "Open the store without a model file to use the model cached inside it.",
                ]
            )
        }
        let source: ModelSource =
            isBundleScan ? .appBundle(modelURL, models: match.files) : .userSelected(match.files)
        return LoadedModel(model: match.model, source: source)
    }

    /// Matches the store's entity hashes against each model alone, then against a merge of all of them — apps
    /// commonly use `mergedModel(from:)`, so a store's entities can be the union of several files.
    static func firstMatch(
        among files: [URL],
        for metadata: StoreMetadata
    ) throws -> (model: NSManagedObjectModel, files: [URL])? {
        let dictionary = metadata.coreDataDictionary
        var models: [(URL, NSManagedObjectModel)] = []
        for file in files {
            guard let model = try? loadModel(at: file) else { continue }
            if isCompatible(model, with: dictionary) { return (model, [file]) }
            models.append((file, model))
        }
        guard models.count > 1 else { return nil }
        let merged = try? objcGuarded("The models could not be merged.") {
            NSManagedObjectModel(byMerging: models.map(\.1), forStoreMetadata: dictionary)
        }
        guard let merged, isCompatible(merged, with: dictionary) else { return nil }
        let used = models.filter { _, model in
            model.entities.contains { entity in
                entity.name.map { metadata.entityVersionHashes[$0] == entity.versionHash } ?? false
            }
        }
        return (merged, used.map(\.0))
    }

    static func isCompatible(_ model: NSManagedObjectModel, with metadata: [String: Any]) -> Bool {
        (try? objcGuarded("The model could not be compared with the store.") {
            model.isConfiguration(withName: nil, compatibleWithStoreMetadata: metadata)
        }) ?? false
    }

    // MARK: Model files

    /// Loads one compiled model: a `.mom`, or a `.momd` (its current version).
    public static func loadModel(at url: URL) throws -> NSManagedObjectModel {
        guard FileManager.default.fileExists(atPath: url.path) else {
            throw DabbiError(.modelNotFound, "There is no model at this location.", arguments: ["path": url.path])
        }
        let model = try objcGuarded("The model file could not be read.", code: .modelUnreadable) {
            NSManagedObjectModel(contentsOf: url)
        }
        guard let model else {
            throw DabbiError(
                .modelUnreadable,
                "\(url.lastPathComponent) is not a compiled Core Data model.",
                arguments: ["path": url.path],
                recovery: ["Choose a compiled model (.mom or .momd). An .xcdatamodeld must be compiled by Xcode first."]
            )
        }
        return model
    }

    /// Every compiled model file `url` stands for.
    ///
    /// - A `.mom` is itself.
    /// - A `.momd` is **all** of its versions, not only the current one: the store may be on an older version.
    /// - Anything else is scanned as an app bundle or folder: every `.momd` version and every loose `.mom` inside,
    ///   including `Frameworks/` and `PlugIns/`.
    public static func modelFiles(at url: URL) throws -> [URL] {
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory) else {
            throw DabbiError(.modelNotFound, "There is no model at this location.", arguments: ["path": url.path])
        }
        if url.pathExtension.lowercased() == "mom" { return [url] }
        guard isDirectory.boolValue else {
            throw DabbiError(
                .modelUnreadable,
                "\(url.lastPathComponent) is not a compiled Core Data model.",
                arguments: ["path": url.path],
                recovery: ["Choose a .mom file, a .momd folder or an app bundle."]
            )
        }
        let enumerator = FileManager.default.enumerator(
            at: url, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles])
        var files: [URL] = []
        while let file = enumerator?.nextObject() as? URL {
            if file.pathExtension.lowercased() == "mom" { files.append(file) }
        }
        guard !files.isEmpty else {
            throw DabbiError(
                .modelNotFound,
                "No compiled Core Data model was found in \(url.lastPathComponent).",
                arguments: ["path": url.path]
            )
        }
        return files.sorted { $0.path < $1.path }
    }

    // MARK: Store-cached model

    /// The model Core Data cached inside the store.
    public static func cachedModel(in connection: SQLiteConnection) throws -> NSManagedObjectModel {
        let content = try cachedModelContent(in: connection)
        let archive = try inflateCachedModel(content)
        return try unarchiveModel(archive)
    }

    static func cachedModelContent(in connection: SQLiteConnection) throws -> Data {
        guard try connection.tableExists("Z_MODELCACHE"),
            let content = try connection.scalar("SELECT Z_CONTENT FROM Z_MODELCACHE LIMIT 1")?.data,
            !content.isEmpty
        else {
            throw DabbiError(
                .modelCacheMissing,
                "This store does not contain a cached copy of its model.",
                diagnosis: ["Stores written by older OS versions, or by other tools, have no model cache."],
                recovery: ["Choose the app, or its compiled model (.momd), to browse this store."]
            )
        }
        return content
    }

    private static let plistMagic = Data("bplist00".utf8)

    /// `Z_CONTENT` is a keyed archive, either as is or compressed. Current OS versions write raw DEFLATE
    /// (ARCHITECTURE.md Appendix A); the other algorithms are fallbacks for what older or future ones may write.
    static func inflateCachedModel(_ content: Data) throws -> Data {
        if content.starts(with: plistMagic) { return content }
        let algorithms: [BoundedDecompressor.Algorithm] = [.rawDeflate, .zlib, .lzfse, .lz4, .lzma]
        for algorithm in algorithms {
            do {
                let inflated = try BoundedDecompressor.decompress(
                    content, using: algorithm, maxOutputBytes: maxCachedModelBytes)
                if inflated.starts(with: plistMagic) { return inflated }
            } catch let error as DabbiError where error.code == .limitExceeded {
                throw error
            } catch {
                continue
            }
        }
        throw DabbiError(
            .modelUnreadable,
            "The model cached in the store is in a format this version does not understand.",
            recovery: ["Choose the app, or its compiled model (.momd), to browse this store."]
        )
    }

    /// The single sanctioned use of an unarchiver on file content: secure coding, restricted to
    /// `NSManagedObjectModel` and the Core Data classes it declares. Never used on attribute data.
    static func unarchiveModel(_ archive: Data) throws -> NSManagedObjectModel {
        let model: NSManagedObjectModel?
        do {
            model = try objcGuarded("The model cached in the store could not be read.", code: .modelUnreadable) {
                try NSKeyedUnarchiver.unarchivedObject(ofClass: NSManagedObjectModel.self, from: archive)
            }
        } catch let error as DabbiError {
            throw error
        } catch {
            throw DabbiError(
                .modelUnreadable, "The model cached in the store could not be read.", underlying: error)
        }
        guard let model else {
            throw DabbiError(.modelUnreadable, "The model cached in the store is empty.")
        }
        return model
    }
}
