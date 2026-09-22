import Foundation

/// One node of the foldable tree the content viewer shows for JSON, property lists and keyed archives
/// (CNT-2, CNT-4).
///
/// It is a description, not a value: numbers keep the text they had, data keeps only its size and a prefix, and
/// an archived object is its class name and its fields — no class is ever instantiated to make one (ADR-08).
public struct ContentNode: Sendable, Hashable, Codable {
    public enum Kind: String, Sendable, Hashable, Codable {
        case dictionary, array, set
        case string, number, bool, date, data, null
        /// A `CFKeyedArchiverUID` in a property list that is not an archive.
        case uid
        /// An archived object of a class without a friendlier rendering; `className` says which.
        case object
        /// An object that is already open further up the tree. Following it would never end.
        case reference
        /// Where a safety limit cut the tree short.
        case truncated
    }

    /// What the parent calls this node: a dictionary key, `[3]`, a field of an archived object.
    public var key: String?
    public var kind: Kind
    /// `$classname` of an archived object, also when it is shown as a friendlier kind (`NSMutableArray` → array).
    public var className: String?
    /// A leaf's value as text, or a one-line summary of a container (“3 items”, an attributed string's text).
    public var value: String?
    public var children: [ContentNode]

    public init(
        key: String? = nil, kind: Kind, className: String? = nil, value: String? = nil,
        children: [ContentNode] = []
    ) {
        self.key = key
        self.kind = kind
        self.className = className
        self.value = value
        self.children = children
    }

    public var isContainer: Bool {
        switch kind {
        case .dictionary, .array, .set, .object: true
        default: false
        }
    }

    /// The number of nodes in this subtree, itself included.
    public var nodeCount: Int { children.reduce(1) { $0 + $1.nodeCount } }

    /// The first descendant reached by following `keys`, for tests and scripted callers.
    public subscript(path keys: String...) -> ContentNode? {
        var node = self
        for key in keys {
            guard let next = node.children.first(where: { $0.key == key }) else { return nil }
            node = next
        }
        return node
    }
}

extension ContentNode {
    /// An indented text rendering — the Text mode of a tree that has no source text of its own (a binary
    /// property list, an archive), and what the CLI prints.
    public func outline(indent: String = "  ") -> String {
        var lines: [String] = []
        appendOutline(to: &lines, depth: 0, indent: indent)
        return lines.joined(separator: "\n")
    }

    private func appendOutline(to lines: inout [String], depth: Int, indent: String) {
        var line = String(repeating: indent, count: depth)
        if let key { line += "\(key): " }
        line += headline
        lines.append(line)
        for child in children { child.appendOutline(to: &lines, depth: depth + 1, indent: indent) }
    }

    /// The node on one line, without its key.
    public var headline: String {
        let name = className.map { "\($0) " } ?? ""
        switch kind {
        case .dictionary, .array, .set, .object:
            let summary = value ?? "\(children.count) item\(children.count == 1 ? "" : "s")"
            return kind == .object ? "\(name)— \(summary)" : "\(name)\(kind.rawValue) — \(summary)"
        case .string:
            return "\(name)\"\(value ?? "")\""
        case .null:
            return "\(name)null"
        case .reference:
            return "↩ \(value ?? "")"
        case .truncated:
            return "… \(value ?? "")"
        case .number, .bool, .date, .data, .uid:
            return "\(name)\(value ?? "")"
        }
    }
}

/// Counts down the nodes a tree may still have. A property list can name the same array from a thousand places
/// (it is a graph; the tree repeats it), so the size of the input says nothing about the size of the tree.
struct NodeBudget {
    private(set) var remaining: Int

    init(_ limit: Int) { remaining = max(1, limit) }

    /// `false` once the budget is spent; the caller then adds a `.truncated` node and stops.
    mutating func take() -> Bool {
        guard remaining > 0 else { return false }
        remaining -= 1
        return true
    }

    static func truncated(key: String?, what: String = "more than the viewer's limit") -> ContentNode {
        ContentNode(key: key, kind: .truncated, value: what)
    }
}
