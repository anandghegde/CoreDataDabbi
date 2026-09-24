import DabbiKit
import Foundation

/// How a value is edited where it is shown (EDT-3): what can be typed into, what the typing becomes, and how it
/// is staged. The inspector's fields and the grid's cells both ask here, so that the rules are the same wherever
/// a value is edited.
extension ProjectContext {
    /// The attribute `name` of `object`'s own entity, when the store is open for editing and the attribute is one
    /// a person can type: stored, not derived, and of a type `ValueText` reads.
    func editableAttribute(_ name: String, of object: PendingObjectID) -> AttributeDescription? {
        guard accessMode == .editable,
            let attribute = model?.entity(named: object.entity)?.attribute(named: name),
            !attribute.isTransient, !attribute.isDerived, ValueText.isEditableAsText(attribute.type)
        else { return nil }
        return attribute
    }

    /// Stages what was typed for `attribute` of `object`, read in the project's time zone.
    ///
    /// - Returns: why the text cannot be a value of the attribute's type, for the editor to show while it keeps
    ///   the text; `nil` once the value is sent to be staged. A value the session then refuses is explained by
    ///   the window, as any refused edit is.
    func stage(_ text: String, for attribute: AttributeDescription, of object: PendingObjectID) -> String? {
        do {
            let value = try ValueText.value(from: text, for: attribute.type, timeZone: timeZone)
            editing.setValue(value, for: attribute.name, of: object)
            return nil
        } catch {
            return DabbiError.wrapping(error).message
        }
    }

    /// Stages no value for `attribute` of `object`.
    func clear(_ attribute: AttributeDescription, of object: PendingObjectID) {
        editing.setValue(.null, for: attribute.name, of: object)
    }

    /// How the property `name` of `object`, which holds `value` now, is edited — `nil` when it cannot be typed.
    func fieldEditing(_ name: String, value: Value, of object: PendingObjectID) -> FieldEditing? {
        guard let attribute = editableAttribute(name, of: object) else { return nil }
        var clear: (@MainActor () -> Void)?
        if attribute.isOptional, !value.isNull {
            clear = { [weak self] in self?.clear(attribute, of: object) }
        }
        return FieldEditing(
            text: ValueText.text(for: value, timeZone: timeZone),
            stage: { [weak self] in self?.stage($0, for: attribute, of: object) }, clear: clear)
    }
}
