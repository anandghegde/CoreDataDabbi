import Darwin
import DabbiBase
import Foundation

/// A process that has a store's files open.
public struct LiveProcess: Sendable, Hashable {
    public let pid: Int32
    /// The executable's name, as Activity Monitor shows it.
    public let name: String

    public init(pid: Int32, name: String) {
        self.pid = pid
        self.name = name
    }
}

/// Who has a store open (ARCHITECTURE.md §6.9, "Live-process guard").
///
/// `proc_listpidspath` asks the kernel which processes hold a file descriptor on a path: precise, cheap, and it
/// sees simulator apps, which are processes of this Mac. Only this user's processes can be seen, which are the
/// only ones that could have a store in this user's containers open.
public enum LiveProcesses {
    /// The processes, other than `excluded`, that have the database or its write-ahead log open.
    public static func holding(_ store: URL, excluding excluded: Set<Int32> = [getpid()]) -> [LiveProcess] {
        var found: [Int32: LiveProcess] = [:]
        for suffix in [""] + StoreFiles.sideFileSuffixes {
            let path = store.path + suffix
            guard FileManager.default.fileExists(atPath: path) else { continue }
            for pid in pids(holding: path) where !excluded.contains(pid) && found[pid] == nil {
                found[pid] = LiveProcess(pid: pid, name: name(of: pid))
            }
        }
        return found.values.sorted { $0.pid < $1.pid }
    }

    private static func pids(holding path: String) -> [Int32] {
        // Asked with no buffer, it says how many bytes the answer takes; room is made for a few more, in case
        // processes open the file between the two calls.
        let needed = proc_listpidspath(
            UInt32(PROC_ALL_PIDS), 0, path, UInt32(PROC_LISTPIDSPATH_EXCLUDE_EVTONLY), nil, 0)
        guard needed > 0 else { return [] }
        var buffer = [pid_t](repeating: 0, count: Int(needed) / MemoryLayout<pid_t>.size + 16)
        let bytes = buffer.withUnsafeMutableBytes { raw in
            proc_listpidspath(
                UInt32(PROC_ALL_PIDS), 0, path, UInt32(PROC_LISTPIDSPATH_EXCLUDE_EVTONLY), raw.baseAddress,
                Int32(raw.count))
        }
        guard bytes > 0 else { return [] }
        return Array(buffer.prefix(Int(bytes) / MemoryLayout<pid_t>.size)).filter { $0 > 0 }
    }

    private static func name(of pid: Int32) -> String {
        var buffer = [CChar](repeating: 0, count: 4 * Int(MAXCOMLEN) + 1)
        let length = proc_name(pid, &buffer, UInt32(buffer.count))
        guard length > 0 else { return "pid \(pid)" }
        return String(decoding: buffer.prefix(Int(length)).map { UInt8(bitPattern: $0) }, as: UTF8.self)
    }

    /// The error a restore refused because of `processes` carries.
    public static func inUse(_ store: URL, by processes: [LiveProcess]) -> DabbiError {
        let names = processes.map { "\($0.name) (\($0.pid))" }.joined(separator: ", ")
        return DabbiError(
            .storeInUse, "The store is open in another process.",
            arguments: ["path": store.path, "processes": names],
            diagnosis: ["Open by: \(names)."],
            recovery: ["Quit the app that uses the store, then try again."])
    }
}
