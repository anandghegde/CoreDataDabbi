import Foundation

@testable import DabbiContent

/// A binary property list written by hand, so that tests can say things `PropertyListSerialization` never
/// would: an array that contains itself, two objects at one offset, a reference to nowhere.
enum Raw {
    case null
    case bool(Bool)
    /// `bytes` wide: 1, 2, 4, 8 or 16.
    case int(UInt64, bytes: Int)
    case real(Double)
    case date(Double)
    case data([UInt8])
    case ascii(String)
    case utf16(String)
    case uid(UInt8)
    case array([Int])
    case set([Int])
    case dict([(key: Int, value: Int)])
    /// Verbatim bytes, for markers the format does not have.
    case bytes([UInt8])
    /// No bytes of its own: the offset table points at the object with this index instead.
    case alias(Int)
}

func binaryPlist(_ objects: [Raw], top: Int = 0, declaredCount: Int? = nil) -> Data {
    func bigEndian(_ value: UInt64, _ width: Int) -> [UInt8] {
        (0..<width).map { UInt8(truncatingIfNeeded: value >> UInt64((width - 1 - $0) * 8)) }
    }
    func header(_ type: UInt8, _ count: Int) -> [UInt8] {
        count < 15 ? [type << 4 | UInt8(count)] : [type << 4 | 0x0F, 0x12] + bigEndian(UInt64(count), 4)
    }
    func references(_ indices: [Int]) -> [UInt8] { indices.flatMap { bigEndian(UInt64($0), 2) } }

    var file = Array("bplist00".utf8)
    var offsets: [Int] = []
    for object in objects {
        offsets.append(file.count)
        switch object {
        case .null: file += [0x00]
        case .bool(let value): file += [value ? 0x09 : 0x08]
        case .int(let value, let width):
            file += [0x10 | UInt8(width.trailingZeroBitCount)]
            file += width == 16 ? bigEndian(0, 8) + bigEndian(value, 8) : bigEndian(value, width)
        case .real(let value): file += [0x23] + bigEndian(value.bitPattern, 8)
        case .date(let value): file += [0x33] + bigEndian(value.bitPattern, 8)
        case .data(let bytes): file += header(0x4, bytes.count) + bytes
        case .ascii(let text): file += header(0x5, text.utf8.count) + Array(text.utf8)
        case .utf16(let text): file += header(0x6, text.utf16.count) + text.utf16.flatMap { bigEndian(UInt64($0), 2) }
        case .uid(let value): file += [0x80, value]
        case .array(let items): file += header(0xA, items.count) + references(items)
        case .set(let items): file += header(0xC, items.count) + references(items)
        case .dict(let entries):
            file += header(0xD, entries.count) + references(entries.map(\.key)) + references(entries.map(\.value))
        case .bytes(let bytes): file += bytes
        case .alias: break
        }
    }
    for (index, object) in objects.enumerated() {
        if case .alias(let target) = object { offsets[index] = offsets[target] }
    }
    let table = file.count
    for offset in offsets { file += bigEndian(UInt64(offset), 4) }
    file += [0, 0, 0, 0, 0, 0, 4, 2]
    file +=
        bigEndian(UInt64(declaredCount ?? objects.count), 8) + bigEndian(UInt64(top), 8) + bigEndian(UInt64(table), 8)
    return Data(file)
}

/// An archive by hand: `$objects[0]` is `$null`, the root is UID 1.
func handArchive(_ objects: [Raw]) -> Data {
    // 0: top dictionary, 1–6: its keys and values, 7…: $objects' members.
    let base = 8
    let members = [Raw.ascii("$null")] + objects
    var all: [Raw] = [
        .dict([(1, 2), (3, 4), (5, 6)]),
        .ascii("$archiver"), .ascii("NSKeyedArchiver"),
        .ascii("$objects"), .array(members.indices.map { base + $0 }),
        .ascii("$top"), .dict([(7, base + members.count)]),
        .ascii("root"),
    ]
    all += members
    all.append(.uid(1))
    return binaryPlist(all)
}

/// Runs `body` on a thread with the stack of a Swift concurrency worker (512 KB). Overflowing it takes the
/// test process down, which is the point: the limits have to make that impossible.
func onSmallStack<T: Sendable>(_ body: @escaping @Sendable () -> T) -> T {
    onThread(stackSize: 512 * 1024, body)
}

func onThread<T: Sendable>(stackSize: Int, _ body: @escaping @Sendable () -> T) -> T {
    let box = ResultBox<T>()
    let done = DispatchSemaphore(value: 0)
    let thread = Thread {
        box.value = body()
        done.signal()
    }
    thread.stackSize = stackSize
    thread.start()
    done.wait()
    return box.value!
}

private final class ResultBox<T>: @unchecked Sendable {
    var value: T?
}

func tree(_ report: ContentReport) -> ContentNode? {
    guard case .tree(let node, _, _) = report.content else { return nil }
    return node
}

extension ContentNode {
    /// `true` when this node or one below it matches.
    func contains(where matches: (ContentNode) -> Bool) -> Bool {
        matches(self) || children.contains { $0.contains(where: matches) }
    }

    /// The tree with the fields of objects and dictionaries in key order; arrays keep theirs.
    func sortedByKey() -> ContentNode {
        var copy = self
        copy.children = children.map { $0.sortedByKey() }
        if kind == .object || kind == .dictionary { copy.children.sort { ($0.key ?? "") < ($1.key ?? "") } }
        return copy
    }
}
