import DabbiBase
import Foundation
import Testing

@Suite struct ObjectRefTests {
    @Test func parsesAPermanentURI() throws {
        let uri = try #require(URL(string: "x-coredata://6F1C2A7E-0000-4000-8000-000000000001/Person/p42"))
        let ref = try #require(ObjectRef(uri: uri))
        #expect(ref.entity == "Person")
        #expect(ref.pk == 42)
        #expect(ref.storeIdentifier == "6F1C2A7E-0000-4000-8000-000000000001")
        #expect(ref.description == "Person#42")
    }

    @Test(arguments: [
        "x-coredata://STORE/Person/t6F1C2A7E-0000-4000-8000-0000000000012",  // temporary ID
        "x-coredata://STORE/Person",
        "x-coredata://STORE/Person/p42/extra",
        "https://example.org/Person/p42",
        "x-coredata://STORE/Person/pNaN",
    ])
    func rejectsEverythingElse(_ string: String) throws {
        let uri = try #require(URL(string: string))
        #expect(ObjectRef(uri: uri) == nil)
    }

    @Test func ordersByEntityThenKey() throws {
        func ref(_ entity: String, _ pk: Int64) throws -> ObjectRef {
            let uri = try #require(URL(string: "x-coredata://S/\(entity)/p\(pk)"))
            return try #require(ObjectRef(uri: uri))
        }
        let sorted = try [ref("B", 1), ref("A", 10), ref("A", 9)].sorted()
        #expect(sorted.map(\.description) == ["A#9", "A#10", "B#1"])
    }
}
