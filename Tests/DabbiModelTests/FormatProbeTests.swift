import DabbiBase
import DabbiModel
import DabbiSQLite
import DabbiTestSupport
import Foundation
import Testing

@Suite struct FormatProbeTests {
    @Test func storeWithoutModelCache() throws {
        let location = try TestFixtures.location(.noModelCache)
        let connection = try SQLiteConnection(readOnly: location.storeURL)
        #expect(try connection.tableExists("Z_MODELCACHE") == false)
        let probe = try FormatProbe.probe(connection)
        #expect(probe.kind == .coreData)
        #expect(!probe.hasModelCache)
        #expect(throws: DabbiError.self) { try ModelLoader.cachedModel(in: connection) }
    }
}
