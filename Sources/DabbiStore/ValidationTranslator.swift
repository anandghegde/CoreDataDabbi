@preconcurrency import CoreData
import DabbiBase
import DabbiModel
import Foundation

/// Core Data's validation errors as `ValidationIssue`s: one per object, property and rule, in plain language
/// (EDT-2, ARCHITECTURE.md §6.4).
///
/// Core Data says which rule broke in two ways. A model made in Xcode gives each rule its own error code —
/// `NSValidationStringTooShortError` for a minimum length. A model built in code may give a rule a message of
/// its own instead, and Core Data then reports the generic `NSManagedObjectValidationError` with the predicate
/// that failed. Both come out as the same issue: the code decides the rule when it names one, the predicate's
/// shape when it does not, and the model supplies the figure the rule is about when the predicate cannot.
///
/// Inside `context.perform` only: it reads the objects the errors name.
///
/// Privacy: the value that broke the rule (`NSValidationValueErrorKey`) is never read.
struct ValidationTranslator: Sendable {
    let converter: ValueConverter

    // MARK: Asking Core Data

    /// Every rule the edit context's staged objects break: the questions `save()` asks, asked now. Inserted
    /// objects are validated for insert, updated ones for update, and deleted ones for delete — the Deny rules.
    ///
    /// Uniqueness constraints are not among them: SQLite checks those, and only a save asks it.
    func issues(in context: NSManagedObjectContext) -> [ValidationIssue] {
        var issues: [ValidationIssue] = []
        func validate(_ objects: Set<NSManagedObject>, _ check: (NSManagedObject) throws -> Void) {
            for object in objects {
                do {
                    try objcGuarded("The object could not be validated.", code: .internal) { try check(object) }
                } catch is DabbiError {
                    // Validation raised rather than answering, which the commit will do too. Say so, since there
                    // is nothing more precise to say.
                    issues.append(issue(object, property: nil, rule: .other))
                } catch {
                    let found = self.issues(from: error, validating: object)
                    issues += found.isEmpty ? [issue(object, property: nil, rule: .other)] : found
                }
            }
        }
        validate(context.insertedObjects) { try $0.validateForInsert() }
        validate(context.updatedObjects) { try $0.validateForUpdate() }
        validate(context.deletedObjects) { try $0.validateForDelete() }
        return Self.sorted(issues)
    }

    // MARK: Translating

    /// Whether `error` is one of Core Data's validation errors, several of them together included.
    static func isValidationError(_ error: any Error) -> Bool {
        let nsError = error as NSError
        return nsError.domain == NSCocoaErrorDomain
            && (NSManagedObjectValidationError...invalidURIError).contains(nsError.code)
    }

    /// The issues `error` reports, with `NSDetailedErrorsKey` unfolded. `object` is the object that was validated,
    /// for an error that does not name one. Anything that is not a validation error reports nothing.
    func issues(from error: any Error, validating object: NSManagedObject? = nil) -> [ValidationIssue] {
        let nsError = error as NSError
        if let details = nsError.userInfo[NSDetailedErrorsKey] as? [NSError], !details.isEmpty {
            return details.flatMap { issues(from: $0, validating: object) }
        }
        guard Self.isValidationError(nsError),
            let target = (nsError.userInfo[NSValidationObjectErrorKey] as? NSManagedObject) ?? object
        else { return [] }

        let key = nsError.userInfo[NSValidationKeyErrorKey] as? String
        let layout = target.entity.name.flatMap { converter.layouts[$0] }
        let attribute = key.flatMap { layout?.attributes[$0] }
        let relationship = key.flatMap { layout?.relationships[$0] }
        let isDate = attribute?.type == .date
        let predicate = nsError.userInfo[NSValidationPredicateErrorKey] as? NSPredicate
        let shape = predicate.flatMap { Self.shape(of: $0, isDate: isDate) }

        let rule: ValidationIssue.Rule = Self.rule(forCode: nsError.code, isDate: isDate) ?? shape?.rule ?? .other
        var limit: String? = shape?.rule == rule ? shape?.limit : nil
        if limit == nil {
            limit = rule == .other ? predicate?.predicateFormat : Self.limit(of: rule, attribute, relationship)
        }
        var count: Int?
        if rule == .deleteDenied, let key {
            count = Self.count(of: target.value(forKey: key))
        }
        return [issue(target, property: key, rule: rule, limit: limit, count: count)]
    }

    /// An issue of `object`'s, with its message.
    func issue(
        _ object: NSManagedObject, property: String?, rule: ValidationIssue.Rule, limit: String? = nil,
        count: Int? = nil
    ) -> ValidationIssue {
        let relationships = object.entity.name.flatMap { converter.layouts[$0]?.relationships }
        let isRelationship = property.map { relationships?[$0] != nil } ?? false
        return ValidationIssue(
            object: converter.pendingID(of: object), property: property, rule: rule, limit: limit, count: count,
            message: Self.message(for: rule, limit: limit, count: count, isRelationship: isRelationship))
    }

    /// By object, then property and rule, each once.
    static func sorted(_ issues: [ValidationIssue]) -> [ValidationIssue] {
        Set(issues).sorted {
            ($0.object.entity, $0.object.uri.absoluteString, $0.property ?? "", $0.rule.rawValue)
                < ($1.object.entity, $1.object.uri.absoluteString, $1.property ?? "", $1.rule.rawValue)
        }
    }

    // MARK: Rules

    /// `NSManagedObjectConstraintValidationError` and `NSValidationInvalidURIError`, the two codes of the range
    /// that came later than the rest (macOS 10.11 and 10.13). Spelled out, so that the range is plain to read.
    private static let constraintValidationError = 1551
    private static let invalidURIError = 1690

    /// The rule a specific error code stands for; `nil` for the generic codes, which name none.
    private static func rule(forCode code: Int, isDate: Bool) -> ValidationIssue.Rule? {
        switch code {
        case NSValidationMissingMandatoryPropertyError: .required
        case NSValidationRelationshipLacksMinimumCountError: .tooFewObjects
        case NSValidationRelationshipExceedsMaximumCountError: .tooManyObjects
        case NSValidationRelationshipDeniedDeleteError: .deleteDenied
        case NSValidationNumberTooLargeError: isDate ? .tooLate : .aboveMaximum
        case NSValidationNumberTooSmallError: isDate ? .tooEarly : .belowMinimum
        case NSValidationDateTooLateError: .tooLate
        case NSValidationDateTooSoonError: .tooEarly
        case NSValidationInvalidDateError: .invalidDate
        case NSValidationStringTooLongError: .tooLong
        case NSValidationStringTooShortError: .tooShort
        case NSValidationStringPatternMatchingError: .patternMismatch
        case constraintValidationError: .notUnique
        case invalidURIError: .invalidURI
        default: nil
        }
    }

    /// A failed rule in one of the shapes the model editor writes — `SELF >= min`, `SELF <= max`,
    /// `SELF MATCHES regex`, `length >= n`, `length <= n` — as the rule it is and the figure it names.
    private static func shape(
        of predicate: NSPredicate, isDate: Bool
    ) -> (rule: ValidationIssue.Rule, limit: String)? {
        guard let comparison = predicate as? NSComparisonPredicate,
            comparison.rightExpression.expressionType == .constantValue,
            let constant = comparison.rightExpression.constantValue
        else { return nil }
        let left = comparison.leftExpression
        let rule: ValidationIssue.Rule
        switch (left.expressionType, comparison.predicateOperatorType) {
        case (.evaluatedObject, .greaterThanOrEqualTo): rule = isDate ? .tooEarly : .belowMinimum
        case (.evaluatedObject, .lessThanOrEqualTo): rule = isDate ? .tooLate : .aboveMaximum
        case (.evaluatedObject, .matches): rule = .patternMismatch
        case (.keyPath, .greaterThanOrEqualTo) where left.keyPath == "length": rule = .tooShort
        case (.keyPath, .lessThanOrEqualTo) where left.keyPath == "length": rule = .tooLong
        default: return nil
        }
        return (rule, String(describing: constant))
    }

    /// The figure the model gives for `rule`, when the error did not carry it.
    private static func limit(
        of rule: ValidationIssue.Rule, _ attribute: AttributeDescription?, _ relationship: RelationshipDescription?
    ) -> String? {
        let facets = attribute?.validation
        switch rule {
        case .tooShort: return facets?.minimumLength.map(String.init)
        case .tooLong: return facets?.maximumLength.map(String.init)
        case .belowMinimum, .tooEarly: return facets?.minimum
        case .aboveMaximum, .tooLate: return facets?.maximum
        case .patternMismatch: return facets?.regularExpression
        // A relationship that is not optional needs one object even when its minimum says nothing.
        case .tooFewObjects: return relationship.map { String(max($0.minCount, 1)) }
        case .tooManyObjects: return relationship.flatMap { $0.maxCount > 0 ? String($0.maxCount) : nil }
        default: return nil
        }
    }

    /// How many objects a relationship's value holds; `nil` for anything else.
    static func count(of raw: Any?) -> Int? {
        switch raw {
        case let set as NSSet: set.count
        case let set as NSOrderedSet: set.count
        case is NSManagedObject: 1
        default: nil
        }
    }

    /// The rule, said about the property it is about.
    static func message(
        for rule: ValidationIssue.Rule, limit: String?, count: Int?, isRelationship: Bool
    ) -> String {
        func plural(_ figure: String, _ one: String, _ many: String) -> String {
            "\(figure) \(figure == "1" ? one : many)"
        }
        switch rule {
        case .required:
            return isRelationship ? "An object is required." : "A value is required."
        case .tooShort:
            return limit.map { "Must be at least \(plural($0, "character", "characters")) long." }
                ?? "Is shorter than the model allows."
        case .tooLong:
            return limit.map { "Must be at most \(plural($0, "character", "characters")) long." }
                ?? "Is longer than the model allows."
        case .belowMinimum:
            return limit.map { "Must be at least \($0)." } ?? "Is below the model's minimum."
        case .aboveMaximum:
            return limit.map { "Must be at most \($0)." } ?? "Is above the model's maximum."
        case .tooEarly:
            return limit.map { "Must be no earlier than \($0)." } ?? "Is earlier than the model allows."
        case .tooLate:
            return limit.map { "Must be no later than \($0)." } ?? "Is later than the model allows."
        case .invalidDate:
            return "Is not a valid date."
        case .patternMismatch:
            return limit.map { "Must match the pattern \($0)." } ?? "Does not match the model's pattern."
        case .invalidURI:
            return "Is not a URI Core Data can store."
        case .tooFewObjects:
            return limit.map { "Must have at least \(plural($0, "object", "objects"))." }
                ?? "Has fewer objects than the model allows."
        case .tooManyObjects:
            return limit.map { "Must have at most \(plural($0, "object", "objects"))." }
                ?? "Has more objects than the model allows."
        case .deleteDenied:
            return count.map {
                "Still has \(plural(String($0), "object", "objects")), and its delete rule is Deny."
            } ?? "Still has objects, and its delete rule is Deny."
        case .notUnique:
            return "Must be unique, and another object has the same value."
        case .other:
            return limit.map { "Does not satisfy the model's rule \($0)." } ?? "Does not pass the model's validation."
        }
    }
}
