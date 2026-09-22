import DabbiBase
import DabbiModel
import DabbiSQLite
import DabbiStore
import Foundation

/// Watches a store somebody else is writing and says what changed, row by row and field by field
/// (ARCHITECTURE.md §6.6, TRK-1, TRK-2, TRK-7, TRK-9).
///
/// The last stage of the tracker chain, and the one the app talks to:
///
/// 1. `StoreWatcher` — *something* committed, and nothing but a `PRAGMA data_version` was spent finding out.
/// 2. `ChangeScanner` — *which rows*, from primary keys and save counters alone.
/// 3. this — *what about them*: the objects materialised on the store session's tracking context, the fields that
///    differ, the to-many links that moved, whether the row came into or went out of the view being watched, and a
///    `VersionLog` entry for each.
///
/// Three things it will not do:
///
/// - **Guess.** A row nobody had read before it changed has no before-values, and says so. A view whose membership
///   was too large to prime reports no transition for a row it cannot place, rather than a likely one.
/// - **Merge silently.** Every batch says how many commits it stands for, so a burst the watcher debounced and the
///   commits that arrived while tracking was paused are both visible as what they are.
/// - **Hold the store.** Nothing here writes, and no read transaction outlives one scan, so the app being watched
///   can checkpoint and commit throughout.
///
/// Costs, for a store of a million rows: about 20 MB of primary keys, plus the values of the entities small enough
/// to prime (`Options.primeUpTo`), plus what the front end hands over from what the user is looking at
/// (`remember(_:)`). The version log keeps its newest 10 000 rows in memory and spills the rest.
public actor ChangeTracker {
    public struct Options: Sendable, Hashable {
        /// Entities with at most this many rows of their own have their values read at the start, so the first
        /// change to any of their rows can be shown as before → after. Larger entities are not read: a million
        /// rows of values is minutes and gigabytes to have ready for a change that may never come.
        public var primeUpTo: Int = 50_000
        /// Objects per Core Data round trip while materialising.
        public var materialiseBatch: Int = 500
        /// How many rows' values to hold at once. The oldest arrivals are dropped first, and a change to a row
        /// whose values were dropped reads as *changed — prior value unknown*.
        public var priorValueLimit: Int = 100_000
        public var versions = VersionLog.Options()
        /// Copies the store when tracking starts, so that *every* row's prior value is knowable — at the cost of
        /// the copy. Off by default; see `deepTrackingIsActive` for whether it took.
        public var deepTracking = false
        public var watcher = StoreWatcher.Options()
        public var scanner = ChangeScanner.Options()
        /// Persistent history enrichment: who saved, when, and which fields (TRK-10).
        public var history = History()

        public init() {}
    }

    /// What the tracker is holding, for the diagnostics pane and for tests.
    public struct Statistics: Sendable, Hashable {
        public var isTracking: Bool
        public var isPaused: Bool
        /// Rows whose values are held, so a change to them can be shown as before → after.
        public var heldRows: Int
        /// Primary keys the scan remembers, and what remembering them costs.
        public var heldKeys: Int
        public var heldKeyBytes: Int
        /// Commits noticed but not yet reported — always 0 unless tracking is paused or a scan is under way.
        public var pendingCommits: Int
        /// What cannot be tracked exactly for this store and scope.
        public var limitations: [ScanLimitation]
        public var deepTrackingIsActive: Bool
        /// Which of the two history readers is in use, or `nil` when the store records none, when reading it
        /// failed, or when the option is off. Never `nil` silently: a store that tracks history and will not be
        /// read reports a `historyUnavailable` limitation on every batch.
        public var historySource: HistorySource?
        /// The last failure, if any. Tracking carries on after one: the scanner keeps its baseline when a scan
        /// fails, so the next commit reports what this one could not — late, not lost.
        public var lastFailure: DabbiError?
    }

    /// Every change reported so far (TRK-2). Kept across `stop()`, because the user is still reading it; emptied by
    /// `VersionLog.clear()` (TRK-9).
    public nonisolated let versions: VersionLog
    public nonisolated let options: Options

    private let session: StoreSession
    private let watcher: StoreWatcher
    private let model: ModelDescription
    private let log = DabbiLog.logger(.tracking)

    private var scanner: ChangeScanner?
    private var scope = TrackingScope.allEntities
    private var trackedEntities: Set<String> = []
    private var prior: PriorValues
    private var subscribers: [UUID: AsyncStream<ChangeBatch>.Continuation] = [:]
    private var pump: Task<Void, Never>?
    private var tracking = false
    private var paused = false
    private var isDraining = false
    private var pendingCommits = 0
    private var pendingSince: Date?
    private var pendingReplacement = false
    private var deep: DeepStore?
    private var failure: DabbiError?
    private var history: (any HistoryReader)?
    private var historyToken: HistoryToken?
    private var historyFailed = false

    /// - Parameter session: the store to track, already open. Materialising uses its tracking context, which is
    ///   separate from the one the grid pages with, so neither waits for the other.
    public init(session: StoreSession, options: Options = .init()) {
        self.session = session
        self.options = options
        self.model = session.info.model
        self.watcher = StoreWatcher(url: session.info.url, options: options.watcher)
        self.versions = VersionLog(options: options.versions)
        self.prior = PriorValues(limit: options.priorValueLimit)
    }

    // MARK: State

    public var isTracking: Bool { tracking }
    public var isPaused: Bool { paused }
    /// Whether the store was copied for prior values. False when deep tracking was not asked for, and when it was
    /// asked for and the copy could not be made.
    public var deepTrackingIsActive: Bool { deep != nil }

    public func statistics() async -> Statistics {
        Statistics(
            isTracking: tracking,
            isPaused: paused,
            heldRows: prior.count,
            heldKeys: await scanner?.heldRows ?? 0,
            heldKeyBytes: await scanner?.heldBytes ?? 0,
            pendingCommits: pendingCommits,
            limitations: await scanner?.limitations ?? [],
            deepTrackingIsActive: deep != nil,
            historySource: historyFailed ? nil : history?.source,
            lastFailure: failure)
    }

    // MARK: Starting and stopping (TRK-1)

    /// Starts watching, and returns the batches — one per commit.
    ///
    /// Not a cheap call, and not meant to be: it reads every tracked table's keys for a baseline, reads the values
    /// of the entities small enough to prime, and, when deep tracking is on, copies the store. What comes back
    /// stays alive until `stop()`; dropping it stops delivery, not tracking, so the version log keeps filling.
    ///
    /// Called again while tracking, it returns another stream onto the same pipeline. The scope of the first call
    /// stands until `stop()`.
    @discardableResult
    public func start(_ scope: TrackingScope = .allEntities) async throws -> AsyncStream<ChangeBatch> {
        guard !tracking else { return subscribe() }
        self.scope = scope
        self.trackedEntities = Set(scope.resolved(in: model))
        prior = PriorValues(limit: options.priorValueLimit)
        failure = nil

        // Before the baseline, so that everything the first scan reports is something history can still be asked
        // about. A token taken afterwards would stand past saves the scan is about to call news.
        await openHistory()

        // The copy is taken before the baseline: a commit landing between the two is then one the scan still
        // reports, and its before-values come from a file that predates it.
        if options.deepTracking { await openDeepStore() }

        let scanner = ChangeScanner(
            url: session.info.url, model: model, schema: session.info.schemaMap, scope: scope,
            options: options.scanner)
        self.scanner = scanner
        try await scanner.prime()
        await primeValues()

        let commits = try await watcher.commits()
        tracking = true
        paused = false
        pump = Task { [weak self] in
            for await commit in commits {
                guard let self else { return }
                await self.noticed(commit)
            }
        }
        return subscribe()
    }

    /// Stops watching, finishes every stream and lets go of everything held about the store. The version log stays.
    public func stop() async {
        tracking = false
        paused = false
        pump?.cancel()
        pump = nil
        await watcher.stop()
        await scanner?.close()
        scanner = nil
        prior.removeAll()
        await closeDeepStore()
        await closeHistory()
        pendingCommits = 0
        pendingSince = nil
        pendingReplacement = false
        for continuation in subscribers.values { continuation.finish() }
        subscribers.removeAll()
    }

    /// Stops reading the store without losing the thread of the session (TRK-9).
    ///
    /// Commits are still noticed and counted while paused; nothing is scanned and nothing is fetched. `resume()`
    /// runs one scan that reports the net difference — a row inserted and deleted again while paused is not news —
    /// and the batch it delivers says how many commits it stands for.
    public func pause() {
        paused = true
    }

    public func resume() async {
        guard tracking, paused else { return }
        paused = false
        await drain()
    }

    // MARK: What the front end already knows

    /// Remembers rows the front end has just shown, so that when they change the tracker can say what they were.
    ///
    /// This is the cheap half of prior values, and what makes before-values work on a store too large to prime: the
    /// grid has these rows anyway (§6.6).
    public func remember(_ page: RowPage) {
        prior.remember(page)
    }

    public func remember(_ object: ObjectSnapshot) {
        prior.remember(object)
    }

    // MARK: The pipeline

    private func subscribe() -> AsyncStream<ChangeBatch> {
        let id = UUID()
        let (stream, continuation) = AsyncStream<ChangeBatch>.makeStream()
        subscribers[id] = continuation
        continuation.onTermination = { [weak self] _ in Task { await self?.unsubscribe(id) } }
        return stream
    }

    private func unsubscribe(_ id: UUID) {
        subscribers[id] = nil
    }

    private func noticed(_ commit: StoreCommit) async {
        guard tracking else { return }
        pendingCommits += 1
        if pendingSince == nil { pendingSince = commit.noticedAt }
        if commit.kind == .storeReplaced { pendingReplacement = true }
        guard !paused else { return }
        await drain()
    }

    /// Reports every pending commit, one batch at a time.
    ///
    /// Reentrant on purpose: a commit that lands while a scan is in flight adds to the pending count and this loop
    /// picks it up, rather than starting a second scan against the same connection.
    private func drain() async {
        guard !isDraining else { return }
        isDraining = true
        defer { isDraining = false }

        while tracking, !paused, pendingCommits > 0 {
            let commits = pendingCommits
            let noticedAt = pendingSince ?? Date()
            let replaced = pendingReplacement
            pendingCommits = 0
            pendingSince = nil
            pendingReplacement = false

            if replaced {
                let batch = await replacedBatch(coalescing: commits, noticedAt: noticedAt)
                deliver(batch)
                // The file being watched is gone; so is the usefulness of a session reading it. The front end
                // reopens the store and starts a new tracker.
                await stop()
                return
            }
            do {
                let batch = try await nextBatch(coalescing: commits, noticedAt: noticedAt)
                await versions.append(batch)
                deliver(batch)
                failure = nil
            } catch {
                // The scanner keeps its baseline when a scan fails, so nothing is lost: the next commit reports
                // what this one could not. Codes and names only in the log — never a value (§10).
                let error = error as? DabbiError ?? DabbiError(.internal, "A change could not be read.")
                failure = error
                log.error("A change could not be read: \(error.code.rawValue, privacy: .public)")
                return
            }
        }
    }

    private func deliver(_ batch: ChangeBatch) {
        for continuation in subscribers.values { continuation.yield(batch) }
    }

    private func nextBatch(coalescing commits: Int, noticedAt: Date) async throws -> ChangeBatch {
        guard let scanner else { throw DabbiError(.internal, "The tracker is not running.") }
        // History first, so that what it holds is a subset of what the scan is about to see. The other order
        // would move the token past saves this batch does not report, and their author would be gone for good.
        // This way the worst case is a save landing between the two: reported without an author, and said so.
        let (digest, advanced) = await historyDigest()
        let raw = try await scanner.scan()
        // Only now, because a scan that threw is one whose rows will be reported by the next scan instead — and
        // they will still need the transactions this read took out.
        if let advanced { historyToken = advanced }
        let materialiseStart = ContinuousClock.now
        let materialised = try await events(for: raw, history: digest, at: Date())
        let materialiseDuration = materialiseStart.duration(to: ContinuousClock.now)
        let now = Date()
        return ChangeBatch(
            at: now,
            kind: .commit,
            events: materialised.events,
            limitations: raw.limitations + materialised.limitations,
            coalescedCommits: commits,
            scanDuration: raw.duration,
            materialiseDuration: materialiseDuration,
            latency: .seconds(max(0, now.timeIntervalSince(noticedAt))))
    }

    /// The store file was replaced, so everything held is about a file that is not there any more (Appendix D).
    private func replacedBatch(coalescing commits: Int, noticedAt: Date) async -> ChangeBatch {
        let limitations = await scanner?.limitations ?? []
        await session.invalidate()
        let now = Date()
        return ChangeBatch(
            at: now, kind: .storeReplaced, events: [], limitations: limitations, coalescedCommits: commits,
            latency: .seconds(max(0, now.timeIntervalSince(noticedAt))))
    }

    // MARK: Materialising (§6.6)

    /// What materialising produced: the events, and what history could not account for.
    private struct Materialised {
        var events: [ChangeEvent] = []
        var limitations: [ScanLimitation] = []
    }

    private func events(
        for raw: RawChangeSet, history digest: HistoryDigest, at time: Date
    ) async throws -> Materialised {
        guard let scanner, !raw.isEmpty else { return Materialised() }

        // Links first. A join table names the entity the relationship *declares*, and for an inheritance
        // hierarchy the row on either end may be a sub-entity; the scan read `Z_ENT` beside the key, so it can say
        // which. Materialising needs the row's own entity: that is the layout its values come back in.
        var links = raw.links
        if !links.isEmpty {
            let resolved = await scanner.resolved(links.flatMap { [$0.source, $0.destination] })
            for index in links.indices {
                links[index].source = resolved[index * 2]
                links[index].destination = resolved[index * 2 + 1]
            }
        }

        // A many-to-many link lives in the join table, and gaining or losing one need not touch either row's save
        // counter — so the rows at its ends are not always in `updated`. They changed all the same.
        let reported = Set(raw.allRows)
        let touched = Set(
            links.flatMap { [$0.source, $0.destination] }
                .filter { !reported.contains($0) && trackedEntities.contains($0.entity) })

        let insertedRows = raw.inserted
        let updatedRows = raw.updated + touched.sorted()
        let deletedRows = raw.deleted

        let insertedRefs = insertedRows.compactMap(reference)
        let updatedRefs = updatedRows.compactMap(reference)
        let deletedRefs = deletedRows.compactMap(reference)

        let materialised = try await session.objects(
            insertedRefs + updatedRefs, matching: scope.predicate, batchSize: options.materialiseBatch)
        let fromDeepStore = await deepSnapshots(
            of: (updatedRefs + deletedRefs).filter { prior.snapshot(of: $0) == nil })

        func before(_ ref: ObjectRef) -> ObjectSnapshot? { prior.snapshot(of: ref) ?? fromDeepStore[ref] }

        var linksByRow: [RowID: [LinkChange]] = [:]
        for change in links {
            linksByRow[change.source, default: []].append(change)
            if change.destination != change.source { linksByRow[change.destination, default: []].append(change) }
        }

        let hasPredicate = scope.predicate != nil
        var events: [ChangeEvent] = []
        events.reserveCapacity(insertedRows.count + updatedRows.count + deletedRows.count)

        for row in insertedRows {
            guard let ref = reference(row) else { continue }
            let object = materialised[ref]
            // A row that never belonged to the watched view is not news to somebody looking at it.
            if hasPredicate, object?.matchesPredicate == false { continue }
            events.append(
                ChangeEvent(
                    object: ref, kind: .inserted, after: object?.snapshot, links: linksByRow[row] ?? [],
                    transition: transition(was: false, now: object?.matchesPredicate, hasPredicate: hasPredicate),
                    history: digest[row]?.info, at: time))
        }

        for row in updatedRows {
            guard let ref = reference(row) else { continue }
            let object = materialised[ref]
            let was = prior.matched(ref)
            let now = object?.matchesPredicate
            if hasPredicate, was != true, now != true { continue }
            let before = before(ref)
            let entry = digest[row]
            var changedKeys: Set<String>?
            if let before, let after = object?.snapshot {
                let diff = FieldDiff.compare(before, after)
                // Nothing in common between the two readings is not the same as nothing changed.
                changedKeys = diff.isEmpty ? nil : diff.changed
            }
            if changedKeys == nil, let named = entry?.updatedProperties, !named.isEmpty {
                // The gap M2-09 left open: nobody held what this row used to be, so there is nothing to diff —
                // but the save itself recorded which fields it wrote, and those are the fields to mark. Prior
                // values stay unknown; `before` is still `nil` and the UI still says so for each of them.
                //
                // Only when there was no diff to make. A diff that could be made is the one that is shown,
                // because the diff is about values and history is about what a save wrote: a save that wrote a
                // field the same value it already held changed nothing, and the diff is the one that knows it.
                changedKeys = named
            }
            events.append(
                ChangeEvent(
                    object: ref, kind: .updated, before: before, after: object?.snapshot,
                    changedKeys: changedKeys, links: linksByRow[row] ?? [],
                    transition: transition(was: was, now: now, hasPredicate: hasPredicate),
                    history: entry?.info, at: time))
        }

        for row in deletedRows {
            guard let ref = reference(row) else { continue }
            let was = prior.matched(ref)
            if hasPredicate, was == false { continue }
            let entry = digest[row]
            // A row nobody ever read is gone with everything it held — except what the model asked history to
            // keep of it. That is the only prior value there will ever be for it, so it is shown, labelled.
            var priorValues = before(ref)
            var isTombstone = false
            if priorValues == nil, let preserved = entry?.tombstoneSnapshot(for: ref) {
                priorValues = preserved
                isTombstone = true
            }
            events.append(
                ChangeEvent(
                    object: ref, kind: .deleted, before: priorValues, links: linksByRow[row] ?? [],
                    transition: hasPredicate && was == true ? .left : nil, history: entry?.info,
                    beforeIsTombstone: isTombstone, at: time))
        }

        // What was just read is what the next change is measured against. A row that was reported but could not be
        // read keeps whatever was held about it: that is still the last thing anybody saw of it.
        for (ref, object) in materialised {
            prior.remember(object.snapshot)
            prior.note(ref, matches: object.matchesPredicate)
        }
        for ref in deletedRefs { prior.forget(ref) }
        // Only the rows the scan itself reported. A row pulled in because a link at its end moved need not have
        // been saved at all, so history owing nothing for it says nothing about history.
        let scanned = raw.inserted + raw.updated + raw.deleted
        return Materialised(events: events, limitations: historyLimitations(for: scanned, digest: digest))
    }

    private nonisolated func reference(_ row: RowID) -> ObjectRef? {
        session.reference(entity: row.entity, pk: row.pk)
    }

    /// `nil` unless the object really crossed the view's boundary. A prior side nobody knows gives no transition —
    /// the row is still reported, because the view holds it now, but it is not claimed to have just arrived.
    private func transition(was: Bool?, now: Bool?, hasPredicate: Bool) -> PredicateTransition? {
        guard hasPredicate, let was, let now, was != now else { return nil }
        return now ? .entered : .left
    }

    // MARK: Priming

    /// Reads what the first change will be compared against: the values of the entities small enough to read
    /// whole, and which rows the watched view holds (TRK-7).
    ///
    /// An entity with more rows than `Options.primeUpTo` is not read at all — the front end hands over the rows the
    /// user is actually looking at instead — but its *membership* still is, when there is a predicate, because
    /// identities are cheap and without them no transition can be told from a change.
    ///
    /// Nothing here is fatal. An entity that cannot be primed is one whose rows start out unknown, which the events
    /// about them say.
    private func primeValues() async {
        guard !trackedEntities.isEmpty else { return }
        var counts: [String: Int] = [:]
        do {
            for count in try await session.entityCounts() { counts[count.entity] = count.own }
        } catch {
            log.notice("The store's row counts could not be read; prior values start out unknown.")
            return
        }

        var members: [ObjectRef] = []
        var membershipIsComplete = scope.predicate != nil
        for entity in trackedEntities.sorted() {
            let rows = counts[entity] ?? 0
            guard rows > 0 else { continue }
            do {
                if rows <= options.primeUpTo {
                    let refs = try await session.references(
                        FetchSpec(entity: entity, includeSubentities: false), limit: options.primeUpTo + 1)
                    guard refs.count <= options.primeUpTo else {
                        // It grew between the count and the fetch. Treat it as the large entity it now is.
                        membershipIsComplete = false
                        continue
                    }
                    let objects = try await session.objects(
                        refs, matching: scope.predicate, batchSize: options.materialiseBatch)
                    for (ref, object) in objects {
                        prior.remember(object.snapshot)
                        if object.matchesPredicate == true { members.append(ref) }
                    }
                } else if let predicate = scope.predicate {
                    // Identities only: which rows the view holds, without reading a single value.
                    let refs = try await session.references(
                        FetchSpec(entity: entity, includeSubentities: false, predicate: predicate),
                        limit: options.primeUpTo + 1)
                    if refs.count > options.primeUpTo {
                        membershipIsComplete = false
                    } else {
                        members += refs
                    }
                }
            } catch {
                membershipIsComplete = false
                log.notice("\(entity, privacy: .public) could not be primed; its rows start out unknown.")
            }
        }
        prior.noteMembers(members, isComplete: membershipIsComplete)
    }

    // MARK: Persistent history (TRK-10)

    /// Opens a history reader, when there is one to open, and marks where the store's history stands now.
    ///
    /// Nothing here is fatal and nothing here is silent. A store that records no history gets no reader and no
    /// complaint — that is most stores. A store that *does* record history and will not be read gets no reader
    /// and a `historyUnavailable` limitation on every batch, because on that store the missing author is news.
    private func openHistory() async {
        historyFailed = false
        historyToken = nil
        guard options.history.isEnabled else { return }
        history = await HistoryReaders.open(for: session, preferring: options.history.preferring)
        guard let reader = history else {
            if session.tracksHistory {
                log.notice("This store records persistent history and neither reader could read it.")
            }
            return
        }
        // The starting mark. Without it the first batch would carry the store's whole history, and a batch that
        // reports one commit would be attributed to a save from last year.
        historyToken = try? await reader.currentToken()
        log.notice("History enrichment is on, through \(reader.source.rawValue, privacy: .public).")
    }

    private func closeHistory() async {
        await history?.close()
        history = nil
        historyToken = nil
        historyFailed = false
    }

    /// The transactions since the last batch, folded by row, and the token they end at.
    ///
    /// The token is returned rather than stored so the caller can hold it back until the scan that goes with it
    /// has succeeded: transactions consumed for a batch that never arrived are attribution thrown away.
    private func historyDigest() async -> (HistoryDigest, HistoryToken?) {
        guard let reader = history else { return (HistoryDigest(), nil) }
        let cap = max(1, options.history.maxTransactions)
        do {
            // One more than the cap, so that having hit it is a fact and not a suspicion.
            var transactions = try await reader.transactions(after: historyToken, limit: cap + 1)
            let isTruncated = transactions.count > cap
            if isTruncated { transactions.removeFirst(transactions.count - cap) }
            historyFailed = false
            return (HistoryDigest(transactions, isTruncated: isTruncated), transactions.last?.token)
        } catch {
            // The token stays where it was, so the next batch asks for these transactions again. Late, not lost —
            // and meanwhile every batch says its changes arrived without an author. Codes only, never a value (§10).
            if !historyFailed {
                let code = (error as? DabbiError)?.code.rawValue ?? "unknown"
                log.notice("The store's persistent history could not be read: \(code, privacy: .public)")
            }
            historyFailed = true
            return (HistoryDigest(), nil)
        }
    }

    /// What the batch has to admit about its history.
    ///
    /// Silent on a store that records none: reporting a missing author on every batch of every ordinary store
    /// would make `isReducedFidelity` mean nothing. Loud on a store that records history and did not deliver it.
    private func historyLimitations(for rows: [RowID], digest: HistoryDigest) -> [ScanLimitation] {
        guard options.history.isEnabled, session.tracksHistory, !rows.isEmpty else { return [] }
        guard history != nil, !historyFailed else {
            return [ScanLimitation(reason: .historyUnavailable, subject: "ATRANSACTION")]
        }
        return digest.limitations(accountingFor: rows)
    }

    // MARK: Deep tracking (§6.6)

    /// The store as it was when tracking started, so that *any* row's prior values are knowable — not only the
    /// rows that were primed or paged in.
    private struct DeepStore {
        /// Ours, and deleted with the tracker.
        let directory: URL
        let session: StoreSession
    }

    /// Copies the store with SQLite's online backup — the app being watched can carry on writing throughout — and
    /// opens the copy read-only.
    ///
    /// The copy keeps the store's UUID, so an `ObjectRef` means the same row in both. What it does not keep is
    /// external binary data: a blob the model stores beside the store is not in the copy and reads as missing
    /// there, which is why a deep reading leaves those attributes out altogether (`withoutExternalBlobs`) rather
    /// than report a blob nobody touched as emptied. Deep tracking is off by default; nothing about it is silent
    /// (`deepTrackingIsActive`).
    private func openDeepStore() async {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("coredatadabbi-deep-\(UUID().uuidString)", isDirectory: true)
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let copy = directory.appendingPathComponent(session.info.url.lastPathComponent)
            let reader = try SQLiteReader(url: session.info.url)
            do {
                try await reader.read { try SQLiteBackup.copy(from: $0, to: copy) }
            } catch {
                await reader.close()
                throw error
            }
            await reader.close()
            deep = DeepStore(
                directory: directory,
                session: try await StoreSession.open(storeURL: copy, modelURL: modelURLForDeepStore()))
            log.notice("Deep tracking is on: the store was copied, so every row's prior values are known.")
        } catch {
            try? FileManager.default.removeItem(at: directory)
            log.notice("Deep tracking could not copy the store; prior values are the ones that have been read.")
        }
    }

    /// The copy carries Core Data's own model cache, so nothing extra is needed for most stores. A store opened
    /// with a model the user pointed at is opened with that same model.
    private nonisolated func modelURLForDeepStore() -> URL? {
        switch session.info.modelSource {
        case .userSelected(let files): return files.first
        case .appBundle(let bundle, _): return bundle
        case .storeCache: return nil
        }
    }

    private func closeDeepStore() async {
        guard let deep else { return }
        self.deep = nil
        await deep.session.close()
        try? FileManager.default.removeItem(at: deep.directory)
    }

    /// The prior values of rows nobody had read, from the copy. Empty without deep tracking.
    private func deepSnapshots(of refs: [ObjectRef]) async -> [ObjectRef: ObjectSnapshot] {
        guard let deep, !refs.isEmpty else { return [:] }
        do {
            let objects = try await deep.session.objects(refs, batchSize: options.materialiseBatch)
            return objects.mapValues { withoutExternalBlobs($0.snapshot) }
        } catch {
            return [:]
        }
    }

    /// Binary attributes Core Data may keep in files beside the store, by entity. The copy is the database alone,
    /// so these are the attributes a deep reading cannot speak for.
    private lazy var externalBlobs: [String: Set<String>] = {
        var result: [String: Set<String>] = [:]
        for entity in model.entities {
            let names = entity.attributes.filter(\.allowsExternalBinaryDataStorage).map(\.name)
            if !names.isEmpty { result[entity.name] = Set(names) }
        }
        return result
    }()

    /// A reading of the copy with those attributes dropped. Dropped, not nulled: a field the two readings do not
    /// both carry is one `FieldDiff` does not compare (§6.6), so the blob is reported as *unknown* — which it is —
    /// instead of as a value that went away with the file it was in.
    private func withoutExternalBlobs(_ snapshot: ObjectSnapshot) -> ObjectSnapshot {
        guard let excluded = externalBlobs[snapshot.row.ref.entity] else { return snapshot }
        let kept = snapshot.columns.properties.filter { !excluded.contains($0) }
        guard kept.count != snapshot.columns.properties.count else { return snapshot }
        return ObjectSnapshot(
            row: RowSnapshot(ref: snapshot.row.ref, values: kept.map { snapshot[$0] ?? .null }),
            columns: ColumnSet(kept), generation: snapshot.generation)
    }
}
