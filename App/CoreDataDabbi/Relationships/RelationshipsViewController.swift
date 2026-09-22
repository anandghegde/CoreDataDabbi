import AppKit
import SwiftUI

/// Hosts the relationships panel (REL-1…REL-3).
final class RelationshipsViewController: NSViewController {
    let context: ProjectContext
    let model: RelationshipsModel

    init(context: ProjectContext) {
        self.context = context
        model = RelationshipsModel(context: context)
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("not in a nib") }

    private var hosting: NSHostingView<RelationshipsView>?

    override func loadView() {
        let hosting = NSHostingView(rootView: RelationshipsView(model: model))
        hosting.translatesAutoresizingMaskIntoConstraints = false
        self.hosting = hosting
        view = NSView()
        view.addSubview(hosting)
        NSLayoutConstraint.activate([
            hosting.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            hosting.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            hosting.topAnchor.constraint(equalTo: view.topAnchor),
            hosting.bottomAnchor.constraint(equalTo: view.bottomAnchor),
        ])
    }
}

extension RelationshipsViewController: KeyboardPane {
    var keyboardResponder: NSResponder? { hosting }
}
