import DabbiBase
import Foundation

/// One object of a property list, with its children named by index rather than held.
///
/// A property list is a graph — a binary one can name the same object from many places, and its own ancestors —
/// so it is read as a table of objects, and whoever walks it decides how far to go (`PlistTreeBuilder`,
/// `KeyedArchiveTreeBuilder`).
enum PlistObject: Sendable, Hashable {
    case null
    case bool(Bool)
    case int(Int64)
    /// A 16-byte integer that does not fit 64 bits, as hexadecimal text.
    case bigInt(String)
    case real(Double)
    case date(Date)
    case data(Data)
    case string(String)
    /// A `CFKeyedArchiverUID`: an index into an archive's `$objects`.
    case uid(UInt64)
    case array([Int])
    case set([Int])
    case dictionary(keys: [Int], values: [Int])
}

/// Where `PlistObject`s come from: `BinaryPlist` or `XMLPlist`.
protocol PlistSource: AnyObject {
    var top: Int { get }
    func object(at index: Int) throws -> PlistObject
}

extension PlistSource {
    /// The entries of a dictionary whose keys are strings, as every dictionary the archiver writes is.
    func entries(keys: [Int], values: [Int]) throws -> [(key: String, value: Int)] {
        try zip(keys, values).map { key, value in
            guard case .string(let name) = try object(at: key) else {
                throw malformed("property list", "A dictionary key is not a string.")
            }
            return (name, value)
        }
    }
}

/// Our own reader of the `bplist00` format (ADR-08).
///
/// `PropertyListSerialization` would hide archive UIDs behind a private class and has no limits to set. This
/// one checks every offset, reads objects only when asked, and stops when the file makes it work harder than an
/// honest file could: offsets may point anywhere, so a hostile one can alias one large array a million times.
///
/// Layout: `bplist00`, objects, an offset table, and a 32-byte trailer saying how wide offsets and object
/// references are, how many objects there are, which is the top one, and where the offset table starts.
final class BinaryPlist: PlistSource {
    static let magic = Array("bplist0".utf8)
    private static let trailerLength = 32

    private let bytes: [UInt8]
    private let offsetSize: Int
    private let refSize: Int
    private let objectCount: Int
    private let offsetTable: Int
    let top: Int

    private var cache: [Int: PlistObject] = [:]
    /// Bytes and references read so far, against `workLimit`.
    private var work = 0
    private let workLimit: Int

    init(_ data: Data) throws {
        bytes = [UInt8](data)
        guard bytes.count >= 8 + 1 + Self.trailerLength, bytes.starts(with: Self.magic) else {
            throw malformed("binary property list", "It does not start with “bplist0”, or is too short.")
        }
        let trailer = bytes.count - Self.trailerLength
        offsetSize = Int(bytes[trailer + 6])
        refSize = Int(bytes[trailer + 7])
        let count = Self.bigEndian(bytes, at: trailer + 8, size: 8)
        let topObject = Self.bigEndian(bytes, at: trailer + 16, size: 8)
        let table = Self.bigEndian(bytes, at: trailer + 24, size: 8)

        guard (1...8).contains(offsetSize), (1...8).contains(refSize) else {
            throw malformed("binary property list", "Its trailer gives impossible integer sizes.")
        }
        // Every object takes at least a byte, and its offset at least another: no honest count is higher.
        guard count >= 1, count <= UInt64(trailer), topObject < count, table >= 8, table < UInt64(trailer),
            UInt64(trailer) - table >= count * UInt64(offsetSize)
        else {
            throw malformed("binary property list", "Its trailer does not describe this file.")
        }
        objectCount = Int(count)
        top = Int(topObject)
        offsetTable = Int(table)
        workLimit = bytes.count * 8 + 4096
    }

    func object(at index: Int) throws -> PlistObject {
        if let cached = cache[index] { return cached }
        guard index >= 0, index < objectCount else {
            throw malformed("binary property list", "It refers to object \(index); there are \(objectCount).")
        }
        let offset = Self.bigEndian(bytes, at: offsetTable + index * offsetSize, size: offsetSize)
        guard offset >= 8, offset < UInt64(offsetTable) else {
            throw malformed("binary property list", "Object \(index) lies outside the object area.")
        }
        let object = try parse(at: Int(offset))
        cache[index] = object
        return object
    }

    // MARK: Objects

    private func parse(at start: Int) throws -> PlistObject {
        var position = start
        let marker = try byte(&position)
        let info = Int(marker & 0x0F)

        switch marker >> 4 {
        case 0x0:
            switch marker {
            case 0x00: return .null
            case 0x08: return .bool(false)
            case 0x09: return .bool(true)
            default: throw malformed("binary property list", "Unknown object marker \(marker).")
            }
        case 0x1:
            return try integer(&position, exponent: info)
        case 0x2:
            switch info {
            case 2: return .real(Double(Float(bitPattern: UInt32(try unsigned(&position, size: 4)))))
            case 3: return .real(Double(bitPattern: try unsigned(&position, size: 8)))
            default: throw malformed("binary property list", "A real number of \(1 << info) bytes.")
            }
        case 0x3:
            guard info == 3 else { throw malformed("binary property list", "A date that is not 8 bytes.") }
            let seconds = Double(bitPattern: try unsigned(&position, size: 8))
            return .date(Date(timeIntervalSinceReferenceDate: seconds))
        case 0x4:
            let range = try span(&position, count: try length(&position, info: info), unit: 1)
            return .data(Data(bytes[range]))
        case 0x5:
            let range = try span(&position, count: try length(&position, info: info), unit: 1)
            // Bytes that are not ASCII after all become replacement characters: a lossy reading beats none.
            return .string(String(decoding: bytes[range], as: UTF8.self))
        case 0x6:
            let range = try span(&position, count: try length(&position, info: info), unit: 2)
            let units = stride(from: range.lowerBound, to: range.upperBound, by: 2).map {
                UInt16(bytes[$0]) << 8 | UInt16(bytes[$0 + 1])
            }
            return .string(String(decoding: units, as: UTF16.self))
        case 0x7:
            let range = try span(&position, count: try length(&position, info: info), unit: 1)
            return .string(String(decoding: bytes[range], as: UTF8.self))
        case 0x8:
            guard info < 8 else { throw malformed("binary property list", "A UID of \(info + 1) bytes.") }
            return .uid(try unsigned(&position, size: info + 1))
        case 0xA:
            return .array(try references(&position, count: try length(&position, info: info)))
        case 0xC:
            return .set(try references(&position, count: try length(&position, info: info)))
        case 0xD:
            let count = try length(&position, info: info)
            let keys = try references(&position, count: count)
            return .dictionary(keys: keys, values: try references(&position, count: count))
        default:
            throw malformed("binary property list", "Unknown object marker \(marker).")
        }
    }

    private func integer(_ position: inout Int, exponent: Int) throws -> PlistObject {
        switch exponent {
        case 0, 1, 2:
            // One, two and four bytes are unsigned; only eight are two's complement.
            return .int(Int64(try unsigned(&position, size: 1 << exponent)))
        case 3:
            return .int(Int64(bitPattern: try unsigned(&position, size: 8)))
        case 4:
            let high = try unsigned(&position, size: 8)
            let low = try unsigned(&position, size: 8)
            let signExtension: UInt64 = low >> 63 == 1 ? .max : 0
            if high == signExtension { return .int(Int64(bitPattern: low)) }
            return .bigInt("0x" + String(high, radix: 16) + String(low, radix: 16).leftPadded(to: 16))
        default:
            throw malformed("binary property list", "An integer of \(1 << exponent) bytes.")
        }
    }

    /// A count of 15 or more does not fit the marker; an integer object follows and says it.
    private func length(_ position: inout Int, info: Int) throws -> Int {
        guard info == 0x0F else { return info }
        let marker = try byte(&position)
        guard marker >> 4 == 0x1, marker & 0x0F <= 3 else {
            throw malformed("binary property list", "A length that is not an integer.")
        }
        let value = try unsigned(&position, size: 1 << Int(marker & 0x0F))
        guard value <= UInt64(bytes.count) else {
            throw malformed("binary property list", "An object longer than the file.")
        }
        return Int(value)
    }

    private func references(_ position: inout Int, count: Int) throws -> [Int] {
        let range = try span(&position, count: count, unit: refSize)
        return stride(from: range.lowerBound, to: range.upperBound, by: refSize).map {
            // Range-checked when followed, by `object(at:)`.
            Int(clamping: Self.bigEndian(bytes, at: $0, size: refSize))
        }
    }

    // MARK: Bytes

    /// `count` units at `position`, inside the object area — and on the bill.
    private func span(_ position: inout Int, count: Int, unit: Int) throws -> Range<Int> {
        let (length, overflow) = count.multipliedReportingOverflow(by: unit)
        guard !overflow, count >= 0, length <= offsetTable - position else {
            throw malformed("binary property list", "An object runs past the end of the object area.")
        }
        work += length + 1
        guard work <= workLimit else {
            throw limitExceeded("The property list repeats itself more than any real one would.")
        }
        defer { position += length }
        return position..<position + length
    }

    private func byte(_ position: inout Int) throws -> UInt8 {
        bytes[try span(&position, count: 1, unit: 1).lowerBound]
    }

    private func unsigned(_ position: inout Int, size: Int) throws -> UInt64 {
        Self.bigEndian(bytes, at: try span(&position, count: size, unit: 1).lowerBound, size: size)
    }

    /// The caller has checked that `offset..<offset + size` is inside `bytes`, and that `size` ≤ 8.
    private static func bigEndian(_ bytes: [UInt8], at offset: Int, size: Int) -> UInt64 {
        bytes[offset..<offset + size].reduce(0) { $0 << 8 | UInt64($1) }
    }
}
