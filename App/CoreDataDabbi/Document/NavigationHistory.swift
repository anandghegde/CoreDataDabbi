import DabbiKit
import Foundation
import Observation

/// A place in the store the main grid can show (REL-3).
struct BrowseLocation: Hashable, Sendable {
    var entity: String
    /// The saved predicate the entity is seen through (PRD-3): its filter, columns and sort rather than the
    /// entity's own. `nil` is the entity itself.
    var savedPredicate: UUID?
    /// The model's fetch-request template the entity is seen through, as it was run (BRW-1). `nil` is not one.
    var fetchRequest: FetchRequestRun?
    /// What is typed in the quick filter here (PRD-6): a search within the rows the place shows, not part of
    /// what the place is. It goes with the place into Back and Forward, starts empty anywhere new, and is never
    /// saved.
    var quickFilter: String = ""
    /// The object to select and bring into view; `nil` leaves the selection to the grid.
    var focus: ObjectRef?
    /// How the user got here through relationships, for the breadcrumb: `["Order #12", "customer"]`.
    var trail: [String] = []
}

/// A fetch-request template, run with the values the user gave it (BRW-1).
///
/// What running it produced is kept here rather than in the project: a run is a place to go back to, like a
/// search, and the template it came from is the model's, which the project does not own. Changing its filter or
/// its sort changes this run; its columns are the entity's.
struct FetchRequestRun: Hashable, Sendable {
    /// The template's name in the model.
    var name: String
    /// What each `$VARIABLE` was given, so that running it again starts from them.
    var values: [String: PredicateLiteral]
    /// The template's predicate with the values in it; `nil` for every row.
    var filter: PredicateSource?
    /// Empty leaves the entity's own sort in charge.
    var sort: [SortKey]
    /// The template's fetch limit; `nil` for none.
    var limit: Int?
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
