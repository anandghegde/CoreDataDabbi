@preconcurrency import CoreData
import Foundation

enum BasicFixture {
    static let rowCount = 40

    static func makeModel() -> NSManagedObjectModel {
        let sample = entity(
            "Sample",
            [
                attribute(
                    "name", .stringAttributeType, optional: false, defaultValue: "untitled",
                    validation: ["length >= 1", "length <= 100"], userInfo: ["display": "primary"]),
                attribute(
                    "int16Value", .integer16AttributeType, defaultValue: 0,
                    validation: ["SELF >= 0", "SELF <= 1000"]),
                attribute("int32Value", .integer32AttributeType),
                attribute("int64Value", .integer64AttributeType),
                attribute("decimalValue", .decimalAttributeType),
                attribute("doubleValue", .doubleAttributeType),
                attribute("floatValue", .floatAttributeType),
                attribute("stringValue", .stringAttributeType),
                attribute("boolValue", .booleanAttributeType, defaultValue: false),
                attribute("dateValue", .dateAttributeType),
                attribute("dataValue", .binaryDataAttributeType),
                attribute("uuidValue", .UUIDAttributeType),
                attribute("urlValue", .URIAttributeType),
                attribute(
                    "colour", .transformableAttributeType,
                    transformer: FixtureTransformers.colourName.rawValue),
                // No transformer name: Core Data's secure-unarchive default.
                attribute("keywords", .transformableAttributeType),
            ])
        sample.userInfo = ["owner": "fixtures"]
        sample.uniquenessConstraints = [["uuidValue"]]
        if let stringValue = sample.propertiesByName["stringValue"] {
            sample.indexes = [
                NSFetchIndexDescription(
                    name: "byStringValue",
                    elements: [NSFetchIndexElementDescription(property: stringValue, collationType: .binary)])
            ]
        }

        let model = model([sample], identifier: "basic-1")
        // A template's entity must be set directly; an entity *name* cannot be resolved without a context.
        let recent = NSFetchRequest<NSFetchRequestResult>()
        recent.entity = sample
        recent.predicate = NSPredicate(format: "dateValue > $SINCE AND boolValue == YES")
        recent.sortDescriptors = [NSSortDescriptor(key: "dateValue", ascending: false)]
        model.setFetchRequestTemplate(recent, forName: "RecentSamples")
        return model
    }

    static func build(in directory: URL) throws -> FixtureManifest {
        let writer = try StoreWriter(model: makeModel(), storeURL: directory.appendingPathComponent("Basic.sqlite"))
        var random = SeededGenerator(seed: 1)
        let strings = ["plain", "", "naïve café", "日本語のテキスト", "emoji 🍱 dabbi", String(repeating: "long ", count: 400)]

        try writer.perform { writer in
            for index in 0..<rowCount {
                // Every fifth row leaves all optional attributes unset.
                guard index % 5 != 4 else {
                    writer.insert("Sample", ["name": "sparse-\(index)"])
                    continue
                }
                let int64: Int64 =
                    switch index {
                    case 0: .max
                    case 1: .min
                    default: Int64(index) * 1_000_000_007
                    }
                writer.insert(
                    "Sample",
                    [
                        "name": "sample-\(index)",
                        "int16Value": Int16(index * 25),
                        "int32Value": Int32(index) * -100_000,
                        "int64Value": int64,
                        "decimalValue": NSDecimalNumber(string: "\(index).\(String(format: "%04d", index * 7))"),
                        "doubleValue": Double(index) * 1.5 - 7.25,
                        "floatValue": Float(index) / 3,
                        "stringValue": strings[index % strings.count],
                        "boolValue": index % 2 == 0,
                        "dateValue": fixtureEpoch.addingTimeInterval(Double(index) * 86_400.5),
                        "dataValue": random.data(count: 16 + index * 8),
                        "uuidValue": random.uuid(),
                        "urlValue": URL(string: "https://example.org/samples/\(index)?q=dabbi"),
                        "colour": ["red": Double(index) / 40, "green": 0.5, "blue": 1],
                        "keywords": ["alpha", "beta", "row-\(index)"] as NSArray,
                    ])
            }
        }
        try writer.close()

        return FixtureManifest(
            fixture: .basic,
            summary: "One entity with an attribute of every type.",
            store: "Basic.sqlite",
            entityCounts: ["Sample": rowCount]
        )
    }
}
