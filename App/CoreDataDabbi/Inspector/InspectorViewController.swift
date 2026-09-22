import AppKit
import SwiftUI

/// Hosts the inspector (BRW-7, BRW-8).
///
/// The pane is SwiftUI because it is a list of labelled facts that changes shape with every selection — exactly
/// what SwiftUI is good at, and nothing the grid's performance budget depends on.
final class InspectorViewController: NSViewController {
    let context: ProjectContext
    let model: InspectorModel

    init(context: ProjectContext) {
        self.context = context
        model = InspectorModel(context: context)
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("not in a nib") }

    private var hosting: NSHostingView<InspectorView>?

    override func loadView() {
        let hosting = NSHostingView(rootView: InspectorView(model: model))
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

extension InspectorViewController: KeyboardPane {
    var keyboardResponder: NSResponder? { hosting }
}
