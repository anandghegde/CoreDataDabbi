import DabbiKit
import SwiftUI

/// How the entity is really stored: the table, its columns, its indexes and the DDL (BRW-8, PRJ-13).
///
/// The Entity tab is what the model promises; this is what the file has. They disagree after a migration that
/// half-happened, and this is the tab that shows it.
struct StructureTab: View {
    let model: InspectorModel

    var body: some View {
        if let error = model.structureError {
            InspectorMessage(
                symbol: "exclamationmark.triangle",
                title: error.errorDescription ?? String(localized: "The table could not be read."),
                detail: error.recoverySuggestion)
        } else if let structure = model.structure {
            content(structure)
        } else if model.entityName == nil {
            InspectorMessage(
                symbol: "tablecells.badge.ellipsis",
                title: String(localized: "No entity selected"),
                detail: String(localized: "Choose an entity in the sidebar."))
        } else {
            ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private func content(_ structure: TableStructure) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 6) {
                        Text(structure.table)
                            .font(.title3.weight(.semibold).monospaced())
                            .textSelection(.enabled)
                        Spacer(minLength: 0)
                        Button {
                            NSPasteboard.general.clearContents()
                            NSPasteboard.general.setString(structure.script, forType: .string)
                        } label: {
                            Image(systemName: "doc.on.doc")
                        }
                        .buttonStyle(.borderless)
                        .help(String(localized: "Copy the SQL for this table and its indexes"))
                        .accessibilityLabel(String(localized: "Copy SQL"))
                    }
                    if structure.table != "Z" + structure.entity.uppercased() {
                        // Every entity of an inheritance chain lives in the root's table; that is why the columns
                        // below include ones this entity never uses.
                        Text("Shared with everything that inherits from the same root entity.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                .padding(.horizontal, 12)

                columns(structure.columns)
                indexes(structure.indexes)
                joinTables(structure)
                definition(structure)
            }
            .padding(.vertical, 12)
        }
        .scrollContentBackground(.hidden)
    }

    @ViewBuilder
    private func columns(_ columns: [TableStructure.Column]) -> some View {
        if !columns.isEmpty {
            VStack(alignment: .leading, spacing: 2) {
                heading(String(localized: "Columns (\(columns.count))"))
                ForEach(columns, id: \.name) { column in
                    HStack(alignment: .firstTextBaseline, spacing: 6) {
                        Text(column.name)
                            .font(.system(.callout, design: .monospaced))
                            .textSelection(.enabled)
                        Spacer(minLength: 8)
                        Text(facets(of: column))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    .padding(.horizontal, 12)
                    .accessibilityElement(children: .combine)
                }
            }
        }
    }

    private func facets(of column: TableStructure.Column) -> String {
        var parts = [column.declaredType.isEmpty ? String(localized: "untyped") : column.declaredType]
        if column.primaryKeyPosition != nil { parts.append(String(localized: "primary key")) }
        if column.isNotNull { parts.append(String(localized: "not null")) }
        if let value = column.defaultValue { parts.append(String(localized: "default \(value)")) }
        return parts.joined(separator: " · ")
    }

    @ViewBuilder
    private func indexes(_ indexes: [TableStructure.Index]) -> some View {
        if !indexes.isEmpty {
            VStack(alignment: .leading, spacing: 3) {
                heading(String(localized: "Indexes (\(indexes.count))"))
                ForEach(indexes, id: \.name) { index in
                    VStack(alignment: .leading, spacing: 1) {
                        HStack(spacing: 5) {
                            Text(index.name)
                                .font(.system(.caption, design: .monospaced))
                                .textSelection(.enabled)
                            if index.isUnique {
                                Text("UNIQUE")
                                    .font(.caption2.weight(.semibold))
                                    .foregroundStyle(.secondary)
                            }
                        }
                        if !index.columns.isEmpty {
                            Text(index.columns.joined(separator: ", "))
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                    .padding(.horizontal, 12)
                    .accessibilityElement(children: .combine)
                }
            }
        }
    }

    @ViewBuilder
    private func joinTables(_ structure: TableStructure) -> some View {
        if !structure.joinTables.isEmpty {
            VStack(alignment: .leading, spacing: 3) {
                heading(String(localized: "Join tables"))
                ForEach(structure.joinTables.keys.sorted(), id: \.self) { name in
                    if let join = structure.joinTables[name] {
                        VStack(alignment: .leading, spacing: 1) {
                            Text(join.table)
                                .font(.system(.callout, design: .monospaced))
                                .textSelection(.enabled)
                            Text("\(structure.entity).\(name) · \(join.columns.map(\.name).joined(separator: ", "))")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        .padding(.horizontal, 12)
                        .accessibilityElement(children: .combine)
                    }
                }
            }
        }
    }

    @ViewBuilder
    private func definition(_ structure: TableStructure) -> some View {
        if !structure.script.isEmpty {
            VStack(alignment: .leading, spacing: 4) {
                heading(String(localized: "SQL"))
                Text(structure.script)
                    .font(.system(.caption, design: .monospaced))
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(8)
                    .background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 5))
                    .padding(.horizontal, 12)
            }
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
