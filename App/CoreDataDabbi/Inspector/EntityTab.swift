import DabbiKit
import SwiftUI

/// What the model says about the entity in the grid (BRW-8).
///
/// Properties are collapsed to a name and a one-line summary; expanding one shows every facet Core Data
/// records. A property with something worth knowing — not optional, a cascade, a transformer the app will not
/// run — is marked, so that the things that bite can be found without opening every row.
struct EntityTab: View {
    let model: InspectorModel

    @State private var expanded: Set<String> = []
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        guard let facts = model.facts else {
            return AnyView(
                InspectorMessage(
                    symbol: "square.on.square.dashed",
                    title: String(localized: "No entity selected"),
                    detail: String(localized: "Choose an entity in the sidebar.")))
        }
        return AnyView(content(facts))
    }

    private func content(_ facts: EntityFacts) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(facts.entity.name)
                        .font(.title3.weight(.semibold))
                        .textSelection(.enabled)
                    ForEach(facts.summary) { fact in
                        FactRow(
                            label: fact.label, value: fact.value, weight: fact.weight,
                            isMonospaced: fact.label == String(localized: "Version hash"))
                    }
                }
                .font(.callout)
                .padding(.horizontal, 12)

                section(String(localized: "Attributes"), facts.attributes, of: facts.entity)
                section(String(localized: "Relationships"), facts.relationships, of: facts.entity)
                indexes(facts)
                constraints(facts)
                userInfo(facts)
            }
            .padding(.vertical, 12)
        }
        .scrollContentBackground(.hidden)
    }

    @ViewBuilder
    private func section(
        _ title: String, _ properties: [EntityFacts.Property], of entity: EntityDescription
    ) -> some View {
        if !properties.isEmpty {
            VStack(alignment: .leading, spacing: 2) {
                heading("\(title) (\(properties.count))")
                ForEach(properties) { property in
                    self.property(property, of: entity)
                }
            }
        }
    }

    private func property(_ property: EntityFacts.Property, of entity: EntityDescription) -> some View {
        let isOpen = expanded.contains(property.id)
        return VStack(alignment: .leading, spacing: 4) {
            Button {
                // Reduce Motion: the facets appear, the chevron is simply turned (§8.4).
                withAnimation(reduceMotion ? nil : .easeOut(duration: 0.12)) {
                    if isOpen { expanded.remove(property.id) } else { expanded.insert(property.id) }
                }
            } label: {
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Image(systemName: "chevron.right")
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(.tertiary)
                        .rotationEffect(.degrees(isOpen ? 90 : 0))
                        .accessibilityHidden(true)
                    VStack(alignment: .leading, spacing: 1) {
                        HStack(spacing: 5) {
                            Text(property.name)
                                .font(.callout.weight(.medium))
                                .foregroundStyle(.primary)
                            if property.isNotable {
                                Image(systemName: "exclamationmark.circle")
                                    .font(.caption2)
                                    .foregroundStyle(.orange)
                                    .accessibilityLabel(String(localized: "Has constraints"))
                            }
                            // An inherited property belongs to an ancestor; saying so explains why it is here.
                            if let declaredIn = property.declaredIn, declaredIn != entity.name {
                                Text(declaredIn)
                                    .font(.caption2)
                                    .padding(.horizontal, 4)
                                    .padding(.vertical, 1)
                                    .background(.quaternary, in: RoundedRectangle(cornerRadius: 3))
                                    .foregroundStyle(.secondary)
                            }
                        }
                        Text(property.summary)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Spacer(minLength: 0)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("\(property.name), \(property.summary)")
            .accessibilityHint(isOpen ? String(localized: "Collapse") : String(localized: "Expand"))

            if isOpen {
                VStack(alignment: .leading, spacing: 2) {
                    ForEach(property.facts) { fact in
                        FactRow(label: fact.label, value: fact.value, weight: fact.weight)
                    }
                }
                .font(.callout)
                .padding(.leading, 4)
                .padding(.bottom, 4)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 3)
    }

    @ViewBuilder
    private func indexes(_ facts: EntityFacts) -> some View {
        if !facts.indexes.isEmpty {
            VStack(alignment: .leading, spacing: 4) {
                heading(String(localized: "Indexes"))
                ForEach(facts.indexes) { index in
                    VStack(alignment: .leading, spacing: 1) {
                        Text(index.name).font(.callout.weight(.medium))
                        Text(index.elements.joined(separator: ", "))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        if let predicate = index.predicate {
                            Text(predicate)
                                .font(.system(.caption, design: .monospaced))
                                .foregroundStyle(.secondary)
                        }
                    }
                    .padding(.horizontal, 12)
                }
            }
        }
    }

    @ViewBuilder
    private func constraints(_ facts: EntityFacts) -> some View {
        if !facts.uniquenessConstraints.isEmpty {
            VStack(alignment: .leading, spacing: 4) {
                heading(String(localized: "Uniqueness constraints"))
                ForEach(Array(facts.uniquenessConstraints.enumerated()), id: \.offset) { _, constraint in
                    Text(constraint.joined(separator: " + "))
                        .font(.callout)
                        .padding(.horizontal, 12)
                }
            }
        }
    }

    @ViewBuilder
    private func userInfo(_ facts: EntityFacts) -> some View {
        if !facts.userInfo.isEmpty {
            VStack(alignment: .leading, spacing: 2) {
                heading(String(localized: "User info"))
                ForEach(facts.userInfo) { fact in
                    FactRow(label: fact.label, value: fact.value)
                }
            }
            .font(.callout)
        }
    }

    private func heading(_ title: String) -> some View {
        Text(title.localizedUppercase)
            .font(.caption.weight(.semibold))
            .foregroundStyle(.secondary)
            .padding(.horizontal, 12)
            .padding(.top, 4)
            .accessibilityAddTraits(.isHeader)
    }
}
