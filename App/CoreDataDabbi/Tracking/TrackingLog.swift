import DabbiKit
import Foundation

/// Everything the tracker has reported this session, in the shape the window draws it (TRK-1, TRK-2, TRK-9).
///
/// A value with no view in it, so the ordering, the version rows, the strong-and-dim of a diff and the words
/// VoiceOver says are all testable without a window (ARCHITECTURE.md §11).
///
/// **Newest first.** An object that has just changed goes to the top, and its own row shows that change with the
/// fields it touched picked out, so the last thing the watched app did is the first thing on screen. What
/// happened to it before stays beneath it, which is what TRK-2 asks for: prior versions remain visible.
///
/// **Bounded, and says so.** The log holds `objectLimit` objects and `versionLimit` versions of each; what it has
/// to let go of is counted, never quietly forgotten. That is the rule the engine's `VersionLog` keeps, and
/// ADR-17's rule applied to a front end: a log that forgets in silence is worse than one that admits it.
struct TrackingLog {
    /// One change the tracker reported, numbered in the order it arrived.
    struct Version: Identifiable, Equatable {
        let sequence: Int
        let event: ChangeEvent
        /// How many commits the batch this came from stood for: 1 normally, more after a burst the watcher
        /// debounced or after a pause (TRK-9). Shown when it is not 1, so a log that coalesced never looks like
        /// one that did not.
        let coalescedCommits: Int

        var id: Int { sequence }
        var kind: ChangeEvent.Kind { event.kind }
        var at: Date { event.at }

        /// The values this version reads: what the row became, or — for a delete — the last thing anybody saw
        /// of it. `nil` when neither side is known, which is what a delete of a row nobody had read looks like.
        var values: ObjectSnapshot? { event.after ?? event.before }
    }

    /// One object the log has something about, with its versions newest first.
    struct Entry: Identifiable, Equatable {
        let object: ObjectRef
        /// Newest first, never empty.
        fileprivate(set) var versions: [Version]
        /// How many versions the entry has had, including any dropped past `versionLimit`.
        fileprivate(set) var versionCount: Int
        /// Earlier versions are shown by default (TRK-2); folding them away is the user's doing.
        var isExpanded = true

        var id: ObjectRef { object }
        /// The change the object's own row stands for. Its earlier versions are the lines beneath it.
        var latest: Version { versions[0] }
        /// What last happened to the object: the colour and the glyph of its row (TRK-1).
        var kind: ChangeEvent.Kind { latest.kind }
        var at: Date { latest.at }
        var hasDroppedVersions: Bool { versionCount > versions.count }
    }

    /// One line of the table: an object's own row — which stands for its newest change — or one of the earlier
    /// versions folded beneath it. Indices rather than copies: an object with a hundred versions must not be
    /// copied once per line it occupies.
    struct Line: Equatable {
        var entry: Int
        /// `nil` on the object's own row, which reads the same version as index 0.
        var version: Int?

        var isObject: Bool { version == nil }
    }

    /// What the footer says: the totals, counted over everything appended, dropped versions included.
    struct Counts: Equatable {
        var created = 0
        var updated = 0
        var deleted = 0
        var versions = 0
        var objects = 0

        var isEmpty: Bool { versions == 0 }
    }

    /// Objects kept. The oldest to have changed go first; the tracker's own log keeps the versions.
    var objectLimit = 2_000
    /// Versions kept per object.
    var versionLimit = 200

    private(set) var entries: [Entry] = []
    private(set) var lines: [Line] = []
    private(set) var counts = Counts()
    /// Objects and versions the log had to let go of, so the footer can say the list is not the whole session.
    private(set) var droppedObjects = 0
    private(set) var droppedVersions = 0

    private var indexByObject: [ObjectRef: Int] = [:]
    /// 1-based and monotonic for the life of the window, and deliberately not reset by `clear()`: a version the
    /// user has already seen must never come back under a number they have also seen.
    private var nextSequence = 1

    var isEmpty: Bool { entries.isEmpty }
    var lineCount: Int { lines.count }

    // MARK: Reading

    func entry(at line: Int) -> Entry? {
        guard let line = self.line(at: line) else { return nil }
        return entries[line.entry]
    }

    func version(at line: Int) -> Version? {
        guard let line = self.line(at: line), let version = line.version else { return nil }
        return entries[line.entry].versions[version]
    }

    func line(at index: Int) -> Line? {
        lines.indices.contains(index) ? lines[index] : nil
    }

    func object(at line: Int) -> ObjectRef? { entry(at: line)?.object }

    /// Where an object's own row is now — how a selection is kept while the rows move under it.
    func line(of object: ObjectRef) -> Int? {
        guard let entry = indexByObject[object] else { return nil }
        return lines.firstIndex { $0.entry == entry && $0.isObject }
    }

    // MARK: Appending

    mutating func append(_ batch: ChangeBatch) {
        guard !batch.events.isEmpty else { return }
        for event in batch.events { record(event, coalescing: batch.coalescedCommits) }
        rebuildLines()
    }

    mutating func append(_ event: ChangeEvent, coalescing commits: Int = 1) {
        record(event, coalescing: commits)
        rebuildLines()
    }

    private mutating func record(_ event: ChangeEvent, coalescing commits: Int) {
        let version = Version(sequence: nextSequence, event: event, coalescedCommits: max(1, commits))
        nextSequence += 1
        counts.versions += 1
        switch event.kind {
        case .inserted: counts.created += 1
        case .updated: counts.updated += 1
        case .deleted: counts.deleted += 1
        }

        if let index = indexByObject[event.object] {
            var entry = entries.remove(at: index)
            entry.versions.insert(version, at: 0)
            entry.versionCount += 1
            if entry.versions.count > versionLimit {
                droppedVersions += entry.versions.count - versionLimit
                entry.versions.removeLast(entry.versions.count - versionLimit)
            }
            entries.insert(entry, at: 0)
        } else {
            entries.insert(
                Entry(object: event.object, versions: [version], versionCount: 1), at: 0)
        }
        // Evicted before the index is rebuilt, so that the count the footer shows is the count of what the log
        // is actually holding.
        evictIfNeeded()
        reindex()
    }

    private mutating func evictIfNeeded() {
        guard entries.count > objectLimit else { return }
        let removed = entries.count - objectLimit
        entries.removeLast(removed)
        droppedObjects += removed
    }

    private mutating func reindex() {
        indexByObject.removeAll(keepingCapacity: true)
        for (index, entry) in entries.enumerated() { indexByObject[entry.object] = index }
        counts.objects = entries.count
    }

    private mutating func rebuildLines() {
        lines.removeAll(keepingCapacity: true)
        for (index, entry) in entries.enumerated() {
            // The object's row is its newest change, drawn in full; the earlier versions follow it. Listing
            // the newest one again beneath its own row would put an identical line under every change.
            lines.append(Line(entry: index, version: nil))
            guard entry.isExpanded else { continue }
            for version in entry.versions.indices.dropFirst() {
                lines.append(Line(entry: index, version: version))
            }
        }
    }

    // MARK: Folding and emptying (TRK-9)

    mutating func setExpanded(_ expanded: Bool, ofEntryAt index: Int) {
        guard entries.indices.contains(index), entries[index].isExpanded != expanded else { return }
        entries[index].isExpanded = expanded
        rebuildLines()
    }

    mutating func toggleExpanded(ofEntryAt index: Int) {
        guard entries.indices.contains(index) else { return }
        setExpanded(!entries[index].isExpanded, ofEntryAt: index)
    }

    /// Empties the contents and not the counter (TRK-9): the next version keeps the number it would have had.
    mutating func clear() {
        entries.removeAll()
        lines.removeAll()
        indexByObject.removeAll()
        counts = Counts()
        droppedObjects = 0
        droppedVersions = 0
    }
}
