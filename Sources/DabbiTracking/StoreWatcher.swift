import DabbiBase
import DabbiSQLite
import Foundation

/// Somebody else committed to the store, as the watcher noticed it.
public struct StoreCommit: Sendable, Hashable {
    public enum Kind: String, Sendable, Hashable, Codable {
        /// Another connection committed. Ask the store what changed.
        case commit
        /// The store *file* was replaced — a reinstall, a restore, a copy put back. Every primary key, token
        /// and prior value cached about the old file is about a file that no longer exists.
        case storeReplaced
    }

    public var kind: Kind
    /// `PRAGMA data_version` as it now reads; `nil` when the store could not be asked, which happens while it
    /// is being replaced.
    public var dataVersion: Int64?
    public var noticedAt: Date

    public init(kind: Kind = .commit, dataVersion: Int64?, noticedAt: Date = Date()) {
        self.kind = kind
        self.dataVersion = dataVersion
        self.noticedAt = noticedAt
    }
}

/// Says when another process commits to a store, and says it cheaply (ARCHITECTURE.md §6.6).
///
/// Three ways of noticing, in order of how much they cost:
///
/// 1. **File events.** A `DispatchSource` on the store, its `-wal` and its `-shm`. A WAL commit only appends to
///    the `-wal`, so that is usually the one that fires.
/// 2. **Folder events.** One FSEvents stream on the store's folder, because a file can be replaced by another
///    of the same name — a reinstall, a restore, a copy put back — and a source on a deleted vnode is deaf.
///    Every settling re-arms whatever is missing.
/// 3. **Polling**, if `Options.pollInterval` says so. Insurance for a file system that reports nothing; the two
///    event paths cover every local one.
///
/// Whatever wakes it, the watcher answers the same question before it says anything: has `PRAGMA data_version`
/// changed? It changes only when a *different* connection commits, so a `-wal` that grew because the app opened
/// the store, a checkpoint, an `-shm` rebuilt by a reader — none of them reach a subscriber. That gate is one
/// pragma on a long-lived read-only connection that never holds a transaction open, so it never pins the WAL and
/// never stops the inspected app from checkpointing.
///
/// The gate connection is only good for the three files it was opened onto (Appendix D). A connection opened
/// while the store had no `-wal` is not in WAL mode and would never see a WAL commit, so when any of the three
/// is replaced — the app opening a store that had no log, a reinstall, a restore — the connection is opened
/// again before the gate is believed.
public actor StoreWatcher {
    public struct Options: Sendable, Hashable {
        /// Events are coalesced for this long before the gate is read, so a burst of writes costs one read. The
        /// tracker's latency budget (§6.6) starts here.
        public var debounce: Duration = .milliseconds(150)
        /// FSEvents coalescing for the store's folder. Only recreations need this path, so it can be slow; the
        /// per-file sources are the fast one.
        public var folderLatency: TimeInterval = 0.25
        /// Reads the gate on a timer as well. Cheap — one pragma — and it bounds how long a change can go
        /// unnoticed on a file system that does not report events. `nil` turns it off.
        public var pollInterval: Duration? = .seconds(2)
        /// How many further rounds to give a gate read that failed. A read fails when a rollback-journal writer
        /// holds the lock for longer than the busy timeout, or when the store is caught mid-replacement.
        public var readAttempts: Int = 3

        public init() {}
    }

    /// The store, as the watcher was asked for it. Its `-wal` and `-shm` are watched with it.
    public nonisolated let url: URL
    public nonisolated let options: Options

    private let queue = DispatchQueue(label: "org.coredatadabbi.store-watcher", qos: .utility)
    private let log = DabbiLog.logger(.tracking)

    private var sources: [String: FileEventSource] = [:]
    private var folder: DirectoryWatcher?
    private var poller: Task<Void, Never>?
    private var pump: Task<Void, Never>?
    private var subscribers: [UUID: AsyncStream<StoreCommit>.Continuation] = [:]

    private var reader: SQLiteReader?
    private var files = StoreFiles()
    private var lastVersion: Int64?
    private var isPending = false
    private var attemptsLeft: Int
    private var isStarted = false

    /// The store and the two files SQLite keeps beside it.
    private static let suffixes = ["", "-wal", "-shm"]

    public init(url: URL, options: Options = .init()) {
        self.url = url
        self.options = options
        self.attemptsLeft = options.readAttempts
    }

    /// The last `PRAGMA data_version` the watcher read. Diagnostics only.
    public var dataVersion: Int64? { lastVersion }

    /// Commits by other connections, coalesced.
    ///
    /// The first subscriber opens the gate connection — which is what can fail, and fails for the same reasons
    /// opening the store for reading does — and arms the events. When the last stream is finished the watching
    /// stops again.
    public func commits() async throws -> AsyncStream<StoreCommit> {
        try await start()
        let id = UUID()
        let (stream, continuation) = AsyncStream<StoreCommit>.makeStream()
        subscribers[id] = continuation
        continuation.onTermination = { [weak self] _ in Task { await self?.unsubscribe(id) } }
        return stream
    }

    /// Closes everything and finishes every stream. Watching starts again with the next `commits()`.
    public func stop() async {
        isStarted = false
        poller?.cancel()
        poller = nil
        pump?.cancel()
        pump = nil
        isPending = false
        for source in sources.values { source.cancel() }
        sources.removeAll()
        folder?.stop()
        folder = nil
        await closeReader()
        files = StoreFiles()
        lastVersion = nil
        for continuation in subscribers.values { continuation.finish() }
        subscribers.removeAll()
    }

    deinit {
        poller?.cancel()
        pump?.cancel()
    }

    // MARK: Starting and stopping

    private func start() async throws {
        guard !isStarted else { return }
        let reader = try SQLiteReader(url: url, options: Self.gateOptions)
        isStarted = true
        isPending = false
        self.reader = reader
        files = StoreFiles(url)
        // The store as it is now is not news. A read that fails here — a writer holding the lock at just this
        // moment — leaves the baseline unknown, and the first event then counts as a commit rather than risking
        // a real one being taken for the baseline.
        lastVersion = try? await reader.read { try $0.dataVersion() }
        arm()
        startPolling()
    }

    private func unsubscribe(_ id: UUID) async {
        subscribers[id] = nil
        if subscribers.isEmpty { await stop() }
    }

    private func arm() {
        for suffix in Self.suffixes where sources[suffix] == nil {
            sources[suffix] = FileEventSource(path: url.path + suffix, queue: queue) { [weak self] event in
                Task { await self?.noticed(event, from: suffix) }
            }
        }
        guard folder == nil else { return }
        folder = DirectoryWatcher(root: url.deletingLastPathComponent(), latency: options.folderLatency) {
            [weak self] _ in
            Task { await self?.schedule() }
        }
    }

    private func startPolling() {
        guard let interval = options.pollInterval, poller == nil else { return }
        poller = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: interval)
                guard !Task.isCancelled, let self else { return }
                await self.schedule()
            }
        }
    }

    // MARK: Noticing

    private func noticed(_ event: FileEventSource.Event, from suffix: String) {
        if event == .vanished {
            // The vnode is gone; this source is deaf from here on. `settle` arms a new one.
            sources[suffix]?.cancel()
            sources[suffix] = nil
        }
        schedule()
    }

    private func schedule() {
        isPending = true
        guard pump == nil, isStarted else { return }
        pump = Task { [weak self] in await self?.drain() }
    }

    private func drain() async {
        while isPending {
            try? await Task.sleep(for: options.debounce)
            guard !Task.isCancelled else { break }
            // Cleared after the wait, so everything that happened during it is this round's business.
            isPending = false
            await settle()
        }
        pump = nil
    }

    /// One round: re-arm what went missing, notice a replaced store, read the gate, tell the subscribers.
    private func settle() async {
        guard !subscribers.isEmpty else { return }
        arm()

        var isReplaced = false
        let current = StoreFiles(url)
        if current != files {
            // The store itself being a different file is news: every primary key and prior value anybody cached
            // belongs to the old one. A new `-wal` or `-shm` is not news in itself, but it does mean the gate
            // connection is looking at bytes nobody writes to any more.
            isReplaced = current.store != files.store
            files = current
            await closeReader()
        }
        if reader == nil { await openReader() }

        guard let reader else {
            if isReplaced { yield(StoreCommit(kind: .storeReplaced, dataVersion: nil)) }
            retry()
            return
        }
        do {
            let version = try await reader.read { try $0.dataVersion() }
            attemptsLeft = options.readAttempts
            guard isReplaced || version != lastVersion else { return }
            lastVersion = version
            yield(StoreCommit(kind: isReplaced ? .storeReplaced : .commit, dataVersion: version))
        } catch {
            log.debug("The store's data_version could not be read: \(Self.describe(error), privacy: .public)")
            if isReplaced { yield(StoreCommit(kind: .storeReplaced, dataVersion: nil)) }
            retry()
        }
    }

    /// Gives a failed gate read another round. Events keep arriving while a writer holds the lock, so this only
    /// matters when the failure was the last thing to happen.
    private func retry() {
        guard attemptsLeft > 0 else {
            attemptsLeft = options.readAttempts
            return
        }
        attemptsLeft -= 1
        isPending = true
    }

    private func yield(_ commit: StoreCommit) {
        for continuation in subscribers.values { continuation.yield(commit) }
    }

    // MARK: The gate connection

    /// An error's code, which is all a log needs: never a path, never anything out of a row (§10).
    private static func describe(_ error: Error) -> String {
        (error as? DabbiError)?.code.rawValue ?? "\(type(of: error))"
    }

    private static var gateOptions: SQLiteConnection.Options {
        var options = SQLiteConnection.Options()
        // Half the latency budget is not worth spending on a lock: another event is coming either way.
        options.busyTimeoutMilliseconds = 100
        return options
    }

    private func openReader() async {
        do {
            reader = try SQLiteReader(url: url, options: Self.gateOptions)
            lastVersion = nil
        } catch {
            log.debug("The store could not be reopened for watching: \(Self.describe(error), privacy: .public)")
        }
    }

    private func closeReader() async {
        await reader?.close()
        reader = nil
        lastVersion = nil
    }
}

/// Which files the gate connection was opened onto.
///
/// Core Data keeps its companions: closing a store checkpoints the log and truncates the `-wal` to nothing, but
/// both it and the `-shm` stay, with the same inode, across an app restart and across the app's whole lifetime
/// (Appendix C). So a change here really does mean a different file, not routine housekeeping.
private struct StoreFiles: Hashable {
    var store: FileIdentity?
    var log: FileIdentity?
    var sharedMemory: FileIdentity?

    /// Nothing watched yet.
    init() {}

    init(_ url: URL) {
        store = FileIdentity(atPath: url.path)
        log = FileIdentity(atPath: url.path + "-wal")
        sharedMemory = FileIdentity(atPath: url.path + "-shm")
    }
}

/// Which file a path pointed at when it was looked at.
private struct FileIdentity: Hashable {
    let device: dev_t
    let inode: ino_t

    init?(atPath path: String) {
        var info = stat()
        guard stat(path, &info) == 0 else { return nil }
        device = info.st_dev
        inode = info.st_ino
    }
}
