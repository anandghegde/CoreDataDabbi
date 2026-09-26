@preconcurrency import CoreData
import DabbiBase
import DabbiModel
import Foundation

/// One row of an import, as the store takes it: property names and values, already coerced from the file's text
/// (IMX-2). `DabbiExchange` makes these from a CSV or JSON file and an `ImportMapping`.
public struct ImportRow: Sendable, Hashable {
    /// Where the row is in its file: a CSV line, or a position in a JSON array. Reports name rows by it.
    public var line: Int
    /// The URI the row was exported with (`$id`): the object an upsert updates, when it is in this store.
    public var id: URL?
    /// Property name → value. A property that is not here is left as it is.
    public var values: [String: ImportValue]
    /// What was wrong before the store was asked: a cell that is not a value of its column's type. A row with
    /// issues fails without being tried.
    public var issues: [ImportIssue]

    public init(line: Int, id: URL? = nil, values: [String: ImportValue] = [:], issues: [ImportIssue] = []) {
        self.line = line
        self.id = id
        self.values = values
        self.issues = issues
    }
}

/// A value an import sets.
public indirect enum ImportValue: Sendable, Hashable {
    /// An attribute's value, or `.null` for none — for a relationship too, which it empties.
    case value(Value)
    /// A binary attribute's bytes.
    case data(Data)
    /// Some of a composite attribute's elements; the ones not here keep their values.
    case composite([String: ImportValue])
    /// The objects a relationship is to lead to: all of them, replacing what it leads to now.
    case references([ImportReference])
}

/// An object a relationship is to lead to (IMX-4): by URI, or by the values of the destination's attributes —
/// a key, which exactly one object has to match.
public enum ImportReference: Sendable, Hashable {
    case uri(URL)
    case key([String: Value])
}

/// What is wrong with a row. Never the value itself (privacy): which property, and which rule.
public struct ImportIssue: Sendable, Hashable, CustomStringConvertible {
    /// The property, or column, the issue is about; `nil` for the row as a whole.
    public var property: String?
    public var message: String

    public init(property: String?, message: String) {
        self.property = property
        self.message = message
    }

    public var description: String { property.map { "\($0): \(message)" } ?? message }
}

public struct ImportOptions: Sendable, Hashable {
    public enum Mode: String, Sendable, Hashable, CaseIterable {
        /// Nothing is staged unless every row can be (IMX-3).
        case allOrNothing
        /// The rows that can be staged are; the others are reported and left out.
        case skipInvalid
    }

    public var mode: Mode
    /// Whether a row that matches an object — by its `$id`, or by a uniqueness constraint's values — updates
    /// that object instead of inserting another (IMX-4). Rows that match nothing are inserted either way.
    public var upsert: Bool
    /// The undo menu's name for the edit; “Import” when not given. Pass it localised.
    public var actionName: String?

    public init(mode: Mode = .allOrNothing, upsert: Bool = false, actionName: String? = nil) {
        self.mode = mode
        self.upsert = upsert
        self.actionName = actionName
    }
}

/// What happened, or would happen, to each row.
public struct ImportRowResult: Sendable, Hashable {
    public enum Outcome: String, Sendable, Hashable {
        case inserted, updated
        /// The row matched an object that already has every value it gives.
        case unchanged
        case failed
    }

    public var line: Int
    public var outcome: Outcome
    public var issues: [ImportIssue]
    /// The object the row inserted or updated — once staged. A dry run's new objects have none.
    public var object: PendingObjectID?

    public init(line: Int, outcome: Outcome, issues: [ImportIssue] = [], object: PendingObjectID? = nil) {
        self.line = line
        self.outcome = outcome
        self.issues = issues
        self.object = object
    }
}

public struct ImportReport: Sendable, Hashable {
    public var rows: [ImportRowResult]
    /// Whether rows were staged. A dry run stages nothing, and neither does an all-or-nothing import with a row
    /// that fails.
    public var isApplied: Bool

    public init(rows: [ImportRowResult], isApplied: Bool) {
        self.rows = rows
        self.isApplied = isApplied
    }

    public func count(_ outcome: ImportRowResult.Outcome) -> Int { rows.count { $0.outcome == outcome } }
    public var failed: [ImportRowResult] { rows.filter { $0.outcome == .failed } }
}

/// Staged imports (IMX-2 – IMX-4).
///
/// A dry run tries every row in a scratch context that sees what is staged and is thrown away afterwards — the
/// undo and redo stacks never hear of it. An import runs the dry run first, then stages the rows that passed, as
/// one undoable edit that Commit writes, pre-commit backup and all, like any other.
///
/// Every row is checked as the commit would check it: the model's validation, and the uniqueness constraints
/// against the store, what is staged and the rows before it. A row that fails leaves nothing behind, so the rows
/// after it are tried against the same state whether it is left out or not.
extension StoreSession {
    /// What importing `rows` into `entity` would do, row by row. Nothing is staged.
    public func previewImport(
        _ rows: [ImportRow], into entity: String, options: ImportOptions = .init()
    ) async throws -> ImportReport {
        let plan = try importPlan(rows, into: entity, options: options)
        let results = try await stack.performScratch { context in
            try Self.importRows(rows, plan: plan, in: context, staging: false).results
        }
        return ImportReport(rows: results, isApplied: false)
    }

    /// Imports `rows` into `entity`: a dry run, then — unless the options' mode refuses because a row failed —
    /// the rows that passed, staged as one undoable edit. The report is the dry run's, with the staged objects.
    ///
    /// Throws `.importRejected`, with nothing staged, when a row that passed the dry run fails when staged, which
    /// only another edit made in between can cause.
    public func importRows(
        _ rows: [ImportRow], into entity: String, options: ImportOptions = .init()
    ) async throws -> (report: ImportReport, changes: PendingChanges) {
        var report = try await previewImport(rows, into: entity, options: options)
        let passed = Set(report.rows.filter { $0.outcome == .inserted || $0.outcome == .updated }.map(\.line))
        guard !passed.isEmpty, options.mode == .skipInvalid || report.failed.isEmpty else {
            return (report, try await pendingChanges())
        }
        let staged = rows.filter { passed.contains($0.line) }
        let plan = try importPlan(staged, into: entity, options: options)
        let converter = stack.converter
        let (outcome, changes) = try await stack.edit(actionName: options.actionName ?? "Import") { context in
            let outcome = try Self.importRows(staged, plan: plan, in: context, staging: true)
            if let failed = outcome.results.first(where: { $0.outcome == .failed }) {
                throw DabbiError(
                    .importRejected,
                    "Line \(failed.line) could not be imported after all. Nothing was imported.",
                    arguments: ["line": String(failed.line)],
                    diagnosis: failed.issues.map(\.description),
                    recovery: ["Run the import again."])
            }
            return ImportOutcome(
                results: outcome.results,
                inserted: outcome.inserted.map { ($0.objectID, converter.pendingID(of: $0)) })
        }
        for (id, object) in outcome.inserted { insertedObjectIDs[object.uri] = id }
        let objects = Dictionary(outcome.results.map { ($0.line, $0.object) }, uniquingKeysWith: { first, _ in first })
        for index in report.rows.indices where passed.contains(report.rows[index].line) {
            report.rows[index].object = objects[report.rows[index].line] ?? nil
        }
        report.isApplied = true
        return (report, changes)
    }

    // MARK: Planning

    /// What the rows need that only the actor has: the entity, and the objects their URIs name.
    private func importPlan(_ rows: [ImportRow], into name: String, options: ImportOptions) throws -> ImportPlan {
        try ensureOpen()
        guard stack.isEditable else { throw CoreDataStack.notEditable }
        let entity = try entityDescription(name)
        var urls = Set<URL>()
        for row in rows {
            if let id = row.id { urls.insert(id) }
            for value in row.values.values {
                guard case .references(let references) = value else { continue }
                for case .uri(let url) in references { urls.insert(url) }
            }
        }
        var known: [URL: NSManagedObjectID] = [:]
        for url in urls {
            if let id = insertedObjectIDs[url] {
                known[url] = id
            } else if let ref = ObjectRef(uri: url), let id = stack.objectID(for: ref) {
                known[url] = id
            }
        }
        return ImportPlan(
            entity: entity, model: info.model, converter: stack.converter, knownIDs: known, upsert: options.upsert)
    }

    // MARK: Rows

    /// Tries `rows` in order in `context`. A row that fails is taken back before the next is tried. Staging, the
    /// objects inserted are returned too, for their temporary IDs.
    private static func importRows(
        _ rows: [ImportRow], plan: ImportPlan, in context: NSManagedObjectContext, staging: Bool
    ) throws -> (results: [ImportRowResult], inserted: [NSManagedObject]) {
        var results: [ImportRowResult] = []
        var inserted: [NSManagedObject] = []
        for row in rows {
            let result = try objcGuarded("Line \(row.line) could not be imported.", code: .importRejected) {
                try importRow(row, plan: plan, in: context)
            }
            if staging, result.outcome == .inserted, let object = result.object { inserted.append(object) }
            let object = staging && result.outcome != .failed ? result.object.map(plan.converter.pendingID(of:)) : nil
            results.append(
                ImportRowResult(line: row.line, outcome: result.outcome, issues: result.issues, object: object))
        }
        return (results, inserted)
    }

    private static func importRow(
        _ row: ImportRow, plan: ImportPlan, in context: NSManagedObjectContext
    ) throws -> (outcome: ImportRowResult.Outcome, issues: [ImportIssue], object: NSManagedObject?) {
        guard row.issues.isEmpty else { return (.failed, row.issues, nil) }
        let entity = plan.entity
        var issues: [ImportIssue] = []
        let target: NSManagedObject
        let isInsert: Bool
        if plan.upsert, let match = try plan.match(row, in: context) {
            (target, isInsert) = (match, false)
        } else {
            guard !entity.isAbstract else {
                return (
                    .failed,
                    [
                        ImportIssue(
                            property: nil, message: "\(entity.name) is abstract and cannot have objects of its own.")
                    ],
                    nil
                )
            }
            target = NSEntityDescription.insertNewObject(forEntityName: entity.name, into: context)
            isInsert = true
        }
        let description = plan.model.entity(named: target.entity.name ?? entity.name) ?? entity

        // What the row changes, for taking an update back.
        var previous: [String: Any?] = [:]
        var changed = false
        for (property, value) in row.values.sorted(by: { $0.key < $1.key }) {
            let current = target.value(forKey: property)
            do {
                let new: Any?
                if let attribute = description.attribute(named: property) {
                    new = try plan.raw(value, for: attribute, of: description.name, current: current)
                } else if let relationship = description.relationship(named: property), !relationship.isTransient {
                    new = try plan.destinations(value, for: relationship, of: description.name, in: context)
                } else {
                    throw ImportIssue(property: property, message: "\(description.name) has no property by this name.")
                }
                guard !Self.same(current, new) else { continue }
                previous[property] = Self.copy(current)
                target.setValue(new, forKey: property)
                changed = true
            } catch let issue as ImportIssue {
                issues.append(issue)
            } catch let error as DabbiError {
                issues.append(ImportIssue(property: property, message: error.message))
            }
        }

        if issues.isEmpty {
            issues += plan.validate(target, isInsert: isInsert || target.isInserted)
            issues += try plan.uniquenessIssues(of: target, in: context)
        }
        guard issues.isEmpty else {
            if isInsert {
                // Emptied first, so that deleting it cascades to nothing it was linked to.
                for relationship in description.relationships where !relationship.isTransient {
                    target.setValue(nil, forKey: relationship.name)
                }
                context.delete(target)
            } else {
                for (property, value) in previous { target.setValue(value ?? nil, forKey: property) }
            }
            return (.failed, issues, nil)
        }
        return (isInsert ? .inserted : changed ? .updated : .unchanged, [], target)
    }

    /// Whether setting `new` would change nothing. Core Data counts setting the same value as a change.
    private static func same(_ current: Any?, _ new: Any?) -> Bool {
        switch (current, new) {
        case (nil, nil): return true
        case (let set as NSSet, nil), (nil, let set as NSSet): return set.count == 0
        case (let set as NSOrderedSet, nil), (nil, let set as NSOrderedSet): return set.count == 0
        case (let a as NSObject, let b as NSObject): return a == b
        default: return false
        }
    }

    /// A to-many's value is live; what it held is kept as a copy.
    private static func copy(_ value: Any?) -> Any? {
        switch value {
        case let set as NSOrderedSet: set.copy()
        case let set as NSSet: set.copy()
        default: value
        }
    }
}

/// The result of staging an import, out of the edit context.
private struct ImportOutcome: @unchecked Sendable {
    var results: [ImportRowResult]
    var inserted: [(NSManagedObjectID, PendingObjectID)]
}

extension ImportIssue: Error {}

/// Everything a row is tried with, on the context's queue. The object IDs were looked up on the actor.
private struct ImportPlan: @unchecked Sendable {
    let entity: EntityDescription
    let model: ModelDescription
    let converter: ValueConverter
    let knownIDs: [URL: NSManagedObjectID]
    let upsert: Bool

    private var allowed: Set<String> { Set(model.entityAndDescendants(of: entity.name).map(\.name)) }

    // MARK: Matching

    /// The object an upsert updates: the one the row's `$id` names, or else the one with the row's values for a
    /// uniqueness constraint.
    func match(_ row: ImportRow, in context: NSManagedObjectContext) throws -> NSManagedObject? {
        if let url = row.id, let id = knownIDs[url], allowed.contains(id.entity.name ?? ""),
            let object = try? context.existingObject(with: id), !object.isDeleted
        {
            return object
        }
        for constraint in entity.uniquenessConstraints {
            var terms: [NSPredicate] = []
            for name in constraint {
                guard let attribute = entity.attribute(named: name), case .value(let value)? = row.values[name],
                    !value.isNull, let raw = try? converter.raw(value, for: attribute, of: entity.name)
                else { break }
                terms.append(NSPredicate(format: "%K == %@", name, raw as! NSObject))
            }
            guard terms.count == constraint.count, !terms.isEmpty else { continue }
            let request = NSFetchRequest<NSManagedObject>(entityName: entity.name)
            request.predicate = NSCompoundPredicate(andPredicateWithSubpredicates: terms)
            request.fetchLimit = 1
            if let found = try context.fetch(request).first { return found }
        }
        return nil
    }

    // MARK: Values

    /// What to set `attribute` to. A composite keeps the elements the row does not give.
    func raw(_ value: ImportValue, for attribute: AttributeDescription, of entity: String, current: Any?) throws -> Any?
    {
        func refused(_ reason: String) -> ImportIssue {
            ImportIssue(property: attribute.name, message: reason)
        }
        if attribute.isTransient || attribute.isDerived {
            throw refused("It is \(attribute.isTransient ? "transient" : "derived") and not set directly.")
        }
        switch (value, attribute.type) {
        case (.value(.null), _):
            return nil
        case (.data(let data), .binaryData):
            return data
        case (.composite(let elements), .composite):
            var dictionary = (current as? [String: Any]) ?? [:]
            for (name, element) in elements {
                guard let description = attribute.compositeElements?.first(where: { $0.name == name }) else {
                    throw refused("The composite has no element named “\(name)”.")
                }
                dictionary[name] = try raw(element, for: description, of: entity, current: dictionary[name])
            }
            // A composite with no element that has a value is none: what an export of none reads back as.
            return dictionary.isEmpty ? nil : dictionary as NSDictionary
        case (.value(let value), .string), (.value(let value), .integer16), (.value(let value), .integer32),
            (.value(let value), .integer64), (.value(let value), .decimal), (.value(let value), .double),
            (.value(let value), .float), (.value(let value), .boolean), (.value(let value), .date),
            (.value(let value), .uuid), (.value(let value), .uri):
            return try converter.raw(value, for: attribute, of: entity)
        case (.references, _):
            throw refused("It is an attribute, not a relationship.")
        default:
            throw refused("This is not a value of a \(attribute.type.displayName) attribute.")
        }
    }

    /// What to set `relationship` to: an object or none for a to-one, a set for a to-many.
    func destinations(
        _ value: ImportValue, for relationship: RelationshipDescription, of entity: String,
        in context: NSManagedObjectContext
    ) throws -> Any? {
        let references: [ImportReference]
        switch value {
        case .value(.null): references = []
        case .references(let given): references = given
        default: throw ImportIssue(property: relationship.name, message: "It is a relationship; give it objects.")
        }
        let allowed = Set(model.entityAndDescendants(of: relationship.destinationEntity).map(\.name))
        let objects = try references.map { reference in
            let object = try find(reference, destination: relationship.destinationEntity, in: context)
            guard allowed.contains(object.entity.name ?? "") else {
                throw ImportIssue(
                    property: relationship.name,
                    message:
                        "It leads to \(relationship.destinationEntity), not \(object.entity.name ?? "this entity").")
            }
            return object
        }
        func issue(_ message: String) -> ImportIssue { ImportIssue(property: relationship.name, message: message) }
        if relationship.isOrdered { return NSOrderedSet(array: objects) }
        if relationship.isToMany { return NSSet(array: objects) }
        guard objects.count <= 1 else { throw issue("It is a to-one relationship; give it one object.") }
        return objects.first
    }

    private func find(
        _ reference: ImportReference, destination: String, in context: NSManagedObjectContext
    ) throws -> NSManagedObject {
        switch reference {
        case .uri(let url):
            guard let id = knownIDs[url], let object = try? context.existingObject(with: id), !object.isDeleted else {
                throw ImportIssue(property: nil, message: "No object in this store has the URI given.")
            }
            return object
        case .key(let key):
            guard let description = model.entity(named: destination), !key.isEmpty else {
                throw ImportIssue(property: nil, message: "No key was given.")
            }
            var terms: [NSPredicate] = []
            for (name, value) in key.sorted(by: { $0.key < $1.key }) {
                guard let attribute = description.attribute(named: name) else {
                    throw ImportIssue(property: nil, message: "\(destination) has no attribute “\(name)”.")
                }
                let raw = try converter.raw(value, for: attribute, of: destination)
                terms.append(
                    raw.map { NSPredicate(format: "%K == %@", name, $0 as! NSObject) }
                        ?? NSPredicate(format: "%K == nil", name))
            }
            let request = NSFetchRequest<NSManagedObject>(entityName: destination)
            request.predicate = NSCompoundPredicate(andPredicateWithSubpredicates: terms)
            request.fetchLimit = 2
            let found = try context.fetch(request)
            guard found.count == 1 else {
                throw ImportIssue(
                    property: nil,
                    message: found.isEmpty
                        ? "No \(destination) has the key given." : "More than one \(destination) has the key given.")
            }
            return found[0]
        }
    }

    // MARK: Checking

    /// The model's validation, as the commit would ask it.
    func validate(_ object: NSManagedObject, isInsert: Bool) -> [ImportIssue] {
        let translator = ValidationTranslator(converter: converter)
        do {
            try objcGuarded("The object could not be validated.", code: .internal) {
                if isInsert { try object.validateForInsert() } else { try object.validateForUpdate() }
            }
            return []
        } catch is DabbiError {
            return [ImportIssue(property: nil, message: "The object could not be validated.")]
        } catch {
            let issues = ValidationTranslator.sorted(translator.issues(from: error, validating: object))
            guard !issues.isEmpty else {
                return [ImportIssue(property: nil, message: "The object does not pass the model's validation.")]
            }
            return issues.map { ImportIssue(property: $0.property, message: $0.message) }
        }
    }

    /// Another object — in the store, staged, or imported by an earlier row — with the same values for one of the
    /// entity's uniqueness constraints. SQLite would refuse the commit; this says which row.
    func uniquenessIssues(of object: NSManagedObject, in context: NSManagedObjectContext) throws -> [ImportIssue] {
        var issues: [ImportIssue] = []
        var name = object.entity.name
        while let current = name, let description = model.entity(named: current) {
            for constraint in description.uniquenessConstraints {
                // A constraint the parent declares too is checked there, across all of its sub-entities.
                if let parent = description.superentity.flatMap(model.entity(named:)),
                    parent.uniquenessConstraints.contains(constraint)
                {
                    continue
                }
                var terms = [NSPredicate(format: "self != %@", object)]
                for key in constraint {
                    guard let value = object.value(forKey: key) as? NSObject else { break }
                    terms.append(NSPredicate(format: "%K == %@", key, value))
                }
                guard terms.count == constraint.count + 1 else { continue }
                let request = NSFetchRequest<NSManagedObject>(entityName: current)
                request.predicate = NSCompoundPredicate(andPredicateWithSubpredicates: terms)
                if try context.count(for: request) > 0 {
                    issues.append(
                        ImportIssue(
                            property: constraint.joined(separator: ", "),
                            message: ValidationTranslator.message(
                                for: .notUnique, limit: nil, count: nil, isRelationship: false)))
                }
            }
            name = description.superentity
        }
        return issues
    }
}
