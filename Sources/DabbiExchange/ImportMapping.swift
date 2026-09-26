import DabbiBase
import DabbiModel
import DabbiStore
import Foundation

/// Which property each column of an import file sets, and how its cells become values (IMX-2, IMX-4).
///
/// `automatic` maps columns by name, as an export names them: an attribute's name, `name.element` for a composite's
/// element, a relationship's name for its objects' URIs, and `$id` for the URI an upsert matches by. Whatever it
/// cannot place is ignored, and a person can map it by hand.
///
/// Cells are read as `ValueText` reads what is typed, dates without an offset in `timeZone`. Bytes are Base64. A
/// relationship's cell holds URIs — separated by spaces in a CSV cell, `{"$ref": …}` objects or strings in JSON —
/// or, mapped by a key, the values of one of the destination's attributes: in a CSV cell, several are separated by
/// a vertical bar.
public struct ImportMapping: Sendable, Hashable {
    public enum Target: Sendable, Hashable {
        case ignored
        /// The object's URI as exported: what an upsert matches by.
        case id
        /// An attribute, or an element of a composite one: `["location", "latitude"]`.
        case attribute([String])
        /// A relationship, by its objects' URIs.
        case relationship(String)
        /// A relationship, by the value of an attribute of its destination (IMX-4).
        case relationshipKey(String, key: String)
    }

    public struct Column: Sendable, Hashable {
        public var name: String
        public var target: Target

        public init(_ name: String, _ target: Target) {
            self.name = name
            self.target = target
        }
    }

    public var entity: String
    public var columns: [Column]
    public var timeZone: TimeZone

    public init(entity: String, columns: [Column], timeZone: TimeZone = .gmt) {
        self.entity = entity
        self.columns = columns
        self.timeZone = timeZone
    }

    /// The separator between several keys in one CSV cell.
    public static let keySeparator: Character = "|"

    // MARK: Mapping by name

    /// Every column of `table` mapped by its name onto `entity`, as an export of it names them.
    public static func automatic(
        for table: ImportTable, entity: EntityDescription, timeZone: TimeZone = .gmt
    ) -> ImportMapping {
        let choices = Set(targets(for: entity, model: nil))
        let columns = table.columns.map { name -> Column in
            if name == ExportLayout.idColumn { return Column(name, .id) }
            if entity.relationship(named: name) != nil, choices.contains(.relationship(name)) {
                return Column(name, .relationship(name))
            }
            let path = name.split(separator: ".", omittingEmptySubsequences: false).map(String.init)
            return Column(name, choices.contains(.attribute(path)) ? .attribute(path) : .ignored)
        }
        return ImportMapping(entity: entity.name, columns: columns, timeZone: timeZone)
    }

    /// What a column can be mapped onto, in the order a pop-up lists them: nothing, the URI, the attributes (a
    /// composite whole and element by element), then the relationships — by URI, then, when `model` is given, by
    /// each attribute of the destination a key can be typed as.
    ///
    /// Transient and derived attributes are not set, and transformables not imported: their bytes are the app's
    /// archive, which only the app can check.
    public static func targets(for entity: EntityDescription, model: ModelDescription?) -> [Target] {
        var targets: [Target] = [.ignored, .id]
        func add(_ attribute: AttributeDescription, path: [String]) {
            guard !attribute.isTransient, !attribute.isDerived else { return }
            switch attribute.type {
            case .transformable, .objectID, .undefined:
                return
            case .composite:
                targets.append(.attribute(path))
                for element in attribute.compositeElements ?? [] { add(element, path: path + [element.name]) }
            default:
                targets.append(.attribute(path))
            }
        }
        for attribute in entity.attributes { add(attribute, path: [attribute.name]) }
        for relationship in entity.relationships where !relationship.isTransient {
            targets.append(.relationship(relationship.name))
            guard let destination = model?.entity(named: relationship.destinationEntity) else { continue }
            for key in destination.attributes
            where !key.isTransient && !key.isDerived && ValueText.isEditableAsText(key.type) {
                targets.append(.relationshipKey(relationship.name, key: key.name))
            }
        }
        return targets
    }

    /// A target as a pop-up names it.
    public static func name(of target: Target) -> String {
        switch target {
        case .ignored: "—"
        case .id: ExportLayout.idColumn
        case .attribute(let path): path.joined(separator: ".")
        case .relationship(let name): name
        case .relationshipKey(let name, let key): "\(name) by \(key)"
        }
    }

    // MARK: Rows

    /// A cell as the preview shows it: the value it is read as, or why it cannot be.
    public enum Coerced: Sendable, Hashable {
        /// The column is not imported, or the cell does not say anything — a count, a summary of bytes.
        case skipped
        case value(ImportValue)
        case id(URL)
        case invalid(String)
    }

    /// What `row`'s cell in `column` is read as.
    public func coerce(_ row: ImportTable.Row, column: Column, model: ModelDescription) -> Coerced {
        guard let cell = row.cells[column.name] else { return .skipped }
        do {
            switch column.target {
            case .ignored:
                return .skipped
            case .id:
                guard case .string(let text) = cell, let url = URL(string: text), url.scheme != nil else {
                    return cell == .null ? .skipped : .invalid("This is not an object URI.")
                }
                return .id(url)
            case .attribute(let path):
                guard let attribute = Self.attribute(at: path, of: entity, model: model) else {
                    return .invalid("\(entity) has no attribute “\(path.joined(separator: "."))”.")
                }
                guard let value = try attributeValue(cell, of: attribute) else { return .skipped }
                // An element is set inside its composite, and the elements not given keep their values.
                return .value(path.dropFirst().reversed().reduce(value) { .composite([$1: $0]) })
            case .relationship:
                guard let references = try uriReferences(cell) else { return .skipped }
                return .value(.references(references))
            case .relationshipKey(let name, let key):
                guard let relationship = model.entity(named: entity)?.relationship(named: name),
                    let destination = model.entity(named: relationship.destinationEntity),
                    let keyAttribute = destination.attribute(named: key)
                else { return .invalid("\(entity) has no relationship “\(name)” with a key “\(key)”.") }
                let references = try keyReferences(cell, key: keyAttribute, destination: destination)
                return .value(.references(references))
            }
        } catch let error as DabbiError {
            return .invalid(error.message)
        } catch {
            return .invalid("This cell cannot be read.")
        }
    }

    /// The rows the store imports: one per row of `table`, with the cells that cannot be read as its issues.
    public func rows(from table: ImportTable, model: ModelDescription) -> [ImportRow] {
        table.rows.map { row in
            var result = ImportRow(line: row.line)
            for column in columns {
                switch coerce(row, column: column, model: model) {
                case .skipped: break
                case .id(let url): result.id = url
                case .invalid(let message): result.issues.append(ImportIssue(property: column.name, message: message))
                case .value(let value):
                    guard let property = column.property else { break }
                    result.values[property] = result.values[property].map { Self.merged($0, value) } ?? value
                }
            }
            return result
        }
    }

    /// Two columns of the same composite — `location.latitude`, `location.longitude` — make one value.
    private static func merged(_ first: ImportValue, _ second: ImportValue) -> ImportValue {
        guard case .composite(let a) = first, case .composite(let b) = second else { return second }
        return .composite(a.merging(b) { merged($0, $1) })
    }

    // MARK: Reading cells

    static func attribute(at path: [String], of entity: String, model: ModelDescription) -> AttributeDescription? {
        guard let first = path.first, var attribute = model.entity(named: entity)?.attribute(named: first) else {
            return nil
        }
        for element in path.dropFirst() {
            guard let next = attribute.compositeElements?.first(where: { $0.name == element }) else { return nil }
            attribute = next
        }
        return attribute
    }

    /// `nil` for a cell that says nothing about the value: a `$blob` summary, which an export writes for bytes it
    /// leaves out.
    private func attributeValue(_ cell: JSONNode, of attribute: AttributeDescription) throws -> ImportValue? {
        if cell == .null { return .value(.null) }
        switch attribute.type {
        case .binaryData:
            if cell[JSONExporter.blobKey] != nil { return nil }
            guard case .string(let text) = cell, let data = Data(base64Encoded: text) else {
                throw DabbiError(.invalidValue, "This is not Base64 text.")
            }
            return .data(data)
        case .composite:
            var node = cell
            // A CSV cell holds a composite as JSON text.
            if case .string(let text) = cell { node = try JSONNode.parse(text) }
            guard case .object(let members) = node else {
                throw DabbiError(.invalidValue, "This is not a composite's elements.")
            }
            var elements: [String: ImportValue] = [:]
            for (name, value) in members {
                guard let element = attribute.compositeElements?.first(where: { $0.name == name }) else {
                    throw DabbiError(.invalidValue, "The composite has no element named “\(name)”.")
                }
                if let value = try attributeValue(value, of: element) { elements[name] = value }
            }
            return .composite(elements)
        default:
            guard let text = cell.scalarText else {
                throw DabbiError(.invalidValue, "This is not a \(attribute.type.displayName) value.")
            }
            return .value(try ValueText.value(from: text, for: attribute.type, timeZone: timeZone))
        }
    }

    /// `nil` for a count, which an export writes for objects it does not name.
    private func uriReferences(_ cell: JSONNode) throws -> [ImportReference]? {
        func reference(_ node: JSONNode) throws -> ImportReference? {
            let text: String?
            switch node {
            case .string(let string): text = string
            case .object:
                if node[JSONExporter.countKey] != nil { return nil }
                // A reference, or an embedded object with its URI.
                text = node[JSONExporter.referenceKey]?.stringValue ?? node[ExportLayout.idColumn]?.stringValue
            default: text = nil
            }
            guard let text, let url = URL(string: text), url.scheme != nil else {
                throw DabbiError(.invalidValue, "This is not an object URI.")
            }
            return .uri(url)
        }
        switch cell {
        case .null: return []
        case .string(let text):
            return try text.split(whereSeparator: \.isWhitespace).compactMap { try reference(.string(String($0))) }
        case .array(let items):
            var references: [ImportReference] = []
            for item in items {
                guard let found = try reference(item) else { return nil }
                references.append(found)
            }
            return references
        default:
            return try reference(cell).map { [$0] }
        }
    }

    private func keyReferences(
        _ cell: JSONNode, key: AttributeDescription, destination: EntityDescription
    ) throws -> [ImportReference] {
        func value(_ node: JSONNode, of attribute: AttributeDescription) throws -> Value {
            guard let text = node.scalarText else {
                throw DabbiError(.invalidValue, "This is not a \(attribute.type.displayName) value.")
            }
            return try ValueText.value(from: text, for: attribute.type, timeZone: timeZone)
        }
        switch cell {
        case .null: return []
        case .string(let text):
            return try text.split(separator: Self.keySeparator).map {
                .key([key.name: try value(.string(String($0)), of: key)])
            }
        case .array(let items):
            return try items.flatMap { try keyReferences($0, key: key, destination: destination) }
        case .object(let members):
            // Several attributes together: `{"firstName": "Ada", "lastName": "Lovelace"}`.
            var values: [String: Value] = [:]
            for (name, node) in members {
                guard let attribute = destination.attribute(named: name) else {
                    throw DabbiError(.invalidValue, "\(destination.name) has no attribute “\(name)”.")
                }
                values[name] = try value(node, of: attribute)
            }
            return [.key(values)]
        default:
            return [.key([key.name: try value(cell, of: key)])]
        }
    }
}

extension ImportMapping.Column {
    /// The property the column sets, or `nil` for one that sets none.
    public var property: String? {
        switch target {
        case .ignored, .id: nil
        case .attribute(let path): path.first
        case .relationship(let name), .relationshipKey(let name, _): name
        }
    }
}

extension ImportValue {
    /// The value as the preview shows it. Bytes are counted, not shown.
    public func previewText(timeZone: TimeZone = .gmt) -> String {
        switch self {
        case .value(.null): "nil"
        case .value(let value): ValueText.text(for: value, timeZone: timeZone)
        case .data(let data): ByteCountFormatter.string(fromByteCount: Int64(data.count), countStyle: .file)
        case .composite(let elements):
            "{"
                + elements.sorted { $0.key < $1.key }.map { "\($0.key): \($0.value.previewText(timeZone: timeZone))" }
                .joined(separator: ", ") + "}"
        case .references(let references):
            references.map { reference in
                switch reference {
                case .uri(let url): url.absoluteString
                case .key(let key):
                    key.sorted { $0.key < $1.key }.map { ValueText.text(for: $0.value, timeZone: timeZone) }
                        .joined(separator: " ")
                }
            }
            .joined(separator: ", ")
        }
    }
}
