import DabbiKit
import Observation

/// A place in the store the main grid can show (REL-3).
struct BrowseLocation: Hashable, Sendable {
    var entity: String
    /// The object to select and bring into view; `nil` leaves the selection to the grid.
    var focus: ObjectRef?
    /// How the user got here through relationships, for the breadcrumb: `["Order #12", "customer"]`.
    var trail: [String] = []
}

/// Back and forward, as in a browser (REL-3): going somewhere new forgets what was ahead.
@MainActor
@Observable
final class NavigationHistory {
    private(set) var current: BrowseLocation?
    private(set) var behind: [BrowseLocation] = []
    private(set) var ahead: [BrowseLocation] = []

    /// Enough to retrace an afternoon of drilling down, and nothing that grows without bound.
    static let limit = 100

    var canGoBack: Bool { !behind.isEmpty }
    var canGoForward: Bool { !ahead.isEmpty }

    func show(_ location: BrowseLocation) {
        guard location != current else { return }
        if let current {
            behind.append(current)
            if behind.count > Self.limit { behind.removeFirst(behind.count - Self.limit) }
        }
        ahead.removeAll()
        current = location
    }

    /// The same place, seen differently: the grid's selection moved. Nothing to go back to.
    func amend(_ update: (inout BrowseLocation) -> Void) {
        guard var location = current else { return }
        update(&location)
        current = location
    }

    func goBack() {
        guard let location = behind.popLast() else { return }
        if let current { ahead.append(current) }
        current = location
    }

    func goForward() {
        guard let location = ahead.popLast() else { return }
        if let current { behind.append(current) }
        current = location
    }

    /// Another store, or the same one with another model: places in the old one mean nothing now.
    func reset(to location: BrowseLocation?) {
        behind.removeAll()
        ahead.removeAll()
        current = location
    }
}
