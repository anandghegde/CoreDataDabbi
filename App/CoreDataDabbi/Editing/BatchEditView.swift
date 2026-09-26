import DabbiKit
import SwiftUI

/// The sheet a batch edit is set up in (EDT-4): the edit, the rows, the attribute and what it becomes, then how
/// many rows it would change and a few of them before and after. Apply stages it as one undoable edit.
struct BatchEditView: View {
    @Bindable var model: BatchEditModel

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            form
            Divider()
            preview
            Spacer(minLength: 0)
            buttons
        }
        .padding(20)
        .frame(width: 480, height: 440)
        .task(id: model.trigger) {
            // Typing settles before the rows are read again.
            try? await Task.sleep(for: .milliseconds(150))
            guard !Task.isCancelled else { return }
            await model.updatePreview()
        }
    }

    private var form: some View {
        Form {
            Picker(String(localized: "Edit:"), selection: $model.kind) {
                ForEach(BatchEditModel.Kind.allCases, id: \.self) { Text($0.title).tag($0) }
            }
            .accessibilityLabel(String(localized: "Kind of edit"))

            Picker(String(localized: "Rows:"), selection: $model.scope) {
                Text(String(localized: "Selected rows (\(model.selection.count))"))
                    .tag(BatchEditModel.Scope.selection)
                    .selectionDisabled(!model.hasSelection)
                Text(String(localized: "All rows shown")).tag(BatchEditModel.Scope.all)
            }
            .pickerStyle(.radioGroup)
            .accessibilityLabel(String(localized: "Rows to change"))

            Picker(String(localized: "Attribute:"), selection: $model.attribute) {
                ForEach(model.attributes, id: \.name) { attribute in
                    Text(verbatim: "\(attribute.name) — \(attribute.type.displayName)")
                        .tag(Optional(attribute.name))
                }
            }
            .disabled(model.attributes.isEmpty)
            .accessibilityLabel(String(localized: "Attribute to change"))

            switch model.kind {
            case .set:
                TextField(String(localized: "New value:"), text: $model.text)
                    .accessibilityLabel(String(localized: "New value"))
            case .replace:
                TextField(String(localized: "Find:"), text: $model.find)
                    .accessibilityLabel(String(localized: "Find"))
                TextField(String(localized: "Replace with:"), text: $model.replacement)
                    .accessibilityLabel(String(localized: "Replace with"))
                Toggle(String(localized: "Regular expression"), isOn: $model.isRegularExpression)
                Toggle(String(localized: "Ignore case"), isOn: $model.ignoresCase)
            case .nullify:
                Text(String(localized: "The attribute is set to nil on every row."))
                    .foregroundStyle(.secondary)
            }
        }
    }

    @ViewBuilder private var preview: some View {
        if let problem = model.problem {
            HStack(alignment: .firstTextBaseline, spacing: 4) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(.red)
                    .accessibilityHidden(true)
                Text(problem)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .accessibilityElement(children: .combine)
        } else if let preview = model.preview {
            Text(Self.summary(preview))
                .font(.headline)
            if !preview.samples.isEmpty {
                List(preview.samples, id: \.object) { sample in
                    VStack(alignment: .leading, spacing: 1) {
                        Text(sample.label ?? sample.object.description)
                            .font(.callout.weight(.medium))
                        Text(
                            verbatim:
                                "\(GridValue.render(sample.before, timeZone: model.context.timeZone).text) → \(GridValue.render(sample.after, timeZone: model.context.timeZone).text)"
                        )
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                    }
                    .accessibilityElement(children: .combine)
                }
                .frame(minHeight: 80)
                .accessibilityLabel(String(localized: "Sample of the rows that change"))
            }
        } else if model.isPreviewing {
            ProgressView().controlSize(.small)
        }
    }

    private var buttons: some View {
        HStack {
            Spacer()
            Button(String(localized: "Cancel"), role: .cancel, action: model.cancel)
                .keyboardShortcut(.cancelAction)
            Button(String(localized: "Apply"), action: model.apply)
                .keyboardShortcut(.defaultAction)
                .disabled(!model.canApply)
                .accessibilityHint(String(localized: "Stages the change as one edit that can be undone."))
        }
    }

    /// “12 of 40 rows will change”.
    static func summary(_ preview: BatchPreview) -> String {
        preview.changing == 0
            ? String(localized: "No rows would change (\(preview.matched) matched).")
            : String(localized: "\(preview.changing) of \(preview.matched) rows will change.")
    }
}
