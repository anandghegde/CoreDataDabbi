import DabbiBase
import Foundation

/// Indents XML for the Text mode, leaving every tag, attribute, entity and comment exactly as written.
///
/// Not `XMLDocument`: it crashes on some malformed documents (found by `ContentFuzz` within seconds — the
/// initialiser hands back a wild error pointer), it expands entities, and it re-serialises what it parsed
/// rather than what was there. A tokenizer is enough to indent, checks that tags balance, and cannot be talked
/// into anything: it never interprets a DTD or an entity.
enum XMLIndenter {
    enum Token {
        case open(name: String, raw: Range<Int>)
        case close(name: String, raw: Range<Int>)
        case selfClosing(raw: Range<Int>)
        case text(Range<Int>)
        /// A comment, a processing instruction, CDATA or a DOCTYPE: passed through.
        case other(Range<Int>)
        case cdata(Range<Int>)
    }

    /// The name of the first element, without reading further: how SVG is told from other XML.
    static func rootElementName(_ text: String) -> String? {
        let bytes = Array(text.utf8)
        var position = 0
        while let token = try? next(in: bytes, at: &position) {
            switch token {
            case .open(let name, _): return name
            case .selfClosing(let raw): return name(in: bytes, from: raw.lowerBound + 1)
            case .close, .cdata: return nil
            case .text(let range):
                guard bytes[range].allSatisfy(isSpace) else { return nil }
            case .other: continue
            }
        }
        return nil
    }

    static func indent(_ text: String, maxDepth: Int) throws -> String {
        let bytes = Array(text.utf8)
        var tokens: [Token] = []
        var position = 0
        while let token = try next(in: bytes, at: &position) {
            if case .text(let range) = token, bytes[range].allSatisfy(isSpace) { continue }
            tokens.append(token)
        }

        var output = ""
        output.reserveCapacity(bytes.count + bytes.count / 4)
        var open: [String] = []
        var sawElement = false
        func line(_ range: Range<Int>, trimmed: Bool = false) {
            if !output.isEmpty { output += "\n" }
            output += String(repeating: "  ", count: open.count)
            output += string(bytes, range, trimmed: trimmed)
        }

        var index = 0
        while index < tokens.count {
            defer { index += 1 }
            switch tokens[index] {
            case .open(let name, let raw):
                sawElement = true
                guard open.count < maxDepth else {
                    throw limitExceeded("The XML nests deeper than \(maxDepth) levels.")
                }
                line(raw)
                // <a>text</a> and <a></a> stay on one line.
                if index + 1 < tokens.count, case .close(name, let closing) = tokens[index + 1] {
                    output += string(bytes, closing)
                    index += 1
                } else if index + 2 < tokens.count, case .text(let inner) = tokens[index + 1],
                    case .close(name, let closing) = tokens[index + 2]
                {
                    output += string(bytes, inner, trimmed: true) + string(bytes, closing)
                    index += 2
                } else {
                    open.append(name)
                }
            case .close(let name, let raw):
                guard let expected = open.popLast() else {
                    throw malformed("XML document", "</\(name.prefix(40))> closes an element that was never opened.")
                }
                guard expected == name else {
                    throw malformed(
                        "XML document", "</\(name.prefix(40))> closes <\(expected.prefix(40))>, which is still open.")
                }
                line(raw)
            case .selfClosing(let raw):
                sawElement = true
                line(raw)
            case .text(let range):
                guard !open.isEmpty else { throw malformed("XML document", "There is text outside the root element.") }
                line(range, trimmed: true)
            case .cdata(let range):
                guard !open.isEmpty else { throw malformed("XML document", "There is text outside the root element.") }
                line(range)
            case .other(let range):
                line(range)
            }
        }
        guard open.isEmpty else {
            throw malformed("XML document", "<\(open[open.count - 1].prefix(40))> is never closed.")
        }
        guard sawElement else { throw malformed("XML document", "It has no element.") }
        return output
    }

    // MARK: Tokens

    private static func next(in bytes: [UInt8], at position: inout Int) throws -> Token? {
        guard position < bytes.count else { return nil }
        let start = position
        guard bytes[start] == UInt8(ascii: "<") else {
            position = bytes[start...].firstIndex(of: UInt8(ascii: "<")) ?? bytes.count
            return .text(start..<position)
        }

        func starts(_ text: String) -> Bool { bytes[start...].starts(with: text.utf8) }
        func through(_ terminator: String, from: Int, what: String) throws -> Range<Int> {
            let pattern = Array(terminator.utf8)
            var index = from
            while index + pattern.count <= bytes.count {
                if bytes[index] == pattern[0], bytes[index..<index + pattern.count].elementsEqual(pattern) {
                    position = index + pattern.count
                    return start..<position
                }
                index += 1
            }
            throw malformed("XML document", "\(what) is not closed.")
        }

        if starts("<!--") { return .other(try through("-->", from: start + 4, what: "A comment")) }
        if starts("<![CDATA[") { return .cdata(try through("]]>", from: start + 9, what: "A CDATA section")) }
        if starts("<?") { return .other(try through("?>", from: start + 2, what: "A processing instruction")) }

        // A tag or a DOCTYPE ends at the first `>` outside quotes and, for a DOCTYPE, outside its [subset].
        let isDeclaration = starts("<!")
        var quote: UInt8?
        var brackets = 0
        var index = start + 1
        while index < bytes.count {
            let byte = bytes[index]
            if let open = quote {
                if byte == open { quote = nil }
            } else if byte == UInt8(ascii: "\"") || byte == UInt8(ascii: "'") {
                quote = byte
            } else if isDeclaration, byte == UInt8(ascii: "[") {
                brackets += 1
            } else if isDeclaration, byte == UInt8(ascii: "]") {
                brackets -= 1
            } else if byte == UInt8(ascii: ">"), brackets <= 0 {
                break
            } else if byte == UInt8(ascii: "<"), !isDeclaration {
                throw malformed("XML document", "A “<” inside a tag.")
            }
            index += 1
        }
        guard index < bytes.count else { throw malformed("XML document", "A tag is not closed.") }
        position = index + 1
        let raw = start..<position
        if isDeclaration { return .other(raw) }

        let isClosing = bytes[start + 1] == UInt8(ascii: "/")
        guard let name = name(in: bytes, from: start + (isClosing ? 2 : 1)) else {
            throw malformed("XML document", "A tag without a name.")
        }
        if isClosing { return .close(name: name, raw: raw) }
        return bytes[index - 1] == UInt8(ascii: "/") ? .selfClosing(raw: raw) : .open(name: name, raw: raw)
    }

    private static func name(in bytes: [UInt8], from start: Int) -> String? {
        let end = bytes[start...].firstIndex { isSpace($0) || $0 == UInt8(ascii: ">") || $0 == UInt8(ascii: "/") }
        guard let end, end > start else { return nil }
        return String(decoding: bytes[start..<end], as: UTF8.self)
    }

    private static func isSpace(_ byte: UInt8) -> Bool {
        byte == 0x20 || byte == 0x0A || byte == 0x0D || byte == 0x09
    }

    private static func string(_ bytes: [UInt8], _ range: Range<Int>, trimmed: Bool = false) -> String {
        var slice = bytes[range]
        if trimmed {
            slice = slice.drop(while: isSpace)
            while let last = slice.last, isSpace(last) { slice.removeLast() }
        }
        return String(decoding: slice, as: UTF8.self)
    }
}
