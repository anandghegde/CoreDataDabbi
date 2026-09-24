import DabbiBase
import Foundation

/// What is on the far side of one relationship of one object (REL-1, REL-2).
///
/// A list of identities and labels, not rows: the relationships panel shows who is there and lets the grid do
/// the rest. `count` is the whole relationship; `items` is as much of it as was asked for.
public struct RelatedObjects: Sendable, Hashable, Codable {
    public struct Item: Sendable, Hashable, Codable {
        /// The object: a saved one by its reference, or one only inserted — linked in an editable session and
        /// not committed yet — by the identity it was staged under (EDT-3).
        public var object: PendingObjectID
        /// The destination entity's display attribute, when it has one and the object has a value for it.
        public var display: String?

        public init(object: PendingObjectID, display: String? = nil) {
            self.object = object
            self.display = display
        }

        public init(ref: ObjectRef, display: String? = nil) {
            self.init(object: PendingObjectID(ref), display: display)
        }

        /// The saved object's reference; `nil` for one only inserted.
        public var ref: ObjectRef? { object.ref }

        /// What to show for this object: its label, or its identity when it has none.
        public var label: String { display ?? object.description }

        // The encoded form keeps `ref` next to `object`. Until objects only inserted could be listed, an item was
        // a `ref` and a `display`: a reader of that form still reads every saved object, and a payload in it
        // still decodes. An object only inserted has no `ref` for such a reader to find.
        private enum CodingKeys: String, CodingKey {
            case object, ref, display
        }

        public init(from decoder: any Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            if let object = try container.decodeIfPresent(PendingObjectID.self, forKey: .object) {
                self.object = object
            } else {
                object = PendingObjectID(try container.decode(ObjectRef.self, forKey: .ref))
            }
            display = try container.decodeIfPresent(String.self, forKey: .display)
        }

        public func encode(to encoder: any Encoder) throws {
            var container = encoder.container(keyedBy: CodingKeys.self)
            try container.encode(object, forKey: .object)
            try container.encodeIfPresent(ref, forKey: .ref)
            try container.encodeIfPresent(display, forKey: .display)
        }
    }

    public var relationship: String
    public var destinationEntity: String
    public var isToMany: Bool
    /// An ordered to-many keeps the order it was given; everything else is listed in object-ID order, which is
    /// the order the grid shows, with objects only inserted after the saved ones.
    public var isOrdered: Bool
    /// How many there are altogether, which can be more than `items` holds.
    public var count: Int
    public var items: [Item]
    public var generation: Int

    public init(
        relationship: String, destinationEntity: String, isToMany: Bool, isOrdered: Bool, count: Int,
        items: [Item], generation: Int
    ) {
        self.relationship = relationship
        self.destinationEntity = destinationEntity
        self.isToMany = isToMany
        self.isOrdered = isOrdered
        self.count = count
        self.items = items
        self.generation = generation
    }

    /// `true` when the limit cut the list short.
    public var isTruncated: Bool { items.count < count }
}
