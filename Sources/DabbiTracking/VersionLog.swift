import DabbiBase
import DabbiSQLite
import Foundation

/// Every change the tracker has reported, oldest to newest, append-only (ARCHITECTURE.md §6.6, TRK-2).
///
/// Two ways to read it, because the UI shows both: *by time* — the version rows of a session, newest first — and
/// *by object*, which is how "what has happened to this row" is answered.
///
/// The log is capped. The newest `Options.cap` versions stay in memory; older ones are written to a temporary
/// database we own (`SQLiteScratch`) and read back from there on demand, so a session that runs for a day does not
/// grow without bound and does not lose its beginning either. If that file cannot be made — a read-only temporary
/// directory, a full disk — the oldest versions are dropped and `droppedCount` says how many, because a log that
/// quietly forgets is worse than one that admits it.
///
/// The spill file holds row values, so it lives in a directory of its own and is deleted with `clear()`, `close()`
/// or the process. Nothing here is ever written to the system log (§10).
public actor VersionLog {
    /// One entry: a change, and where it falls in the session.
    public struct Version: Sendable, Hashable, Codable, Identifiable {
        /// 1-based and monotonic for the life of the log. Stable across a spill, which is what makes it the
        /// cursor an export or a "load older" pages with.
        public let sequence: Int
        public let at: Date
        public let event: ChangeEvent

        public init(sequence: Int, at: Date, event: ChangeEvent) {
            self.sequence = sequence
            self.at = at
            self.event = event
        }

        public var id: Int { sequence }
        public var object: ObjectRef { event.object }
    }

    /// One object the log has something about — a row of the object-first view.
    public struct LoggedObject: Sendable, Hashable, Codable, Identifiable {
        public let object: ObjectRef
        /// How many versions the log has recorded of it, including any that have been spilled or dropped.
        public let versions: Int
        public let firstSequence: Int
        public let latestSequence: Int
        public let latestAt: Date
        public let latestKind: ChangeEvent.Kind

        public init(
            object: ObjectRef,
            versions: Int,
            firstSequence: Int,
            latestSequence: Int,
            latestAt: Date,
            latestKind: ChangeEvent.Kind
        ) {
            self.object = object
            self.versions = versions
            self.firstSequence = firstSequence
            self.latestSequence = latestSequence
            self.latestAt = latestAt
            self.latestKind = latestKind
        }

        public var id: ObjectRef { object }
    }

    public struct Options: Sendable, Hashable {
        /// Versions kept in memory. §6.6 budgets 10 000; older ones spill.
        public var cap: Int = 10_000
        /// Whether older versions are written to a temporary database. Off means they are dropped instead, which
        /// is what a caller that cannot afford a file on disk wants.
        public var spillsToDisk: Bool = true

        public init() {}
    }

    public nonisolated let options: Options

    /// Ascending by sequence. The tail of the log, at most `options.cap` long.
    private var memory: [Version] = []
    private var nextSequence = 1
    private var objectsByRef: [ObjectRef: LoggedObject] = [:]
    private var spill: SQLiteScratch?
    private var spilledCount = 0
    private var droppedCount = 0
    private var spillIsUnavailable = false
    private let log = DabbiLog.logger(.tracking)
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()

    public init(options: Options = .init()) {
        self.options = options
    }

    // MARK: What the log holds

    /// Versions appended since the last `clear()`, however many of them are still readable.
    public var count: Int { memory.count + spilledCount + droppedCount }

    public var inMemoryCount: Int { memory.count }
    public var spilledToDiskCount: Int { spilledCount }
    /// Versions the log had to let go of because they could neither be kept nor spilled.
    public var droppedVersionCount: Int { droppedCount }
    /// How many distinct objects the log knows about.
    public var objectCount: Int { objectsByRef.count }
    /// The sequence the next appended version will get. A cursor an exporter can come back with.
    public var nextSequenceNumber: Int { nextSequence }
    /// Where older versions are being written, once there are any. Diagnostics and tests.
    public var spillURL: URL? { spill?.url }

    // MARK: Appending

    /// Appends a batch's events in order and returns the versions they became.
    @discardableResult
    public func append(_ events: [ChangeEvent]) -> [Version] {
        guard !events.isEmpty else { return [] }
        var appended: [Version] = []
        appended.reserveCapacity(events.count)
        for event in events {
            let version = Version(sequence: nextSequence, at: event.at, event: event)
            nextSequence += 1
            memory.append(version)
            appended.append(version)
            let known = objectsByRef[event.object]
            objectsByRef[event.object] = LoggedObject(
                object: event.object,
                versions: (known?.versions ?? 0) + 1,
                firstSequence: known?.firstSequence ?? version.sequence,
                latestSequence: version.sequence,
                latestAt: version.at,
                latestKind: event.kind)
        }
        spillIfNeeded()
        return appended
    }

    @discardableResult
    public func append(_ batch: ChangeBatch) -> [Version] {
        append(batch.events)
    }

    // MARK: Reading by time (TRK-2)

    /// The newest versions first — the version list as the UI shows it.
    ///
    /// Reaches into the spill file only when memory cannot answer, so the common case is a slice of an array.
    public func recent(_ limit: Int = 200) -> [Version] {
        guard limit > 0 else { return [] }
        let held = Array(memory.suffix(limit).reversed())
        guard held.count < limit, spilledCount > 0 else { return held }
        let oldestHeld = memory.first?.sequence ?? nextSequence
        return held
            + read(
                "WHERE sequence < ? ORDER BY sequence DESC LIMIT ?",
                [.integer(Int64(oldestHeld)), .integer(Int64(limit - held.count))])
    }

    /// Versions from `sequence` upwards, oldest first — how an export walks the whole log (TRK-5) without ever
    /// holding all of it.
    public func versions(from sequence: Int, limit: Int = 500) -> [Version] {
        guard limit > 0 else { return [] }
        var result: [Version] = []
        if spilledCount > 0, sequence < (memory.first?.sequence ?? nextSequence) {
            result = read(
                "WHERE sequence >= ? ORDER BY sequence ASC LIMIT ?",
                [.integer(Int64(sequence)), .integer(Int64(limit))])
        }
        if result.count < limit {
            let start = max(sequence, result.last.map { $0.sequence + 1 } ?? sequence)
            result += memory.filter { $0.sequence >= start }.prefix(limit - result.count)
        }
        return result
    }

    // MARK: Reading by object (TRK-2)

    /// What has happened to one object, newest first.
    public func versions(of object: ObjectRef, limit: Int = 100) -> [Version] {
        guard limit > 0 else { return [] }
        let held = memory.reversed().filter { $0.object == object }.prefix(limit)
        guard held.count < limit, spilledCount > 0 else { return Array(held) }
        let oldestHeld = memory.first?.sequence ?? nextSequence
        return Array(held)
            + read(
                "WHERE entity = ? AND pk = ? AND sequence < ? ORDER BY sequence DESC LIMIT ?",
                [
                    .text(object.entity), .integer(object.pk), .integer(Int64(oldestHeld)),
                    .integer(Int64(limit - held.count)),
                ])
    }

    /// The objects the log knows about, the most recently changed first. Kept in memory whatever has spilled, so
    /// the object list of a long session is complete even when its oldest versions are on disk.
    public func objects(newestFirst: Bool = true, limit: Int? = nil) -> [LoggedObject] {
        let sorted = objectsByRef.values.sorted {
            newestFirst
                ? ($0.latestSequence, $0.object) > ($1.latestSequence, $1.object)
                : ($0.latestSequence, $0.object) < ($1.latestSequence, $1.object)
        }
        guard let limit else { return sorted }
        return Array(sorted.prefix(max(0, limit)))
    }

    public func version(_ sequence: Int) -> Version? {
        if let held = memory.first(where: { $0.sequence == sequence }) { return held }
        return read("WHERE sequence = ?", [.integer(Int64(sequence))]).first
    }

    // MARK: Emptying (TRK-9)

    /// Forgets everything and deletes the spill file. Sequence numbers carry on where they left off, so a version
    /// the user has already seen never comes back under a different number.
    public func clear() {
        memory.removeAll(keepingCapacity: true)
        objectsByRef.removeAll(keepingCapacity: true)
        spill?.destroy()
        spill = nil
        spilledCount = 0
        droppedCount = 0
        spillIsUnavailable = false
    }

    /// Finished with the log: the same as `clear()`, named for the resource it lets go of.
    public func close() {
        clear()
    }

    // MARK: Spilling

    private func spillIfNeeded() {
        guard memory.count > options.cap else { return }
        let overflow = Array(memory.prefix(memory.count - options.cap))
        memory.removeFirst(overflow.count)
        guard options.spillsToDisk, !spillIsUnavailable else {
            droppedCount += overflow.count
            return
        }
        do {
            try write(overflow)
            spilledCount += overflow.count
        } catch {
            // Once, and without the error: its text may name a path, and this is the system log (§10).
            spillIsUnavailable = true
            droppedCount += overflow.count
            log.error("The version log could not be written to disk; older versions are being dropped.")
        }
    }

    private func write(_ versions: [Version]) throws {
        let scratch = try openedSpill()
        let connection = scratch.connection
        try scratch.transaction {
            for version in versions {
                let payload = try encoder.encode(version.event)
                _ = try connection.query(
                    """
                    INSERT OR REPLACE INTO versions (sequence, at, entity, pk, payload)
                    VALUES (?, ?, ?, ?, ?)
                    """,
                    [
                        .integer(Int64(version.sequence)),
                        .real(version.at.timeIntervalSinceReferenceDate),
                        .text(version.object.entity),
                        .integer(version.object.pk),
                        .blob(payload),
                    ])
            }
        }
    }

    private func openedSpill() throws -> SQLiteScratch {
        if let spill { return spill }
        let scratch = try SQLiteScratch.temporary(name: "version-log")
        do {
            try scratch.connection.execute(
                """
                CREATE TABLE IF NOT EXISTS versions (
                    sequence INTEGER PRIMARY KEY,
                    at REAL NOT NULL,
                    entity TEXT NOT NULL,
                    pk INTEGER NOT NULL,
                    payload BLOB NOT NULL
                )
                """)
            // The object-first view asks for one row's versions, newest first; this is that query's index.
            try scratch.connection.execute(
                "CREATE INDEX IF NOT EXISTS versions_object ON versions (entity, pk, sequence)")
        } catch {
            scratch.destroy()
            throw error
        }
        spill = scratch
        return scratch
    }

    /// Runs one `SELECT` over the spilled versions. A row that cannot be decoded is left out rather than
    /// throwing: the log is a record of what happened, and one unreadable entry must not hide the rest.
    private func read(_ clause: String, _ bindings: [SQLiteValue]) -> [Version] {
        guard let spill else { return [] }
        do {
            let rows = try spill.connection.query(
                "SELECT sequence, at, payload FROM versions \(clause)", bindings)
            return rows.compactMap { row in
                guard let sequence = row[0].int64, let at = row[1].double, let payload = row[2].data,
                    let event = try? decoder.decode(ChangeEvent.self, from: payload)
                else { return nil }
                return Version(
                    sequence: Int(sequence), at: Date(timeIntervalSinceReferenceDate: at), event: event)
            }
        } catch {
            log.error("Spilled versions could not be read back.")
            return []
        }
    }
}
