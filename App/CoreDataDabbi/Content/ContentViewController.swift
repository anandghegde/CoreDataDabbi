import AppKit
import SwiftUI

/// Hosts the content viewer (CNT-1…CNT-5).
final class ContentViewController: NSViewController {
    let context: ProjectContext
    let model: ContentModel

    init(context: ProjectContext) {
        self.context = context
        model = ContentModel(context: context)
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("not in a nib") }

    private var hosting: NSHostingView<ContentView>?

    override func loadView() {
        let hosting = NSHostingView(rootView: ContentView(model: model))
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

extension ContentViewController: KeyboardPane {
    var keyboardResponder: NSResponder? { hosting }
}
