import AppKit
import DabbiKit

/// The predicate bar between the breadcrumb and the grid (PRD §7.1, §8.1, M2-02).
///
/// A monospaced field, a line underneath that says what is wrong with what is in it, and a completion list
/// driven by the model. Return applies; Escape puts the applied predicate back, or hands the keyboard to the
/// rows when there is nothing to put back. Nothing is fetched until it is applied.
@MainActor
final class PredicateBarViewController: NSViewController, NSTextFieldDelegate {
    let context: ProjectContext
    let model: PredicateBarModel

    /// Where the keyboard goes when the user is done with the field — the grid, set by whoever put the two
    /// together. The bar knows nothing else about it.
    var onDone: (() -> Void)?

    let field = PredicateTextField()
    private let icon = NSImageView()
    private let clearButton = NSButton()
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

        let row = NSStackView(views: [icon, field, clearButton])
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

        let column = NSStackView(views: [row, messageRow])
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
        guard !isUpdating else { return }
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

    @objc private func clear() {
        model.clear()
        view.window?.makeFirstResponder(field)
    }

    /// Return applies and keeps the keyboard, so the predicate can be refined against the rows it produced.
    /// Escape gives up the change, or leaves for the grid when there is no change to give up (§8.4).
    func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
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
