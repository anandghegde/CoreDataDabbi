import DabbiBase
import DabbiLocator
import DabbiModel
import DabbiProject
import DabbiStore
import Foundation

/// A store that is open, and how it came to be (PRJ-3, PRJ-12).
public struct OpenedStore: Sendable {
    public let session: StoreSession
    /// The file the location stands for today — the user's file, even when `session` reads a copy of it.
    public let storeURL: URL
    /// Set when the store could not be opened where it is (§6.2): `session` reads this copy, made at
    /// `workingCopy.createdAt`. The window says so, and offers to copy again.
    public let workingCopy: WorkingCopy?
    /// Where the model came from when the project did not say: the app bundle next to a simulator store that
    /// carries no cached model.
    public let modelURL: URL?

    public var isWorkingCopy: Bool { workingCopy != nil }

    /// Closes the session and deletes the copy, if there is one.
    public func close() async {
        await session.close()
        workingCopy?.remove()
    }
}

/// Opens what a project points at: location → file → session, with the two detours a viewer has to know.
///
/// 1. **A store that cannot be read in place** — a write-ahead log without its `-shm`, or a folder that cannot
///    be written to — is copied and the copy is opened (§6.2). Nothing is written next to the original.
/// 2. **A store without a cached model** in a simulator is given the app's bundle to find the model in.
public struct StoreOpener: Sendable {
    public var resolver: StoreLocationResolver
    /// Working copies go here, one folder each.
    public var workingCopiesDirectory: URL

    public static var defaultWorkingCopiesDirectory: URL {
        let caches =
            FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        return caches.appendingPathComponent("org.coredatadabbi/WorkingCopies", isDirectory: true)
    }

    public init(resolver: StoreLocationResolver = StoreLocationResolver(), workingCopiesDirectory: URL? = nil) {
        self.resolver = resolver
        self.workingCopiesDirectory = workingCopiesDirectory ?? Self.defaultWorkingCopiesDirectory
    }

    /// Opens the store of a project.
    public func open(_ location: StoreLocation, model: ModelReference = .storeCache) async throws -> OpenedStore {
        let storeURL = try resolver.resolve(location)
        var modelURL: URL?
        if case .file(let reference) = model {
            guard let url = resolver.fileResolver(reference) else {
                throw DabbiError(
                    .modelNotFound, "The model file cannot be found.",
                    diagnosis: ["It was last seen at \(reference.lastKnownPath)."],
                    recovery: ["Choose the model again in Project Settings, or use the model cached in the store."])
            }
            modelURL = url
        }
        do {
            return try await open(storeURL: storeURL, modelURL: modelURL)
        } catch let error as DabbiError where error.code == .modelCacheMissing && modelURL == nil {
            // The app that owns the store is right there, with its model in it — unless it is a SwiftData app,
            // in which case there is no model to be had and the first error is the one to show.
            guard let bundle = appBundle(of: location), !SwiftDataConventions.shipsNoModel(bundle) else { throw error }
            return try await open(storeURL: storeURL, modelURL: bundle)
        }
    }

    /// Opens a store file.
    public func open(storeURL: URL, modelURL: URL? = nil) async throws -> OpenedStore {
        do {
            let session = try await StoreSession.open(storeURL: storeURL, modelURL: modelURL)
            return OpenedStore(session: session, storeURL: storeURL, workingCopy: nil, modelURL: modelURL)
        } catch  where WorkingCopy.helps(with: error) {
            DabbiLog.logger(.locator).notice("store cannot be read in place; opening a working copy")
            let directory = workingCopiesDirectory
            let copy = try await Task.detached(priority: .userInitiated) {
                try WorkingCopy.make(of: storeURL, in: directory)
            }.value
            do {
                let session = try await StoreSession.open(storeURL: copy.url, modelURL: modelURL)
                return OpenedStore(session: session, storeURL: storeURL, workingCopy: copy, modelURL: modelURL)
            } catch {
                copy.remove()
                throw error
            }
        }
    }

    /// Deletes working copies a crash or a force-quit left behind. Call it at launch, before anything is open.
    public func removeStaleWorkingCopies(olderThan age: TimeInterval = 0) {
        let files = FileManager.default
        let folders =
            (try? files.contentsOfDirectory(
                at: workingCopiesDirectory, includingPropertiesForKeys: [.contentModificationDateKey], options: []))
            ?? []
        let limit = Date(timeIntervalSinceNow: -age)
        for folder in folders {
            let modified = (try? folder.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
            if (modified ?? .distantPast) <= limit { try? files.removeItem(at: folder) }
        }
    }

    private func appBundle(of location: StoreLocation) -> URL? {
        guard case .simulator(let udid, let bundleID, _, _) = location, !bundleID.isEmpty, !udid.contains("/") else {
            return nil
        }
        let data = resolver.devicesDirectory.appendingPathComponent("\(udid)/data", isDirectory: true)
        return ContainerMap(deviceData: data).bundles[bundleID]
    }
}
