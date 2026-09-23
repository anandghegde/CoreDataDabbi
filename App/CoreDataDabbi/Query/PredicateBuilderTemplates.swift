import AppKit
import DabbiKit

/// The row templates of the visual builder, generated from the model (PRD-1, PRD-2, M2-03).
///
/// `NSPredicateEditor` draws a row from a template's views and merges the pop-ups of every template by title,
/// left to right: a key path offered by several templates is one menu item, and choosing it lays out the rest of
/// the row from whichever template owns the next choice. So the templates are cut along the lines where a row's
/// shape changes — the kind of value, whether it needs a quantifier, and how many values the operator takes —
/// and each key path appears in every template that has something to say about it.
///
/// What a row *means* is not decided here: a template reads its predicate into a `BuilderRow` and writes one
/// back, and `BuilderRow` is the engine's, where it is tested (`PredicateBuilderSchemaTests`).
@MainActor
enum PredicateBuilderTemplates {
    /// Every template for `schema`, the compound one (All / Any / None) first.
    static func make(
        for schema: BuilderSchema, onReturn: @escaping @MainActor () -> Void
    )
        -> [NSPredicateEditorRowTemplate]
    {
        let compound = NSPredicateEditorRowTemplate(
            compoundTypes: [NSCompoundPredicate.LogicalType.and, .or, .not].map { NSNumber(value: $0.rawValue) })
        var templates: [NSPredicateEditorRowTemplate] = [compound]

        // Fields with the same kind and the same need for a quantifier share a row shape. Menu order is kept:
        // each group is placed where its first field is.
        var groups: [(key: GroupKey, fields: [BuilderField])] = []
        for field in schema.fields {
            let key = GroupKey(kind: field.kind, isQuantified: field.isQuantified)
            if let index = groups.firstIndex(where: { $0.key == key }) {
                groups[index].fields.append(field)
            } else {
                groups.append((key, [field]))
            }
        }
        for (key, fields) in groups {
            for arity in BuilderArity.allCases {
                // Nil checks are offered field by field (not for `@count`), so their template takes only the
                // fields that have them.
                let owners = arity == .none ? fields.filter(\.offersNilChecks) : fields
                let operators = (owners.first?.operators ?? []).filter { $0.arity == arity }
                guard !owners.isEmpty, !operators.isEmpty else { continue }
                let spec = BuilderRowTemplate.Spec(
                    fields: owners, kind: key.kind, isQuantified: key.isQuantified, arity: arity,
                    operators: operators, schema: schema, onReturn: onReturn)
                templates.append(BuilderRowTemplate(spec: spec))
            }
        }
        return templates
    }

    private struct GroupKey: Hashable {
        var kind: BuilderValueKind
        var isQuantified: Bool
    }

    // MARK: Titles

    /// `author › name`: the key path as a reader says it. `@count` is kept as written — it is what the text
    /// field says too, and the two sit one above the other.
    static func title(of field: BuilderField) -> String {
        field.components.joined(separator: " › ")
    }

    /// Keyed apart from the other "none" and "all" in the app, which mean something else in another language.
    static func title(of quantifier: BuilderQuantifier) -> String {
        switch quantifier {
        case .any:
            String(
                localized: "builder.quantifier.any", defaultValue: "any",
                comment: "Predicate builder quantifier: ANY of a to-many relationship")
        case .all:
            String(
                localized: "builder.quantifier.all", defaultValue: "all",
                comment: "Predicate builder quantifier: ALL of a to-many relationship")
        case .notAny:
            String(
                localized: "builder.quantifier.none", defaultValue: "none",
                comment: "Predicate builder quantifier: NONE of a to-many relationship")
        }
    }

    static func title(of op: BuilderOperator, kind: BuilderValueKind) -> String {
        switch op {
        case .isNil: return String(localized: "is nil", comment: "Predicate builder operator")
        case .isNotNil: return String(localized: "is not nil", comment: "Predicate builder operator")
        case .compare(let compared):
            let isDate = kind == .date
            switch compared {
            case .equal: return String(localized: "is", comment: "Predicate builder operator: ==")
            case .notEqual: return String(localized: "is not", comment: "Predicate builder operator: !=")
            case .lessThan:
                return isDate
                    ? String(localized: "is before", comment: "Predicate builder operator: < on a date")
                    : String(localized: "is less than", comment: "Predicate builder operator: <")
            case .lessThanOrEqual:
                return isDate
                    ? String(localized: "is on or before", comment: "Predicate builder operator: <= on a date")
                    : String(localized: "is at most", comment: "Predicate builder operator: <=")
            case .greaterThan:
                return isDate
                    ? String(localized: "is after", comment: "Predicate builder operator: > on a date")
                    : String(localized: "is greater than", comment: "Predicate builder operator: >")
            case .greaterThanOrEqual:
                return isDate
                    ? String(localized: "is on or after", comment: "Predicate builder operator: >= on a date")
                    : String(localized: "is at least", comment: "Predicate builder operator: >=")
            case .contains: return String(localized: "contains", comment: "Predicate builder operator: CONTAINS")
            case .beginsWith:
                return String(localized: "begins with", comment: "Predicate builder operator: BEGINSWITH")
            case .endsWith: return String(localized: "ends with", comment: "Predicate builder operator: ENDSWITH")
            case .like: return String(localized: "is like", comment: "Predicate builder operator: LIKE (wildcards)")
            case .matches:
                return String(
                    localized: "matches", comment: "Predicate builder operator: MATCHES (a regular expression)")
            case .inCollection: return String(localized: "is one of", comment: "Predicate builder operator: IN")
            case .between: return String(localized: "is between", comment: "Predicate builder operator: BETWEEN")
            }
        }
    }

    static func title(of options: PredicateOptions) -> String {
        switch (options.contains(.caseInsensitive), options.contains(.diacriticInsensitive)) {
        case (false, false): String(localized: "exactly", comment: "Predicate builder: no [cd] options")
        case (true, false): String(localized: "ignoring case", comment: "Predicate builder: [c]")
        case (false, true): String(localized: "ignoring accents", comment: "Predicate builder: [d]")
        case (true, true): String(localized: "ignoring case and accents", comment: "Predicate builder: [cd]")
        }
    }
}

/// One row shape: `key path · quantifier? · operator · options? · value editor`.
///
/// `NSPredicateEditor` copies a template for every row it shows and then tells the copy which predicate the row
/// is, so all of a row's state lives in its views, and a copy is simply a fresh template of the same shape.
///
/// AppKit only ever calls a template on the main thread, but the class does not say so; the views and what is
/// done with them live in `BuilderRowViews`, which does.
final class BuilderRowTemplate: NSPredicateEditorRowTemplate {
    struct Spec {
        var fields: [BuilderField]
        var kind: BuilderValueKind
        var isQuantified: Bool
        var arity: BuilderArity
        var operators: [BuilderOperator]
        var schema: BuilderSchema
        /// Return in one of the row's fields: the builder's "Enter applies" (PRD-1).
        var onReturn: @MainActor () -> Void
    }

    let spec: Spec
    private let views: BuilderRowViews

    init(spec: Spec) {
        self.spec = spec
        views = MainActor.assumeIsolated { BuilderRowViews(spec: spec) }
        super.init()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("not in a nib") }

    override func copy(with zone: NSZone? = nil) -> Any {
        BuilderRowTemplate(spec: spec)
    }

    override var templateViews: [NSView] {
        let views = views
        return MainActor.assumeIsolated { views.templateViews }
    }

    override func match(for predicate: NSPredicate) -> Double {
        let ast = PredicateAST(predicate), views = views
        return MainActor.assumeIsolated { views.row(for: ast) == nil ? 0 : 1 }
    }

    override func setPredicate(_ predicate: NSPredicate) {
        let ast = PredicateAST(predicate), views = views
        MainActor.assumeIsolated { views.show(ast) }
    }

    override func predicate(withSubpredicates subpredicates: [NSPredicate]?) -> NSPredicate {
        let views = views
        let row = MainActor.assumeIsolated { views.row() }
        // A row built from the schema always makes a predicate; should one ever not, the row asks nothing
        // rather than bringing the editor down.
        return (try? row.predicate.makePredicate()) ?? NSPredicate(value: true)
    }
}

/// A row's views, and the reading and writing of a `BuilderRow` through them.
@MainActor
final class BuilderRowViews: NSObject, NSTextFieldDelegate {
    let spec: BuilderRowTemplate.Spec

    private let fieldPopUp = NSPopUpButton()
    private let quantifierPopUp = NSPopUpButton()
    private let operatorPopUp = NSPopUpButton()
    private let optionsPopUp = NSPopUpButton()
    private let booleanPopUp = NSPopUpButton()
    private let firstField = NSTextField()
    private let secondField = NSTextField()
    private let firstDate = NSDatePicker()
    private let secondDate = NSDatePicker()
    private let conjunction = NSTextField(
        labelWithString: String(localized: "and", comment: "Predicate builder: between one value and another"))
    /// What the row last said that was well-formed — what a text field that is still being typed into, and does
    /// not yet hold a number, stands for in the meantime.
    private var lastValues: [BuilderValue] = []

    init(spec: BuilderRowTemplate.Spec) {
        self.spec = spec
        super.init()
        makeViews()
    }

    // MARK: Views

    private func makeViews() {
        for field in spec.fields {
            fieldPopUp.addItem(withTitle: PredicateBuilderTemplates.title(of: field))
            fieldPopUp.lastItem?.representedObject = field.keyPath
        }
        fieldPopUp.setAccessibilityLabel(String(localized: "Key path", comment: "Predicate builder pop-up"))

        for quantifier in BuilderQuantifier.allCases {
            quantifierPopUp.addItem(withTitle: PredicateBuilderTemplates.title(of: quantifier))
        }
        quantifierPopUp.setAccessibilityLabel(String(localized: "Quantifier", comment: "Predicate builder pop-up"))

        for op in spec.operators {
            operatorPopUp.addItem(withTitle: PredicateBuilderTemplates.title(of: op, kind: spec.kind))
        }
        operatorPopUp.setAccessibilityLabel(String(localized: "Comparison", comment: "Predicate builder pop-up"))

        for options in PredicateOptions.builderChoices {
            optionsPopUp.addItem(withTitle: PredicateBuilderTemplates.title(of: options))
        }
        optionsPopUp.setAccessibilityLabel(String(localized: "Case and accents", comment: "Predicate builder pop-up"))

        booleanPopUp.addItems(withTitles: [
            String(localized: "true", comment: "Predicate builder Boolean value"),
            String(localized: "false", comment: "Predicate builder Boolean value"),
        ])
        booleanPopUp.setAccessibilityLabel(String(localized: "Value", comment: "Predicate builder value"))

        for popUp in [fieldPopUp, quantifierPopUp, operatorPopUp, optionsPopUp, booleanPopUp] {
            popUp.controlSize = .small
            popUp.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
            popUp.sizeToFit()
        }

        let isList = spec.arity == .list
        for (index, field) in [firstField, secondField].enumerated() {
            field.controlSize = .small
            field.font = .monospacedSystemFont(ofSize: NSFont.smallSystemFontSize, weight: .regular)
            field.frame.size = NSSize(width: isList ? 240 : 150, height: 19)
            field.formatter = BuilderValueFormatter(kind: spec.kind, isList: isList)
            field.delegate = self
            field.placeholderString = placeholder
            field.setAccessibilityLabel(
                spec.arity == .pair
                    ? (index == 0
                        ? String(localized: "From", comment: "Predicate builder: first value of BETWEEN")
                        : String(localized: "To", comment: "Predicate builder: second value of BETWEEN"))
                    : String(localized: "Value", comment: "Predicate builder value"))
        }
        for (index, picker) in [firstDate, secondDate].enumerated() {
            picker.controlSize = .small
            picker.datePickerStyle = .textFieldAndStepper
            picker.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
            picker.datePickerElements = [.yearMonthDay, .hourMinuteSecond]
            picker.dateValue = Calendar.current.startOfDay(for: Date())
            picker.sizeToFit()
            picker.setAccessibilityLabel(
                spec.arity == .pair
                    ? (index == 0
                        ? String(localized: "From", comment: "Predicate builder: first value of BETWEEN")
                        : String(localized: "To", comment: "Predicate builder: second value of BETWEEN"))
                    : String(localized: "Value", comment: "Predicate builder value"))
        }
        conjunction.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        conjunction.sizeToFit()
        lastValues = currentValues() ?? []
    }

    private var placeholder: String {
        switch (spec.kind, spec.arity) {
        case (.string, .list): String(localized: "a, \"b, c\", d", comment: "Placeholder of a list of strings")
        case (_, .list): String(localized: "1, 2, 3", comment: "Placeholder of a list of values")
        case (.uuid, _): String(localized: "UUID", comment: "Placeholder of a UUID field")
        case (.uri, _): String(localized: "x-coredata://…", comment: "Placeholder of a URI field")
        default: ""
        }
    }

    var templateViews: [NSView] {
        var views: [NSView] = [fieldPopUp]
        if spec.isQuantified { views.append(quantifierPopUp) }
        views.append(operatorPopUp)
        guard spec.arity != .none else { return views }
        if spec.kind.acceptsStringOptions { views.append(optionsPopUp) }
        switch (spec.kind, spec.arity) {
        case (.boolean, _): views.append(booleanPopUp)
        case (.date, .pair): views += [firstDate, conjunction, secondDate]
        case (.date, _): views.append(firstDate)
        case (_, .pair): views += [firstField, conjunction, secondField]
        default: views.append(firstField)
        }
        return views
    }

    // MARK: Predicate ↔ row

    func row(for ast: PredicateAST) -> BuilderRow? {
        guard let row = spec.schema.row(for: ast),
            spec.fields.contains(where: { $0.keyPath == row.keyPath }), spec.operators.contains(row.op)
        else { return nil }
        return row
    }

    func show(_ ast: PredicateAST) {
        guard let row = row(for: ast) else { return }
        if let index = spec.fields.firstIndex(where: { $0.keyPath == row.keyPath }) {
            fieldPopUp.selectItem(at: index)
        }
        if let quantifier = row.quantifier, let index = BuilderQuantifier.allCases.firstIndex(of: quantifier) {
            quantifierPopUp.selectItem(at: index)
        }
        if let index = spec.operators.firstIndex(of: row.op) {
            operatorPopUp.selectItem(at: index)
        }
        if let index = PredicateOptions.builderChoices.firstIndex(of: row.options) {
            optionsPopUp.selectItem(at: index)
        }
        show(row.values)
    }

    /// The row the views say.
    func row() -> BuilderRow {
        let field = spec.fields[max(fieldPopUp.indexOfSelectedItem, 0)]
        let op = spec.operators[max(operatorPopUp.indexOfSelectedItem, 0)]
        let values = currentValues() ?? lastValues
        lastValues = values
        return BuilderRow(
            keyPath: field.keyPath,
            quantifier: spec.isQuantified
                ? BuilderQuantifier.allCases[max(quantifierPopUp.indexOfSelectedItem, 0)] : nil,
            op: op,
            options: spec.kind.acceptsStringOptions
                ? PredicateOptions.builderChoices[max(optionsPopUp.indexOfSelectedItem, 0)] : [],
            values: values)
    }

    private func show(_ values: [BuilderValue]) {
        lastValues = values
        switch (spec.kind, spec.arity) {
        case (_, .none):
            break
        case (.boolean, _):
            booleanPopUp.selectItem(at: values.first.map(Self.isTrue) == false ? 1 : 0)
        case (.date, _):
            for (picker, value) in zip([firstDate, secondDate], values) {
                if case .literal(.date(let date)) = value { picker.dateValue = date }
            }
        case (_, .list):
            firstField.stringValue = spec.kind.listText(for: values)
        default:
            for (field, value) in zip([firstField, secondField], values) {
                field.stringValue = spec.kind.text(for: value)
            }
        }
    }

    /// The values the views hold, or `nil` while a field holds something that is not one yet.
    private func currentValues() -> [BuilderValue]? {
        switch (spec.kind, spec.arity) {
        case (_, .none):
            return []
        case (.boolean, _):
            return [.literal(.bool(booleanPopUp.indexOfSelectedItem != 1))]
        case (.date, .pair):
            return [.literal(.date(firstDate.dateValue)), .literal(.date(secondDate.dateValue))]
        case (.date, _):
            return [.literal(.date(firstDate.dateValue))]
        case (_, .list):
            return spec.kind.values(fromList: firstField.stringValue)
        case (_, .pair):
            guard let first = spec.kind.value(from: firstField.stringValue),
                let second = spec.kind.value(from: secondField.stringValue)
            else { return nil }
            return [first, second]
        default:
            return spec.kind.value(from: firstField.stringValue).map { [$0] }
        }
    }

    private static func isTrue(_ value: BuilderValue) -> Bool {
        switch value {
        case .literal(.bool(let flag)): flag
        case .literal(.int(let number)): number != 0
        default: true
        }
    }

    // MARK: Return applies

    func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
        guard selector == #selector(NSResponder.insertNewline(_:)) else { return false }
        // The field ends editing first, which is when the editor reads the new value; applying waits for that.
        let onReturn = spec.onReturn
        DispatchQueue.main.async { onReturn() }
        return false
    }
}

/// Keeps a row's text field to what its kind can read: a number field will not end editing on "twelve". What it
/// accepts is `BuilderValueKind`'s to decide, so the field and the row agree.
final class BuilderValueFormatter: Formatter {
    let kind: BuilderValueKind
    let isList: Bool

    init(kind: BuilderValueKind, isList: Bool) {
        self.kind = kind
        self.isList = isList
        super.init()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("not in a nib") }

    override func string(for obj: Any?) -> String? { obj as? String }

    override func getObjectValue(
        _ obj: AutoreleasingUnsafeMutablePointer<AnyObject?>?, for string: String,
        errorDescription error: AutoreleasingUnsafeMutablePointer<NSString?>?
    ) -> Bool {
        let readable = isList ? kind.values(fromList: string) != nil : kind.value(from: string) != nil
        guard readable else {
            error?.pointee = String(localized: "That is not a value this row can compare with.") as NSString
            return false
        }
        obj?.pointee = string as NSString
        return true
    }
}
