import DabbiBase
import Foundation

/// JSON as the viewer wants it: keys in the order they were written, numbers as they were written.
///
/// `JSONSerialization` would give neither — dictionaries lose their order and `12345678901234567890.5` its
/// digits — and a viewer that re-orders and rounds what it shows is showing something else. RFC 8259, strictly.
struct JSONTreeParser {
    private let bytes: [UInt8]
    private var position = 0
    private var budget: NodeBudget
    private let maxDepth: Int

    static func parse(_ text: String, limits: DecodeLimits) throws -> ContentNode {
        var parser = JSONTreeParser(bytes: Array(text.utf8), limits: limits)
        parser.skipWhiteSpace()
        let node = try parser.value(key: nil, depth: 0)
        parser.skipWhiteSpace()
        guard parser.position == parser.bytes.count else { throw parser.error("Something follows the document.") }
        return node
    }

    private init(bytes: [UInt8], limits: DecodeLimits) {
        self.bytes = bytes
        budget = NodeBudget(limits.maxNodes)
        maxDepth = limits.maxTreeDepth
    }

    // MARK: Grammar

    private mutating func value(key: String?, depth: Int) throws -> ContentNode {
        guard budget.take() else { throw limitExceeded("The JSON has more values than the viewer shows as a tree.") }
        guard let byte = peek else { throw error("It ends where a value should be.") }
        switch byte {
        case UInt8(ascii: "{"):
            return ContentNode(key: key, kind: .dictionary, children: try members(depth: depth))
        case UInt8(ascii: "["):
            return ContentNode(key: key, kind: .array, children: try elements(depth: depth))
        case UInt8(ascii: "\""):
            return ContentNode(key: key, kind: .string, value: try string())
        case UInt8(ascii: "t"):
            try literal("true")
            return ContentNode(key: key, kind: .bool, value: "true")
        case UInt8(ascii: "f"):
            try literal("false")
            return ContentNode(key: key, kind: .bool, value: "false")
        case UInt8(ascii: "n"):
            try literal("null")
            return ContentNode(key: key, kind: .null)
        default:
            return ContentNode(key: key, kind: .number, value: try number())
        }
    }

    private mutating func members(depth: Int) throws -> [ContentNode] {
        guard depth < maxDepth else { throw limitExceeded("The JSON nests deeper than \(maxDepth) levels.") }
        position += 1
        var nodes: [ContentNode] = []
        skipWhiteSpace()
        if peek == UInt8(ascii: "}") {
            position += 1
            return nodes
        }
        while true {
            skipWhiteSpace()
            guard peek == UInt8(ascii: "\"") else { throw error("An object key must be a string.") }
            let key = try string()
            skipWhiteSpace()
            guard peek == UInt8(ascii: ":") else { throw error("A colon must follow an object key.") }
            position += 1
            skipWhiteSpace()
            nodes.append(try value(key: key, depth: depth + 1))
            skipWhiteSpace()
            switch peek {
            case UInt8(ascii: ","): position += 1
            case UInt8(ascii: "}"):
                position += 1
                return nodes
            default: throw error("An object continues with “,” or ends with “}”.")
            }
        }
    }

    private mutating func elements(depth: Int) throws -> [ContentNode] {
        guard depth < maxDepth else { throw limitExceeded("The JSON nests deeper than \(maxDepth) levels.") }
        position += 1
        var nodes: [ContentNode] = []
        skipWhiteSpace()
        if peek == UInt8(ascii: "]") {
            position += 1
            return nodes
        }
        while true {
            skipWhiteSpace()
            nodes.append(try value(key: "[\(nodes.count)]", depth: depth + 1))
            skipWhiteSpace()
            switch peek {
            case UInt8(ascii: ","): position += 1
            case UInt8(ascii: "]"):
                position += 1
                return nodes
            default: throw error("An array continues with “,” or ends with “]”.")
            }
        }
    }

    private mutating func literal(_ word: String) throws {
        guard bytes[position...].starts(with: word.utf8) else { throw error("An unknown word.") }
        position += word.utf8.count
    }

    /// The number's own text, checked against the grammar: `-? (0 | [1-9][0-9]*) (.[0-9]+)? ([eE][+-]?[0-9]+)?`.
    private mutating func number() throws -> String {
        let start = position
        func digits(_ parser: inout JSONTreeParser) -> Int {
            let from = parser.position
            while let byte = parser.peek, (UInt8(ascii: "0")...UInt8(ascii: "9")).contains(byte) {
                parser.position += 1
            }
            return parser.position - from
        }
        if peek == UInt8(ascii: "-") { position += 1 }
        if peek == UInt8(ascii: "0") {
            position += 1
        } else if digits(&self) == 0 {
            throw error("This is not a JSON value.")
        }
        if peek == UInt8(ascii: ".") {
            position += 1
            guard digits(&self) > 0 else { throw error("Digits must follow a decimal point.") }
        }
        if peek == UInt8(ascii: "e") || peek == UInt8(ascii: "E") {
            position += 1
            if peek == UInt8(ascii: "+") || peek == UInt8(ascii: "-") { position += 1 }
            guard digits(&self) > 0 else { throw error("Digits must follow an exponent.") }
        }
        return String(decoding: bytes[start..<position], as: UTF8.self)
    }

    private mutating func string() throws -> String {
        position += 1
        var scalars = String.UnicodeScalarView()
        var run = position
        func flush(_ parser: JSONTreeParser, to end: Int) {
            scalars.append(contentsOf: String(decoding: parser.bytes[run..<end], as: UTF8.self).unicodeScalars)
        }
        while true {
            guard let byte = peek else { throw error("A string is not closed.") }
            switch byte {
            case UInt8(ascii: "\""):
                flush(self, to: position)
                position += 1
                return String(scalars)
            case UInt8(ascii: "\\"):
                flush(self, to: position)
                position += 1
                scalars.append(try escape())
                run = position
            case 0..<0x20:
                throw error("A control character inside a string must be escaped.")
            default:
                position += 1
            }
        }
    }

    private mutating func escape() throws -> Unicode.Scalar {
        guard let byte = peek else { throw error("A string is not closed.") }
        position += 1
        switch byte {
        case UInt8(ascii: "\""): return "\""
        case UInt8(ascii: "\\"): return "\\"
        case UInt8(ascii: "/"): return "/"
        case UInt8(ascii: "b"): return "\u{08}"
        case UInt8(ascii: "f"): return "\u{0C}"
        case UInt8(ascii: "n"): return "\n"
        case UInt8(ascii: "r"): return "\r"
        case UInt8(ascii: "t"): return "\t"
        case UInt8(ascii: "u"):
            let unit = try hexUnit()
            // A high surrogate needs its low one right behind it; alone, either is U+FFFD.
            if (0xD800...0xDBFF).contains(unit),
                bytes[position...].starts(with: [UInt8(ascii: "\\"), UInt8(ascii: "u")])
            {
                let mark = position
                position += 2
                let low = try hexUnit()
                if (0xDC00...0xDFFF).contains(low) {
                    return Unicode.Scalar(0x10000 + ((unit - 0xD800) << 10) + (low - 0xDC00)) ?? "\u{FFFD}"
                }
                position = mark
            }
            return Unicode.Scalar(unit) ?? "\u{FFFD}"
        default:
            throw error("An unknown escape in a string.")
        }
    }

    private mutating func hexUnit() throws -> UInt32 {
        guard position + 4 <= bytes.count,
            let unit = UInt32(String(decoding: bytes[position..<position + 4], as: UTF8.self), radix: 16)
        else { throw error("Four hexadecimal digits must follow \\u.") }
        position += 4
        return unit
    }

    // MARK: Bytes

    private var peek: UInt8? { position < bytes.count ? bytes[position] : nil }

    private mutating func skipWhiteSpace() {
        while let byte = peek, byte == 0x20 || byte == 0x0A || byte == 0x0D || byte == 0x09 { position += 1 }
    }

    private func error(_ detail: String) -> DabbiError {
        let line = bytes[..<min(position, bytes.count)].reduce(1) { $1 == 0x0A ? $0 + 1 : $0 }
        return malformed("JSON document", "Line \(line): \(detail)")
    }
}

/// Pretty-prints a JSON tree: two spaces, one member per line, nothing re-ordered or re-formatted.
enum JSONPrettyPrinter {
    static func print(_ node: ContentNode) -> String {
        var output = ""
        write(node, to: &output, indent: 0)
        return output
    }

    private static func write(_ node: ContentNode, to output: inout String, indent: Int) {
        switch node.kind {
        case .dictionary, .array:
            let (opening, closing) = node.kind == .dictionary ? ("{", "}") : ("[", "]")
            guard !node.children.isEmpty else { return output += opening + closing }
            let padding = String(repeating: "  ", count: indent + 1)
            output += opening + "\n"
            for (position, child) in node.children.enumerated() {
                output += padding
                if node.kind == .dictionary { output += quote(child.key ?? "") + ": " }
                write(child, to: &output, indent: indent + 1)
                output += position == node.children.count - 1 ? "\n" : ",\n"
            }
            output += String(repeating: "  ", count: indent) + closing
        case .string:
            output += quote(node.value ?? "")
        case .null:
            output += "null"
        default:
            output += node.value ?? "null"
        }
    }

    static func quote(_ text: String) -> String {
        var quoted = "\""
        for scalar in text.unicodeScalars {
            switch scalar {
            case "\"": quoted += "\\\""
            case "\\": quoted += "\\\\"
            case "\n": quoted += "\\n"
            case "\r": quoted += "\\r"
            case "\t": quoted += "\\t"
            case _ where scalar.value < 0x20:
                quoted += "\\u" + String(scalar.value, radix: 16).leftPadded(to: 4)
            default: quoted.unicodeScalars.append(scalar)
            }
        }
        return quoted + "\""
    }
}
