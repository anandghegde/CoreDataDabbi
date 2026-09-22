import DabbiBase
import Foundation

/// An XML property list, read into the same object table as a binary one — so that an archive written with
/// `outputFormat = .xml` gets the same tree, and dictionaries keep the order they were written in.
///
/// `XMLParser` does the XML (it does not resolve external entities unless told to); what the elements mean is
/// decided here. `{ CF$UID = n }` is how the XML format spells an archive UID.
final class XMLPlist: NSObject, PlistSource, XMLParserDelegate {
    /// An open `<array>` or `<dict>`. Mutated in place: an array of 100,000 items is appended to that often.
    private struct Frame {
        let isDictionary: Bool
        var keys: [Int] = []
        var values: [Int] = []
        var pendingKey: Int?
    }

    private(set) var top = 0
    private var objects: [PlistObject] = []
    private var stack: [Frame] = []
    private var text = ""
    private var hasTop = false
    private var failure: DabbiError?
    private let limits: DecodeLimits

    init(_ data: Data, limits: DecodeLimits) throws {
        self.limits = limits
        super.init()
        let parser = XMLParser(data: data)
        parser.shouldResolveExternalEntities = false
        parser.delegate = self
        let finished = parser.parse()
        if let failure { throw failure }
        guard finished, hasTop, stack.isEmpty else {
            let detail = parser.parserError.map { ($0 as NSError).localizedDescription } ?? "It has no root object."
            throw malformed("XML property list", detail)
        }
    }

    func object(at index: Int) throws -> PlistObject {
        guard objects.indices.contains(index) else {
            throw malformed("XML property list", "It refers to an object it does not have.")
        }
        return objects[index]
    }

    // MARK: XMLParserDelegate

    func parser(
        _ parser: XMLParser, didStartElement element: String, namespaceURI: String?, qualifiedName: String?,
        attributes: [String: String] = [:]
    ) {
        guard failure == nil else { return }
        text = ""
        switch element {
        case "array": stack.append(Frame(isDictionary: false))
        case "dict": stack.append(Frame(isDictionary: true))
        default: break
        }
        if stack.count > limits.maxTreeDepth {
            fail(parser, limitExceeded("The property list nests deeper than \(limits.maxTreeDepth) levels."))
        }
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) {
        text += string
    }

    func parser(
        _ parser: XMLParser, didEndElement element: String, namespaceURI: String?, qualifiedName: String?
    ) {
        guard failure == nil else { return }
        defer { text = "" }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        switch element {
        case "plist":
            return
        case "key":
            guard let frame = stack.last, frame.isDictionary, frame.pendingKey == nil else {
                return fail(parser, malformed("XML property list", "A <key> outside a dictionary, or two in a row."))
            }
            stack[stack.count - 1].pendingKey = add(.string(text))
        case "string":
            attach(add(.string(text)), parser)
        case "integer":
            guard let value = Self.integer(trimmed) else {
                return fail(parser, malformed("XML property list", "“\(trimmed.prefix(40))” is not an integer."))
            }
            attach(add(value), parser)
        case "real":
            guard let value = Double(trimmed) else {
                return fail(parser, malformed("XML property list", "“\(trimmed.prefix(40))” is not a number."))
            }
            attach(add(.real(value)), parser)
        case "true", "false":
            attach(add(.bool(element == "true")), parser)
        case "date":
            guard let value = try? Date(trimmed, strategy: .iso8601) else {
                return fail(parser, malformed("XML property list", "“\(trimmed.prefix(40))” is not a date."))
            }
            attach(add(.date(value)), parser)
        case "data":
            guard let value = Data(base64Encoded: trimmed, options: .ignoreUnknownCharacters) else {
                return fail(parser, malformed("XML property list", "A <data> element is not Base64."))
            }
            attach(add(.data(value)), parser)
        case "array":
            guard let frame = stack.popLast(), !frame.isDictionary else {
                return fail(parser, malformed("XML property list", "An </array> without its <array>."))
            }
            attach(add(.array(frame.values)), parser)
        case "dict":
            guard let frame = stack.popLast(), frame.isDictionary, frame.pendingKey == nil else {
                return fail(parser, malformed("XML property list", "A dictionary key without a value."))
            }
            let (keys, values) = (frame.keys, frame.values)
            attach(add(uid(keys: keys, values: values) ?? .dictionary(keys: keys, values: values)), parser)
        default:
            fail(parser, malformed("XML property list", "<\(element.prefix(40))> is not a property-list element."))
        }
    }

    // MARK: Building

    private func add(_ object: PlistObject) -> Int {
        objects.append(object)
        return objects.count - 1
    }

    private func attach(_ index: Int, _ parser: XMLParser) {
        guard objects.count <= limits.maxNodes * 2 else {
            return fail(parser, limitExceeded("The property list has more objects than the viewer shows."))
        }
        guard let frame = stack.last else {
            guard !hasTop else {
                return fail(parser, malformed("XML property list", "It has more than one root object."))
            }
            top = index
            hasTop = true
            return
        }
        if frame.isDictionary {
            guard let key = frame.pendingKey else {
                return fail(parser, malformed("XML property list", "A dictionary value without a key."))
            }
            stack[stack.count - 1].keys.append(key)
            stack[stack.count - 1].pendingKey = nil
        }
        stack[stack.count - 1].values.append(index)
    }

    private func uid(keys: [Int], values: [Int]) -> PlistObject? {
        guard keys.count == 1, case .string("CF$UID") = objects[keys[0]], case .int(let value) = objects[values[0]],
            value >= 0
        else { return nil }
        return .uid(UInt64(value))
    }

    private func fail(_ parser: XMLParser, _ error: DabbiError) {
        if failure == nil { failure = error }
        parser.abortParsing()
    }

    private static func integer(_ text: String) -> PlistObject? {
        if let value = Int64(text) { return .int(value) }
        if UInt64(text) != nil { return .bigInt(text) }
        let (negative, digits) = text.hasPrefix("-") ? (true, text.dropFirst()) : (false, text[...])
        guard digits.hasPrefix("0x") || digits.hasPrefix("0X"), let value = UInt64(digits.dropFirst(2), radix: 16)
        else { return nil }
        if let signed = Int64(exactly: value) { return .int(negative ? -signed : signed) }
        return negative ? nil : .bigInt(String(text))
    }
}
