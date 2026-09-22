import DabbiKit
import Foundation
import Observation

/// What the content viewer shows for one field (CNT-1…CNT-5).
///
/// The field is the clicked cell: an object and one of its properties. Reading it is two steps — the row, then
/// the full bytes of a blob, which the grid never loads — and decoding is a third that runs off the main actor.
@MainActor
@Observable
final class ContentModel {
    /// The three ways of looking at the same bytes (CNT-1). Every field has all three; Rendered falls back to
    /// Hex when nothing recognised the content.
    enum Mode: String, CaseIterable, Identifiable {
        case rendered, text, hex
        var id: String { rawValue }

        var title: String {
            switch self {
            case .rendered: String(localized: "Rendered")
            case .text: String(localized: "Text")
            case .hex: String(localized: "Hex")
            }
        }
    }

    /// The cell the viewer is reading.
    struct Field: Equatable {
        var ref: ObjectRef
        var property: String
        /// What the model calls this property's type, for the header.
        var typeName: String?
    }

    enum State {
        /// No cell has been clicked, or the store is not open.
        case noField
        case loading(Field)
        /// Decoded: the report is what every mode reads from.
        case ready(Field, ContentReport)
        /// The field is null, or holds no bytes at all.
        case empty(Field, String)
        /// A number, a date, a relationship: something whose value the grid already shows in full.
        case plain(Field, String)
        case failed(Field, DabbiError)
    }

    private let context: ProjectContext

    private(set) var state: State = .noField
    /// The type the user picked from "Decode as", which wins over what the magic bytes say until the field
    /// changes (CNT-2).
    private(set) var forcedType: ContentTypeID?

    @ObservationIgnored private var task: Task<Void, Never>?
    @ObservationIgnored private var loaded: Field?
    @ObservationIgnored private var loadedFrom: ObjectIdentifier?

    init(context: ProjectContext) {
        self.context = context
    }

    var mode: Mode {
        get { context.local.selection.contentMode.flatMap(Mode.init) ?? .rendered }
        set { context.updateSelection { $0.contentMode = newValue.rawValue } }
    }

    var timeZone: TimeZone { context.timeZone }

    /// What the window is pointing at, whether or not it has been read yet.
    var field: Field? {
        guard let ref = context.inspectedObject, let property = context.focusedProperty else { return nil }
        return Field(ref: ref, property: property, typeName: typeName(of: property, in: ref.entity))
    }

    var sessionIdentity: ObjectIdentifier? { context.session.map(ObjectIdentifier.init) }

    private func typeName(of property: String, in entity: String) -> String? {
        guard let description = context.model?.entity(named: entity) else { return nil }
        if let attribute = description.attribute(named: property) { return attribute.type.displayName }
        if let relationship = description.relationship(named: property) {
            return relationship.isToMany
                ? String(localized: "To-many → \(relationship.destinationEntity)")
                : String(localized: "To-one → \(relationship.destinationEntity)")
        }
        return nil
    }

    // MARK: Reading

    /// Reads whatever the window is pointing at. Called from the view's `task`, so that a hidden pane reads
    /// nothing: a blob is the one thing in the window that can be tens of megabytes.
    func refresh() {
        let identity = sessionIdentity
        if identity != loadedFrom {
            loadedFrom = identity
            loaded = nil
            state = .noField
        }
        guard let session = context.session, let field else {
            task?.cancel()
            loaded = nil
            state = .noField
            return
        }
        guard field != loaded else { return }
        loaded = field
        forcedType = nil
        load(field, from: session, as: nil)
    }

    /// "Decode as": the user knows better than the magic bytes (CNT-2).
    func decode(as type: ContentTypeID?) {
        guard let session = context.session, let field = loaded else { return }
        forcedType = type
        load(field, from: session, as: type)
    }

    private func load(_ field: Field, from session: StoreSession, as forced: ContentTypeID?) {
        task?.cancel()
        state = .loading(field)
        let hint = self.hint(for: field)
        let timeZone = context.timeZone
        task = Task { [weak self] in
            let state: State
            do {
                let snapshot = try await session.object(field.ref)
                switch try await Self.bytes(of: field, in: snapshot, from: session) {
                case .bytes(let data) where !data.isEmpty:
                    let report = await Self.decode(data, hint: hint, as: forced)
                    state = .ready(field, report)
                case .bytes:
                    state = .empty(field, String(localized: "The field holds no bytes."))
                case .null:
                    state = .empty(field, String(localized: "The field is null."))
                case .plain(let value):
                    state = .plain(field, value.displayString(timeZone: timeZone))
                case .missing:
                    state = .empty(field, String(localized: "This row has no such property."))
                }
            } catch let error as DabbiError {
                state = .failed(field, error)
            } catch {
                state = .failed(field, DabbiError(.internal, "The field could not be read.", underlying: error))
            }
            guard !Task.isCancelled, let self, self.loaded == field else { return }
            self.state = state
        }
    }

    /// What a field turned out to hold.
    private enum Bytes {
        case bytes(Data)
        case null
        /// Nothing to decode: the grid's own rendering says everything there is to say.
        case plain(Value)
        case missing
    }

    private static func bytes(
        of field: Field, in snapshot: ObjectSnapshot, from session: StoreSession
    ) async throws
        -> Bytes
    {
        guard let value = snapshot[field.property] else { return .missing }
        switch value {
        case .null:
            return .null
        case .blob:
            // The grid only ever reads a blob's size; the viewer is where the bytes are actually fetched.
            return .bytes(try await session.blob(for: field.ref, attribute: field.property) ?? Data())
        case .string(let text):
            return .bytes(Data(text.utf8))
        case .url(let url):
            return .bytes(Data(url.absoluteString.utf8))
        default:
            return .plain(value)
        }
    }

    private func hint(for field: Field) -> ContentHint {
        let attribute = context.model?.entity(named: field.ref.entity)?.attribute(named: field.property)
        let storage: ContentHint.Storage? =
            switch attribute?.type {
            case .string: .string
            case .uri: .uri
            case .transformable: .transformable
            case .binaryData: .binary
            default: nil
            }
        return ContentHint(storage: storage, attributeName: field.property)
    }

    /// Decoding runs on a thread of its own, deep enough for a hostile archive (ARCHITECTURE.md §6.8), and it
    /// blocks the caller while it does — so the caller must not be one of Swift concurrency's few threads.
    private static func decode(_ data: Data, hint: ContentHint, as forced: ContentTypeID?) async -> ContentReport {
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                let registry = ContentRegistry.standard
                continuation.resume(
                    returning: forced.map { registry.decode(data, as: $0) } ?? registry.decode(data, hint: hint))
            }
        }
    }

    /// Returns once the field on screen has been read. For the tests.
    func whenSettled() async {
        await task?.value
    }
}

extension ContentTypeID {
    /// What the "Decode as" menu and the header call this kind of content.
    var displayName: String {
        switch self {
        case .png: "PNG"
        case .jpeg: "JPEG"
        case .gif: "GIF"
        case .tiff: "TIFF"
        case .webp: "WebP"
        case .heic: "HEIC"
        case .pdf: "PDF"
        case .svg: "SVG"
        case .mpeg4: "MPEG-4"
        case .mpeg4Audio: "MPEG-4 audio"
        case .quickTime: "QuickTime"
        case .binaryPlist: String(localized: "Binary property list")
        case .keyedArchive: String(localized: "Keyed archive")
        case .xmlPlist: String(localized: "XML property list")
        case .json: "JSON"
        case .xml: "XML"
        case .html: "HTML"
        case .rtf: "RTF"
        case .gzip: "gzip"
        case .zlib: "zlib"
        case .sqlite: "SQLite"
        case .text: String(localized: "Text")
        case .link: String(localized: "Link")
        default: rawValue
        }
    }
}
