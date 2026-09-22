@preconcurrency import CoreData
import DabbiModel
import Foundation

// A model built in code, the way the fixture generator builds its own (Tools/FixtureKit/ModelDSL.swift). The
// predicate core never touches a store, so these tests need the model and nothing else.

private func attribute(_ name: String, _ type: NSAttributeType) -> NSAttributeDescription {
    let attribute = NSAttributeDescription()
    attribute.name = name
    attribute.attributeType = type
    attribute.isOptional = true
    return attribute
}

private func composite(_ name: String, _ elements: [NSAttributeDescription]) -> NSCompositeAttributeDescription {
    let attribute = NSCompositeAttributeDescription()
    attribute.name = name
    attribute.isOptional = true
    attribute.elements = elements
    return attribute
}

private func relationship(
    _ name: String, to destination: NSEntityDescription, toMany: Bool
) -> NSRelationshipDescription {
    let relationship = NSRelationshipDescription()
    relationship.name = name
    relationship.destinationEntity = destination
    relationship.isOptional = true
    relationship.deleteRule = .nullifyDeleteRule
    relationship.minCount = 0
    relationship.maxCount = toMany ? 0 : 1
    return relationship
}

/// `Author` ↔ `Book` ↔ `Tag`, plus an abstract `Media` with a `Photo` child.
///
/// - `Author`: name, age, rating, birthday, identifier, homepage, avatar, settings, `books` (to-many)
/// - `Book`: title, price, pages, published, `place` (composite of latitude/longitude), `author` (to-one),
///   `tags` (to-many)
/// - `Tag`: label
/// - `Media` (abstract): title · `Photo`: width
let testModel: ModelDescription = {
    let author = NSEntityDescription()
    author.name = "Author"
    author.properties = [
        attribute("name", .stringAttributeType),
        attribute("age", .integer64AttributeType),
        attribute("rating", .doubleAttributeType),
        attribute("birthday", .dateAttributeType),
        attribute("identifier", .UUIDAttributeType),
        attribute("homepage", .URIAttributeType),
        attribute("avatar", .binaryDataAttributeType),
        attribute("settings", .transformableAttributeType),
    ]

    let book = NSEntityDescription()
    book.name = "Book"
    book.properties = [
        attribute("title", .stringAttributeType),
        attribute("price", .decimalAttributeType),
        attribute("pages", .integer32AttributeType),
        attribute("published", .dateAttributeType),
        composite(
            "place",
            [attribute("latitude", .doubleAttributeType), attribute("longitude", .doubleAttributeType)]),
    ]

    let tag = NSEntityDescription()
    tag.name = "Tag"
    tag.properties = [attribute("label", .stringAttributeType)]

    let books = relationship("books", to: book, toMany: true)
    let bookAuthor = relationship("author", to: author, toMany: false)
    books.inverseRelationship = bookAuthor
    bookAuthor.inverseRelationship = books
    author.properties.append(books)
    book.properties.append(bookAuthor)

    let tags = relationship("tags", to: tag, toMany: true)
    let taggedBooks = relationship("books", to: book, toMany: true)
    tags.inverseRelationship = taggedBooks
    taggedBooks.inverseRelationship = tags
    book.properties.append(tags)
    tag.properties.append(taggedBooks)

    let media = NSEntityDescription()
    media.name = "Media"
    media.isAbstract = true
    media.properties = [attribute("title", .stringAttributeType)]

    let photo = NSEntityDescription()
    photo.name = "Photo"
    photo.properties = [attribute("width", .integer32AttributeType)]
    media.subentities = [photo]

    let model = NSManagedObjectModel()
    model.entities = [author, book, tag, media, photo]
    return ModelDescription(model)
}()
