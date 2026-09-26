import AppKit
import DabbiKit
import UniformTypeIdentifiers

/// How a binary field's bytes are handled (EDT-6): saved to a file whether or not the store is open for editing,
/// and, when it is, replaced from a file or cleared.
struct BinaryEditing {
    /// Writes the staged bytes to a file the person chooses; `nil` when there are none.
    let save: (@MainActor () -> Void)?
    /// Replaces the bytes with a file's; `nil` when the store is not open for editing.
    let replace: (@MainActor () -> Void)?
    /// Empties the attribute; `nil` when it cannot be edited, must have a value, or has none.
    let clear: (@MainActor () -> Void)?
}

/// One element of a composite attribute, as a field of its own (EDT-7).
struct CompositeField {
    /// `attribute.element[.subelement]`, as `setElement` takes it.
    let path: String
    /// How deep it is under the attribute: 1 for an element of it.
    let depth: Int
    let element: AttributeDescription
    let value: Value
}

extension ProjectContext {
    // MARK: Binary data (EDT-6)

    /// How the binary or transformable attribute `name` of `object`, which holds `value` now, is handled — `nil`
    /// for any other property.
    func binaryEditing(_ name: String, value: Value, of object: PendingObjectID) -> BinaryEditing? {
        guard let attribute = model?.entity(named: object.entity)?.attribute(named: name),
            attribute.type == .binaryData || attribute.type == .transformable, !attribute.isTransient
        else { return nil }
        let editable = accessMode == .editable && !attribute.isDerived
        var save: (@MainActor () -> Void)?
        var replace: (@MainActor () -> Void)?
        var clear: (@MainActor () -> Void)?
        if attribute.type == .binaryData, !value.isNull {
            save = { [weak self] in self?.chooseFileToSave(name, of: object) }
        }
        if editable, attribute.type == .binaryData {
            replace = { [weak self] in self?.chooseFileToReplace(name, of: object) }
        }
        if editable, attribute.isOptional, !value.isNull {
            clear = { [weak self] in self?.editing.clearData(of: name, of: object) }
        }
        return BinaryEditing(save: save, replace: replace, clear: clear)
    }

    /// Writes the bytes `attribute` of `object` holds as staged — externally stored or not — to `url`.
    func saveData(_ attribute: String, of object: PendingObjectID, to url: URL) async throws {
        guard let session else { throw DabbiError(.notEditable, String(localized: "The store is not open.")) }
        let data = try await session.stagedData(of: object, attribute: attribute) ?? Data()
        try data.write(to: url, options: .atomic)
    }

    private func chooseFileToReplace(_ attribute: String, of object: PendingObjectID) {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.message = String(localized: "Choose the file whose contents replace \(attribute).")
        panel.prompt = String(localized: "Replace")
        guard panel.runModal() == .OK, let url = panel.url else { return }
        editing.replaceData(of: attribute, of: object, from: url)
    }

    private func chooseFileToSave(_ attribute: String, of object: PendingObjectID) {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = attribute
        panel.message = String(localized: "Save the contents of \(attribute) to a file.")
        guard panel.runModal() == .OK, let url = panel.url else { return }
        Task { [weak self] in
            do {
                try await self?.saveData(attribute, of: object, to: url)
            } catch {
                NSApp.presentError(DabbiError.wrapping(error))
            }
        }
    }

    // MARK: Composites (EDT-7)

    /// The elements of the composite attribute `name` of `object`, holding `value` now, nested ones after the one
    /// they are in — empty for any other property.
    func compositeFields(_ name: String, value: Value, of object: PendingObjectID) -> [CompositeField] {
        guard let attribute = model?.entity(named: object.entity)?.attribute(named: name),
            attribute.type == .composite, let elements = attribute.compositeElements
        else { return [] }
        return Self.fields(elements, in: value, path: name, depth: 1)
    }

    private static func fields(
        _ elements: [AttributeDescription], in value: Value, path: String, depth: Int
    ) -> [CompositeField] {
        let values: [String: Value] = if case .composite(let values) = value { values } else { [:] }
        return elements.flatMap { element in
            let path = "\(path).\(element.name)"
            let value = values[element.name] ?? .null
            let field = CompositeField(path: path, depth: depth, element: element, value: value)
            guard element.type == .composite, let nested = element.compositeElements else { return [field] }
            return [field] + fields(nested, in: value, path: path, depth: depth + 1)
        }
    }

    /// How the composite element at `field.path` of `object` is edited — `nil` when it cannot be typed.
    func fieldEditing(_ field: CompositeField, of object: PendingObjectID) -> FieldEditing? {
        guard accessMode == .editable, ValueText.isEditableAsText(field.element.type) else { return nil }
        let element = field.element
        let path = field.path
        var clear: (@MainActor () -> Void)?
        if element.isOptional, !field.value.isNull {
            clear = { [weak self] in self?.editing.setElement(.null, at: path, of: object) }
        }
        return FieldEditing(
            text: ValueText.text(for: field.value, timeZone: timeZone),
            stage: { [weak self] text in
                guard let self else { return nil }
                do {
                    let value = try ValueText.value(from: text, for: element.type, timeZone: timeZone)
                    editing.setElement(value, at: path, of: object)
                    return nil
                } catch {
                    return DabbiError.wrapping(error).message
                }
            },
            clear: clear)
    }
}
