import DabbiBase
import Foundation

/// Shows an `NSKeyedArchiver` archive as a tree of objects — without the app's classes, and without
/// instantiating any class at all (CNT-4, ADR-08).
///
/// An archive is a property list: `$objects` is a flat table, `$top` names the root, and every reference is a
/// UID, an index into the table. An archived object is a dictionary whose `$class` leads to `$classname` and
/// the superclass chain `$classes`; its other keys are what the class's `encode(with:)` wrote. That is all read
/// as data. Foundation's collections and a few value classes are recognised by name and shown as what they
/// mean (`NSMutableArray` → an array); everything else is its class name and its fields.
final class KeyedArchiveTreeBuilder {
    private typealias Entry = (key: String, value: Int)

    private let source: any PlistSource
    private let trees: PlistTreeBuilder
    /// `$objects`: property-list indices, by UID.
    private let objects: [Int]
    private let topEntries: [Entry]
    /// Property-list indices of the containers open on the way down — the cycle guard.
    private var open: Set<Int> = []

    /// `nil` when `source` is not an archive.
    init?(source: any PlistSource, trees: PlistTreeBuilder) throws {
        guard case .dictionary(let keys, let values) = try source.object(at: source.top),
            let entries = try? source.entries(keys: keys, values: values)
        else { return nil }
        func entry(_ key: String) -> PlistObject? {
            entries.first { $0.key == key }.flatMap { try? source.object(at: $0.value) }
        }
        guard case .string? = entry("$archiver"), case .array(let objects)? = entry("$objects"),
            case .dictionary(let topKeys, let topValues)? = entry("$top"),
            let topEntries = try? source.entries(keys: topKeys, values: topValues)
        else { return nil }
        self.source = source
        self.trees = trees
        self.objects = objects
        self.topEntries = topEntries
    }

    func build(key: String?) throws -> ContentNode {
        _ = trees.budget.take()
        // Nearly every archive has the one top-level key “root”; a level saying so would only be in the way.
        let depth = trees.baseDepth
        if topEntries.count == 1 { return try value(at: topEntries[0].value, key: key, depth: depth) }
        return ContentNode(key: key, kind: .dictionary, children: try children(topEntries, depth: depth))
    }

    // MARK: Values

    /// Whatever sits at a property-list index: a UID to follow, a container written inline, or a leaf.
    private func value(at index: Int, key: String?, depth: Int) throws -> ContentNode {
        let object = try source.object(at: index)
        switch object {
        case .uid(let uid):
            return try archived(uid, key: key, depth: depth)
        case .array(let items), .set(let items):
            let kind: ContentNode.Kind = if case .set = object { .set } else { .array }
            return try plainContainer(index, key: key, depth: depth, kind: kind) {
                try self.children(items.enumerated().map { ("[\($0)]", $1) }, depth: depth)
            }
        case .dictionary(let keys, let values):
            let entries = try source.entries(keys: keys, values: values)
            return try plainContainer(index, key: key, depth: depth, kind: .dictionary) {
                try self.children(entries, depth: depth)
            }
        default:
            return trees.leaf(object, key: key, depth: depth)
        }
    }

    private func archived(_ uid: UInt64, key: String?, depth: Int) throws -> ContentNode {
        guard uid < UInt64(objects.count) else {
            return NodeBudget.truncated(key: key, what: "UID \(uid) is not in the archive")
        }
        let index = objects[Int(uid)]
        let object = try source.object(at: index)
        if uid == 0, case .string("$null") = object { return ContentNode(key: key, kind: .null) }
        // A UID in `$objects` would be a reference to a reference; followed, a hostile one never ends.
        if case .uid = object { return trees.leaf(object, key: key, depth: depth) }
        guard case .dictionary(let keys, let values) = object else {
            return try value(at: index, key: key, depth: depth)
        }
        let entries = try source.entries(keys: keys, values: values)
        guard let classReference = entries.first(where: { $0.key == "$class" }) else {
            return try value(at: index, key: key, depth: depth)
        }

        let classes = classChain(classReference.value)
        let fields = entries.filter { $0.key != "$class" }
        return try container(
            index, key: key, depth: depth, kind: .object, referenceName: "\(classes.first ?? "object") #\(uid)"
        ) {
            if let node = try self.friendly(classes, fields: fields, key: key, depth: depth) { return node }
            return ContentNode(
                key: key, kind: .object, className: classes.first,
                children: try self.children(fields, depth: depth))
        }
    }

    /// Runs `make` with `index` marked open, unless it already is, or the tree is as deep as it may get.
    private func container(
        _ index: Int, key: String?, depth: Int, kind: ContentNode.Kind, referenceName: String? = nil,
        make: () throws -> ContentNode
    ) throws -> ContentNode {
        guard depth < trees.limits.maxTreeDepth else {
            return NodeBudget.truncated(key: key, what: "nested too deeply")
        }
        guard open.insert(index).inserted else {
            return ContentNode(
                key: key, kind: .reference, value: referenceName ?? "the \(kind.rawValue) this one is inside")
        }
        defer { open.remove(index) }
        return try make()
    }

    private func plainContainer(
        _ index: Int, key: String?, depth: Int, kind: ContentNode.Kind, children: () throws -> [ContentNode]
    ) throws -> ContentNode {
        try container(index, key: key, depth: depth, kind: kind, referenceName: nil) {
            ContentNode(key: key, kind: kind, children: try children())
        }
    }

    private func children(_ entries: [Entry], depth: Int) throws -> [ContentNode] {
        try trees.children(entries.map { ($0.key, $0.value) }) { key, index in
            try self.value(at: index, key: key, depth: depth + 1)
        }
    }

    // MARK: Classes

    /// `$classname`, then the rest of `$classes`: most specific first.
    private func classChain(_ reference: Int) -> [String] {
        guard case .uid(let uid)? = try? source.object(at: reference), uid < UInt64(objects.count),
            case .dictionary(let keys, let values)? = try? source.object(at: objects[Int(uid)]),
            let entries = try? source.entries(keys: keys, values: values)
        else { return [] }

        var names: [String] = []
        if let name = entries.first(where: { $0.key == "$classname" }), let text = string(at: name.value) {
            names.append(text)
        }
        if let list = entries.first(where: { $0.key == "$classes" }),
            case .array(let items)? = try? source.object(at: list.value)
        {
            for item in items.prefix(32) {
                if let text = string(at: item), !names.contains(text) { names.append(text) }
            }
        }
        return names
    }

    /// The rendering of the first class in the chain that has one; `nil` = show the fields.
    private func friendly(_ classes: [String], fields: [Entry], key: String?, depth: Int) throws -> ContentNode? {
        let name = classes.first
        func field(_ key: String) -> Int? { fields.first { $0.key == key }?.value }
        func items(_ key: String) -> [Int]? {
            guard let index = field(key), case .array(let items)? = try? source.object(at: index) else { return nil }
            return items
        }
        func leaf(_ object: PlistObject) -> ContentNode {
            trees.leaf(object, key: key, className: name, depth: depth)
        }

        for candidate in classes {
            switch candidate {
            case "NSArray", "NSMutableArray", "NSSet", "NSMutableSet", "NSCountedSet":
                guard let items = items("NS.objects") else { return nil }
                return ContentNode(
                    key: key, kind: candidate.hasSuffix("Set") ? .set : .array, className: name,
                    children: try children(items.enumerated().map { ("[\($0)]", $1) }, depth: depth))

            case "NSOrderedSet", "NSMutableOrderedSet":
                // One key per element: NS.object.0, NS.object.1, …
                let numbered = fields.compactMap { entry -> (Int, Int)? in
                    guard entry.key.hasPrefix("NS.object."), let position = Int(entry.key.dropFirst(10)) else {
                        return nil
                    }
                    return (position, entry.value)
                }
                guard numbered.count == fields.count else { return nil }
                return ContentNode(
                    key: key, kind: .array, className: name,
                    children: try children(numbered.sorted { $0.0 < $1.0 }.map { ("[\($0.0)]", $0.1) }, depth: depth))

            case "NSDictionary", "NSMutableDictionary":
                guard let keys = items("NS.keys"), let values = items("NS.objects"), keys.count == values.count
                else { return nil }
                return ContentNode(
                    key: key, kind: .dictionary, className: name,
                    children: try dictionaryChildren(keys: keys, values: values, depth: depth))

            case "NSString", "NSMutableString":
                guard let index = field("NS.string") ?? field("NS.bytes"), let text = string(at: index) else {
                    return nil
                }
                return leaf(.string(text))

            case "NSDate":
                guard let seconds = field("NS.time").flatMap(number) else { return nil }
                return leaf(.date(Date(timeIntervalSinceReferenceDate: seconds)))

            case "NSURL":
                guard let relative = field("NS.relative").flatMap(string) else { return nil }
                let base = field("NS.base").flatMap(string)
                return leaf(.string(base.map { "\(relative) (relative to \($0))" } ?? relative))

            case "NSUUID":
                guard let index = field("NS.uuidbytes"), case .data(let bytes)? = resolved(index), bytes.count == 16
                else { return nil }
                let uuid = bytes.withUnsafeBytes { UUID(uuid: $0.loadUnaligned(as: uuid_t.self)) }
                return leaf(.string(uuid.uuidString))

            case "NSData", "NSMutableData":
                guard let index = field("NS.data") ?? field("NS.bytes"), case .data(let bytes)? = resolved(index)
                else { return nil }
                return trees.dataNode(bytes, key: key, className: name, depth: depth)

            case "NSNull":
                return ContentNode(key: key, kind: .null, className: name)

            case "NSAttributedString", "NSMutableAttributedString":
                guard let text = field("NSString").flatMap(string) else { return nil }
                return ContentNode(
                    key: key, kind: .object, className: name, value: Self.quoted(text),
                    children: try children(fields, depth: depth))

            case "NSColor", "UIColor":
                guard let summary = colour(field: field) else { return nil }
                return ContentNode(
                    key: key, kind: .object, className: name, value: summary,
                    children: try children(fields, depth: depth))

            default:
                continue
            }
        }
        return nil
    }

    /// String and number keys label their values. Anything else — an archived object as a key — gets a numbered
    /// pair of `key` and `value`.
    private func dictionaryChildren(keys: [Int], values: [Int], depth: Int) throws -> [ContentNode] {
        var complexKeys: [String: Int] = [:]
        let references = zip(keys, values).enumerated().map { position, pair -> (String, Int) in
            switch resolved(pair.0) {
            case .string(let text)?: return (text, pair.1)
            case .int(let number)?: return (String(number), pair.1)
            default:
                complexKeys["[\(position)]"] = pair.0
                return ("[\(position)]", pair.1)
            }
        }
        return try trees.children(references) { label, index in
            guard let keyIndex = complexKeys[label] else {
                return try self.value(at: index, key: label, depth: depth + 1)
            }
            return ContentNode(
                key: label, kind: .dictionary, value: "key and value",
                children: [
                    try self.value(at: keyIndex, key: "key", depth: depth + 2),
                    try self.value(at: index, key: "value", depth: depth + 2),
                ])
        }
    }

    // MARK: Reading fields

    /// The object at `index`, one UID followed.
    private func resolved(_ index: Int) -> PlistObject? {
        guard let object = try? source.object(at: index) else { return nil }
        guard case .uid(let uid) = object else { return object }
        guard uid < UInt64(objects.count), let target = try? source.object(at: objects[Int(uid)]) else { return nil }
        // UID 0 is the archiver's nil: an `NSURL` without a base has it for one.
        if uid == 0, case .string("$null") = target { return .null }
        return target
    }

    /// The string at `index`: written inline, behind a UID, as UTF-8 data, or as an archived object that is
    /// one — an `NSMutableString`, or the `NSURL` another URL is relative to.
    private func string(at index: Int) -> String? {
        switch resolved(index) {
        case .string(let text)?:
            return text
        case .data(let bytes)?:
            return String(data: bytes, encoding: .utf8)
        case .dictionary(let keys, let values)?:
            guard let entries = try? source.entries(keys: keys, values: values),
                let inner = entries.first(where: { $0.key == "NS.string" || $0.key == "NS.relative" }),
                case .string(let text)? = resolved(inner.value)
            else { return nil }
            return text
        default:
            return nil
        }
    }

    private func number(at index: Int) -> Double? {
        switch resolved(index) {
        case .real(let value)?: value
        case .int(let value)?: Double(value)
        default: nil
        }
    }

    // MARK: Colours

    /// `UIColor` writes `UIRed`… or `UIWhite` as numbers; `NSColor`, and `UIColor` too for compatibility, write
    /// `NSRGB` or `NSWhite` as ASCII text: “0.5 0.25 1 0.8”. Catalogue colours have a name instead.
    ///
    /// A colour in a colour space of its own (sRGB, Display P3) also has `NSComponents`, and those are the
    /// numbers the app set: `NSRGB` is then the same colour converted to the generic space for old readers —
    /// sRGB (1, 0.5, 0) reads (0.989, 0.415, 0.032) there, which nobody would recognise.
    private func colour(field: (String) -> Int?) -> String? {
        func components(_ key: String) -> [Double]? {
            guard let index = field(key), case .data(let bytes)? = resolved(index), bytes.count < 256 else {
                return nil
            }
            let numbers = String(decoding: bytes, as: UTF8.self)
                .split(whereSeparator: { $0 == " " || $0 == "\0" }).map { Double($0) }
            return numbers.contains(nil) || numbers.isEmpty ? nil : numbers.compactMap { $0 }
        }
        if let red = field("UIRed").flatMap(number), let green = field("UIGreen").flatMap(number),
            let blue = field("UIBlue").flatMap(number)
        {
            return Self.describeColour(red, green, blue, field("UIAlpha").flatMap(number) ?? 1)
        }
        if let own = components("NSComponents") {
            switch own.count {
            case 4: return Self.describeColour(own[0], own[1], own[2], own[3])
            case 2: return Self.describeColour(own[0], own[0], own[0], own[1])
            default: break
            }
        }
        if let rgb = components("NSRGB"), rgb.count >= 3 {
            return Self.describeColour(rgb[0], rgb[1], rgb[2], rgb.count > 3 ? rgb[3] : 1)
        }
        if let white = field("UIWhite").flatMap(number) {
            return Self.describeColour(white, white, white, field("UIAlpha").flatMap(number) ?? 1)
        }
        if let white = components("NSWhite") {
            return Self.describeColour(white[0], white[0], white[0], white.count > 1 ? white[1] : 1)
        }
        if let colourName = field("NSColorName").flatMap(string) {
            return [field("NSCatalogName").flatMap(string), colourName].compactMap { $0 }.joined(separator: " / ")
        }
        return nil
    }

    static func describeColour(_ red: Double, _ green: Double, _ blue: Double, _ alpha: Double) -> String {
        func text(_ value: Double) -> String { "\((value * 1000).rounded() / 1000)" }
        func hex(_ value: Double) -> String {
            let clamped = value.isFinite ? min(max(value, 0), 1) : 0
            return String(Int((clamped * 255).rounded()), radix: 16, uppercase: true).leftPadded(to: 2)
        }
        let rgba = [red, green, blue, alpha].map(text).joined(separator: ", ")
        return "rgba(\(rgba)) · #\(hex(red))\(hex(green))\(hex(blue))\(alpha == 1 ? "" : hex(alpha))"
    }

    static func quoted(_ text: String, limit: Int = 200) -> String {
        let flat = text.prefix(limit).replacingOccurrences(of: "\n", with: "⏎")
        return "“\(flat)\(text.count > limit ? "…" : "")”"
    }
}
