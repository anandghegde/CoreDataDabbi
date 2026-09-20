import ArgumentParser
import DabbiKit
import Foundation

struct Describe: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Show a store's model, format and row counts.")

    @OptionGroup var options: StoreOptions

    func run() async throws {
        try await withSession(options) { session in
            let counts = try await session.entityCounts()
            if options.json {
                try Output.printJSON(Description(store: session.info, counts: counts))
            } else {
                print(Self.text(session.info, counts: counts))
            }
        }
    }

    private struct Description: Encodable {
        let store: StoreInfo
        let counts: [EntityCount]
    }

    // MARK: Text

    static func text(_ info: StoreInfo, counts: [EntityCount]) -> String {
        let probe = info.probe
        let schema =
            info.schemaMap.isVerified
            ? "verified" : "unverified (\(info.schemaMap.unverified.joined(separator: ", ")))"
        var lines = [
            "Store     \(info.url.path)",
            "Model     \(modelOrigin(info.modelSource))",
            "Versions  \(info.model.versionIdentifiers.isEmpty ? "—" : info.model.versionIdentifiers.joined(separator: ", "))",
            "Format    model cache: \(yesNo(probe.hasModelCache)) · history: \(yesNo(probe.hasHistory))"
                + " · CloudKit mirroring: \(yesNo(probe.hasCloudKitMirroring)) · schema map: \(schema)",
        ]
        if !probe.otherTables.isEmpty {
            lines.append("Other     tables not owned by Core Data: \(probe.otherTables.joined(separator: ", "))")
        }

        let countsByEntity = Dictionary(counts.map { ($0.entity, $0) }, uniquingKeysWith: { first, _ in first })
        for entity in info.model.entities {
            lines.append("")
            lines.append(
                heading(entity, count: countsByEntity[entity.name], table: info.schemaMap.entities[entity.name]))
            let rows =
                entity.attributes.map { [$0.name, describe($0, in: entity)] }
                + entity.relationships.map { [$0.name, describe($0, in: entity)] }
            let width = rows.map { $0[0].count }.max() ?? 0
            for row in rows {
                lines.append("  " + row[0].padding(toLength: width, withPad: " ", startingAt: 0) + "  " + row[1])
            }
            for constraint in entity.uniquenessConstraints {
                lines.append("  unique: \(constraint.joined(separator: ", "))")
            }
            for index in entity.indexes {
                lines.append("  index \(index.name): \(index.elements.map(\.property).joined(separator: ", "))")
            }
        }

        for template in info.model.fetchRequestTemplates {
            lines.append("")
            lines.append(
                "Template \(template.name) on \(template.entity ?? "?"): \(template.predicateFormat ?? "all rows")")
        }
        return lines.joined(separator: "\n")
    }

    private static func heading(_ entity: EntityDescription, count: EntityCount?, table: SchemaMap.EntityMap?) -> String
    {
        var heading = entity.name
        if entity.isAbstract { heading += " (abstract)" }
        if let parent = entity.superentity { heading += " : \(parent)" }
        if let count {
            heading += " — \(count.total) row\(count.total == 1 ? "" : "s")"
            if count.own != count.total { heading += ", \(count.own) of exactly this entity" }
        }
        if let table { heading += "  [\(table.table)\(table.entityNumber.map { ", Z_ENT \($0)" } ?? "")]" }
        return heading
    }

    private static func describe(_ attribute: AttributeDescription, in entity: EntityDescription) -> String {
        var parts = [attribute.type.displayName]
        if let elements = attribute.compositeElements {
            parts[0] += " {" + elements.map { "\($0.name): \($0.type.displayName)" }.joined(separator: ", ") + "}"
        }
        if !attribute.isOptional { parts.append("required") }
        if attribute.isTransient { parts.append("transient") }
        if let expression = attribute.derivationExpression { parts.append("derived from \(expression)") }
        if let value = attribute.defaultValue {
            parts.append("default " + (attribute.type == .string ? "\"\(value)\"" : value))
        }
        if let transformer = attribute.valueTransformerName { parts.append("transformer \(transformer)") }
        if attribute.allowsExternalBinaryDataStorage { parts.append("external storage") }
        parts += attribute.validation.predicates
        if attribute.declaredIn != entity.name { parts.append("from \(attribute.declaredIn)") }
        return parts.joined(separator: ", ")
    }

    private static func describe(_ relationship: RelationshipDescription, in entity: EntityDescription) -> String {
        var parts = ["→ \(relationship.destinationEntity)"]
        parts.append(relationship.isToMany ? (relationship.isOrdered ? "ordered to-many" : "to-many") : "to-one")
        parts.append(relationship.inverseName.map { "inverse \($0)" } ?? "no inverse")
        if !relationship.isOptional { parts.append("required") }
        parts.append("delete: \(relationship.deleteRule.rawValue)")
        if relationship.declaredIn != entity.name { parts.append("from \(relationship.declaredIn)") }
        return parts.joined(separator: ", ")
    }

    private static func modelOrigin(_ source: ModelSource) -> String {
        switch source {
        case .storeCache: "cached in the store"
        case .userSelected(let files): files.map(\.lastPathComponent).joined(separator: " + ")
        case .appBundle(let bundle, let models):
            models.map(\.lastPathComponent).joined(separator: " + ") + " in \(bundle.lastPathComponent)"
        }
    }

    private static func yesNo(_ value: Bool) -> String { value ? "yes" : "no" }
}
