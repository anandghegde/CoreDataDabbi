@preconcurrency import CoreData
import DabbiBase
import Foundation

/// Returns the stored bytes of a transformable attribute untouched, in both directions (ADR-09).
///
/// With this in place of the app's transformers, Core Data never instantiates an app class or unarchives
/// attribute data: a transformable attribute's value is simply its `Data`.
@objc(DabbiPassThroughTransformer)
public final class DabbiPassThroughTransformer: ValueTransformer {
    public static let name = NSValueTransformerName("DabbiPassThroughTransformer")

    /// Registers the transformer under `name`. Safe to call repeatedly and from any thread.
    public static func register() {
        if ValueTransformer(forName: name) == nil {
            ValueTransformer.setValueTransformer(DabbiPassThroughTransformer(), forName: name)
        }
    }

    public override class func transformedValueClass() -> AnyClass { NSData.self }
    public override class func allowsReverseTransformation() -> Bool { true }
    public override func transformedValue(_ value: Any?) -> Any? { value }
    public override func reverseTransformedValue(_ value: Any?) -> Any? { value }
}

/// Makes a model safe to load without the app's code. Applied to a copy before any coordinator sees it.
public enum ModelSanitiser {
    /// A mutable copy of `model` in which
    ///
    /// - every entity is backed by plain `NSManagedObject`, and
    /// - every transformable attribute — composite elements included — uses `DabbiPassThroughTransformer`.
    ///
    /// Nothing else is touched. Entity version hashes must come out unchanged, otherwise the store would no
    /// longer open; that is asserted here and fails with `.modelSanitiserChangedHashes`.
    public static func sanitised(_ model: NSManagedObjectModel) throws -> NSManagedObjectModel {
        DabbiPassThroughTransformer.register()
        let before = model.entityVersionHashesByName

        let copy = try objcGuarded("The model could not be prepared for browsing.", code: .modelUnreadable) {
            guard let copy = model.copy() as? NSManagedObjectModel else {
                throw DabbiError(.internal, "Copying the model produced an unexpected object.")
            }
            for entity in copy.entities {
                entity.managedObjectClassName = NSStringFromClass(NSManagedObject.self)
                for case let attribute as NSAttributeDescription in entity.properties {
                    sanitise(attribute)
                }
            }
            return copy
        }

        let after = copy.entityVersionHashesByName
        guard before == after else {
            let changed = before.keys.filter { before[$0] != after[$0] }.sorted()
            throw DabbiError(
                .modelSanitiserChangedHashes,
                "Preparing the model for browsing changed its version hashes.",
                arguments: ["entities": changed.joined(separator: ", ")],
                diagnosis: [
                    "This OS version hashes a model property that earlier versions ignored.",
                    "Opening the store with the changed model would fail, so nothing was opened.",
                ],
                recovery: ["Please report this together with your macOS version."]
            )
        }
        return copy
    }

    private static func sanitise(_ attribute: NSAttributeDescription) {
        if attribute.attributeType == .transformableAttributeType {
            attribute.valueTransformerName = DabbiPassThroughTransformer.name.rawValue
        }
        if let composite = attribute as? NSCompositeAttributeDescription {
            for element in composite.elements { sanitise(element) }
        }
    }
}
