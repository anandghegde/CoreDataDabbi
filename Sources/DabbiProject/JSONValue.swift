import Foundation

/// Any JSON document, as a value.
///
/// Project files are read twice: once into the typed schema, once into this. The difference between the two is
/// what a newer version of the app wrote and this one does not understand — and must not lose (ADR-13).
enum JSONValue: Sendable, Hashable {
    case null
    case bool(Bool)
    case int(Int64)
    case double(Double)
    case string(String)
    case array([JSONValue])
    case object([String: JSONValue])

    static let emptyObject = JSONValue.object([:])

    subscript(key: String) -> JSONValue? {
        guard case .object(let members) = self else { return nil }
        return members[key]
    }

    var isEmptyObject: Bool {
        if case .object(let members) = self { return members.isEmpty }
        return false
    }
}

extension JSONValue: Codable {
    init(from decoder: any Decoder) throws {
        if let members = try? decoder.container(keyedBy: AnyKey.self) {
            var object: [String: JSONValue] = [:]
            for key in members.allKeys {
                object[key.stringValue] = try members.decode(JSONValue.self, forKey: key)
            }
            self = .object(object)
        } else if var elements = try? decoder.unkeyedContainer() {
            var array: [JSONValue] = []
            while !elements.isAtEnd { array.append(try elements.decode(JSONValue.self)) }
            self = .array(array)
        } else {
            let value = try decoder.singleValueContainer()
            // The order matters: `JSONDecoder` reads neither `true` as a number nor `1` as a Bool, and an integer
            // must be tried before Double so that it is written back without a fraction.
            if value.decodeNil() {
                self = .null
            } else if let bool = try? value.decode(Bool.self) {
                self = .bool(bool)
            } else if let int = try? value.decode(Int64.self) {
                self = .int(int)
            } else if let double = try? value.decode(Double.self) {
                self = .double(double)
            } else {
                self = .string(try value.decode(String.self))
            }
        }
    }

    func encode(to encoder: any Encoder) throws {
        switch self {
        case .null:
            var value = encoder.singleValueContainer()
            try value.encodeNil()
        case .bool(let bool): try bool.encode(to: encoder)
        case .int(let int): try int.encode(to: encoder)
        case .double(let double): try double.encode(to: encoder)
        case .string(let string): try string.encode(to: encoder)
        case .array(let array): try array.encode(to: encoder)
        case .object(let object):
            var members = encoder.container(keyedBy: AnyKey.self)
            for (key, value) in object { try members.encode(value, forKey: AnyKey(key)) }
        }
    }

    private struct AnyKey: CodingKey {
        let stringValue: String
        var intValue: Int? { nil }
        init(_ string: String) { stringValue = string }
        init?(stringValue: String) { self.stringValue = stringValue }
        init?(intValue: Int) { nil }
    }
}

// MARK: - What the schema does not know

extension JSONValue {
    /// The members of `self` that `known` lacks, at any depth of nested objects.
    ///
    /// Arrays are not descended into: their elements have no identity to match by, so an array the schema knows
    /// belongs to the schema entirely.
    func subtracting(_ known: JSONValue) -> JSONValue {
        guard case .object(let mine) = self, case .object(let theirs) = known else { return .emptyObject }
        var rest: [String: JSONValue] = [:]
        for (key, value) in mine {
            guard let counterpart = theirs[key] else {
                rest[key] = value
                continue
            }
            let nested = value.subtracting(counterpart)
            if !nested.isEmptyObject { rest[key] = nested }
        }
        return .object(rest)
    }

    /// `self` with the members of `extra` added wherever `self` has none. `self` wins every conflict.
    func merging(_ extra: JSONValue) -> JSONValue {
        guard case .object(var mine) = self, case .object(let theirs) = extra else { return self }
        for (key, value) in theirs {
            mine[key] = mine[key].map { $0.merging(value) } ?? value
        }
        return .object(mine)
    }
}

// MARK: - Files

enum ProjectJSON {
    /// Sorted keys and one member per line: a project in a repository should produce small, readable diffs.
    static func encoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }

    static func decoder() -> JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }

    /// A typed value as the JSON tree it encodes to.
    static func tree<T: Encodable>(_ value: T) throws -> JSONValue {
        try decoder().decode(JSONValue.self, from: encoder().encode(value))
    }

    static func data(_ tree: JSONValue) throws -> Data {
        var data = try encoder().encode(tree)
        data.append(0x0A)  // Text files end with a newline; Git says so on every diff otherwise.
        return data
    }
}
