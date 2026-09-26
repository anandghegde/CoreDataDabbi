import DabbiBase
import Foundation

/// A JSON value that keeps what `JSONSerialization` loses: the order of an object's keys, and a number's digits.
///
/// Exports are read by people, and diffed: `$id` and `$entity` come first and the properties follow in the model's
/// order. A Decimal attribute holds more digits than a `Double` does, so a number is kept as the text it was
/// written with, and only the attribute it is imported into decides what it means.
public indirect enum JSONNode: Sendable, Hashable {
    case null
    case bool(Bool)
    /// The number as JSON writes it.
    case number(String)
    case string(String)
    case array([JSONNode])
    /// Members in order. A key that appears twice keeps its first value when read (`subscript`).
    case object([(key: String, value: JSONNode)])

    public static func == (lhs: JSONNode, rhs: JSONNode) -> Bool {
        switch (lhs, rhs) {
        case (.null, .null): true
        case (.bool(let a), .bool(let b)): a == b
        case (.number(let a), .number(let b)): a == b
        case (.string(let a), .string(let b)): a == b
        case (.array(let a), .array(let b)): a == b
        case (.object(let a), .object(let b)): a.map(\.key) == b.map(\.key) && a.map(\.value) == b.map(\.value)
        default: false
        }
    }

    public func hash(into hasher: inout Hasher) {
        switch self {
        case .null: hasher.combine(0)
        case .bool(let value): hasher.combine(value)
        case .number(let value): hasher.combine(value)
        case .string(let value): hasher.combine(value)
        case .array(let values): hasher.combine(values)
        case .object(let members):
            for member in members {
                hasher.combine(member.key)
                hasher.combine(member.value)
            }
        }
    }

    /// An object member by key.
    public subscript(key: String) -> JSONNode? {
        guard case .object(let members) = self else { return nil }
        return members.first { $0.key == key }?.value
    }

    public var stringValue: String? {
        if case .string(let string) = self { return string }
        return nil
    }

    /// The text an attribute of any scalar type is read from: a string's own, a number's digits, `true` or
    /// `false`; `nil` for JSON's null and for arrays and objects, which are not text.
    public var scalarText: String? {
        switch self {
        case .string(let string): string
        case .number(let digits): digits
        case .bool(let flag): flag ? "true" : "false"
        case .null, .array, .object: nil
        }
    }
}

// MARK: Writing

extension JSONNode {
    /// The value as JSON text. `indent` spaces per level; 0 writes it on one line, as a record of JSON Lines is.
    public func text(indent: Int = 2) -> String {
        var output = ""
        write(to: &output, indent: indent, level: 0)
        return output
    }

    func write(to output: inout String, indent: Int, level: Int) {
        switch self {
        case .null: output += "null"
        case .bool(let flag): output += flag ? "true" : "false"
        case .number(let digits): output += digits
        case .string(let string): Self.writeString(string, to: &output)
        case .array(let values):
            guard !values.isEmpty else { return output += "[]" }
            output += "["
            for (index, value) in values.enumerated() {
                if index > 0 { output += "," }
                Self.newline(&output, indent: indent, level: level + 1)
                value.write(to: &output, indent: indent, level: level + 1)
            }
            Self.newline(&output, indent: indent, level: level)
            output += "]"
        case .object(let members):
            guard !members.isEmpty else { return output += "{}" }
            output += "{"
            for (index, member) in members.enumerated() {
                if index > 0 { output += "," }
                Self.newline(&output, indent: indent, level: level + 1)
                Self.writeString(member.key, to: &output)
                output += indent > 0 ? ": " : ":"
                member.value.write(to: &output, indent: indent, level: level + 1)
            }
            Self.newline(&output, indent: indent, level: level)
            output += "}"
        }
    }

    private static func newline(_ output: inout String, indent: Int, level: Int) {
        guard indent > 0 else { return }
        output += "\n" + String(repeating: " ", count: indent * level)
    }

    /// RFC 8259: the quote, the backslash and control characters escaped; everything else as it is, in UTF-8.
    static func writeString(_ string: String, to output: inout String) {
        output += "\""
        for scalar in string.unicodeScalars {
            switch scalar {
            case "\"": output += "\\\""
            case "\\": output += "\\\\"
            case "\n": output += "\\n"
            case "\r": output += "\\r"
            case "\t": output += "\\t"
            case "\u{08}": output += "\\b"
            case "\u{0C}": output += "\\f"
            case let control where control.value < 0x20:
                output += String(format: "\\u%04x", control.value)
            default: output.unicodeScalars.append(scalar)
            }
        }
        output += "\""
    }
}

// MARK: Reading

extension JSONNode {
    /// Parses JSON text: one value, with nothing but white space around it.
    ///
    /// Throws `.invalidValue` saying where the text stopped being JSON — a line and a column, never what was
    /// there (privacy).
    public static func parse(_ text: String) throws -> JSONNode {
        var parser = Parser(scalars: Array(text.unicodeScalars))
        parser.skipSpace()
        let value = try parser.value(depth: 0)
        parser.skipSpace()
        guard parser.isAtEnd else { throw parser.error("There is more after the end of the JSON value.") }
        return value
    }

    private struct Parser {
        let scalars: [Unicode.Scalar]
        var position = 0

        /// Deeper than this is not an export, and would take the stack with it: a test or a task runs on a small one.
        static let maximumDepth = 100

        var isAtEnd: Bool { position >= scalars.count }
        var current: Unicode.Scalar? { isAtEnd ? nil : scalars[position] }

        mutating func skipSpace() {
            while let scalar = current, scalar == " " || scalar == "\n" || scalar == "\r" || scalar == "\t" {
                position += 1
            }
        }

        func error(_ message: String) -> DabbiError {
            var line = 1
            var column = 1
            for scalar in scalars[..<min(position, scalars.count)] {
                if scalar == "\n" {
                    line += 1
                    column = 1
                } else {
                    column += 1
                }
            }
            return DabbiError(
                .invalidValue, "The file is not valid JSON: \(message)",
                arguments: ["line": String(line), "column": String(column)],
                diagnosis: ["The problem is at line \(line), column \(column)."])
        }

        mutating func expect(_ literal: String, _ value: JSONNode) throws -> JSONNode {
            for scalar in literal.unicodeScalars {
                guard current == scalar else { throw error("An unexpected word.") }
                position += 1
            }
            return value
        }

        mutating func value(depth: Int) throws -> JSONNode {
            guard depth < Self.maximumDepth else { throw error("It is nested too deeply.") }
            guard let scalar = current else { throw error("It ends where a value was expected.") }
            switch scalar {
            case "{": return try object(depth: depth)
            case "[": return try array(depth: depth)
            case "\"": return .string(try string())
            case "t": return try expect("true", .bool(true))
            case "f": return try expect("false", .bool(false))
            case "n": return try expect("null", .null)
            case "-", "0"..."9": return .number(try number())
            default: throw error("A value was expected.")
            }
        }

        mutating func object(depth: Int) throws -> JSONNode {
            position += 1
            var members: [(key: String, value: JSONNode)] = []
            skipSpace()
            if current == "}" {
                position += 1
                return .object(members)
            }
            while true {
                skipSpace()
                guard current == "\"" else { throw error("A key in quotes was expected.") }
                let key = try string()
                skipSpace()
                guard current == ":" else { throw error("A colon was expected after the key.") }
                position += 1
                skipSpace()
                members.append((key, try value(depth: depth + 1)))
                skipSpace()
                switch current {
                case ",": position += 1
                case "}":
                    position += 1
                    return .object(members)
                default: throw error("A comma or a closing brace was expected.")
                }
            }
        }

        mutating func array(depth: Int) throws -> JSONNode {
            position += 1
            var values: [JSONNode] = []
            skipSpace()
            if current == "]" {
                position += 1
                return .array(values)
            }
            while true {
                skipSpace()
                values.append(try value(depth: depth + 1))
                skipSpace()
                switch current {
                case ",": position += 1
                case "]":
                    position += 1
                    return .array(values)
                default: throw error("A comma or a closing bracket was expected.")
                }
            }
        }

        mutating func number() throws -> String {
            let start = position
            if current == "-" { position += 1 }
            guard let first = current, ("0"..."9").contains(first) else { throw error("A digit was expected.") }
            position += 1
            if first != "0" { digits() }
            if current == "." {
                position += 1
                guard let next = current, ("0"..."9").contains(next) else { throw error("A digit was expected.") }
                digits()
            }
            if current == "e" || current == "E" {
                position += 1
                if current == "+" || current == "-" { position += 1 }
                guard let next = current, ("0"..."9").contains(next) else { throw error("A digit was expected.") }
                digits()
            }
            var text = ""
            text.unicodeScalars.append(contentsOf: scalars[start..<position])
            return text
        }

        mutating func digits() {
            while let scalar = current, ("0"..."9").contains(scalar) { position += 1 }
        }

        mutating func string() throws -> String {
            position += 1
            var result = String.UnicodeScalarView()
            while true {
                guard let scalar = current else { throw error("A string is not closed.") }
                position += 1
                switch scalar {
                case "\"": return String(result)
                case "\\":
                    guard let escape = current else { throw error("A string is not closed.") }
                    position += 1
                    switch escape {
                    case "\"": result.append("\"")
                    case "\\": result.append("\\")
                    case "/": result.append("/")
                    case "b": result.append("\u{08}")
                    case "f": result.append("\u{0C}")
                    case "n": result.append("\n")
                    case "r": result.append("\r")
                    case "t": result.append("\t")
                    case "u":
                        var code = try hex()
                        // A pair of surrogates is one scalar.
                        if (0xD800...0xDBFF).contains(code), current == "\\",
                            position + 1 < scalars.count, scalars[position + 1] == "u"
                        {
                            position += 2
                            let low = try hex()
                            guard (0xDC00...0xDFFF).contains(low) else { throw error("A broken surrogate pair.") }
                            code = 0x10000 + ((code - 0xD800) << 10) + (low - 0xDC00)
                        }
                        guard let decoded = Unicode.Scalar(code) else { throw error("A broken \\u escape.") }
                        result.append(decoded)
                    default: throw error("An unknown escape in a string.")
                    }
                case let control where control.value < 0x20:
                    throw error("A control character in a string.")
                default:
                    result.append(scalar)
                }
            }
        }

        mutating func hex() throws -> UInt32 {
            guard position + 4 <= scalars.count else { throw error("A broken \\u escape.") }
            var text = ""
            text.unicodeScalars.append(contentsOf: scalars[position..<position + 4])
            guard let code = UInt32(text, radix: 16) else { throw error("A broken \\u escape.") }
            position += 4
            return code
        }
    }
}
