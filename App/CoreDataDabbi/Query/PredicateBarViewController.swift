import AppKit
import DabbiKit

/// The predicate bar between the breadcrumb and the grid (PRD §7.1, §8.1, M2-02).
///
/// A monospaced field, a line underneath that says what is wrong with what is in it, and a completion list
/// driven by the model. Return applies; Escape puts the applied predicate back, or hands the keyboard to the
/// rows when there is nothing to put back. Nothing is fetched until it is applied. The builder under it
/// (M2-03) is another way of writing the same text. The search field at its end is the quick filter (PRD-6): a
/// term looked for in the rows the predicate leaves, as it is typed, and never saved.
@MainActor
final class PredicateBarViewController: NSViewController, NSSearchFieldDelegate {
    let context: ProjectContext
    let model: PredicateBarModel

    /// Where the keyboard goes when the user is done with the field — the grid, set by whoever put the two
    /// together. The bar knows nothing else about it.
    var onDone: (() -> Void)?

    let field = PredicateTextField()
    private let icon = NSImageView()
    private let clearButton = NSButton()
    private let builderButton = NSButton()
    let searchField = NSSearchField()
    let builder: PredicateBuilderViewController
    private let message = NSTextField(labelWithString: "")
    private var messageRow: NSStackView!
    private var loop: ObservationLoop?
    /// Set while the bar writes to the field, to keep the write from coming back as an edit.
    private var isUpdating = false
    /// A completion list is a suggestion about what is being typed, not about what has just been rubbed out.
    private var isDeleting = false

    init(context: ProjectContext) {
        self.context = context
        model = PredicateBarModel(context: context)
        builder = PredicateBuilderViewController(model: model)
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("not in a nib") }

    // MARK: The view

    override func loadView() {
        view = NSView()

        icon.image = NSImage(
            systemSymbolName: "line.3.horizontal.decrease.circle",
            accessibilityDescription: String(localized: "Filter"))
        icon.contentTintColor = .secondaryLabelColor
        icon.setContentHuggingPriority(.required, for: .horizontal)

        field.font = .monospacedSystemFont(ofSize: NSFont.smallSystemFontSize, weight: .regular)
        field.placeholderString = String(
            localized: "Filter rows — age > 30 AND name BEGINSWITH[cd] \"a\"",
            comment: "Placeholder of the predicate field, with an example predicate")
        field.delegate = self
        field.bezelStyle = .roundedBezel
        field.usesSingleLineMode = true
        field.cell?.isScrollable = true
        field.setContentHuggingPriority(.defaultLow, for: .horizontal)
        field.setAccessibilityLabel(String(localized: "Filter"))
        field.wordToComplete = { [weak self] text, caret in
            self?.model.completions(in: text, at: caret).range ?? (caret..<caret)
        }

        clearButton.image = NSImage(
            systemSymbolName: "xmark.circle.fill", accessibilityDescription: String(localized: "Clear Filter"))
        clearButton.isBordered = false
        clearButton.imagePosition = .imageOnly
        clearButton.contentTintColor = .secondaryLabelColor
        clearButton.target = self
        clearButton.action = #selector(clear)
        clearButton.toolTip = String(localized: "Clear the filter")
        clearButton.setContentHuggingPriority(.required, for: .horizontal)

        message.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        message.textColor = .secondaryLabelColor
        message.lineBreakMode = .byTruncatingTail
        message.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        builderButton.image = NSImage(
            systemSymbolName: "slider.horizontal.3",
            accessibilityDescription: String(localized: "Show Predicate Builder"))
        builderButton.setButtonType(.pushOnPushOff)
        builderButton.bezelStyle = .toolbar
        builderButton.isBordered = false
        builderButton.imagePosition = .imageOnly
        builderButton.target = self
        builderButton.action = #selector(toggleBuilder(_:))
        builderButton.setContentHuggingPriority(.required, for: .horizontal)

        searchField.controlSize = .small
        searchField.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        searchField.sendsWholeSearchString = false
        searchField.sendsSearchStringImmediately = false
        searchField.target = self
        searchField.action = #selector(search(_:))
        searchField.delegate = self
        searchField.setAccessibilityLabel(String(localized: "Search Rows"))
        searchField.setContentHuggingPriority(.defaultHigh, for: .horizontal)
        searchField.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        let searchWidth = searchField.widthAnchor.constraint(equalToConstant: 180)
        searchWidth.priority = .defaultHigh
        NSLayoutConstraint.activate([searchWidth, searchField.widthAnchor.constraint(greaterThanOrEqualToConstant: 90)])

        let row = NSStackView(views: [icon, field, clearButton, builderButton, searchField])
        row.spacing = 6
        row.alignment = .centerY

        // Indented to where the field starts, so the message reads as being about it.
        let indent = NSView()
        indent.translatesAutoresizingMaskIntoConstraints = false
        indent.widthAnchor.constraint(equalToConstant: 16).isActive = true
        messageRow = NSStackView(views: [indent, message])
        messageRow.spacing = 6
        messageRow.alignment = .centerY
        messageRow.isHidden = true

        addChild(builder)
        builder.view.isHidden = true

        let column = NSStackView(views: [row, messageRow, builder.view])
        column.orientation = .vertical
        column.alignment = .leading
        column.spacing = 4
        column.edgeInsets = NSEdgeInsets(top: 6, left: 10, bottom: 6, right: 10)
        column.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(column)

        let separator = NSBox()
        separator.boxType = .separator
        separator.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(separator)

        NSLayoutConstraint.activate([
            column.topAnchor.constraint(equalTo: view.topAnchor),
            column.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            column.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            column.bottomAnchor.constraint(equalTo: separator.topAnchor),
            // A vertical stack leaves its rows their natural width; these two are meant to fill it.
            row.widthAnchor.constraint(equalTo: column.widthAnchor, constant: -20),
            messageRow.widthAnchor.constraint(equalTo: column.widthAnchor, constant: -20),
            builder.view.widthAnchor.constraint(equalTo: column.widthAnchor, constant: -20),
            separator.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            separator.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            separator.bottomAnchor.constraint(equalTo: view.bottomAnchor),
        ])
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        loop = ObservationLoop { [weak self] in self?.follow() }
    }

    // MARK: Following the model

    private func follow() {
        model.follow()
        let text = model.text
        if field.stringValue != text {
            isUpdating = true
            field.stringValue = text
            isUpdating = false
        }
        clearButton.isHidden = text.isEmpty
        icon.contentTintColor = model.isFiltering ? .controlAccentColor : .secondaryLabelColor
        show(model.message, isError: model.isShowingError)

        let isShowingBuilder = model.isShowingBuilder
        builder.view.isHidden = !isShowingBuilder
        builderButton.state = isShowingBuilder ? .on : .off
        builderButton.contentTintColor = isShowingBuilder ? .controlAccentColor : .secondaryLabelColor
        let title =
            isShowingBuilder
            ? String(localized: "Hide Predicate Builder") : String(localized: "Show Predicate Builder")
        builderButton.toolTip = title
        builderButton.setAccessibilityLabel(title)
        if isShowingBuilder { builder.follow() }

        followQuickFilter()
    }

    /// The search field says what is searched for where the grid is, and in what: going Back brings a search
    /// back with its place, and an entity with nothing to search in has nothing to type into (PRD-6).
    private func followQuickFilter() {
        let term = context.navigation.current?.quickFilter ?? ""
        if searchField.stringValue != term { searchField.stringValue = term }
        let quick = context.shownQuickFilter
        let isSearchable = quick?.isSearchable ?? false
        searchField.isEnabled = isSearchable
        searchField.placeholderString =
            isSearchable || quick == nil
            ? String(localized: "Search", comment: "Placeholder of the quick filter field")
            : String(localized: "No text to search", comment: "Placeholder of the quick filter field, disabled")
        searchField.toolTip = quick.flatMap { quick in
            quick.isSearchable
                ? String(
                    localized: "Shows the rows with the text in \(quick.keyPaths.joined(separator: ", "))",
                    comment: "Tooltip of the quick filter field; the list is of attribute names")
                : nil
        }
    }

    private func show(_ text: String?, isError: Bool) {
        messageRow.isHidden = text == nil
        message.stringValue = text ?? ""
        message.textColor = isError ? .systemRed : .secondaryLabelColor
        let suggestions = model.suggestions
        message.toolTip = suggestions.isEmpty ? nil : suggestions.joined(separator: "\n")
    }

    // MARK: What the user does

    func controlTextDidChange(_ notification: Notification) {
        guard !isUpdating, notification.object as? NSTextField === field else { return }
        let wasDeleting = isDeleting
        isDeleting = false
        model.text = field.stringValue
        // Completing on every keystroke is what makes the list feel like part of the field rather than a
        // command; a deletion is left alone, so backspacing out of a word does not fight the popup.
        guard !wasDeleting, let editor = field.currentEditor() as? NSTextView else { return }
        editor.complete(nil)
    }

    private func apply() {
        model.apply()
    }

    /// The quick filter: sent a moment after typing stops, and at once on Return or the field's clear button.
    @objc private func search(_ sender: NSSearchField) {
        context.setQuickFilter(sender.stringValue)
    }

    /// Puts the keyboard in the quick filter, with what is there selected to be typed over (PRD-6).
    @discardableResult
    func focusQuickFilter() -> Bool {
        guard searchField.isEnabled, let window = view.window, window.makeFirstResponder(searchField) else {
            return false
        }
        searchField.currentEditor()?.selectAll(nil)
        return true
    }

    /// Opens or closes the builder under the field (M2-03).
    @IBAction func toggleBuilder(_ sender: Any?) {
        model.isShowingBuilder.toggle()
    }

    /// "New Predicate": the builder with one row to type a value into, and the keyboard in it (PRD-3).
    func startNewPredicate() {
        let hasRow = model.startNewPredicate()
        follow()
        if !hasRow || !builder.focusFirstValue() { view.window?.makeFirstResponder(field) }
    }

    @objc private func clear() {
        model.clear()
        view.window?.makeFirstResponder(field)
    }

    /// Return applies and keeps the keyboard, so the predicate can be refined against the rows it produced.
    /// Escape gives up the change, or leaves for the grid when there is no change to give up (§8.4).
    func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
        if control === searchField { return searchField(doCommandBy: selector) }
        isDeleting =
            selector == #selector(NSResponder.deleteBackward(_:))
            || selector == #selector(NSResponder.deleteForward(_:))
        switch selector {
        case #selector(NSResponder.insertNewline(_:)):
            apply()
            return true
        case #selector(NSResponder.cancelOperation(_:)):
            if model.isApplied {
                onDone?()
            } else {
                model.revert()
            }
            return true
        default:
            return false
        }
    }

    /// Escape empties the search, and leaves for the rows when there is nothing to empty — as the predicate field
    /// does, so that it takes two presses at most to get back to the grid from either (§8.4).
    private func searchField(doCommandBy selector: Selector) -> Bool {
        guard selector == #selector(NSResponder.cancelOperation(_:)) else { return false }
        if searchField.stringValue.isEmpty {
            onDone?()
        } else {
            searchField.stringValue = ""
            context.setQuickFilter("")
        }
        return true
    }

    /// The completion list, from the model (M2-02).
    ///
    /// AppKit asks what can replace `charRange`, which the field editor has been told is exactly the range the
    /// completer replaces. A standard field editor may still hand over a wider word — an `@` or a `.` in front
    /// of it — and what it takes in goes back in front of every item.
    func control(
        _ control: NSControl, textView: NSTextView, completions words: [String],
        forPartialWordRange charRange: NSRange, indexOfSelectedItem index: UnsafeMutablePointer<Int>
    ) -> [String] {
        let text = textView.string
        let completions = model.completions(in: text, at: textView.selectedRange().location)
        guard !completions.isEmpty else { return [] }
        // Nothing is picked until the user says so: Return applies the predicate, ↓ and Tab choose an item.
        index.pointee = -1
        let units = Array(text.utf16)
        let start = min(max(charRange.location, 0), units.count)
        guard start < completions.range.lowerBound else { return completions.items.map(\.text) }
        let kept = String(decoding: units[start..<completions.range.lowerBound], as: UTF16.self)
        return completions.items.map { kept + $0.text }
    }
}

extension PredicateBarViewController: KeyboardPane {
    var keyboardResponder: NSResponder? { field }
}

/// The predicate field: an `NSTextField` whose field editor knows what a word is here, and does not improve
/// what is typed into it.
final class PredicateTextField: NSTextField {
    /// The range a completion replaces, as UTF-16 offsets — the completer's answer, which a field editor would
    /// otherwise guess at with rules meant for prose.
    var wordToComplete: ((String, Int) -> Range<Int>)?

    override class var cellClass: AnyClass? {
        get { PredicateTextFieldCell.self }
        set {}
    }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        let editor = PredicateFieldEditor()
        editor.isFieldEditor = true
        editor.wordToComplete = { [weak self] text, caret in self?.wordToComplete?(text, caret) }
        // A cell of another class leaves the standard field editor in place, and the field works without it.
        (cell as? PredicateTextFieldCell)?.editor = editor
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("not in a nib") }
}

final class PredicateTextFieldCell: NSTextFieldCell {
    /// The editor this cell hands AppKit when the field is edited.
    var editor: NSTextView?

    override func fieldEditor(for controlView: NSView) -> NSTextView? {
        editor ?? super.fieldEditor(for: controlView)
    }

    /// Whatever editor is used, it must leave the text alone: curly quotes, an em dash for `--` or a corrected
    /// `BEGINSWITH` would each change what the predicate says.
    override func setUpFieldEditorAttributes(_ textObj: NSText) -> NSText {
        let editor = super.setUpFieldEditorAttributes(textObj)
        guard let view = editor as? NSTextView else { return editor }
        view.isAutomaticQuoteSubstitutionEnabled = false
        view.isAutomaticDashSubstitutionEnabled = false
        view.isAutomaticTextReplacementEnabled = false
        view.isAutomaticSpellingCorrectionEnabled = false
        view.isAutomaticTextCompletionEnabled = false
        view.isContinuousSpellCheckingEnabled = false
        view.isGrammarCheckingEnabled = false
        return editor
    }
}

/// The field editor of the predicate field: it replaces `[cd`, `@cou` or `first_na` whole, where the standard
/// one stops at the punctuation and leaves half a word standing.
final class PredicateFieldEditor: NSTextView {
    var wordToComplete: ((String, Int) -> Range<Int>?)?

    override var rangeForUserCompletion: NSRange {
        guard let range = wordToComplete?(string, selectedRange().location) else {
            return super.rangeForUserCompletion
        }
        return NSRange(location: range.lowerBound, length: range.count)
    }
}
