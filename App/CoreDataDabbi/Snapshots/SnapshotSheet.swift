import AppKit
import SwiftUI

/// Name and note of a snapshot: asked for when one is taken, and the note again when it is edited (§7.3).
struct SnapshotSheet: View {
    @Observable
    final class Model {
        var name: String
        var note: String
        /// Whether the name is asked for; editing a note shows it, but renaming is done in the sidebar.
        let editsName: Bool
        let title: String
        let confirmTitle: String
        /// The name and the note, or `nil` for Cancel.
        @ObservationIgnored var onFinish: ((name: String, note: String)?) -> Void = { _ in }

        init(title: String, confirmTitle: String, name: String, note: String, editsName: Bool) {
            self.title = title
            self.confirmTitle = confirmTitle
            self.name = name
            self.note = note
            self.editsName = editsName
        }
    }

    @Bindable var model: Model

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(model.title).font(.headline)
            Form {
                if model.editsName {
                    TextField(String(localized: "Name:"), text: $model.name)
                } else {
                    LabeledContent(String(localized: "Name:"), value: model.name)
                }
                TextField(String(localized: "Note:"), text: $model.note, axis: .vertical)
                    .lineLimit(3...6)
            }
            if model.editsName {
                Text(String(localized: "The copy is of the store as it is on disk. Pending changes are not in it."))
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            HStack {
                Spacer()
                Button(String(localized: "Cancel"), role: .cancel) { model.onFinish(nil) }
                    .keyboardShortcut(.cancelAction)
                Button(model.confirmTitle) { model.onFinish((model.name, model.note)) }
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 420)
    }
}

final class SnapshotSheetController: NSHostingController<SnapshotSheet> {
    let model: SnapshotSheet.Model

    init(_ model: SnapshotSheet.Model) {
        self.model = model
        super.init(rootView: SnapshotSheet(model: model))
        sizingOptions = [.preferredContentSize]
        title = model.title
    }

    @available(*, unavailable)
    @MainActor required dynamic init?(coder: NSCoder) { fatalError("not in a nib") }
}
