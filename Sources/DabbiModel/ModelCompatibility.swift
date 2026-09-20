@preconcurrency import CoreData
import DabbiBase
import Foundation

/// Whether a model can open a store, and if not, which entities disagree (PRJ-7).
public struct ModelCompatibility: Sendable, Hashable, Codable {
    public var isCompatible: Bool
    /// Entities the store has but the model lacks.
    public var storeOnly: [String]
    /// Entities the model has but the store lacks.
    public var modelOnly: [String]
    /// Entities both have, with different version hashes.
    public var hashDiffers: [String]

    public static func check(model: NSManagedObjectModel, metadata: StoreMetadata) -> ModelCompatibility {
        let modelHashes = model.entityVersionHashesByName
        let storeHashes = metadata.entityVersionHashes
        let modelNames = Set(modelHashes.keys)
        let storeNames = Set(storeHashes.keys)
        return ModelCompatibility(
            isCompatible: ModelLoader.isCompatible(model, with: metadata.coreDataDictionary),
            storeOnly: storeNames.subtracting(modelNames).sorted(),
            modelOnly: modelNames.subtracting(storeNames).sorted(),
            hashDiffers: modelNames.intersection(storeNames).filter { modelHashes[$0] != storeHashes[$0] }.sorted()
        )
    }

    /// The error shown when a store cannot be opened with the chosen model.
    public func error(storeURL: URL) -> DabbiError {
        var diagnosis: [String] = []
        if !hashDiffers.isEmpty { diagnosis.append("Changed entities: \(hashDiffers.joined(separator: ", ")).") }
        if !storeOnly.isEmpty { diagnosis.append("Only in the store: \(storeOnly.joined(separator: ", ")).") }
        if !modelOnly.isEmpty { diagnosis.append("Only in the model: \(modelOnly.joined(separator: ", ")).") }
        return DabbiError(
            .modelIncompatible,
            "The model does not match the store.",
            arguments: ["store": storeURL.path],
            diagnosis: diagnosis,
            recovery: [
                "Choose the model version the store was saved with.",
                "Open the store without a model file to use the model cached inside it.",
            ]
        )
    }
}
