import DabbiBase
import Foundation

/// A `.dabbi` project as it is on disk: a folder of JSON files (ADR-13).
///
/// ```
/// MyApp.dabbi/
/// ├─ project.json        Project — shareable
/// ├─ predicates/ diagrams/ sql/ snapshots/        (later milestones; carried along untouched until then)
/// └─ local/state.json    LocalState — this machine only; may live outside the package instead
/// ```
///
/// Reading keeps whatever this version of the app does not understand — keys inside the two JSON files, and
/// files and folders next to them — and writing puts it all back. Opening a colleague's project with an older
/// build and saving it therefore loses nothing.
public struct ProjectPackage: Sendable, Hashable {
    public static let fileExtension = "dabbi"
    /// The exported uniform type identifier of a project package.
    public static let typeIdentifier = "org.coredatadabbi.project"

    static let projectFileName = "project.json"
    static let localFolderName = "local"
    static let localFileName = "state.json"

    public var project: Project
    public var local: LocalState
    private var unknownProjectKeys = JSONValue.emptyObject
    private var unknownLocalKeys = JSONValue.emptyObject

    public init(project: Project = Project(), local: LocalState = LocalState()) {
        self.project = project
        self.local = local
    }

    /// Where local state goes when a project keeps it out of its package: one folder per project ID under this.
    public static var defaultExternalLocalRoot: URL {
        URL.applicationSupportDirectory.appending(path: "CoreDataDabbi/Local", directoryHint: .isDirectory)
    }

    // MARK: Reading

    /// - Parameter externalLocalRoot: where to look for local state when the project keeps it outside.
    public static func read(
        from wrapper: FileWrapper, externalLocalRoot: URL = defaultExternalLocalRoot
    ) throws -> ProjectPackage {
        guard wrapper.isDirectory,
            let data = wrapper.fileWrappers?[projectFileName]?.regularFileContents
        else {
            throw DabbiError(
                .projectUnreadable, "This is not a CoreDataDabbi project.",
                diagnosis: ["A project is a folder with a \(projectFileName) inside; this one has none."])
        }
        var package = ProjectPackage()
        (package.project, package.unknownProjectKeys) = try decode(Project.self, from: data, migrating: true)

        let localData =
            switch package.project.localStatePlacement {
            case .inPackage:
                wrapper.fileWrappers?[localFolderName]?.fileWrappers?[localFileName]?.regularFileContents
            case .applicationSupport:
                try? Data(contentsOf: externalLocalURL(for: package.project.id, root: externalLocalRoot))
            }
        // Local state is a convenience. When it is missing or damaged the project still opens — by last known
        // paths, with a default window — rather than refusing over a file nobody edits by hand.
        if let localData, let decoded = try? decode(LocalState.self, from: localData, migrating: false) {
            (package.local, package.unknownLocalKeys) = decoded
        }
        return package
    }

    public static func read(
        at url: URL, externalLocalRoot: URL = defaultExternalLocalRoot
    ) throws -> ProjectPackage {
        let wrapper: FileWrapper
        do {
            wrapper = try FileWrapper(url: url, options: .immediate)
        } catch {
            throw DabbiError(
                .projectUnreadable, "The project \(url.lastPathComponent) could not be read.",
                arguments: ["path": url.path], underlying: error)
        }
        return try read(from: wrapper, externalLocalRoot: externalLocalRoot)
    }

    private static func decode<T: Codable>(
        _ type: T.Type, from data: Data, migrating: Bool
    ) throws -> (T, unknown: JSONValue) {
        do {
            var raw = try ProjectJSON.decoder().decode(JSONValue.self, from: data)
            if migrating { raw = try ProjectMigrations.migrate(raw) }
            let value = try ProjectJSON.decoder().decode(type, from: ProjectJSON.encoder().encode(raw))
            return (value, raw.subtracting(try ProjectJSON.tree(value)))
        } catch let error as DabbiError {
            throw error
        } catch {
            throw DabbiError(
                .projectUnreadable, "The project file is damaged.",
                diagnosis: [describe(error)],
                recovery: ["Restore an earlier version with File › Revert To, or from version control."],
                underlying: error)
        }
    }

    /// Where in the file decoding stopped, in words.
    private static func describe(_ error: any Error) -> String {
        func path(_ context: DecodingError.Context) -> String {
            let keys = context.codingPath.map(\.stringValue).joined(separator: ".")
            return keys.isEmpty ? "the top level" : "“\(keys)”"
        }
        return switch error {
        case DecodingError.keyNotFound(let key, let context):
            "“\(key.stringValue)” is missing at \(path(context))."
        case DecodingError.typeMismatch(_, let context), DecodingError.valueNotFound(_, let context):
            "The value at \(path(context)) is not of the expected kind."
        case DecodingError.dataCorrupted(let context):
            context.codingPath.isEmpty ? "The file is not valid JSON." : "The value at \(path(context)) is invalid."
        default:
            "The file could not be decoded."
        }
    }

    // MARK: Writing

    /// The package's files. Pass the wrapper the project was read from: what it holds besides the two state
    /// files stays as it is, and unchanged files are not rewritten.
    ///
    /// A project that keeps its local state outside has no `local/` here; save that with
    /// `writeExternalLocalState(root:)`.
    public func fileWrapper(updating existing: FileWrapper? = nil) throws -> FileWrapper {
        let root = existing.flatMap { $0.isDirectory ? $0 : nil } ?? FileWrapper(directoryWithFileWrappers: [:])
        do {
            Self.replace(
                Self.projectFileName, in: root,
                with: try ProjectJSON.data(try ProjectJSON.tree(project).merging(unknownProjectKeys)))

            switch project.localStatePlacement {
            case .inPackage:
                let folder =
                    root.fileWrappers?[Self.localFolderName].flatMap { $0.isDirectory ? $0 : nil }
                    ?? {
                        let folder = FileWrapper(directoryWithFileWrappers: [:])
                        folder.preferredFilename = Self.localFolderName
                        root.addFileWrapper(folder)
                        return folder
                    }()
                Self.replace(Self.localFileName, in: folder, with: try localData())
            case .applicationSupport:
                if let folder = root.fileWrappers?[Self.localFolderName] { root.removeFileWrapper(folder) }
            }
        } catch {
            throw DabbiError(.projectWriteFailed, "The project could not be encoded.", underlying: error)
        }
        return root
    }

    /// Saves local state under `root` when the project keeps it outside its package; does nothing otherwise.
    public func writeExternalLocalState(root: URL = defaultExternalLocalRoot) throws {
        guard project.localStatePlacement == .applicationSupport else { return }
        let url = Self.externalLocalURL(for: project.id, root: root)
        do {
            try FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try localData().write(to: url, options: .atomic)
        } catch {
            throw DabbiError(
                .projectWriteFailed, "The project's local state could not be saved.",
                arguments: ["path": url.path], underlying: error)
        }
    }

    /// Writes the whole package to `url`, replacing what is there but keeping files this version does not know.
    public func write(to url: URL, externalLocalRoot: URL = defaultExternalLocalRoot) throws {
        let existing = try? FileWrapper(url: url, options: .immediate)
        let wrapper = try fileWrapper(updating: existing)
        do {
            try wrapper.write(to: url, options: [.atomic, .withNameUpdating], originalContentsURL: url)
        } catch {
            throw DabbiError(
                .projectWriteFailed, "The project could not be saved to \(url.lastPathComponent).",
                arguments: ["path": url.path], underlying: error)
        }
        try writeExternalLocalState(root: externalLocalRoot)
    }

    private func localData() throws -> Data {
        try ProjectJSON.data(try ProjectJSON.tree(local).merging(unknownLocalKeys))
    }

    private static func externalLocalURL(for id: UUID, root: URL) -> URL {
        root.appending(path: id.uuidString, directoryHint: .isDirectory).appending(path: localFileName)
    }

    /// Replaces the file only when its bytes differ, so an autosave that changed nothing touches nothing.
    private static func replace(_ name: String, in folder: FileWrapper, with data: Data) {
        if let current = folder.fileWrappers?[name] {
            guard current.regularFileContents != data else { return }
            folder.removeFileWrapper(current)
        }
        folder.addRegularFile(withContents: data, preferredFilename: name)
    }
}

/// Brings a project file written by an older version of the app up to the current schema, one version at a time.
enum ProjectMigrations {
    typealias Step = @Sendable (JSONValue) throws -> JSONValue

    /// `steps[n]` turns schema `n` into schema `n + 1`. Version 1 is the first, so there is nothing here yet.
    static let steps: [Int: Step] = [:]

    static func migrate(
        _ tree: JSONValue, steps: [Int: Step] = steps, to current: Int = Project.currentSchemaVersion
    ) throws -> JSONValue {
        guard case .object(var members) = tree else { return tree }
        guard case .int(let stored)? = members["schemaVersion"] else { return tree }
        var version = Int(stored)
        guard version <= current else {
            throw DabbiError(
                .projectTooNew, "This project was saved by a newer version of CoreDataDabbi.",
                arguments: ["schemaVersion": String(version), "supported": String(current)],
                diagnosis: ["The project uses format \(version); this version reads up to format \(current)."],
                recovery: ["Update CoreDataDabbi to open it."])
        }
        var tree = tree
        while version < current {
            guard let step = steps[version] else {
                throw DabbiError(.projectUnreadable, "Project format \(version) is not supported any more.")
            }
            tree = try step(tree)
            version += 1
        }
        guard case .object(let migrated) = tree else { return tree }
        members = migrated
        members["schemaVersion"] = .int(Int64(current))
        return .object(members)
    }
}
