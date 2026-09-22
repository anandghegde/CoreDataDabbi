import DabbiKit
import FixtureKit
import Foundation

@testable import CoreDataDabbi

/// Contexts and models over the fixture zoo, for the tests that need a real model but no window.
@MainActor
enum TestProject {
    /// A context pointed at a fixture's store, open and settled. The caller shuts it down.
    static func context(on fixture: Fixture) async throws -> ProjectContext {
        let context = ProjectContext()
        context.workingCopiesDirectory = try AppFixtures.scratchFolder("copies")
        context.adoptStore(at: try AppFixtures.location(fixture).storeURL)
        context.openStoreIfNeeded()
        await context.whenSettled()
        return context
    }

    private static var models: [Fixture: ModelDescription] = [:]

    /// A fixture's model, read once per process: opening a store for every test of pure model logic is slower
    /// than the tests themselves.
    static func model(of fixture: Fixture) async throws -> ModelDescription {
        if let model = models[fixture] { return model }
        let context = try await context(on: fixture)
        defer { context.shutDown() }
        guard let model = context.model else {
            throw DabbiError(.storeOpenFailed, "The fixture's model could not be read.")
        }
        models[fixture] = model
        return model
    }
}
