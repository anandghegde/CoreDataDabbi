import AppKit
import ContentFuzzKit
import DabbiBase
import Foundation
import Testing

@testable import DabbiContent

/// A class of "the app's" that the viewer has never heard of — and, archived under another name, one that
/// does not exist in this process at all.
@objc(DabbiTestPerson) private final class Person: NSObject, NSCoding {
    var name: String
    var age: Int
    var friend: Person?
    var tags: [String]

    init(name: String, age: Int, tags: [String] = []) {
        self.name = name
        self.age = age
        self.tags = tags
    }

    func encode(with coder: NSCoder) {
        coder.encode(name, forKey: "name")
        coder.encode(age, forKey: "age")
        coder.encode(friend, forKey: "friend")
        coder.encode(tags, forKey: "tags")
    }

    init?(coder: NSCoder) { fatalError("The viewer never instantiates what it shows.") }
}

@Suite struct KeyedArchiveTests {
    private let registry = ContentRegistry.standard

    private func root(
        _ object: Any, format: PropertyListSerialization.PropertyListFormat = .binary
    ) throws -> ContentNode {
        let report = registry.decode(
            try Corpus.archive(object, format: format), hint: ContentHint(storage: .transformable))
        #expect(report.type == .keyedArchive)
        #expect(report.issues.isEmpty)
        return try #require(tree(report))
    }

    @Test func showsFoundationValuesAsWhatTheyMean() throws {
        let uuid = UUID()
        let root = try root(
            [
                "text": "hello", "number": 42, "real": 1.5, "flag": true,
                "date": Date(timeIntervalSinceReferenceDate: 86_400), "data": Data([0xDE, 0xAD]),
                "url": URL(string: "https://example.org/a?b=c")!, "uuid": uuid as NSUUID, "null": NSNull(),
                "array": ["a", "b"], "set": NSSet(array: ["only"]), "ordered": NSOrderedSet(array: ["x", "y"]),
                "mutable": NSMutableString(string: "changing"),
                "relative": NSURL(string: "page.html", relativeTo: URL(string: "https://example.org/dir/"))!,
            ] as NSDictionary)

        #expect(root.kind == .dictionary)
        #expect(root.className?.contains("Dictionary") == true)
        #expect(root[path: "text"]?.value == "hello")
        #expect(root[path: "number"]?.value == "42")
        #expect(root[path: "real"]?.value == "1.5")
        #expect(root[path: "flag"]?.value == "true")
        #expect(root[path: "date"]?.kind == .date)
        #expect(root[path: "date"]?.value?.hasPrefix("2001-01-02T00:00:00") == true)
        #expect(root[path: "data"]?.kind == .data)
        #expect(root[path: "data"]?.value == "2 bytes · de ad")
        #expect(root[path: "url"]?.value == "https://example.org/a?b=c")
        #expect(root[path: "url"]?.className == "NSURL")
        #expect(root[path: "uuid"]?.value == uuid.uuidString)
        #expect(root[path: "null"]?.kind == .null)
        #expect(root[path: "array"]?.kind == .array)
        #expect(root[path: "array"]?.children.map(\.value) == ["a", "b"])
        #expect(root[path: "set"]?.kind == .set)
        #expect(root[path: "set", "[0]"]?.value == "only")
        #expect(root[path: "ordered"]?.children.map(\.value) == ["x", "y"])
        #expect(root[path: "mutable"]?.value == "changing")
        #expect(root[path: "mutable"]?.className == "NSMutableString")
        #expect(root[path: "relative"]?.value == "page.html (relative to https://example.org/dir/)")
    }

    @Test func showsAnUnknownClassAsItsNameAndFields() throws {
        let ada = Person(name: "Ada", age: 36, tags: ["maths", "engines"])
        let root = try root(ada)
        #expect(root.kind == .object)
        #expect(root.className == "DabbiTestPerson")
        #expect(root[path: "name"]?.value == "Ada")
        #expect(root[path: "age"]?.value == "36")
        #expect(root[path: "friend"]?.kind == .null)
        #expect(root[path: "tags"]?.children.map(\.value) == ["maths", "engines"])
    }

    @Test func aClassThatDoesNotExistHereIsShownAllTheSame() throws {
        let archiver = NSKeyedArchiver(requiringSecureCoding: false)
        archiver.setClassName("SomeApp.Customer", for: Person.self)
        archiver.encode(Person(name: "Grace", age: 85), forKey: NSKeyedArchiveRootObjectKey)
        archiver.finishEncoding()
        let root = try #require(tree(registry.decode(archiver.encodedData)))
        #expect(root.className == "SomeApp.Customer")
        #expect(root[path: "name"]?.value == "Grace")
    }

    @Test func anObjectGraphWithACycleEndsInAReference() throws {
        let ada = Person(name: "Ada", age: 36)
        let charles = Person(name: "Charles", age: 60)
        ada.friend = charles
        charles.friend = ada
        let root = try root(ada)
        #expect(root[path: "friend", "name"]?.value == "Charles")
        let back = try #require(root[path: "friend", "friend"])
        #expect(back.kind == .reference)
        #expect(back.value?.hasPrefix("DabbiTestPerson #") == true)
    }

    @Test func anXMLArchiveGivesTheSameTree() throws {
        let object: NSDictionary = ["list": [1, 2, 3], "who": Person(name: "Ada", age: 36, tags: ["x"]), "text": "é"]
        let binary = try root(object, format: .binary)
        let xml = try root(object, format: .xml)
        // An XML property list has its dictionaries sorted by key, so an object's fields come in another order.
        #expect(binary.sortedByKey() == xml.sortedByKey())
        #expect(xml[path: "who", "tags"]?.children.map(\.value) == ["x"])
    }

    @Test func severalTopLevelKeysBecomeADictionary() throws {
        let archiver = NSKeyedArchiver(requiringSecureCoding: false)
        archiver.encode("first", forKey: "a")
        archiver.encode(2, forKey: "b")
        archiver.finishEncoding()
        let root = try #require(tree(registry.decode(archiver.encodedData)))
        #expect(root.kind == .dictionary)
        #expect(root[path: "a"]?.value == "first")
        #expect(root[path: "b"]?.value == "2")
    }

    @Test func anArchiveInsideAnArchiveIsOpened() throws {
        let inner = try Corpus.archive(["secret": "inside"] as NSDictionary, format: .binary)
        let root = try root(["payload": inner] as NSDictionary)
        let payload = try #require(root[path: "payload"])
        #expect(payload.kind == .data)
        #expect(payload.value?.hasPrefix("archive, ") == true)
        #expect(payload[path: "contents", "secret"]?.value == "inside")
    }

    @Test func dictionaryKeysThatAreNotStringsStillLabelTheirValues() throws {
        let root = try root([7: "seven", ["compound", "key"] as NSArray: "object key"] as NSDictionary)
        #expect(root[path: "7"]?.value == "seven")
        let pair = try #require(root.children.first { $0.value == "key and value" })
        #expect(pair[path: "key"]?.children.map(\.value) == ["compound", "key"])
        #expect(pair[path: "value"]?.value == "object key")
    }

    @Test func summarisesAttributedStringsAndColours() throws {
        let text = try root(NSAttributedString(string: "Hello\nworld", attributes: [.foregroundColor: NSColor.red]))
        #expect(text.className == "NSAttributedString")
        #expect(text.value == "“Hello⏎world”")
        #expect(!text.children.isEmpty)

        let colour = try root(NSColor(srgbRed: 1, green: 0.5, blue: 0, alpha: 1))
        #expect(colour.className == "NSColor")
        #expect(colour.value == "rgba(1.0, 0.5, 0.0, 1.0) · #FF8000")

        let translucent = try root(NSColor(white: 0.5, alpha: 0.25))
        #expect(translucent.value == "rgba(0.5, 0.5, 0.5, 0.25) · #80808040")

        // Without a colour space of its own there is only `NSRGB`.
        #expect(
            try root(NSColor(calibratedRed: 0.2, green: 0.4, blue: 0.6, alpha: 1)).value?.hasSuffix("#336699") == true)

        #expect(try root(NSColor.controlAccentColor).value?.contains("controlAccentColor") == true)
    }

    // MARK: Hostile archives

    @Test func aPropertyListThatOnlyLooksLikeAnArchiveIsAPropertyList() throws {
        let data = try PropertyListSerialization.data(
            fromPropertyList: ["$archiver": "NSKeyedArchiver", "$objects": "not an array"], format: .binary, options: 0)
        let report = registry.decode(data)
        #expect(report.type == .binaryPlist)
        #expect(report.issues.isEmpty)
    }

    @Test func uidsThatLeadNowhereOrInCirclesEnd() throws {
        // $objects: 0 $null, 1 the root array, 2 a UID pointing at itself, 3 a UID pointing at 2.
        let data = handArchive([.array([10, 11, 12]), .uid(2), .uid(2), .uid(200), .uid(3)])
        // The root array's members are property-list indices: 8 + 2 = 10 is "UID 2" and so on.
        let root = try #require(tree(registry.decode(data)))
        #expect(root.kind == .array)
        #expect(root.children.map(\.kind) == [.uid, .uid, .truncated])
        #expect(root.children[2].value?.contains("UID 200") == true)
    }

    @Test func anObjectWhoseClassIsMissingIsShownWithoutOne() throws {
        // The root claims class UID 9, which the archive does not have.
        let data = handArchive([
            .dict([(10, 11), (12, 13)]), .ascii("$class"), .uid(9), .ascii("field"), .ascii("value"),
        ])
        let root = try #require(tree(registry.decode(data)))
        #expect(root.kind == .object)
        #expect(root.className == nil)
        #expect(root[path: "field"]?.value == "value")
    }

    @Test func deepObjectGraphsDoNotOverflowASmallStack() throws {
        // `NSKeyedArchiver` recurses too, and needs more stack to write this than a test thread has.
        let data = onThread(stackSize: 256 * 1024 * 1024) {
            let head = Person(name: "0", age: 0)
            var tail = head
            for index in 1..<2_000 {
                let next = Person(name: "\(index)", age: index)
                tail.friend = next
                tail = next
            }
            return try? Corpus.archive(head, format: .binary)
        }
        let archive = try #require(data)
        let outline = onSmallStack { tree(ContentRegistry.standard.decode(archive))?.outline() ?? "" }
        #expect(outline.contains("nested too deeply"))
    }
}
