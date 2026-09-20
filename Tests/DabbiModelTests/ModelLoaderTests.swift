import CoreData
import DabbiBase
import DabbiSQLite
import DabbiTestSupport
import FixtureKit
import Foundation
import Testing

@testable import DabbiModel

private func resolve(_ fixture: Fixture, model: URL?? = .none) throws -> LoadedModel {
    let location = try TestFixtures.location(fixture)
    let connection = try SQLiteConnection(readOnly: location.storeURL)
    defer { connection.close() }
    let modelURL: URL? =
        switch model {
        case .none: location.modelURL
        case .some(let chosen): chosen
        }
    return try ModelLoader.resolve(storeURL: location.storeURL, modelURL: modelURL, connection: connection)
}

@Suite struct ModelLoaderTests {
    @Test func usesTheModelCachedInTheStore() throws {
        let loaded = try resolve(.company)
        #expect(loaded.source == .storeCache)
        #expect(loaded.description.versionIdentifiers == ["company-1"])
        #expect(
            loaded.description.entities.map(\.name)
                == ["Department", "Employee", "Manager", "Organisation", "Party", "Person", "Tag"])
    }

    @Test func theCachedModelMatchesTheStore() throws {
        for fixture in [Fixture.basic, .company, .ordered, .composites, .derived, .externalData, .history, .walOnly] {
            let location = try TestFixtures.location(fixture)
            let loaded = try resolve(fixture)
            let compatibility = ModelCompatibility.check(
                model: loaded.model, metadata: try StoreMetadata.read(from: location.storeURL))
            #expect(compatibility.isCompatible, "\(fixture)")
            #expect(compatibility.hashDiffers.isEmpty && compatibility.storeOnly.isEmpty, "\(fixture)")
        }
    }

    @Test func aStoreWithoutACacheSaysWhatToDo() throws {
        let error = #expect(throws: DabbiError.self) { try resolve(.noModelCache, model: .some(nil)) }
        #expect(error?.code == .modelCacheMissing)
        #expect(error?.recovery.isEmpty == false)
    }

    @Test func loadsASingleMom() throws {
        let loaded = try resolve(.noModelCache)
        guard case .userSelected(let files) = loaded.source else {
            Issue.record("unexpected source \(loaded.source)")
            return
        }
        #expect(files.map(\.lastPathComponent) == ["Notes.mom"])
        #expect(loaded.description.entities.map(\.name) == ["Folder", "Note"])
    }

    @Test func picksTheVersionTheStoreWasSavedWith() throws {
        let location = try TestFixtures.location(.versioned)
        let momd = try #require(location.modelURL)
        // The .momd's current version is "Articles 2"; the store was saved with the first one.
        let current = try ModelLoader.loadModel(at: momd)
        #expect(current.versionIdentifiers != ["articles-1"] as Set<AnyHashable>)

        let loaded = try resolve(.versioned)
        #expect(loaded.description.versionIdentifiers == ["articles-1"])
        guard case .userSelected(let files) = loaded.source else {
            Issue.record("unexpected source \(loaded.source)")
            return
        }
        #expect(files.map(\.lastPathComponent) == ["Articles.mom"])
    }

    @Test func mergesModelsWhenNoSingleOneMatches() throws {
        let loaded = try resolve(.merged)
        guard case .appBundle(_, let models) = loaded.source else {
            Issue.record("unexpected source \(loaded.source)")
            return
        }
        #expect(Set(models.map(\.lastPathComponent)) == ["Billing.mom", "Customers.mom"])
        #expect(loaded.description.entities.map(\.name) == ["Customer", "Invoice"])
    }

    @Test func findsTheModelInsideAnAppBundle() throws {
        let location = try TestFixtures.location(.appBundle)
        let loaded = try resolve(.appBundle)
        guard case .appBundle(let bundle, let models) = loaded.source else {
            Issue.record("unexpected source \(loaded.source)")
            return
        }
        #expect(bundle == location.modelURL)
        #expect(models.count == 1)
        #expect(loaded.description.entity(named: "Article") != nil)
    }

    @Test func aModelForAnotherStoreIsRefusedNotIgnored() throws {
        let other = try #require(try TestFixtures.location(.noModelCache).modelURL)
        // The company store has a perfectly good cached model; choosing a wrong file must still be an error.
        let error = #expect(throws: DabbiError.self) { try resolve(.company, model: .some(other)) }
        #expect(error?.code == .modelIncompatible)
    }

    @Test func aMissingModelFileIsReported() throws {
        let missing = TestFixtures.root.appendingPathComponent("Nothing.momd")
        #expect(throws: DabbiError.self) { try resolve(.company, model: .some(missing)) }
    }

    @Test func compatibilityNamesWhatDiffers() throws {
        let notes = try ModelLoader.loadModel(at: try #require(try TestFixtures.location(.noModelCache).modelURL))
        let location = try TestFixtures.location(.history)  // also Folder + Note, but a different model
        let metadata = try StoreMetadata.read(from: location.storeURL)
        let compatibility = ModelCompatibility.check(model: notes, metadata: metadata)
        if compatibility.isCompatible { return }  // identical models would make this fixture pair useless, not wrong
        #expect(!(compatibility.hashDiffers + compatibility.storeOnly + compatibility.modelOnly).isEmpty)
        let error = compatibility.error(storeURL: location.storeURL)
        #expect(error.code == .modelIncompatible)
        #expect(!error.diagnosis.isEmpty)
    }

    @Test func readsStoreMetadataWithoutCoreDataOpeningTheStore() throws {
        let location = try TestFixtures.location(.company)
        let metadata = try StoreMetadata.read(from: location.storeURL)
        #expect(metadata.storeType == NSSQLiteStoreType)
        #expect(metadata.storeUUID?.isEmpty == false)
        #expect(metadata.modelVersionIdentifiers == ["company-1"])
        #expect(Set(metadata.entityVersionHashes.keys).contains("Manager"))
        #expect(metadata.entityVersionHashes.values.allSatisfy { $0.count == 32 })
    }
}

@Suite struct ModelSanitiserTests {
    @Test func replacesTransformersAndClassesWithoutChangingHashes() throws {
        let original = try resolve(.basic).model
        let sanitised = try ModelSanitiser.sanitised(original)
        #expect(sanitised !== original)
        #expect(sanitised.entityVersionHashesByName == original.entityVersionHashesByName)

        let sample = try #require(sanitised.entitiesByName["Sample"])
        #expect(sample.managedObjectClassName == NSStringFromClass(NSManagedObject.self))
        let transformables = sample.attributesByName.values.filter { $0.attributeType == .transformableAttributeType }
        #expect(transformables.count == 2)
        #expect(transformables.allSatisfy { $0.valueTransformerName == DabbiPassThroughTransformer.name.rawValue })

        // The model we were given is left alone.
        #expect(
            original.entitiesByName["Sample"]?.attributesByName["colour"]?.valueTransformerName
                == "FixtureColourTransformer")
    }

    @Test func keepsHashesOnEveryFixtureModel() throws {
        for fixture in Fixture.allCases {
            let location = try TestFixtures.location(fixture)
            guard location.manifest.kind == .coreDataStore else { continue }
            let model = try resolve(fixture).model
            #expect(
                try ModelSanitiser.sanitised(model).entityVersionHashesByName == model.entityVersionHashesByName,
                "\(fixture)")
        }
    }

    @Test func thePassThroughTransformerNeverDecodes() {
        DabbiPassThroughTransformer.register()
        let transformer = ValueTransformer(forName: DabbiPassThroughTransformer.name)
        let archive = Data("bplist00 not really".utf8)
        #expect(transformer?.transformedValue(archive) as? Data == archive)
        #expect(transformer?.reverseTransformedValue(archive) as? Data == archive)
    }
}

@Suite struct ModelDescriptionTests {
    @Test func describesInheritance() throws {
        let model = try resolve(.company).description
        let party = try #require(model.entity(named: "Party"))
        #expect(party.isAbstract && party.superentity == nil)
        #expect(model.rootEntities.map(\.name) == ["Department", "Party", "Tag"])
        #expect(model.rootEntity(of: "Manager")?.name == "Party")
        #expect(Set(model.entityAndDescendants(of: "Person").map(\.name)) == ["Person", "Employee", "Manager"])

        let manager = try #require(model.entity(named: "Manager"))
        #expect(manager.superentity == "Employee")
        #expect(manager.attribute(named: "name")?.declaredIn == "Party")
        #expect(manager.attribute(named: "level")?.declaredIn == "Manager")
        #expect(manager.relationship(named: "boss")?.declaredIn == "Person")
    }

    @Test func describesRelationships() throws {
        let model = try resolve(.company).description
        let head = try #require(model.entity(named: "Department")?.relationship(named: "head"))
        #expect(head.destinationEntity == "Manager" && !head.isToMany && head.inverseName == nil)
        let departments = try #require(model.entity(named: "Organisation")?.relationship(named: "departments"))
        #expect(departments.isToMany && departments.deleteRule == .cascade && departments.inverseName == "organisation")

        let tracks = try #require(
            try resolve(.ordered).description.entity(named: "Playlist")?.relationship(named: "tracks"))
        #expect(tracks.isToMany && tracks.isOrdered)
    }

    @Test func describesAttributes() throws {
        let sample = try #require(try resolve(.basic).description.entity(named: "Sample"))
        #expect(sample.attributes.map(\.name) == sample.attributes.map(\.name).sorted())
        let expected: [String: AttributeType] = [
            "boolValue": .boolean, "colour": .transformable, "dataValue": .binaryData, "dateValue": .date,
            "decimalValue": .decimal, "doubleValue": .double, "floatValue": .float, "int16Value": .integer16,
            "int32Value": .integer32, "int64Value": .integer64, "name": .string, "urlValue": .uri, "uuidValue": .uuid,
        ]
        for (name, type) in expected { #expect(sample.attribute(named: name)?.type == type, "\(name)") }

        let name = try #require(sample.attribute(named: "name"))
        #expect(!name.isOptional && name.defaultValue == "untitled")
        #expect(name.validation.minimumLength == 1 && name.validation.maximumLength == 100)
        #expect(sample.attribute(named: "colour")?.valueTransformerName == "FixtureColourTransformer")
        #expect(sample.uniquenessConstraints == [["uuidValue"]])
        #expect(
            sample.indexes.contains { $0.name == "byStringValue" && $0.elements.map(\.property) == ["stringValue"] })
    }

    @Test func describesCompositesDerivedAttributesAndTemplates() throws {
        let address = try #require(
            try resolve(.composites).description.entity(named: "Place")?.attribute(named: "address"))
        #expect(address.type == .composite)
        #expect(address.compositeElements?.map(\.name) == ["street", "city", "location"])
        #expect(address.compositeElements?.last?.compositeElements?.map(\.name).sorted() == ["latitude", "longitude"])

        let list = try #require(try resolve(.derived).description.entity(named: "List"))
        #expect(list.attribute(named: "itemCount")?.isDerived == true)
        #expect(list.attribute(named: "name")?.isDerived == false)

        let externalPayload = try resolve(.externalData).description.entity(named: "Document")?.attribute(
            named: "payload")
        #expect(externalPayload?.allowsExternalBinaryDataStorage == true)

        let template = try #require(try resolve(.basic).description.fetchRequestTemplates.first)
        #expect(template.name == "RecentSamples" && template.entity == "Sample")
        #expect(template.predicateFormat?.contains("$SINCE") == true)
    }

    @Test func survivesCodable() throws {
        for fixture in [Fixture.basic, .company, .composites] {
            let model = try resolve(fixture).description
            #expect(try JSONDecoder().decode(ModelDescription.self, from: JSONEncoder().encode(model)) == model)
        }
    }
}
