import DabbiBase
import Foundation

/// The machine-specific part of a project: `local/state.json` (ADR-13).
///
/// Nothing here is worth sharing — a bookmark resolves on one machine only, and nobody wants a colleague's
/// window frame — so a team can keep it out of the repository, or out of the package altogether
/// (`LocalStatePlacement`).
public struct LocalState: Sendable, Hashable {
    /// Bookmark data by `FileReference.bookmarkID`.
    public var bookmarks: [UUID: Data]
    public var window: WindowState
    public var selection: SelectionState

    public init(
        bookmarks: [UUID: Data] = [:], window: WindowState = WindowState(),
        selection: SelectionState = SelectionState()
    ) {
        self.bookmarks = bookmarks
        self.window = window
        self.selection = selection
    }
}

public struct WindowState: Sendable, Hashable {
    /// The window's frame in AppKit's own string form, which also names the screen it was on.
    public var frame: String?
    /// Identifiers of the panes that are collapsed (PRD §8.1: "all panes collapsible; layout saved per project").
    public var collapsedPanes: Set<String>
    /// Divider positions by split-view identifier, in points.
    public var dividers: [String: [Double]]

    public init(frame: String? = nil, collapsedPanes: Set<String> = [], dividers: [String: [Double]] = [:]) {
        self.frame = frame
        self.collapsedPanes = collapsedPanes
        self.dividers = dividers
    }
}

public struct SelectionState: Sendable, Hashable {
    /// The entity shown in the main grid.
    public var entity: String?
    public var inspectorTab: String?
    public var contentMode: String?
    /// The relationship the panel is following (REL-1). Names a property of whatever object is selected, so a
    /// remembered one is used only when the object has it.
    public var relationship: String?

    public init(
        entity: String? = nil, inspectorTab: String? = nil, contentMode: String? = nil, relationship: String? = nil
    ) {
        self.entity = entity
        self.inspectorTab = inspectorTab
        self.contentMode = contentMode
        self.relationship = relationship
    }
}

// MARK: - Bookmarks

/// A `FileReference` resolved to a place on this machine.
public struct ResolvedFile: Sendable, Hashable {
    public enum Origin: Sendable, Hashable {
        /// The bookmark led here.
        case bookmark
        /// There was no usable bookmark — the project came from another machine, or the bookmark broke — but
        /// the item is where it last was.
        case lastKnownPath
    }

    public let url: URL
    public let origin: Origin
    /// The item has moved or the bookmark has aged; the reference should be refreshed with `remember`.
    public let needsRefresh: Bool
}

extension LocalState {
    /// Makes a reference to `url` and stores its bookmark.
    ///
    /// - Parameter securityScoped: for a sandboxed build. The app as distributed is not sandboxed (PRD §9.7).
    public mutating func remember(
        _ url: URL, as id: UUID = UUID(), securityScoped: Bool = false
    ) -> FileReference {
        let url = url.standardizedFileURL
        // An item that does not exist cannot be bookmarked; the path alone is still a reference worth keeping.
        bookmarks[id] = try? url.bookmarkData(
            options: securityScoped ? [.withSecurityScope] : [], includingResourceValuesForKeys: nil, relativeTo: nil)
        return FileReference(bookmarkID: id, lastKnownPath: url.path)
    }

    /// Finds the item: by bookmark first — it follows moves and renames — then at the last known path.
    /// `nil` when neither leads to something that exists.
    public func resolve(_ reference: FileReference, securityScoped: Bool = false) -> ResolvedFile? {
        if let data = bookmarks[reference.bookmarkID] {
            var isStale = false
            let options: URL.BookmarkResolutionOptions =
                securityScoped ? [.withSecurityScope, .withoutUI] : [.withoutUI, .withoutMounting]
            if let url = try? URL(resolvingBookmarkData: data, options: options, bookmarkDataIsStale: &isStale),
                FileManager.default.fileExists(atPath: url.path)
            {
                let url = url.standardizedFileURL
                return ResolvedFile(
                    url: url, origin: .bookmark, needsRefresh: isStale || url.path != reference.lastKnownPath)
            }
        }
        guard FileManager.default.fileExists(atPath: reference.lastKnownPath) else { return nil }
        return ResolvedFile(url: reference.lastKnownURL, origin: .lastKnownPath, needsRefresh: true)
    }

    /// Drops bookmarks that no reference in `project` uses any more.
    public mutating func pruneBookmarks(keeping project: Project) {
        var used: Set<UUID> = []
        switch project.store {
        case .file(let reference), .container(let reference, _): used.insert(reference.bookmarkID)
        case .simulator, .macApp, .devicePull, nil: break
        }
        if case .file(let reference) = project.model { used.insert(reference.bookmarkID) }
        bookmarks = bookmarks.filter { used.contains($0.key) }
    }
}

// MARK: - Coding

extension LocalState: Codable {
    private enum CodingKeys: String, CodingKey { case bookmarks, window, selection }

    public init(from decoder: any Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        // Keyed by string: a `[UUID: Data]` dictionary would be encoded as a flat array of keys and values.
        let encoded = try values.decodeIfPresent([String: Data].self, forKey: .bookmarks) ?? [:]
        bookmarks = [:]
        for (key, data) in encoded {
            if let id = UUID(uuidString: key) { bookmarks[id] = data }
        }
        window = try values.decodeIfPresent(WindowState.self, forKey: .window) ?? WindowState()
        selection = try values.decodeIfPresent(SelectionState.self, forKey: .selection) ?? SelectionState()
    }

    public func encode(to encoder: any Encoder) throws {
        var values = encoder.container(keyedBy: CodingKeys.self)
        try values.encode(
            Dictionary(uniqueKeysWithValues: bookmarks.map { ($0.key.uuidString, $0.value) }), forKey: .bookmarks)
        try values.encode(window, forKey: .window)
        try values.encode(selection, forKey: .selection)
    }
}

extension WindowState: Codable {
    private enum CodingKeys: String, CodingKey { case frame, collapsedPanes, dividers }

    public init(from decoder: any Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        frame = try values.decodeIfPresent(String.self, forKey: .frame)
        collapsedPanes = try values.decodeIfPresent(Set<String>.self, forKey: .collapsedPanes) ?? []
        dividers = try values.decodeIfPresent([String: [Double]].self, forKey: .dividers) ?? [:]
    }

    public func encode(to encoder: any Encoder) throws {
        var values = encoder.container(keyedBy: CodingKeys.self)
        try values.encodeIfPresent(frame, forKey: .frame)
        // A set has no order; sorted, the file does not change when nothing did.
        try values.encode(collapsedPanes.sorted(), forKey: .collapsedPanes)
        try values.encode(dividers, forKey: .dividers)
    }
}

extension SelectionState: Codable {}
