import DabbiKit
import Foundation

/// A row of the sidebar (PRD §8.2, MOD-2).
///
/// A class, because `NSOutlineView` holds on to its items and asks about them by identity. Building and
/// filtering are static functions over a model, so that both can be tested without a window.
@MainActor
final class SidebarNode {
    enum Kind {
        /// A heading: "Entities", "Fetch Requests". Never selectable.
        case group(String)
        case entity(EntityDescription)
        case fetchRequest(FetchRequestTemplate)
    }

    let kind: Kind
    private(set) var children: [SidebarNode]
    private(set) weak var parent: SidebarNode?

    init(_ kind: Kind, children: [SidebarNode] = []) {
        self.kind = kind
        self.children = children
        for child in children { child.parent = self }
    }

    /// The entity this row stands for, if it stands for one.
    var entityName: String? {
        if case .entity(let entity) = kind { entity.name } else { nil }
    }

    var isGroup: Bool {
        if case .group = kind { true } else { false }
    }

    var title: String {
        switch kind {
        case .group(let title): title
        case .entity(let entity): entity.name
        case .fetchRequest(let request): request.name
        }
    }

    /// Ancestors, nearest first — what has to be open for this row to be visible.
    var ancestors: [SidebarNode] {
        var found: [SidebarNode] = []
        var node = parent
        while let current = node {
            found.append(current)
            node = current.parent
        }
        return found
    }

    // MARK: Building

    /// The whole sidebar of a model: entities nested by inheritance, then the model's fetch requests.
    ///
    /// Entities are sorted by name within each level, the way a person looks for one — not in the order the
    /// model happens to list them.
    static func tree(of model: ModelDescription) -> [SidebarNode] {
        var groups: [SidebarNode] = []
        let entities = model.rootEntities.map { subtree(of: $0, in: model) }
        if !entities.isEmpty {
            groups.append(SidebarNode(.group(String(localized: "Entities")), children: entities))
        }
        if !model.fetchRequestTemplates.isEmpty {
            groups.append(
                SidebarNode(
                    .group(String(localized: "Fetch Requests")),
                    children: model.fetchRequestTemplates.map { SidebarNode(.fetchRequest($0)) }))
        }
        return groups
    }

    private static func subtree(of entity: EntityDescription, in model: ModelDescription) -> SidebarNode {
        let children =
            entity.subentities
            .compactMap(model.entity(named:))
            .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
            .map { subtree(of: $0, in: model) }
        return SidebarNode(.entity(entity), children: children)
    }

    // MARK: Filtering

    /// The rows worth showing for `query`: those whose name matches, and the ancestors that lead to them.
    ///
    /// A match keeps its children too — narrowing to "Person" should still show what a `Person` can be.
    static func filter(_ nodes: [SidebarNode], matching query: String) -> [SidebarNode] {
        let query = query.trimmingCharacters(in: .whitespaces)
        guard !query.isEmpty else { return nodes }
        return nodes.compactMap { node in
            if node.matches(query) { return node }
            let children = filter(node.children, matching: query)
            return children.isEmpty ? nil : SidebarNode(node.kind, children: children)
        }
    }

    private func matches(_ query: String) -> Bool {
        guard !isGroup else { return false }
        return title.range(of: query, options: [.caseInsensitive, .diacriticInsensitive]) != nil
    }

    /// Depth-first, this node included.
    func flattened() -> [SidebarNode] {
        [self] + children.flatMap { $0.flattened() }
    }
}
