import DabbiBase
import DabbiTracking
import Foundation

/// A tracked session written out (TRK-5): one record per version in the log, oldest first.
///
/// Each record is the change, not the object: which object, what happened to it and when, who saved it when the
/// store records history, and the values on both sides. An update keeps only the properties that changed; an
/// insert has only an after, and a delete only a before. Any exporter can write it — JSON keeps before and after
/// as objects, CSV puts them in a cell each as compact JSON.
public struct TrackedSessionExport: Sendable {
    public enum Source: Sendable {
        /// A tracker's own log, read a batch at a time: the whole session, spilled versions included.
        case log(VersionLog)
        /// Versions already in hand — what a front end kept on screen after the tracker stopped.
        case versions([VersionLog.Version])
    }

    public let source: Source
    /// Versions read from the log per round trip: the log is never all in memory.
    public var batchSize = 500

    public init(log: VersionLog) {
        source = .log(log)
    }

    /// `versions` in sequence order, whatever order they come in.
    public init(versions: [VersionLog.Version]) {
        source = .versions(versions.sorted { $0.sequence < $1.sequence })
    }

    /// The columns, in the order a table writes them.
    public static let layout = ExportLayout(
        entity: "Version",
        columns: [
            "sequence", "noticed", "saved", "kind", ExportLayout.idColumn, ExportLayout.entityColumn, "changed",
            "author", "context", "transaction", "transition", "before", "after", "links",
        ].map { ExportLayout.Column(name: $0, path: [$0]) })

    /// Reads every version, oldest first, handing each on as a record. Returns how many there were.
    @discardableResult
    public func read(into body: (ExportRecord) async throws -> Void) async throws -> Int {
        var next = 0
        var count = 0
        while true {
            let versions: [VersionLog.Version]
            switch source {
            case .log(let log): versions = await log.versions(from: next, limit: batchSize)
            case .versions(let all): versions = all.filter { $0.sequence >= next }
            }
            guard let last = versions.last else { return count }
            for version in versions {
                try Task.checkCancellation()
                try await body(Self.record(for: version))
                count += 1
            }
            next = last.sequence + 1
        }
    }

    /// The session as text, for what is small enough to hold.
    public func text(as exporter: some Exporter) async throws -> String {
        var output = exporter.header(for: Self.layout)
        var index = 0
        try await read { record in
            output += exporter.record(record, index: index, layout: Self.layout)
            index += 1
        }
        return output + exporter.footer(for: Self.layout, count: index)
    }

    /// Writes the session to a file, moved into place only once it is complete.
    @discardableResult
    public func write(as exporter: some Exporter, to url: URL) async throws -> Int {
        let writer = try ExportFileWriter(destination: url)
        do {
            try writer.append(exporter.header(for: Self.layout))
            var index = 0
            try await read { record in
                try writer.append(exporter.record(record, index: index, layout: Self.layout))
                index += 1
            }
            try writer.append(exporter.footer(for: Self.layout, count: index))
            try writer.finish()
            return index
        } catch {
            writer.abandon()
            throw error
        }
    }

    public static func record(for version: VersionLog.Version) -> ExportRecord {
        let event = version.event
        // An update shows what changed; nothing is lost, as the unchanged values are the same on both sides.
        let kept: Set<String>? = event.kind == .updated ? event.changedKeys : nil
        var fields: [ExportField] = [
            ExportField("sequence", .scalar(.int(Int64(version.sequence)))),
            ExportField("noticed", .scalar(.date(event.at))),
            ExportField("saved", event.history?.timestamp.map { .scalar(.date($0)) } ?? .nothing),
            ExportField("kind", .scalar(.string(event.kind.rawValue))),
            ExportField("changed", .scalar(.string(event.changedProperties.joined(separator: " ")))),
            ExportField("author", event.history?.author.map { .scalar(.string($0)) } ?? .nothing),
            ExportField("context", event.history?.contextName.map { .scalar(.string($0)) } ?? .nothing),
            ExportField(
                "transaction", event.history.map { .scalar(.int($0.transactionNumber)) } ?? .nothing),
            ExportField("transition", event.transition.map { .scalar(.string($0.rawValue)) } ?? .nothing),
            ExportField("before", event.before.map { values(of: $0, keeping: kept) } ?? .nothing),
            ExportField("after", event.after.map { values(of: $0, keeping: kept) } ?? .nothing),
        ]
        if !event.links.isEmpty {
            fields.append(ExportField("links", .objects(event.links.map(link))))
        }
        return ExportRecord(id: event.object.uri, entity: event.object.entity, fields: fields)
    }

    private static func values(of snapshot: ObjectSnapshot, keeping kept: Set<String>?) -> ExportValue {
        .composite(
            zip(snapshot.columns.properties, snapshot.row.values)
                .filter { kept?.contains($0.0) ?? true }
                .map { ExportField($0.0, ExportValue($0.1)) })
    }

    private static func link(_ link: LinkChange) -> ExportValue {
        .composite(
            [
                ExportField("kind", .scalar(.string(link.kind.rawValue))),
                ExportField("relationship", .scalar(.string(link.relationship))),
                ExportField("source", .scalar(.string(link.source.description))),
                ExportField("destination", .scalar(.string(link.destination.description))),
            ] + (link.order.map { [ExportField("order", .scalar(.int($0)))] } ?? []))
    }
}
