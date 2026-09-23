import AppKit
import DabbiKit

/// What the prompt for a fetch-request template's variables holds (BRW-1): one editor per `$VARIABLE`, and
/// whether what is in them is something the template can run with.
///
/// A date is picked and a Boolean chosen; everything else is typed, and read as the kind of value the variable
/// is compared with — the engine decides that (`FetchTemplateVariable`), this only keeps the fields.
struct FetchRequestPromptModel {
    let plan: FetchTemplatePlan
    /// What is typed into each field, by variable name.
    private(set) var texts: [String: String] = [:]
    /// What the date pickers and Boolean pop-ups hold, by variable name.
    private(set) var picked: [String: PredicateLiteral] = [:]

    /// Starts from the values the template was last run with, where they still fit, so that running it again
    /// is changing one field rather than filling in all of them.
    init(
        plan: FetchTemplatePlan, previous: [String: PredicateLiteral],
        today: Date = Calendar.current.startOfDay(for: .now)
    ) {
        self.plan = plan
        for variable in plan.variables {
            let earlier = previous[variable.name].flatMap { variable.accepts($0) ? $0 : nil }
            if Self.isPicked(variable) {
                picked[variable.name] = earlier ?? (variable.kind == .date ? .date(today) : .bool(true))
            } else {
                texts[variable.name] = earlier.map { Self.text(for: $0, of: variable) } ?? ""
            }
        }
    }

    var variables: [FetchTemplateVariable] { plan.variables }

    /// Whether a variable gets a picker rather than a field: a single date or Boolean. A list of dates is typed.
    static func isPicked(_ variable: FetchTemplateVariable) -> Bool {
        variable.arity == .single && (variable.kind == .date || variable.kind == .boolean)
    }

    mutating func setText(_ text: String, for name: String) { texts[name] = text }
    mutating func pick(_ value: PredicateLiteral, for name: String) { picked[name] = value }

    func value(of variable: FetchTemplateVariable) -> PredicateLiteral? {
        let value = Self.isPicked(variable) ? picked[variable.name] : variable.value(from: texts[variable.name] ?? "")
        return value.flatMap { variable.accepts($0) ? $0 : nil }
    }

    /// Every variable's value, or `nil` while one of them is not a value yet.
    var values: [String: PredicateLiteral]? {
        var values: [String: PredicateLiteral] = [:]
        for variable in variables {
            guard let value = value(of: variable) else { return nil }
            values[variable.name] = value
        }
        return values
    }

    /// What is wrong with the first field that is not a value yet, in words. `nil` when the template can run.
    var problem: String? {
        guard let variable = variables.first(where: { value(of: $0) == nil }) else { return nil }
        return String(
            localized: "$\(variable.name) needs \(Self.hint(for: variable)).", comment: "Fetch request prompt")
    }

    /// What a field takes, for its placeholder and for the problem line.
    static func hint(for variable: FetchTemplateVariable) -> String {
        let one: String =
            switch variable.kind {
            case .string, .presence: String(localized: "text", comment: "Fetch request prompt: a value's kind")
            case .integer: String(localized: "a whole number", comment: "Fetch request prompt: a value's kind")
            case .decimal: String(localized: "a number", comment: "Fetch request prompt: a value's kind")
            case .boolean: String(localized: "yes or no", comment: "Fetch request prompt: a value's kind")
            case .date: String(localized: "an ISO 8601 date", comment: "Fetch request prompt: a value's kind")
            case .uuid: String(localized: "a UUID", comment: "Fetch request prompt: a value's kind")
            case .uri: String(localized: "a URL", comment: "Fetch request prompt: a value's kind")
            }
        return switch variable.arity {
        case .list: String(localized: "a comma-separated list of \(one)", comment: "Fetch request prompt")
        case .pair: String(localized: "two of \(one), separated by a comma", comment: "Fetch request prompt")
        case .single, .none: one
        }
    }

    private static func text(for literal: PredicateLiteral, of variable: FetchTemplateVariable) -> String {
        if case .array(let items) = literal {
            return variable.kind.listText(for: items.map(BuilderValue.literal))
        }
        return variable.kind.text(for: .literal(literal))
    }
}

/// The sheet that asks for a template's variables before it runs (BRW-1).
@MainActor
final class FetchRequestPromptController: NSViewController, NSTextFieldDelegate {
    private(set) var model: FetchRequestPromptModel
    /// The values to run with, or `nil` for Cancel. The presenter dismisses the sheet.
    var onFinish: (([String: PredicateLiteral]?) -> Void)?

    private let timeZone: TimeZone
    private var fields: [String: NSTextField] = [:]
    private let problemLabel = NSTextField(wrappingLabelWithString: "")
    private let runButton = NSButton()

    init(model: FetchRequestPromptModel, timeZone: TimeZone = .current) {
        self.model = model
        self.timeZone = timeZone
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("not in a nib") }

    override func loadView() {
        let plan = model.plan
        let title = NSTextField(
            labelWithString: String(localized: "Run “\(plan.name)”", comment: "Fetch request prompt title"))
        title.font = .boldSystemFont(ofSize: NSFont.systemFontSize)

        let summary = NSTextField(
            wrappingLabelWithString: plan.template.predicateFormat.map { "\(plan.entity ?? "") · \($0)" }
                ?? plan.entity ?? "")
        summary.font = .monospacedSystemFont(ofSize: NSFont.smallSystemFontSize, weight: .regular)
        summary.textColor = .secondaryLabelColor
        summary.isSelectable = true

        let grid = NSGridView(numberOfColumns: 2, rows: 0)
        grid.rowSpacing = 10
        grid.columnSpacing = 8
        grid.column(at: 0).xPlacement = .trailing
        for variable in model.variables {
            let label = NSTextField(labelWithString: "$" + variable.name)
            label.font = .monospacedSystemFont(ofSize: NSFont.systemFontSize, weight: .regular)
            let editor = makeEditor(for: variable)
            editor.setAccessibilityLabel(
                variable.keyPath.map {
                    String(localized: "\(variable.name), compared with \($0)", comment: "Fetch request prompt field")
                } ?? variable.name)
            grid.addRow(with: [label, editor])
            grid.cell(for: label)?.yPlacement = .center
        }

        problemLabel.textColor = .secondaryLabelColor
        problemLabel.font = .systemFont(ofSize: NSFont.smallSystemFontSize)

        let cancel = NSButton(
            title: String(localized: "Cancel"), target: self, action: #selector(cancel(_:)))
        cancel.keyEquivalent = "\u{1b}"
        runButton.title = String(localized: "Run", comment: "Fetch request prompt button")
        runButton.bezelStyle = .push
        runButton.target = self
        runButton.action = #selector(run(_:))
        runButton.keyEquivalent = "\r"
        let buttons = NSStackView(views: [problemLabel, cancel, runButton])
        buttons.setHuggingPriority(.defaultHigh, for: .vertical)
        problemLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        problemLabel.setContentHuggingPriority(.defaultLow, for: .horizontal)

        let stack = NSStackView(views: [title, summary, grid, buttons])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 12
        stack.edgeInsets = NSEdgeInsets(top: 20, left: 20, bottom: 20, right: 20)
        stack.setCustomSpacing(16, after: grid)
        buttons.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -40).isActive = true
        summary.preferredMaxLayoutWidth = 400
        stack.widthAnchor.constraint(equalToConstant: 440).isActive = true
        view = stack
        refresh()
    }

    private func makeEditor(for variable: FetchTemplateVariable) -> NSView {
        let name = variable.name
        switch (FetchRequestPromptModel.isPicked(variable), variable.kind) {
        case (true, .date):
            let picker = NSDatePicker()
            picker.datePickerStyle = .textFieldAndStepper
            picker.datePickerElements = [.yearMonthDay, .hourMinuteSecond]
            picker.timeZone = timeZone
            if case .date(let date)? = model.picked[name] { picker.dateValue = date }
            picker.identifier = NSUserInterfaceItemIdentifier(name)
            picker.target = self
            picker.action = #selector(datePicked(_:))
            return picker
        case (true, _):
            let popUp = NSPopUpButton()
            popUp.addItems(withTitles: [
                String(localized: "Yes", comment: "Fetch request prompt: a Boolean value"),
                String(localized: "No", comment: "Fetch request prompt: a Boolean value"),
            ])
            if case .bool(false)? = model.picked[name] { popUp.selectItem(at: 1) }
            popUp.identifier = NSUserInterfaceItemIdentifier(name)
            popUp.target = self
            popUp.action = #selector(booleanChosen(_:))
            return popUp
        default:
            let field = NSTextField(string: model.texts[name] ?? "")
            field.placeholderString = FetchRequestPromptModel.hint(for: variable)
            field.delegate = self
            field.identifier = NSUserInterfaceItemIdentifier(name)
            field.widthAnchor.constraint(greaterThanOrEqualToConstant: 260).isActive = true
            fields[name] = field
            return field
        }
    }

    // MARK: Editing

    func controlTextDidChange(_ notification: Notification) {
        guard let field = notification.object as? NSTextField, let name = field.identifier?.rawValue else { return }
        model.setText(field.stringValue, for: name)
        refresh()
    }

    @objc private func datePicked(_ sender: NSDatePicker) {
        guard let name = sender.identifier?.rawValue else { return }
        model.pick(.date(sender.dateValue), for: name)
        refresh()
    }

    @objc private func booleanChosen(_ sender: NSPopUpButton) {
        guard let name = sender.identifier?.rawValue else { return }
        model.pick(.bool(sender.indexOfSelectedItem == 0), for: name)
        refresh()
    }

    /// Types into a field as the user would. For the tests.
    func type(_ text: String, into name: String) {
        fields[name]?.stringValue = text
        model.setText(text, for: name)
        refresh()
    }

    /// Picks a date or a Boolean as the user would. For the tests.
    func pick(_ value: PredicateLiteral, for name: String) {
        model.pick(value, for: name)
        refresh()
    }

    private func refresh() {
        runButton.isEnabled = model.values != nil
        problemLabel.stringValue = model.problem ?? ""
    }

    // MARK: Finishing

    @objc func run(_ sender: Any?) {
        guard let values = model.values else { return }
        onFinish?(values)
    }

    @objc func cancel(_ sender: Any?) {
        onFinish?(nil)
    }

    override func cancelOperation(_ sender: Any?) {
        cancel(sender)
    }
}
