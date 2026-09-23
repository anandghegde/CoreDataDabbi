import AppKit
import DabbiKit

/// The visual predicate builder under the predicate field (PRD-1, PRD-2, M2-03).
///
/// An `NSPredicateEditor` with rows generated from the model, or — for a predicate it has no rows for — a line
/// saying why, since the text is still there to edit. The field and the builder say the same thing: the builder
/// writes the model's text as it changes, and redraws itself when the text changes under it.
@MainActor
final class PredicateBuilderViewController: NSViewController {
    let model: PredicateBarModel

    /// The builder's own editor. Exposed for the tests.
    let editor = NSPredicateEditor()
    private let scrollView = NSScrollView()
    private let customLabel = NSTextField(wrappingLabelWithString: "")
    private var heightConstraint: NSLayoutConstraint!
    /// The field set the templates were made from; they are remade only when it changes.
    private var templateSchema: BuilderSchema?
    /// The text the editor shows. A change the builder made itself comes back through the model as text, and
    /// must not redraw the editor: that would take the keyboard out of the field being typed in.
    private(set) var shownText: String?
    /// The schema `shownText` was shown against: the same text on another entity is other rows.
    private var shownSchema: BuilderSchema?
    private var isUpdating = false
    /// Rows past this many scroll rather than push the grid off the window.
    private let visibleRows = 8

    init(model: PredicateBarModel) {
        self.model = model
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("not in a nib") }

    override func loadView() {
        view = NSView()

        editor.rowHeight = 25
        editor.target = self
        editor.action = #selector(editorChanged(_:))
        editor.setAccessibilityLabel(String(localized: "Predicate builder"))

        scrollView.documentView = editor
        scrollView.hasVerticalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.borderType = .bezelBorder
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        // The editor sizes its own height to its rows, as it does in a nib; only its width follows the view.
        editor.frame = NSRect(x: 0, y: 0, width: 600, height: editor.rowHeight)
        editor.autoresizingMask = [.width]

        customLabel.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        customLabel.textColor = .secondaryLabelColor
        customLabel.isHidden = true
        customLabel.translatesAutoresizingMaskIntoConstraints = false

        // A stack leaves out whichever of the two is hidden, so the builder is as tall as what it shows.
        let stack = NSStackView(views: [scrollView, customLabel])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 0
        stack.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(stack)
        heightConstraint = scrollView.heightAnchor.constraint(equalToConstant: editor.rowHeight + 2)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: view.topAnchor),
            stack.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            stack.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            scrollView.widthAnchor.constraint(equalTo: stack.widthAnchor),
            customLabel.widthAnchor.constraint(equalTo: stack.widthAnchor),
            heightConstraint,
        ])

        NotificationCenter.default.addObserver(
            self, selector: #selector(rowsChanged(_:)), name: NSRuleEditor.rowsDidChangeNotification,
            object: editor)
    }

    // MARK: Following the model

    /// Shows what the model's text says, unless it is what the builder last wrote. Called from the bar's
    /// observation loop.
    func follow() {
        let text = model.trimmed
        let schema = model.schema
        guard text != shownText || schema != shownSchema else { return }
        shownText = text
        shownSchema = schema
        show(model.builderContent)
    }

    private func show(_ content: PredicateBarModel.BuilderContent?) {
        switch content {
        case .rows(let ast, let schema):
            scrollView.isHidden = false
            customLabel.isHidden = true
            if schema != templateSchema {
                templateSchema = schema
                editor.rowTemplates = PredicateBuilderTemplates.make(for: schema) { [weak self] in
                    self?.model.apply()
                }
            }
            isUpdating = true
            defer { isUpdating = false }
            // The editor raises on a shape it has no row for, and an uncaught exception ends the app; the
            // schema only hands over shapes it has, and this is for the one it got wrong.
            let shown: Void? = try? objcGuarded("The builder could not show the predicate") {
                editor.objectValue = try ast.makePredicate()
            }
            if shown == nil {
                showText([String(localized: "The builder could not show this predicate. It is kept as text.")])
            }
        case .text(let reasons):
            showText(reasons)
        case nil:
            showText([String(localized: "There is no model to build a predicate from.")])
        }
        fitHeight()
    }

    private func showText(_ reasons: [String]) {
        scrollView.isHidden = true
        customLabel.isHidden = false
        let heading = String(
            localized: "This predicate can only be edited as text.",
            comment: "Predicate builder, for a predicate it has no rows for")
        customLabel.stringValue = ([heading] + reasons).joined(separator: "\n")
    }

    private func fitHeight() {
        guard !scrollView.isHidden else { return }
        let rows = CGFloat(min(max(editor.numberOfRows, 1), visibleRows))
        heightConstraint.constant = rows * editor.rowHeight + 2
    }

    // MARK: What the user does

    @objc private func editorChanged(_ sender: Any?) {
        guard !isUpdating, let predicate = editor.objectValue as? NSPredicate else { return }
        model.takeFromBuilder(predicate)
        shownText = model.trimmed
    }

    @objc private func rowsChanged(_ notification: Notification) {
        fitHeight()
    }

    /// Puts the keyboard in the first row's value, the field a new predicate is waiting on (PRD-3).
    @discardableResult
    func focusFirstValue() -> Bool {
        guard !scrollView.isHidden, let field = Self.firstEditableField(in: editor) else { return false }
        return view.window?.makeFirstResponder(field) ?? false
    }

    private static func firstEditableField(in view: NSView) -> NSTextField? {
        let fields = view.subviews.compactMap { $0 as? NSTextField }.filter { $0.isEditable && !$0.isHidden }
        if let field = fields.min(by: { $0.frame.minX < $1.frame.minX }) { return field }
        return view.subviews.lazy.compactMap(firstEditableField(in:)).first
    }
}
