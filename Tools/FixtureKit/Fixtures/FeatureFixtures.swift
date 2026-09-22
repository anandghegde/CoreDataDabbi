@preconcurrency import CoreData
import Foundation

/// Ordered one-to-many (`Playlist.tracks`) and ordered many-to-many (`Playlist.featured`).
public enum OrderedFixture {
    static let playlists = 3
    static let tracks = 12

    public static func makeModel() -> NSManagedObjectModel {
        let playlist = entity("Playlist", [attribute("name", .stringAttributeType)])
        let track = entity(
            "Track",
            [
                attribute("title", .stringAttributeType),
                attribute("duration", .doubleAttributeType),
            ])
        relate(playlist, "tracks", .orderedToMany, track, inverse: "playlist", .toOne)
        relate(playlist, "featured", .orderedToMany, track, inverse: "featuredIn", .toMany)
        return model([playlist, track], identifier: "ordered-1")
    }

    static func build(in directory: URL) throws -> FixtureManifest {
        let writer = try StoreWriter(model: makeModel(), storeURL: directory.appendingPathComponent("Ordered.sqlite"))
        try writer.perform { writer in
            let playlistObjects = (0..<playlists).map { writer.insert("Playlist", ["name": "Playlist \($0)"]) }
            let trackObjects = (0..<tracks).map { index in
                writer.insert("Track", ["title": "Track \(index)", "duration": 120 + Double(index) * 7.5])
            }
            for (index, playlist) in playlistObjects.enumerated() {
                // Deliberately not in insertion order, so ordering is observable.
                let own = trackObjects.enumerated().filter { $0.offset % playlists == index }.map(\.element)
                playlist.setValue(NSOrderedSet(array: own.reversed()), forKey: "tracks")
                let featured = [
                    trackObjects[(index + 5) % tracks], trackObjects[index], trackObjects[(index + 9) % tracks],
                ]
                playlist.setValue(NSOrderedSet(array: featured), forKey: "featured")
            }
        }
        try writer.close()
        return FixtureManifest(
            fixture: .ordered,
            summary: "Ordered to-many relationships, one-to-many and many-to-many.",
            store: "Ordered.sqlite",
            entityCounts: ["Playlist": playlists, "Track": tracks]
        )
    }
}

/// `Place.address` is a composite of `street`, `city` and the nested composite `location`.
enum CompositesFixture {
    static let places = 10

    static func makeModel() -> NSManagedObjectModel {
        let location = composite(
            "location",
            [
                attribute("latitude", .doubleAttributeType),
                attribute("longitude", .doubleAttributeType),
            ])
        let address = composite(
            "address",
            [
                attribute("street", .stringAttributeType),
                attribute("city", .stringAttributeType),
                location,
            ])
        let place = entity("Place", [attribute("name", .stringAttributeType), address])
        return model([place], identifier: "composites-1")
    }

    static func build(in directory: URL) throws -> FixtureManifest {
        let writer = try StoreWriter(
            model: makeModel(), storeURL: directory.appendingPathComponent("Composites.sqlite"))
        try writer.perform { writer in
            for index in 0..<places {
                // Every fourth place has no address at all.
                let address: [String: Any]? =
                    index % 4 == 3
                    ? nil
                    : [
                        "street": "\(index + 1) Tiffin Lane",
                        "city": index % 2 == 0 ? "Mumbai" : "Pune",
                        "location": ["latitude": 19.0 + Double(index) / 10, "longitude": 72.8 + Double(index) / 10],
                    ]
                writer.insert("Place", ["name": "Place \(index)", "address": address])
            }
        }
        try writer.close()
        return FixtureManifest(
            fixture: .composites,
            summary: "Composite attributes, one nested in another.",
            store: "Composites.sqlite",
            entityCounts: ["Place": places]
        )
    }
}

/// `List.itemCount` (`items.@count`), `List.nameFolded` (`canonical:(name)`) and `Item.listName` (`list.name`).
enum DerivedFixture {
    static let lists = 4
    static let items = 18

    static func makeModel() -> NSManagedObjectModel {
        let list = entity(
            "List",
            [
                attribute("name", .stringAttributeType),
                derived("itemCount", .integer64AttributeType, "items.@count"),
                derived("nameFolded", .stringAttributeType, "canonical:(name)"),
            ])
        let item = entity(
            "Item",
            [
                attribute("title", .stringAttributeType),
                derived("listName", .stringAttributeType, "list.name"),
            ])
        relate(list, "items", .toMany, item, inverse: "list", .toOne, deleteRule: .cascadeDeleteRule)
        return model([list, item], identifier: "derived-1")
    }

    static func build(in directory: URL) throws -> FixtureManifest {
        let writer = try StoreWriter(model: makeModel(), storeURL: directory.appendingPathComponent("Derived.sqlite"))
        try writer.perform { writer in
            let listObjects = (0..<lists).map { writer.insert("List", ["name": "Liste Numéro \($0)"]) }
            for index in 0..<items {
                // The last list stays empty.
                writer.insert("Item", ["title": "Item \(index)", "list": listObjects[index % (lists - 1)]])
            }
        }
        try writer.close()
        return FixtureManifest(
            fixture: .derived,
            summary: "Derived attributes: a count, a canonical string and a key path through a relationship.",
            store: "Derived.sqlite",
            entityCounts: ["List": lists, "Item": items]
        )
    }
}

/// `Document.payload` allows external storage; large payloads end up as files next to the store.
enum ExternalDataFixture {
    static let payloadSizes = [512, 4_096, 150_000, 400_000, 1_200_000, 0]

    private static let pngMagic = Data([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A])

    static func makeModel() -> NSManagedObjectModel {
        let document = entity(
            "Document",
            [
                attribute("title", .stringAttributeType),
                attribute("payload", .binaryDataAttributeType, externalStorage: true),
                attribute("thumbnail", .binaryDataAttributeType),
            ])
        return model([document], identifier: "external-1")
    }

    static func build(in directory: URL) throws -> FixtureManifest {
        let writer = try StoreWriter(
            model: makeModel(), storeURL: directory.appendingPathComponent("External.sqlite"))
        var random = SeededGenerator(seed: 6)
        try writer.perform { writer in
            for (index, size) in payloadSizes.enumerated() {
                // Size 0 stands for "no payload".
                let payload: Data? = size == 0 ? nil : pngMagic + random.data(count: size - pngMagic.count)
                writer.insert(
                    "Document",
                    [
                        "title": "Document \(index)",
                        "payload": payload,
                        "thumbnail": pngMagic + random.data(count: 64),
                    ])
            }
        }
        try writer.close()
        return FixtureManifest(
            fixture: .externalData,
            summary: "Binary data with external storage; the large values are files in the support folder.",
            store: "External.sqlite",
            entityCounts: ["Document": payloadSizes.count]
        )
    }
}
