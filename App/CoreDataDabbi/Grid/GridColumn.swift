import DabbiKit
import Foundation

/// One column of the main grid (PRD §8.3, BRW-2, BRW-4).
///
/// Columns come from the pager's `ColumnSet` — what the store actually reads — dressed with what the model
/// knows about each property, and reordered by what the project remembers of this entity.
struct GridColumn: Hashable, Identifiable, Sendable {
    enum Kind: Hashable, Sendable {
        /// The row's object ID: the one column that is never a property of the model.
        case objectID
        /// Which entity the row is, shown when the grid can hold more than one (BRW-6).
        case entity
        case attribute(AttributeDescription)
        case relationship(RelationshipDescription)
    }

    var kind: Kind
    /// `$objectID`, `$entity`, or the property name. What `ColumnLayout` stores.
    var property: String
    var title: String
    var width: Double
    var isHidden: Bool

    var id: String { property }

    /// Sorting happens in SQLite, over a stored, comparable column. A relationship, a blob and a composite have
    /// no order the store could put them in (BRW-9).
    var isSortable: Bool {
        guard case .attribute(let attribute) = kind else { return false }
        switch attribute.type {
        case .binaryData, .transformable, .composite, .undefined: return false
        default: return !attribute.isTransient
        }
    }

    /// Numbers and dates line up on the right; everything else reads from the left.
    var isTrailing: Bool {
        guard case .attribute(let attribute) = kind else { return false }
        switch attribute.type {
        case .integer16, .integer32, .integer64, .decimal, .double, .float, .date: return true
        default: return false
        }
    }

    /// What the inspector and the header tooltip call the column's type.
    var typeName: String? {
        switch kind {
        case .objectID: String(localized: "Object ID")
        case .entity: String(localized: "Entity")
        case .attribute(let attribute): attribute.type.displayName
        case .relationship(let relationship):
            relationship.isToMany
                ? String(localized: "To-many → \(relationship.destinationEntity)")
                : String(localized: "To-one → \(relationship.destinationEntity)")
        }
    }

    // MARK: Building

    static let objectIDWidth = 110.0
    static let entityWidth = 110.0
    static let defaultWidth = 140.0

    /// The columns for an entity, in the order they should appear.
    ///
    /// - Parameters:
    ///   - columns: what the pager reads — the entity's properties followed by those its subentities add.
    ///   - entity: the fetched entity; `$entity` is only offered when its rows can be of more than one kind.
    ///   - layout: what the project remembers. Columns it names come first, in its order; the rest follow where
    ///     the model puts them, so that a model gaining an attribute shows it rather than hiding it.
    static func columns(
        for entity: EntityDescription, in model: ModelDescription, reading columns: ColumnSet,
        layout: EntityLayout = EntityLayout()
    ) -> [GridColumn] {
        var built: [GridColumn] = [
            GridColumn(
                kind: .objectID, property: ColumnLayout.objectIDColumn, title: String(localized: "Object ID"),
                width: objectIDWidth, isHidden: false)
        ]
        if !entity.subentities.isEmpty {
            built.append(
                GridColumn(
                    kind: .entity, property: ColumnLayout.entityColumn, title: String(localized: "Entity"),
                    width: entityWidth, isHidden: false))
        }

        // Every property the pager reads, described by whichever entity in the tree declares it.
        let described = describedProperties(of: entity, in: model)
        for property in columns.properties {
            guard let kind = described[property] else { continue }
            built.append(
                GridColumn(kind: kind, property: property, title: property, width: defaultWidth, isHidden: false))
        }
        return apply(layout, to: built)
    }

    /// `layout` speaks about columns by property name; ones it does not mention keep their place and their
    /// defaults, and ones it mentions that no longer exist are dropped with the model version that had them.
    static func apply(_ layout: EntityLayout, to columns: [GridColumn]) -> [GridColumn] {
        var remaining = columns
        var ordered: [GridColumn] = []
        for saved in layout.columns {
            guard let index = remaining.firstIndex(where: { $0.property == saved.property }) else { continue }
            var column = remaining.remove(at: index)
            if let width = saved.width { column.width = width }
            column.isHidden = saved.isHidden
            ordered.append(column)
        }
        return ordered + remaining
    }

    /// The layout to save for `columns`: their order, their widths, and which are hidden.
    static func layout(of columns: [GridColumn]) -> [ColumnLayout] {
        columns.map { ColumnLayout(property: $0.property, width: $0.width, isHidden: $0.isHidden) }
    }

    /// Property name → what it is, for `entity` and everything below it. A subentity's property is described
    /// by the subentity that declares it, which is where its type lives.
    private static func describedProperties(
        of entity: EntityDescription, in model: ModelDescription
    ) -> [String: Kind] {
        var described: [String: Kind] = [:]
        for current in model.entityAndDescendants(of: entity.name) {
            for attribute in current.attributes where described[attribute.name] == nil {
                described[attribute.name] = .attribute(attribute)
            }
            for relationship in current.relationships where described[relationship.name] == nil {
                described[relationship.name] = .relationship(relationship)
            }
        }
        return described
    }
}

extension Array where Element == GridColumn {
    var visible: [GridColumn] { filter { !$0.isHidden } }

    /// The `ColumnSet` to read for these columns: the properties among them, shown or not.
    ///
    /// Hidden columns are left out of the read — a hidden blob is the whole point of hiding it (BRW-4).
    var columnSet: ColumnSet {
        ColumnSet(
            visible.compactMap { column in
                switch column.kind {
                case .objectID, .entity: nil
                case .attribute, .relationship: column.property
                }
            })
    }
}
