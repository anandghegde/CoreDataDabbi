import AppKit
import DabbiKit

/// The panes of a project window (PRD §8.1).
enum Pane {
    static let sidebar = "sidebar"
    static let bottom = "bottom"
    static let inspector = "inspector"
    static let relationships = "relationships"
    static let content = "content"
    /// The grid. Not a collapsible pane — there would be nothing left — but a place the keyboard is sent to.
    static let rows = "rows"
    /// The predicate bar above the grid. It has a shortcut of its own (⌥⌘F, §8.3) rather than a place in the
    /// list below, whose numbering is what the window reads.
    static let filter = "filter"

    /// In the order the window reads, for the menu that sends the keyboard to one of them (§8.4).
    static let focusable = [sidebar, rows, relationships, content, inspector]

    static func name(of pane: String) -> String {
        switch pane {
        case sidebar: String(localized: "Entities")
        case rows: String(localized: "Rows")
        case filter: String(localized: "Filter")
        case relationships: String(localized: "Relationships")
        case content: String(localized: "Content")
        case inspector: String(localized: "Inspector")
        default: pane
        }
    }
}

/// Sidebar │ centre │ inspector.
final class ProjectSplitViewController: PersistentSplitViewController {
    let centre: CentreSplitViewController
    let sidebar: SidebarViewController
    let inspector: InspectorViewController

    init(context: ProjectContext) {
        centre = CentreSplitViewController(context: context)
        sidebar = SidebarViewController(context: context)
        inspector = InspectorViewController(context: context)
        super.init(context: context, layoutIdentifier: "main")

        let left = NSSplitViewItem(sidebarWithViewController: sidebar)
        left.minimumThickness = 180
        left.maximumThickness = 420
        addPane(left, identifier: Pane.sidebar)

        let middle = NSSplitViewItem(viewController: centre)
        middle.minimumThickness = 420
        addPane(middle)

        let right = NSSplitViewItem(inspectorWithViewController: inspector)
        right.minimumThickness = 260
        right.maximumThickness = 520
        addPane(right, identifier: Pane.inspector)
    }

    /// Opens whatever is in the way and hands back what should take the keyboard (§8.4).
    func reveal(pane: String) -> KeyboardPane? {
        switch pane {
        case Pane.sidebar:
            show(Pane.sidebar)
            return sidebar
        case Pane.rows:
            // The change log stands in for the grid while it is showing, and it is what "the rows" means then.
            return centre.browse.rowsPane
        case Pane.filter:
            return centre.browse.bar
        case Pane.relationships, Pane.content:
            centre.show(Pane.bottom)
            centre.bottom.show(pane)
            return pane == Pane.relationships ? centre.bottom.relationships : centre.bottom.content
        case Pane.inspector:
            show(Pane.inspector)
            return inspector
        default:
            return nil
        }
    }
}

/// The grid above, relationships and content below.
final class CentreSplitViewController: PersistentSplitViewController {
    let bottom: BottomSplitViewController
    let browse: BrowseViewController

    init(context: ProjectContext) {
        bottom = BottomSplitViewController(context: context)
        browse = BrowseViewController(context: context)
        super.init(context: context, layoutIdentifier: "centre")
        splitView.isVertical = false

        let above = NSSplitViewItem(viewController: browse)
        above.minimumThickness = 160
        above.holdingPriority = .defaultLow
        addPane(above)

        let below = NSSplitViewItem(viewController: bottom)
        below.minimumThickness = 120
        below.holdingPriority = .defaultLow + 1
        addPane(below, identifier: Pane.bottom)
    }
}

/// Relationships │ content.
final class BottomSplitViewController: PersistentSplitViewController {
    let relationships: RelationshipsViewController
    let content: ContentViewController

    init(context: ProjectContext) {
        relationships = RelationshipsViewController(context: context)
        content = ContentViewController(context: context)
        super.init(context: context, layoutIdentifier: "bottom")
        splitView.isVertical = true

        let left = NSSplitViewItem(viewController: relationships)
        left.minimumThickness = 200
        addPane(left, identifier: Pane.relationships)

        let right = NSSplitViewItem(viewController: content)
        right.minimumThickness = 200
        addPane(right, identifier: Pane.content)
    }
}
