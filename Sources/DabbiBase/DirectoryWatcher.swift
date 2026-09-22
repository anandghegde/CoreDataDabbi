import CoreServices
import Foundation

/// Says which folders under a root changed, a moment after they did (FSEvents).
///
/// Folder granularity on purpose: a running app writes its `-wal` many times a second, and what a watcher
/// usually needs to know is "something under here is different now" — which folder, not which file. Events are
/// coalesced by `latency`.
///
/// Used by the simulator index to notice container churn (§6.7) and by the store watcher to notice that a
/// store's companion files were deleted and recreated (§6.6), which is why it lives down here.
public final class DirectoryWatcher: @unchecked Sendable {
    private let queue = DispatchQueue(label: "org.coredatadabbi.directory-watcher", qos: .utility)
    private var stream: FSEventStreamRef?
    private let handler: @Sendable ([URL]) -> Void

    /// - Parameter handler: called on a private queue with the folders that changed. When FSEvents had to drop
    ///   events the root itself is reported: everything under it may have changed.
    public init?(root: URL, latency: TimeInterval = 1.5, handler: @escaping @Sendable ([URL]) -> Void) {
        self.handler = handler
        self.root = root
        var context = FSEventStreamContext()
        context.info = Unmanaged.passUnretained(self).toOpaque()

        let callback: FSEventStreamCallback = { _, info, count, paths, flags, _ in
            guard let info, let paths = Unmanaged<CFArray>.fromOpaque(paths).takeUnretainedValue() as? [String] else {
                return
            }
            let watcher = Unmanaged<DirectoryWatcher>.fromOpaque(info).takeUnretainedValue()
            let dropped = UInt32(kFSEventStreamEventFlagMustScanSubDirs | kFSEventStreamEventFlagRootChanged)
            var changed: [URL] = []
            for index in 0..<min(count, paths.count) {
                changed.append(URL(fileURLWithPath: paths[index], isDirectory: true))
                if flags[index] & dropped != 0 { changed.append(watcher.root) }
            }
            watcher.handler(changed)
        }

        let flags = UInt32(kFSEventStreamCreateFlagUseCFTypes | kFSEventStreamCreateFlagWatchRoot)
        guard
            let stream = FSEventStreamCreate(
                kCFAllocatorDefault, callback, &context, [root.path] as CFArray,
                FSEventStreamEventId(kFSEventStreamEventIdSinceNow), latency, flags)
        else { return nil }
        self.stream = stream
        FSEventStreamSetDispatchQueue(stream, queue)
        guard FSEventStreamStart(stream) else {
            FSEventStreamInvalidate(stream)
            FSEventStreamRelease(stream)
            self.stream = nil
            return nil
        }
    }

    public let root: URL

    /// Stops the events. Also happens when the watcher goes away.
    public func stop() {
        queue.sync {
            guard let stream else { return }
            FSEventStreamStop(stream)
            FSEventStreamInvalidate(stream)
            FSEventStreamRelease(stream)
            self.stream = nil
        }
    }

    deinit { stop() }
}
