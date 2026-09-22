import Foundation

/// Watches one file: it was written to, or the thing being watched is no longer reachable by its path.
///
/// A store's files come and go. The `-wal` appears when the app first writes and is truncated at every
/// checkpoint — Core Data keeps it and the `-shm` after that, even across a restart (Appendix C) — but all three
/// are replaced when the app is reinstalled or a snapshot is restored. A `DispatchSource` watches a *vnode*, not
/// a path, so once a file is deleted its source is useless — it reports `.vanished` and `StoreWatcher` opens a
/// new one (§6.6).
///
/// `@unchecked Sendable`: the source is created before it is resumed and afterwards only touched on `queue`.
final class FileEventSource: @unchecked Sendable {
    enum Event: Sendable, Hashable {
        /// The file's contents changed.
        case changed
        /// The vnode was deleted, renamed or revoked. This source will never report anything again.
        case vanished
    }

    private let source: DispatchSourceFileSystemObject

    /// Arms a source on `path`, or returns `nil` when there is no such file (yet).
    ///
    /// - Parameter handler: called on `queue`, possibly several times for one change.
    init?(path: String, queue: DispatchQueue, handler: @escaping @Sendable (Event) -> Void) {
        let descriptor = open(path, O_EVTONLY)
        guard descriptor >= 0 else { return nil }
        source = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: descriptor,
            eventMask: [.write, .extend, .delete, .rename, .revoke],
            queue: queue
        )
        // The handler holds the source, which holds the handler: `self` has to be weak or nothing is ever freed.
        source.setEventHandler { [weak self] in
            guard let self else { return }
            let events = self.source.data
            if !events.intersection([.write, .extend]).isEmpty { handler(.changed) }
            if !events.intersection([.delete, .rename, .revoke]).isEmpty { handler(.vanished) }
        }
        source.setCancelHandler { close(descriptor) }
        source.resume()
    }

    /// Stops the events and closes the descriptor. Also happens when the source goes away.
    func cancel() {
        source.cancel()
    }

    deinit { source.cancel() }
}
