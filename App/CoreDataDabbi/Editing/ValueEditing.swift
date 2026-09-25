import DabbiKit
import Foundation

/// How a value is edited where it is shown (EDT-3): what can be typed into, what the typing becomes, and how it
/// is staged; and which object a to-one leads to, which is picked rather than typed. The inspector's fields, the
/// grid's cells and the relationships panel all ask here, so that the rules are the same wherever a value is
/// edited.
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

    // MARK: To-ones

    /// The to-one relationship `name` of `object`'s own entity, when the store is open for editing: stored, and
    /// changed by choosing the object it leads to.
    func editableToOne(_ name: String, of object: PendingObjectID) -> RelationshipDescription? {
        guard accessMode == .editable,
            let relationship = model?.entity(named: object.entity)?.relationship(named: name),
            !relationship.isToMany, !relationship.isTransient
        else { return nil }
        return relationship
    }

    /// A picker of the saved objects `relationship` can lead to — its destination's and the sub-entities' —
    /// labelled by the display attribute, the project's choice before the model's. Those in `linked` are marked
    /// and not offered again; what is chosen goes to `choose`.
    func objectPicker(
        for relationship: RelationshipDescription, linked: Set<ObjectRef>,
        choose: @escaping @MainActor ([ObjectRef]) -> Void
    ) -> ObjectPicker? {
        guard accessMode == .editable, let session, let model else { return nil }
        let destination = relationship.destinationEntity
        let displayAttribute =
            layout(of: destination).displayAttribute ?? model.entity(named: destination)?.displayAttributeName
        return ObjectPicker(
            entity: destination, relationship: relationship.name, isToMany: relationship.isToMany, linked: linked,
            session: session, model: model, displayAttribute: displayAttribute, onChoose: choose)
    }

    /// How the to-one `name` of `object`, which holds `value` now, is changed — `nil` when it cannot be. The
    /// object chosen replaces the one it leads to, as an edit of the field.
    func toOneChoosing(_ name: String, value: Value, of object: PendingObjectID) -> ToOneChoosing? {
        guard let relationship = editableToOne(name, of: object) else { return nil }
        // The saved object it leads to is marked in the picker; one only inserted is not listed there at all.
        let (linked, leadsSomewhere): (Set<ObjectRef>, Bool) =
            switch value {
            case .toOne(let ref?, _): ([ref], true)
            case .toOneInserted: ([], true)
            default: ([], false)
            }
        var clear: (@MainActor () -> Void)?
        if relationship.isOptional, leadsSomewhere {
            clear = { [weak self] in self?.editing.setValue(.null, for: name, of: object) }
        }
        return ToOneChoosing(
            pick: { [weak self] in
                guard let self else { return nil }
                return self.objectPicker(for: relationship, linked: linked) { [weak self] refs in
                    guard let ref = refs.first else { return }
                    self?.editing.setValue(.toOne(ref, display: nil), for: name, of: object)
                }
            },
            clear: clear)
    }
}
