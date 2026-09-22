import DabbiBase
import DabbiModel
import Foundation

/// What is known about where SwiftData puts things (PRJ-11).
///
/// A SwiftData app has no compiled model in its bundle — the schema is Swift code — so the only model there is
/// to be had is the one Core Data caches inside the store (`ModelSource.cached`). Its store is a Core Data
/// SQLite store like any other, called `default.store` unless the app says otherwise, in `Library/Application
/// Support` of the first App Group container the app is entitled to, or of its data container without one.
///
/// Nothing in a store says "SwiftData wrote me". There are two hints, from either side, and both can be wrong:
/// an app that builds its Core Data model in code ships no `.mom` either, and a Core Data developer is free to
/// give their model the version `1.0.0`. What hangs on the answer is a badge in the browser and the wording of
/// one error message, never whether or how a store is opened.
public enum SwiftDataConventions {
    public static let defaultStoreName = "default.store"
    static let applicationSupport = "Library/Application Support"

    /// `true` when no `.mom` is anywhere in the bundle, frameworks and extensions included.
    public static func shipsNoModel(_ appBundle: URL) -> Bool {
        ((try? ModelLoader.modelFiles(at: appBundle)) ?? []).isEmpty
    }

    /// The store's side of the question (verified with macOS 15's SwiftData, spike S2): SwiftData stamps the
    /// store with its `Schema.Version` — three numbers, `1.0.0` unless the app has a `VersionedSchema` — where
    /// Xcode's model editor leaves the identifier empty, and it always turns persistent history tracking on.
    public static func looksWrittenBySwiftData(modelVersionIdentifiers: [String], tracksHistory: Bool) -> Bool {
        guard tracksHistory, !modelVersionIdentifiers.isEmpty else { return false }
        return modelVersionIdentifiers.allSatisfy { identifier in
            let parts = identifier.split(separator: ".", omittingEmptySubsequences: false)
            return parts.count == 3 && parts.allSatisfy { !$0.isEmpty && $0.allSatisfy { ("0"..."9").contains($0) } }
        }
    }

    /// Where the app's default store would be, the likeliest place first — whether or not anything is there.
    public static func defaultStoreLocations(of app: SimulatorApp) -> [(container: AppContainer, relativePath: String)]
    {
        let path = "\(applicationSupport)/\(defaultStoreName)"
        return app.containers.sorted { lhs, _ in lhs.container != .data }.map { ($0.container, path) }
    }

    /// The default stores that exist.
    public static func defaultStores(of app: SimulatorApp) -> [URL] {
        let byContainer = Dictionary(
            app.containers.map { ($0.container, $0.url) }, uniquingKeysWith: { first, _ in first })
        return defaultStoreLocations(of: app).compactMap { location in
            guard let url = byContainer[location.container]?.appendingPathComponent(location.relativePath),
                FileManager.default.fileExists(atPath: url.path)
            else { return nil }
            return url
        }
    }
}
