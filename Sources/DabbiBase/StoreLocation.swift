import Foundation

/// A file or folder the user picked, remembered two ways (PRJ-2): by a bookmark, which follows the item when it
/// is moved or renamed, and by the path it last had, which is what a person — or another machine — can read.
///
/// The bookmark itself is machine-specific, so it is not stored here: `bookmarkID` is its key in the project's
/// machine-local state, and the reference stays meaningful in a project shared through a repository.
public struct FileReference: Sendable, Hashable, Codable {
    public var bookmarkID: UUID
    public var lastKnownPath: String

    public init(bookmarkID: UUID = UUID(), lastKnownPath: String) {
        self.bookmarkID = bookmarkID
        self.lastKnownPath = lastKnownPath
    }

    public var lastKnownURL: URL { URL(fileURLWithPath: lastKnownPath) }
}

/// Which of an app's containers a store lives in.
public enum AppContainer: Sendable, Hashable {
    /// The app's own data container.
    case data
    /// A shared App Group container, by group identifier.
    case group(String)
}

/// Where a store is, in terms that survive what happens to it (PRJ-2).
///
/// A simulator app's data container gets a new UUID path on every reinstall, so such a store is remembered by
/// *identity* — device, bundle ID, container, path inside the container — and resolved to a path each time.
public enum StoreLocation: Sendable, Hashable {
    /// A store file picked directly.
    case file(FileReference)
    /// A store of an app installed in a simulator.
    case simulator(udid: String, bundleID: String, container: AppContainer, relativePath: String)
    /// A store of a Mac app, relative to its sandbox container (or to the home folder when it has none).
    case macApp(bundleID: String, container: AppContainer, relativePath: String)
    /// A store inside an exported Xcode app container (`.xcappdata`).
    case container(FileReference, relativePath: String)
    /// A store inside a container pulled from a physical device.
    case devicePull(deviceID: String, bundleID: String, relativePath: String)
}

extension StoreLocation {
    /// The store's file name, for window titles and recents.
    public var fileName: String {
        switch self {
        case .file(let reference): reference.lastKnownURL.lastPathComponent
        case .simulator(_, _, _, let path), .macApp(_, _, let path), .container(_, let path),
            .devicePull(_, _, let path):
            (path as NSString).lastPathComponent
        }
    }
}

// MARK: - Coding

// Hand-written so that the JSON is flat, diffable and carries a `kind` — the synthesised shape
// (`{"simulator": {"_0": …}}`) is neither pleasant to read in a repository nor stable under renames.

extension AppContainer: Codable {
    private enum CodingKeys: String, CodingKey { case kind, group }
    private enum Kind: String, Codable { case data, group }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        switch try container.decode(Kind.self, forKey: .kind) {
        case .data: self = .data
        case .group: self = .group(try container.decode(String.self, forKey: .group))
        }
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .data:
            try container.encode(Kind.data, forKey: .kind)
        case .group(let identifier):
            try container.encode(Kind.group, forKey: .kind)
            try container.encode(identifier, forKey: .group)
        }
    }
}

extension StoreLocation: Codable {
    private enum CodingKeys: String, CodingKey {
        case kind, file, udid, bundleID, container, relativePath, deviceID
    }
    private enum Kind: String, Codable { case file, simulator, macApp, container, devicePull }

    public init(from decoder: any Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        func string(_ key: CodingKeys) throws -> String { try values.decode(String.self, forKey: key) }
        switch try values.decode(Kind.self, forKey: .kind) {
        case .file:
            self = .file(try values.decode(FileReference.self, forKey: .file))
        case .simulator:
            self = .simulator(
                udid: try string(.udid), bundleID: try string(.bundleID),
                container: try values.decode(AppContainer.self, forKey: .container),
                relativePath: try string(.relativePath))
        case .macApp:
            self = .macApp(
                bundleID: try string(.bundleID),
                container: try values.decode(AppContainer.self, forKey: .container),
                relativePath: try string(.relativePath))
        case .container:
            self = .container(
                try values.decode(FileReference.self, forKey: .file), relativePath: try string(.relativePath))
        case .devicePull:
            self = .devicePull(
                deviceID: try string(.deviceID), bundleID: try string(.bundleID),
                relativePath: try string(.relativePath))
        }
    }

    public func encode(to encoder: any Encoder) throws {
        var values = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .file(let reference):
            try values.encode(Kind.file, forKey: .kind)
            try values.encode(reference, forKey: .file)
        case .simulator(let udid, let bundleID, let container, let relativePath):
            try values.encode(Kind.simulator, forKey: .kind)
            try values.encode(udid, forKey: .udid)
            try values.encode(bundleID, forKey: .bundleID)
            try values.encode(container, forKey: .container)
            try values.encode(relativePath, forKey: .relativePath)
        case .macApp(let bundleID, let container, let relativePath):
            try values.encode(Kind.macApp, forKey: .kind)
            try values.encode(bundleID, forKey: .bundleID)
            try values.encode(container, forKey: .container)
            try values.encode(relativePath, forKey: .relativePath)
        case .container(let reference, let relativePath):
            try values.encode(Kind.container, forKey: .kind)
            try values.encode(reference, forKey: .file)
            try values.encode(relativePath, forKey: .relativePath)
        case .devicePull(let deviceID, let bundleID, let relativePath):
            try values.encode(Kind.devicePull, forKey: .kind)
            try values.encode(deviceID, forKey: .deviceID)
            try values.encode(bundleID, forKey: .bundleID)
            try values.encode(relativePath, forKey: .relativePath)
        }
    }
}
