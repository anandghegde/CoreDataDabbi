import DabbiBase
import Foundation

/// Turns a property list's object table into the viewer's tree.
///
/// The table is a graph and the tree is not, so this is where it gets bounded: an object already open further
/// up becomes a `.reference`, and when the node budget is spent the rest becomes one `.truncated` node. A
/// reference that leads nowhere costs its own node an error note, not the whole tree.
///
/// An archive (`$archiver`, `$objects`, `$top`) is handed to `KeyedArchiveTreeBuilder`, and so is an archive or
/// property list found inside a data value — transformables are often archives of archives.
final class PlistTreeBuilder {
    /// How many property lists inside data values are opened, one inside the other.
    static let maxNesting = 3

    let limits: DecodeLimits
    var budget: NodeBudget
    private let nesting: Int
    /// How deep in an enclosing tree this one starts. The depth limit is about the stack, and a property list
    /// inside a data value is built on the same one.
    let baseDepth: Int

    init(limits: DecodeLimits, budget: NodeBudget? = nil, nesting: Int = 0, baseDepth: Int = 0) {
        self.limits = limits
        self.budget = budget ?? NodeBudget(limits.maxNodes)
        self.nesting = nesting
        self.baseDepth = baseDepth
    }

    /// The tree of `source`, and whether it turned out to be an archive.
    func build(_ source: any PlistSource, key: String? = nil) throws -> (node: ContentNode, isArchive: Bool) {
        if let archive = try KeyedArchiveTreeBuilder(source: source, trees: self) {
            return (try archive.build(key: key), true)
        }
        var open: Set<Int> = []
        _ = budget.take()
        return (try node(at: source.top, in: source, key: key, depth: baseDepth, open: &open), false)
    }

    // MARK: Plain property lists

    func node(
        at index: Int, in source: any PlistSource, key: String?, depth: Int, open: inout Set<Int>
    ) throws -> ContentNode {
        let object = try source.object(at: index)
        let references: [(key: String, index: Int)]
        let kind: ContentNode.Kind
        switch object {
        case .array(let items):
            (kind, references) = (.array, items.enumerated().map { ("[\($0)]", $1) })
        case .set(let items):
            (kind, references) = (.set, items.enumerated().map { ("[\($0)]", $1) })
        case .dictionary(let keys, let values):
            (kind, references) = (
                .dictionary, try source.entries(keys: keys, values: values).map { ($0.key, $0.value) }
            )
        default:
            return leaf(object, key: key, depth: depth)
        }

        guard depth < limits.maxTreeDepth else { return NodeBudget.truncated(key: key, what: "nested too deeply") }
        guard open.insert(index).inserted else {
            return ContentNode(key: key, kind: .reference, value: "the \(kind.rawValue) this one is inside")
        }
        defer { open.remove(index) }
        let children = try children(references) { key, index in
            try node(at: index, in: source, key: key, depth: depth + 1, open: &open)
        }
        return ContentNode(key: key, kind: kind, children: children)
    }

    /// Builds one child per reference until the budget runs out. A child that cannot be read is said so in its
    /// place; running out of a limit ends the whole tree, because everything after would fail the same way.
    func children(
        _ references: [(key: String, index: Int)], make: (String, Int) throws -> ContentNode
    ) throws -> [ContentNode] {
        var nodes: [ContentNode] = []
        nodes.reserveCapacity(min(references.count, budget.remaining))
        for (key, index) in references {
            guard budget.take() else {
                nodes.append(NodeBudget.truncated(key: nil))
                break
            }
            do {
                nodes.append(try make(key, index))
            } catch let error as DabbiError where error.code != .limitExceeded {
                nodes.append(NodeBudget.truncated(key: key, what: error.diagnosis.first ?? error.message))
            }
        }
        return nodes
    }

    // MARK: Leaves

    func leaf(_ object: PlistObject, key: String?, className: String? = nil, depth: Int) -> ContentNode {
        switch object {
        case .null: ContentNode(key: key, kind: .null, className: className)
        case .bool(let value): ContentNode(key: key, kind: .bool, className: className, value: String(value))
        case .int(let value): ContentNode(key: key, kind: .number, className: className, value: String(value))
        case .bigInt(let text): ContentNode(key: key, kind: .number, className: className, value: text)
        case .real(let value): ContentNode(key: key, kind: .number, className: className, value: "\(value)")
        case .string(let value): ContentNode(key: key, kind: .string, className: className, value: value)
        case .uid(let value): ContentNode(key: key, kind: .uid, className: className, value: "UID \(value)")
        case .date(let value):
            ContentNode(key: key, kind: .date, className: className, value: Self.describe(value))
        case .data(let value): dataNode(value, key: key, className: className, depth: depth)
        case .array, .set, .dictionary:
            // Containers are the callers' business; they never get here.
            ContentNode(key: key, kind: .truncated, value: "a container")
        }
    }

    /// A data value, opened when it is itself a property list or an archive.
    func dataNode(_ data: Data, key: String?, className: String? = nil, depth: Int) -> ContentNode {
        var node = ContentNode(key: key, kind: .data, className: className, value: Self.describe(data))
        guard nesting < Self.maxNesting, depth + 1 < limits.maxTreeDepth, data.starts(with: BinaryPlist.magic),
            budget.remaining > 1,
            let source = try? BinaryPlist(data)
        else { return node }

        let nested = PlistTreeBuilder(limits: limits, budget: budget, nesting: nesting + 1, baseDepth: depth + 1)
        let built = try? nested.build(source, key: "contents")
        budget = nested.budget
        if let built {
            node.value = (built.isArchive ? "archive, " : "property list, ") + (node.value ?? "")
            node.children = [built.node]
        }
        return node
    }

    static func describe(_ data: Data) -> String {
        let size = "\(data.count) byte\(data.count == 1 ? "" : "s")"
        guard !data.isEmpty else { return size }
        let head = data.prefix(16).map { String($0, radix: 16).leftPadded(to: 2) }.joined(separator: " ")
        return "\(size) · \(head)\(data.count > 16 ? " …" : "")"
    }

    static func describe(_ date: Date) -> String {
        let seconds = date.timeIntervalSinceReferenceDate
        // Year 1 to year 9999. A date made of arbitrary bits must not reach the formatter.
        guard seconds.isFinite, (-63_114_076_800...252_423_993_600).contains(seconds) else {
            return "\(seconds) s from 2001-01-01"
        }
        return date.formatted(Date.ISO8601FormatStyle(includingFractionalSeconds: true, timeZone: .gmt))
    }
}

extension String {
    func leftPadded(to length: Int, with pad: Character = "0") -> String {
        String(repeating: pad, count: max(0, length - count)) + self
    }
}
