import Foundation
import SwiftData

/// A store written by SwiftData, not by Core Data (PRJ-11): `default.store`, the name SwiftData picks when the
/// app does not, with the schema SwiftData derives from `@Model` classes — a unique attribute, an array that
/// becomes a transformable, a `Codable` struct that becomes a composite, a `Codable` enum, external storage and
/// a cascading relationship.
public enum SwiftDataFixture {
    public static let storeName = "default.store"

    @Model final class Trip {
        @Attribute(.unique) var name: String
        var startsAt: Date
        var tags: [String]
        var kind: TripKind
        var notes: String?
        @Attribute(.externalStorage) var cover: Data?
        @Relationship(deleteRule: .cascade, inverse: \Stop.trip) var stops: [Stop] = []

        init(name: String, startsAt: Date, tags: [String], kind: TripKind) {
            self.name = name
            self.startsAt = startsAt
            self.tags = tags
            self.kind = kind
        }
    }

    @Model final class Stop {
        var city: String
        var nights: Int
        var position: Coordinate
        var trip: Trip?

        init(city: String, nights: Int, position: Coordinate) {
            self.city = city
            self.nights = nights
            self.position = position
        }
    }

    enum TripKind: String, Codable {
        case business, leisure
    }

    struct Coordinate: Codable {
        var latitude: Double
        var longitude: Double
    }

    static func build(in directory: URL) throws -> FixtureManifest {
        let trips = 3
        let stopsPerTrip = 2
        try write(trips: trips, stopsPerTrip: stopsPerTrip, to: directory.appendingPathComponent(storeName))
        return FixtureManifest(
            fixture: .swiftData,
            summary: "Written by SwiftData: @Model classes, default.store, history tracking on as SwiftData has it.",
            store: storeName,
            entityCounts: ["Trip": trips, "Stop": trips * stopsPerTrip]
        )
    }

    /// The container goes away with this function, which is what closes the store.
    private static func write(trips: Int, stopsPerTrip: Int, to url: URL) throws {
        let container = try ModelContainer(for: Trip.self, Stop.self, configurations: ModelConfiguration(url: url))
        let context = ModelContext(container)
        for index in 0..<trips {
            let trip = Trip(
                name: "Trip \(index)", startsAt: fixtureEpoch.addingTimeInterval(Double(index) * 86_400),
                tags: ["tag-\(index)", "shared"], kind: index.isMultiple(of: 2) ? .business : .leisure)
            if index == 0 { trip.notes = "Booked through the office." }
            context.insert(trip)
            for stop in 0..<stopsPerTrip {
                trip.stops.append(
                    Stop(
                        city: "City \(index).\(stop)", nights: stop + 1,
                        position: Coordinate(latitude: 48 + Double(index), longitude: 11 + Double(stop))))
            }
        }
        try context.save()
    }
}
