import DabbiKit
import SwiftUI

/// The foldable tree of a property list, a JSON document or a keyed archive (CNT-2, CNT-4).
///
/// The tree is a description — a class name and its fields — never an object: nothing here instantiates
/// anything out of the file (ADR-08).
struct ContentTreeView: View {
    var root: ContentNode

    /// A tree bigger than this is shown as an outline instead: every row of a `List` is a view, and a keyed
    /// archive of a large object graph has more nodes than a window has any use for.
    static let maximumNodes = 20_000

    var body: some View {
        if root.nodeCount > Self.maximumNodes {
            TextViewer(text: root.outline())
        } else {
            List([ContentTreeItem(id: "", node: root)], children: \.children) { item in
                row(item.node)
            }
            .listStyle(.sidebar)
            .scrollContentBackground(.hidden)
        }
    }

    private func row(_ node: ContentNode) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            if let key = node.key {
                Text(key)
                    .font(.system(.callout, design: .monospaced).weight(.medium))
            }
            Text(headline(of: node))
                .font(.system(.callout, design: .monospaced))
                .foregroundStyle(colour(of: node.kind))
                .lineLimit(1)
                .truncationMode(.middle)
            Spacer(minLength: 0)
        }
        .textSelection(.enabled)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(node.key.map { "\($0): \(node.headline)" } ?? node.headline)
        .help(node.headline)
    }

    /// The node on one line. Containers say what they hold; a class name is kept, because in an archive it is
    /// most of the information.
    private func headline(of node: ContentNode) -> String {
        switch node.kind {
        case .dictionary, .array, .set, .object:
            let name = node.className.map { "\($0) " } ?? ""
            let count = node.children.count
            let summary = node.value ?? String(localized: "\(count) items")
            return node.kind == .object ? "\(name)— \(summary)" : "\(name)\(label(of: node.kind)) — \(summary)"
        default:
            return node.headline
        }
    }

    private func label(of kind: ContentNode.Kind) -> String {
        switch kind {
        case .dictionary: String(localized: "dictionary")
        case .array: String(localized: "array")
        case .set: String(localized: "set")
        default: kind.rawValue
        }
    }

    private func colour(of kind: ContentNode.Kind) -> Color {
        switch kind {
        case .string: .primary
        case .number, .bool, .date, .uid: .accentColor
        case .null, .reference, .truncated: .secondary
        case .data: .purple
        default: .secondary
        }
    }
}

/// A node, with an identity made of where it sits: `ContentNode` is a value and two identical siblings would
/// otherwise be the same row.
struct ContentTreeItem: Identifiable {
    let id: String
    let node: ContentNode

    /// Built on demand, so that only what is unfolded is ever turned into rows.
    var children: [ContentTreeItem]? {
        guard !node.children.isEmpty else { return nil }
        return node.children.enumerated().map { ContentTreeItem(id: "\(id)/\($0.offset)", node: $0.element) }
    }
}
