import DabbiKit
import Foundation

/// A column of the tracking log (TRK-1, TRK-2).
///
/// The log adds two of its own — *what happened* and *when* — and then shows the entity's columns exactly as the
/// grid does, in the order and at the widths the project remembers, so that switching the grid for the log does
/// not rearrange the fields under the user's eyes.
enum TrackingColumn: Equatable, Identifiable {
    /// The glyph, the word, and what else is worth saying about the change (TRK-1).
    case change
    /// When the tracker noticed. Not when the app saved: nothing in the file records that.
    case when
    case grid(GridColumn)

    /// Names that cannot collide with a property: Core Data forbids a leading `$`, which is why the grid's own
    /// two columns use it as well.
    static let changeProperty = "$change"
    static let whenProperty = "$when"

    var id: String { property }

    var property: String {
        switch self {
        case .change: Self.changeProperty
        case .when: Self.whenProperty
        case .grid(let column): column.property
        }
    }

    var title: String {
        switch self {
        case .change: String(localized: "Change", comment: "Tracking log column: what happened to a row")
        case .when: String(localized: "When", comment: "Tracking log column: when the change was noticed")
        case .grid(let column): column.title
        }
    }

    var width: Double {
        switch self {
        case .change: 210
        case .when: 96
        case .grid(let column): column.width
        }
    }

    var isTrailing: Bool {
        switch self {
        case .change: false
        case .when: true
        case .grid(let column): column.isTrailing
        }
    }

    var typeName: String? {
        switch self {
        case .change, .when: nil
        case .grid(let column): column.typeName
        }
    }

    /// The log's columns for one entity: its two, then the entity's own as the grid would lay them out.
    ///
    /// The tracker materialises whole objects, so every stored property can be shown whether or not the grid was
    /// reading it — but a column the user hid is one they said they did not want, and it stays hidden here too.
    static func columns(
        for entity: EntityDescription, in model: ModelDescription, layout: EntityLayout = EntityLayout()
    ) -> [TrackingColumn] {
        let grid = GridColumn.columns(
            for: entity, in: model, reading: storedProperties(of: entity, in: model), layout: layout)
        return [.change, .when] + grid.map(TrackingColumn.grid)
    }

    /// What a materialised object carries: stored attributes then relationships, the entity's own first and then
    /// whatever its sub-entities add — the order `StoreSession` reads them in.
    static func storedProperties(of entity: EntityDescription, in model: ModelDescription) -> ColumnSet {
        var seen: Set<String> = []
        var names: [String] = []
        for current in model.entityAndDescendants(of: entity.name) {
            let stored =
                current.attributes.filter { !$0.isTransient }.map(\.name)
                + current.relationships.filter { !$0.isTransient }.map(\.name)
            for name in stored where seen.insert(name).inserted { names.append(name) }
        }
        return ColumnSet(names)
    }
}

extension Array where Element == TrackingColumn {
    var visible: [TrackingColumn] {
        filter { column in
            guard case .grid(let grid) = column else { return true }
            return !grid.isHidden
        }
    }
}

/// One value cell of the log: what it reads, and how heavily (TRK-2).
struct TrackingCell: Equatable {
    /// Whether the eye should go here. Every line stands for one change: the fields that change touched are
    /// drawn strongly and the rest are dimmed, so the row reads as a diff and not as a re-print of the object.
    enum Weight: Equatable {
        case normal
        /// A field this version changed.
        case strong
        /// A field it did not: still shown, because a diff with the context cut away is a diff nobody can read.
        case dim
    }

    var value: GridValue
    var weight: Weight = .normal

    /// What VoiceOver says. Strong and dim are drawn, so they are also said (§8.4).
    func spoken(column: String) -> String {
        switch weight {
        case .normal: value.accessibleText
        case .strong: String(localized: "changed to \(value.accessibleText)", comment: "Spoken for a changed field")
        case .dim: String(localized: "\(value.accessibleText), unchanged")
        }
    }
}

/// What the *Change* column of one line says (TRK-1, TRK-7, TRK-9).
struct TrackingBadge: Equatable {
    /// `+`, `✎` or `−`: the change is never told by colour alone (§8.4).
    var glyph: String
    var kind: ChangeEvent.Kind
    var title: String
    /// Which way the row crossed the view's predicate, when it did (TRK-7).
    var transition: PredicateTransition?
    /// The links that moved, the commits that were coalesced, the versions there are — the tooltip.
    var detail: String?
    var spoken: String
    /// A version row, drawn indented under the object it belongs to.
    var isVersion: Bool
    /// Only an object with more than one version can be folded.
    var canFold: Bool
    var isExpanded: Bool
}

extension TrackingLog {
    /// What the *Change* column reads on a line.
    func badge(at line: Int) -> TrackingBadge? {
        guard let line = self.line(at: line) else { return nil }
        let entry = entries[line.entry]
        let version = line.version.map { entry.versions[$0] } ?? entry.latest
        let event = version.event

        var details: [String] = []
        if let links = Self.linkSummary(event.links) { details.append(links) }
        if version.coalescedCommits > 1 {
            details.append(
                String(
                    localized: "\(version.coalescedCommits) commits",
                    comment: "Commits a single tracking batch stood for"))
        }
        if line.isObject, entry.versionCount > 1 {
            details.append(String(localized: "\(entry.versionCount) versions"))
        }
        if line.isObject, entry.hasDroppedVersions {
            details.append(String(localized: "older versions dropped"))
        }

        return TrackingBadge(
            glyph: Self.glyph(for: event.kind),
            kind: event.kind,
            title: Self.title(of: event),
            transition: event.transition,
            detail: details.isEmpty ? nil : details.joined(separator: " · "),
            spoken: Self.spoken(of: event, details: details),
            isVersion: !line.isObject,
            canFold: line.isObject && entry.versions.count > 1,
            isExpanded: entry.isExpanded)
    }

    /// The value a line reads in one column, and how heavily to draw it (TRK-2).
    func cell(at line: Int, column: TrackingColumn, timeZone: TimeZone, locale: Locale = .current) -> TrackingCell? {
        guard let line = self.line(at: line) else { return nil }
        let entry = entries[line.entry]
        let version = line.version.map { entry.versions[$0] } ?? entry.latest
        let event = version.event

        switch column {
        case .change:
            // Drawn by a cell of its own; this is what a copy of the row would carry.
            return TrackingCell(value: GridValue(text: Self.title(of: event)))

        case .when:
            return TrackingCell(value: Self.time(version.at, timeZone: timeZone, locale: locale))

        case .grid(let grid):
            switch grid.kind {
            case .objectID:
                return TrackingCell(
                    value: GridValue(text: String(entry.object.pk), tooltip: entry.object.uri.absoluteString))
            case .entity:
                return TrackingCell(value: GridValue(text: entry.object.entity))
            case .attribute, .relationship:
                return TrackingCell(
                    value: Self.value(of: grid.property, in: version, timeZone: timeZone, locale: locale),
                    weight: Self.weight(of: grid.property, in: event))
            }
        }
    }

    // MARK: Wording

    static func glyph(for kind: ChangeEvent.Kind) -> String {
        switch kind {
        case .inserted: "+"
        case .updated: "✎"
        case .deleted: "−"
        }
    }

    static func word(for kind: ChangeEvent.Kind) -> String {
        switch kind {
        case .inserted: String(localized: "Created", comment: "A row the watched app inserted")
        case .updated: String(localized: "Updated")
        case .deleted: String(localized: "Deleted")
        }
    }

    static func word(for transition: PredicateTransition) -> String {
        switch transition {
        case .entered: String(localized: "entered the filter", comment: "A row that now matches the saved filter")
        case .left: String(localized: "left the filter")
        }
    }

    static func glyph(for transition: PredicateTransition) -> String {
        switch transition {
        case .entered: "↘"
        case .left: "↗"
        }
    }

    /// The heading of one change: the word for what happened, and — where it is not obvious from the row — what
    /// the log does and does not know about it (ADR-17).
    static func title(of event: ChangeEvent) -> String {
        let word = Self.word(for: event.kind)
        guard event.kind == .updated else { return word }
        guard let changed = event.changedKeys else {
            // No prior values were held, so no field can be called changed. Saying so beats an empty diff,
            // which would read as "everything was blank before".
            return String(localized: "\(word) · prior value unknown", comment: "An update with no before-values")
        }
        if changed.isEmpty {
            return String(
                localized: "\(word) · nothing in the reading changed",
                comment: "A row saved over with the values it already had")
        }
        return String(localized: "\(word) · \(changed.count) fields", comment: "An update and how many fields")
    }

    private static func spoken(of event: ChangeEvent, details: [String]) -> String {
        var parts = [title(of: event).replacingOccurrences(of: " · ", with: ", ")]
        if let transition = event.transition { parts.append(word(for: transition)) }
        parts.append(contentsOf: details)
        return parts.joined(separator: ", ")
    }

    /// "tags: 1 added" — which relationships moved, not which objects; the tooltip is a summary, and the
    /// inspector is where a link is followed (TRK-9).
    static func linkSummary(_ links: [LinkChange]) -> String? {
        guard !links.isEmpty else { return nil }
        var order: [String] = []
        var counts: [String: [LinkChange.Kind: Int]] = [:]
        for link in links {
            if counts[link.relationship] == nil {
                counts[link.relationship] = [:]
                order.append(link.relationship)
            }
            counts[link.relationship]?[link.kind, default: 0] += 1
        }
        return order.map { relationship in
            let byKind = counts[relationship] ?? [:]
            let parts: [String] = [LinkChange.Kind.added, .removed, .reordered].compactMap { kind in
                guard let count = byKind[kind], count > 0 else { return nil }
                switch kind {
                case .added: return String(localized: "\(count) added", comment: "Links gained")
                case .removed: return String(localized: "\(count) removed")
                case .reordered: return String(localized: "\(count) moved")
                }
            }
            return "\(relationship): \(parts.joined(separator: ", "))"
        }.joined(separator: " · ")
    }

    // MARK: Values

    private static func value(
        of property: String, in version: Version, timeZone: TimeZone, locale: Locale
    ) -> GridValue {
        // After, or — for a delete, and for a row that was gone by the time the tracker read it — the last
        // thing anybody saw of it.
        guard let value = version.values?[property] else {
            return GridValue(
                text: "", emphasis: .absent,
                spoken: String(
                    localized: "Not known", comment: "Spoken for a tracking cell whose value was never read"))
        }
        return GridValue.render(value, timeZone: timeZone, locale: locale)
    }

    private static func weight(of property: String, in event: ChangeEvent) -> TrackingCell.Weight {
        switch event.kind {
        // Everything an insert carries is new, and everything a delete carries is gone: neither is a diff, so
        // neither has fields to pick out.
        case .inserted: .strong
        case .deleted: .dim
        case .updated:
            // Unknown is not "unchanged": with no before-values, no field is dimmed and none is picked out.
            event.changedKeys == nil ? .normal : (event.isChanged(property) ? .strong : .dim)
        }
    }

    private static func time(_ date: Date, timeZone: TimeZone, locale: Locale) -> GridValue {
        var style = Date.FormatStyle(date: .omitted, time: .standard, locale: locale)
        style.timeZone = timeZone
        var full = Date.FormatStyle(date: .abbreviated, time: .standard, locale: locale)
        full.timeZone = timeZone
        return GridValue(text: date.formatted(style), tooltip: date.formatted(full))
    }
}
