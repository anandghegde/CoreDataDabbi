import DabbiBase
import DabbiModel
import Foundation

/// Which entities a tracker watches (ARCHITECTURE.md §6.6).
///
/// A scope names entities, not tables: naming `Person` also watches `Employee` and `Manager`, because a fetch of
/// `Person` in the app returns those rows too and the user who asked to watch people means all of them. Abstract
/// entities have no rows of their own and drop out of the resolved set, though their table is still read — their
/// concrete descendants live in it.
///
/// A scope may also carry the predicate of a saved view (TRK-7). The scan ignores it — it reads primary keys and
/// has no values to test — and the stage that materialises those keys applies it, which is what turns a change
/// into *entered* or *left*.
public struct TrackingScope: Sendable, Hashable, Codable {
    public enum Entities: Sendable, Hashable, Codable {
        /// Everything the model describes. Sidebar badges (TRK-8) want this.
        case all
        /// Named entities, each with its descendants.
        case some([String])
    }

    public var entities: Entities
    /// The predicate of the view being watched, as the user wrote it. An object that satisfies it is *in* the
    /// view; crossing that boundary is the transition TRK-7 marks with \u{2198} and \u{2197}.
    ///
    /// Only objects the view holds are reported: a row that neither matched before nor matches now is not news
    /// to somebody looking at that view.
    public var predicate: PredicateSource?

    public init(entities: Entities, predicate: PredicateSource? = nil) {
        self.entities = entities
        self.predicate = predicate
    }

    public static let allEntities = TrackingScope(entities: .all)

    public static func entities(_ names: [String], predicate: PredicateSource? = nil) -> TrackingScope {
        TrackingScope(entities: .some(names), predicate: predicate)
    }

    /// The concrete entities in scope, sorted. An entity the model does not describe is dropped — the scan can
    /// neither find its table nor materialise its rows.
    public func resolved(in model: ModelDescription) -> [String] {
        switch entities {
        case .all:
            return model.entities.filter { !$0.isAbstract }.map(\.name).sorted()
        case .some(let names):
            var resolved: Set<String> = []
            for name in names {
                for entity in model.entityAndDescendants(of: name) where !entity.isAbstract {
                    resolved.insert(entity.name)
                }
            }
            return resolved.sorted()
        }
    }

    /// Whether `entity` is watched, once descendants are taken into account.
    public func includes(_ entity: String, in model: ModelDescription) -> Bool {
        resolved(in: model).contains(entity)
    }
}
