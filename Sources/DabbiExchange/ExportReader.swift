import DabbiBase
import DabbiModel
import DabbiStore
import Foundation

/// What an export reads (IMX-1): the rows picked in the grid, or everything a fetch matches — the current view,
/// or a whole entity.
public enum ExportSource: Sendable, Hashable {
    /// These objects, in this order. `entity` is the one the grid shows, which the columns are laid out for.
    case objects([ObjectRef], entity: String)
    /// What the fetch matches, in its order, read a page at a time. Its limit, if it has one, is kept.
    case fetch(FetchSpec)

    public var entity: String {
        switch self {
        case .objects(_, let entity): entity
        case .fetch(let spec): spec.entity
        }
    }
}

public struct ExportOptions: Sendable, Hashable {
    /// How far an export follows relationships.
    public enum Relationships: Sendable, Hashable {
        /// Not at all: attributes only.
        case omitted
        /// A to-one as its object's URI and a to-many as how many objects it has: what the grid shows, at no
        /// extra cost.
        case counts
        /// Each relationship as the URIs of its objects — what import links by.
        case references
        /// Related objects written out in full, `depth` relationships deep; beyond that, and wherever an object
        /// would contain itself, a reference.
        case embedded(depth: Int)
    }

    /// The top-level records' properties, by name. `nil` is every stored property; an embedded object always
    /// has all of its own.
    public var properties: [String]?
    public var relationships: Relationships
    /// Whether binary and transformable values are written, Base64. Without them a file stays small and a blob
    /// is only summarised.
    public var includesBinaryData: Bool

    public init(
        properties: [String]? = nil, relationships: Relationships = .references, includesBinaryData: Bool = true
    ) {
        self.properties = properties
        self.relationships = relationships
        self.includesBinaryData = includesBinaryData
    }
}

/// Reads records out of a store for an exporter (IMX-1, BRW-12).
///
/// Nothing is held that has been written: a fetch is read a page at a time, and each record handed on before the
/// next is read. Values leave through `StoreSession` like any other read, so an export sees staged edits as the
/// grid does.
public struct ExportReader: Sendable {
    public let session: StoreSession
    public let model: ModelDescription
    public var options: ExportOptions

    public init(session: StoreSession, options: ExportOptions = .init()) {
        self.session = session
        self.model = session.info.model
        self.options = options
    }

    // MARK: Layout

    /// The columns a tabular format writes for `source`: `$id`, `$entity`, then every property of the entity and
    /// its sub-entities in the model's order, with composites spread over one column per element.
    public func layout(for source: ExportSource) -> ExportLayout {
        var properties: [(name: String, columns: [ExportLayout.Column])] = []
        var seen: Set<String> = []
        for entity in model.entityAndDescendants(of: source.entity) {
            for attribute in entity.attributes where !attribute.isTransient && isSelected(attribute.name) {
                guard seen.insert(attribute.name).inserted else { continue }
                properties.append((attribute.name, Self.columns(for: attribute, path: [attribute.name])))
            }
            guard options.relationships != .omitted else { continue }
            for relationship in entity.relationships where !relationship.isTransient && isSelected(relationship.name) {
                guard seen.insert(relationship.name).inserted else { continue }
                properties.append((relationship.name, [ExportLayout.Column(relationship.name)]))
            }
        }
        // Picked properties come in the order they were picked in: the grid's, for the current view.
        if let order = options.properties {
            properties.sort { (order.firstIndex(of: $0.name) ?? .max) < (order.firstIndex(of: $1.name) ?? .max) }
        }
        return ExportLayout(
            entity: source.entity,
            columns: [ExportLayout.Column(ExportLayout.idColumn), ExportLayout.Column(ExportLayout.entityColumn)]
                + properties.flatMap(\.columns))
    }

    private static func columns(for attribute: AttributeDescription, path: [String]) -> [ExportLayout.Column] {
        guard attribute.type == .composite, let elements = attribute.compositeElements, !elements.isEmpty else {
            return [ExportLayout.Column(name: path.joined(separator: "."), path: path)]
        }
        return elements.flatMap { columns(for: $0, path: path + [$0.name]) }
    }

    private func isSelected(_ property: String) -> Bool {
        options.properties.map { $0.contains(property) } ?? true
    }

    // MARK: Reading

    /// Reads every record of `source`, handing each to `body` in order, and returns how many there were.
    ///
    /// Checks for cancellation between records.
    @discardableResult
    public func read(
        _ source: ExportSource, into body: (ExportRecord) async throws -> Void
    ) async throws -> Int {
        var count = 0
        switch source {
        case .objects(let refs, _):
            for ref in refs {
                try Task.checkCancellation()
                let snapshot = try await session.object(ref)
                try await body(record(ref, columns: snapshot.columns, values: snapshot.row.values, chain: []))
                count += 1
            }
        case .fetch(let spec):
            let handle = try await session.openPager(spec)
            do {
                var start = 0
                while start < handle.count {
                    let end = min(start + StoreSession.pageSize, handle.count)
                    let page = try await session.page(handle, range: start..<end)
                    for row in page.rows {
                        try Task.checkCancellation()
                        try await body(record(row.ref, columns: page.columns, values: row.values, chain: []))
                        count += 1
                    }
                    start = end
                }
            } catch {
                await session.closePager(handle)
                throw error
            }
            await session.closePager(handle)
        }
        return count
    }

    /// Every record at once: for what is small enough to hold, such as a copy of the selection.
    public func records(_ source: ExportSource) async throws -> [ExportRecord] {
        var records: [ExportRecord] = []
        try await read(source) { records.append($0) }
        return records
    }

    /// `source` written by `exporter`, as text.
    public func text(_ source: ExportSource, as exporter: some Exporter) async throws -> String {
        let layout = layout(for: source)
        var output = exporter.header(for: layout)
        var index = 0
        try await read(source) { record in
            output += exporter.record(record, index: index, layout: layout)
            index += 1
        }
        return output + exporter.footer(for: layout, count: index)
    }

    /// Writes `source` to a file with `exporter`, a page at a time, and returns how many records it wrote.
    ///
    /// The file appears only when it is complete: it is written beside its destination and moved into place, so
    /// a cancelled or failed export leaves whatever was there before.
    @discardableResult
    public func write(_ source: ExportSource, as exporter: some Exporter, to url: URL) async throws -> Int {
        let layout = layout(for: source)
        let writer = try ExportFileWriter(destination: url)
        do {
            try writer.append(exporter.header(for: layout))
            var index = 0
            try await read(source) { record in
                try writer.append(exporter.record(record, index: index, layout: layout))
                index += 1
            }
            try writer.append(exporter.footer(for: layout, count: index))
            try writer.finish()
            return index
        } catch {
            writer.abandon()
            throw error
        }
    }

    // MARK: Records

    /// One object as a record. `chain` is the objects that contain it, outermost first — what it must not embed
    /// again.
    func record(_ ref: ObjectRef, columns: ColumnSet, values: [Value], chain: [URL]) async throws -> ExportRecord {
        guard let entity = model.entity(named: ref.entity) else {
            throw DabbiError(.unknownEntity, "The model has no entity named “\(ref.entity)”.")
        }
        let isTopLevel = chain.isEmpty
        var fields: [ExportField] = []
        for (index, name) in columns.properties.enumerated() where index < values.count {
            if isTopLevel, !isSelected(name) { continue }
            if let attribute = entity.attribute(named: name), !attribute.isTransient {
                fields.append(ExportField(name, try await value(values[index], of: attribute, ref: ref, path: name)))
            } else if let relationship = entity.relationship(named: name), !relationship.isTransient {
                guard let value = try await value(values[index], of: relationship, ref: ref, chain: chain + [ref.uri])
                else { continue }
                fields.append(ExportField(name, value))
            }
        }
        if isTopLevel, let order = options.properties {
            fields.sort { (order.firstIndex(of: $0.name) ?? .max) < (order.firstIndex(of: $1.name) ?? .max) }
        }
        return ExportRecord(id: ref.uri, entity: ref.entity, fields: fields)
    }

    private func value(
        _ value: Value, of attribute: AttributeDescription, ref: ObjectRef, path: String
    ) async throws -> ExportValue {
        switch value {
        case .blob(let summary):
            guard options.includesBinaryData else { return .blob(summary) }
            return try await session.blob(for: ref, attribute: path).map(ExportValue.data) ?? .scalar(.null)
        case .composite(let elements):
            var fields: [ExportField] = []
            for element in attribute.compositeElements ?? [] {
                let inner = elements[element.name] ?? .null
                fields.append(
                    ExportField(
                        element.name,
                        try await self.value(inner, of: element, ref: ref, path: path + "." + element.name)))
            }
            return .composite(fields)
        default:
            return .scalar(value)
        }
    }

    /// A relationship's value as far as the options follow it; `nil` when they leave it out.
    private func value(
        _ value: Value, of relationship: RelationshipDescription, ref: ObjectRef, chain: [URL]
    ) async throws -> ExportValue? {
        switch options.relationships {
        case .omitted:
            return nil
        case .counts:
            return ExportValue(value)
        case .references, .embedded:
            guard relationship.isToMany else {
                switch value {
                case .toOne(let destination?, _): return try await related(destination, chain: chain)
                case .toOneInserted(let object, _): return .reference(object.uri, entity: object.entity)
                default: return ExportValue.nothing
                }
            }
            let related = try await session.related(to: ref, through: relationship.name, limit: .max)
            var values: [ExportValue] = []
            for item in related.items {
                if let destination = item.ref {
                    values.append(try await self.related(destination, chain: chain))
                } else {
                    values.append(.reference(item.object.uri, entity: item.object.entity))
                }
            }
            return .objects(values)
        }
    }

    /// The object at the far end of a relationship: written out when the depth allows and it does not contain
    /// itself, and named otherwise.
    private func related(_ destination: ObjectRef, chain: [URL]) async throws -> ExportValue {
        guard case .embedded(let depth) = options.relationships, chain.count <= depth,
            !chain.contains(destination.uri)
        else { return .reference(destination.uri, entity: destination.entity) }
        let snapshot = try await session.object(destination)
        return .object(
            try await record(destination, columns: snapshot.columns, values: snapshot.row.values, chain: chain))
    }
}

extension ExportValue {
    /// A value as a page or a snapshot holds it, without reading anything more: a to-one as a reference, a
    /// to-many as its count, a blob as its summary.
    public init(_ value: Value) {
        switch value {
        case .blob(let summary): self = .blob(summary)
        case .composite(let elements):
            self = .composite(elements.sorted { $0.key < $1.key }.map { ExportField($0.key, ExportValue($0.value)) })
        case .toOne(let ref?, _): self = .reference(ref.uri, entity: ref.entity)
        case .toOne(nil, _): self = .nothing
        case .toOneInserted(let object, _): self = .reference(object.uri, entity: object.entity)
        case .toMany(let count): self = .count(count)
        default: self = .scalar(value)
        }
    }
}

/// A file written beside its destination and moved into place when it is complete.
final class ExportFileWriter {
    private let destination: URL
    private let temporary: URL
    private let handle: FileHandle
    private var buffer = Data()
    private static let flushSize = 1 << 16

    init(destination: URL) throws {
        self.destination = destination
        temporary = destination.deletingLastPathComponent()
            .appendingPathComponent(".\(destination.lastPathComponent).\(UUID().uuidString).partial")
        guard FileManager.default.createFile(atPath: temporary.path, contents: nil) else {
            throw DabbiError(
                .exportFailed, "The export could not be written there.", arguments: ["path": destination.path],
                recovery: ["Choose a folder you can write to."])
        }
        handle = try FileHandle(forWritingTo: temporary)
    }

    func append(_ text: String) throws {
        buffer.append(contentsOf: text.utf8)
        if buffer.count >= Self.flushSize { try flush() }
    }

    private func flush() throws {
        try handle.write(contentsOf: buffer)
        buffer.removeAll(keepingCapacity: true)
    }

    func finish() throws {
        try flush()
        try handle.close()
        if FileManager.default.fileExists(atPath: destination.path) {
            _ = try FileManager.default.replaceItemAt(destination, withItemAt: temporary)
        } else {
            try FileManager.default.moveItem(at: temporary, to: destination)
        }
    }

    func abandon() {
        try? handle.close()
        try? FileManager.default.removeItem(at: temporary)
    }
}
