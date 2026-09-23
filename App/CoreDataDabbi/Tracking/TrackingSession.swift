import DabbiKit
import Foundation
import Observation

/// One window's change tracking: the tracker, the log it fills, and the three buttons that drive it
/// (TRK-1, TRK-2, TRK-9).
///
/// The window's side of `ChangeTracker`. It owns the actor, turns its batches into a `TrackingLog` on the main
/// actor, and holds the small amount of state the toolbar and the menu validate against. It does not know the
/// project context — the context hands it a store, an entity and a filter — which is what lets the tests drive
/// it against a fixture and a writer with no window in sight.
@MainActor
@Observable
final class TrackingSession {
    enum State: Equatable {
        /// Not tracking, and nothing to read: the window shows the grid.
        case idle
        /// Reading the baseline. Not instant on a large store, so it is a state and not a gap.
        case starting
        case tracking
        case paused
        /// Stopped with the log still on screen. The user is reading it; `close()` puts it away.
        case stopped
        case failed(DabbiError)
    }

    private(set) var state: State = .idle
    private(set) var log = TrackingLog()
    /// The entity being tracked, and the filter it is scoped by (TRK-7).
    private(set) var entity: String?
    private(set) var filter: PredicateSource?
    /// What cannot be tracked exactly for this store and scope. Shown in the footer rather than implied away.
    private(set) var limitations: [ScanLimitation] = []
    /// Noticed → on screen for the last batch: the figure §6.6 budgets 500 ms for.
    private(set) var lastLatency: Duration?
    /// The store file was replaced under the tracker. Everything it held was about a file that is gone.
    private(set) var storeWasReplaced = false
    /// Bumped whenever the log changed, so a view can watch one small thing rather than the whole log.
    private(set) var revision = 0

    /// Called when the store file was replaced: the window reopens the store, and tracking starts again on what
    /// is there now.
    @ObservationIgnored var onStoreReplaced: (() -> Void)?

    /// How the tracker is set up. The window keeps the defaults; a test lowers the debounce, so that it does not
    /// spend the latency budget waiting, and turns priming off to check what the grid handed over.
    @ObservationIgnored var options = ChangeTracker.Options()

    @ObservationIgnored private var tracker: ChangeTracker?
    @ObservationIgnored private var startTask: Task<Void, Never>?
    @ObservationIgnored private var pump: Task<Void, Never>?
    /// The last pause, resume or clear sent to the tracker. Each waits for the one before, so that the tracker
    /// sees them in the order the user pressed the buttons — two bare tasks may reach an actor either way round.
    @ObservationIgnored private var control: Task<Void, Never>?
    /// Bumped per run; anything that arrives from an earlier one is dropped.
    @ObservationIgnored private var generation = 0

    // MARK: What the window asks

    /// Whether the log is what the centre of the window shows.
    var isShowingLog: Bool { state != .idle }
    var isRunning: Bool { state == .starting || state == .tracking || state == .paused }
    var canPause: Bool { state == .tracking }
    var canResume: Bool { state == .paused }
    var canClear: Bool { isShowingLog }

    // MARK: Starting and stopping (TRK-1)

    /// Starts tracking one entity, scoped by the filter the grid is showing it through (TRK-7).
    ///
    /// - Parameter alreadyRead: the rows the window has in memory. They are handed over *after* the tracker has
    ///   started, because starting resets the prior values it holds; giving them earlier would lose them, and
    ///   the first change to a row the user is looking at would read as *prior value unknown* (§6.6, TRK-2).
    func start(
        on store: StoreSession, entity: String, filter: PredicateSource? = nil,
        alreadyRead: @escaping @MainActor () -> [RowPage] = { [] }
    ) {
        stopTracker()
        generation += 1
        let generation = self.generation
        self.entity = entity
        self.filter = filter
        storeWasReplaced = false
        limitations = []
        lastLatency = nil
        state = .starting
        // A log of another entity, another filter or another file would be drawn under this one's columns, and
        // read as though it were about what is being watched now.
        log.clear()
        revision += 1

        let tracker = ChangeTracker(session: store, options: options)
        self.tracker = tracker
        let scope = TrackingScope.entities([entity], predicate: filter)
        startTask = Task { [weak self] in
            do {
                let batches = try await tracker.start(scope)
                guard let self, self.generation == generation else {
                    await tracker.stop()
                    return
                }
                for page in alreadyRead() { await tracker.remember(page) }
                guard self.generation == generation else { return }
                self.limitations = await tracker.statistics().limitations
                guard self.generation == generation else { return }
                self.state = .tracking
                self.consume(batches, generation: generation)
            } catch {
                guard let self, self.generation == generation else { return }
                self.tracker = nil
                self.state = .failed(
                    error as? DabbiError
                        ?? DabbiError(.internal, "Changes could not be tracked.", underlying: error))
            }
        }
    }

    /// Stops the tracker and leaves the log up: what happened is still worth reading (TRK-1).
    func stop() {
        guard isShowingLog else { return }
        stopTracker()
        state = .stopped
    }

    /// Stops and puts the log away — the window shows the rows again.
    func close() {
        stopTracker()
        state = .idle
        entity = nil
        filter = nil
        limitations = []
        lastLatency = nil
        storeWasReplaced = false
        log.clear()
        revision += 1
    }

    /// Stops reading the store without losing the thread: commits are counted while paused, and resuming
    /// reports their net effect in one batch that says how many it stood for (TRK-9).
    func pause() {
        guard state == .tracking, let tracker else { return }
        state = .paused
        send { await tracker.pause() }
    }

    func resume() {
        guard state == .paused, let tracker else { return }
        state = .tracking
        send { await tracker.resume() }
    }

    /// Folds an object's earlier versions away, or back out again (TRK-2).
    func toggleFold(ofEntryAt index: Int) {
        log.toggleExpanded(ofEntryAt: index)
        revision += 1
    }

    /// Empties the log (TRK-9). While stopped there is nothing left to read, so the log closes with it.
    func clear() {
        guard isShowingLog else { return }
        log.clear()
        revision += 1
        if let tracker { send { await tracker.versions.clear() } }
        if !isRunning { close() }
    }

    // MARK: Batches

    private func consume(_ batches: AsyncStream<ChangeBatch>, generation: Int) {
        pump = Task { [weak self] in
            for await batch in batches {
                guard let self, self.generation == generation else { return }
                self.receive(batch)
            }
        }
    }

    private func receive(_ batch: ChangeBatch) {
        lastLatency = batch.latency
        if !batch.limitations.isEmpty { limitations = batch.limitations }

        guard batch.kind != .storeReplaced else {
            // The tracker has already stopped itself: every key and prior value it held was about a file that
            // is no longer there (Appendix D). The window reopens the store and starts again.
            storeWasReplaced = true
            tracker = nil
            pump?.cancel()
            pump = nil
            state = .stopped
            onStoreReplaced?()
            return
        }
        guard !batch.isEmpty else { return }
        log.append(batch)
        revision += 1
    }

    private func send(_ operation: @escaping @MainActor () async -> Void) {
        control = Task { [previous = control] in
            await previous?.value
            await operation()
        }
    }

    private func stopTracker() {
        generation += 1
        startTask?.cancel()
        startTask = nil
        pump?.cancel()
        pump = nil
        if let tracker { send { await tracker.stop() } }
        tracker = nil
    }

    /// Returns once the tracker has started, or failed to, and has been told of every pause, resume and clear
    /// since. Nothing in the app waits for that; the tests do.
    func whenSettled() async {
        await startTask?.value
        await control?.value
    }

    /// The tracker's own account of what it is holding — the diagnostics pane's, and the tests'.
    func statistics() async -> ChangeTracker.Statistics? {
        await tracker?.statistics()
    }
}
