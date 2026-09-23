import DabbiKit
import Foundation
import Observation

/// The predicate bar above the grid (PRD §7.1, M2-02).
///
/// What is typed is checked against the model on every keystroke and applied only when the user says so, so a
/// half-written predicate never reaches a fetch. The applied one is kept in the project, per entity, next to the
/// columns and the sort — switching entities and coming back finds the filter where it was left.
@MainActor
@Observable
final class PredicateBarModel {
    /// What can be said about the text as it stands.
    enum Status: Equatable {
        /// Nothing is typed, or there is no model to check it against.
        case empty
        /// It parses and the model knows every key path in it. Warnings come along: they do not stop a fetch.
        case valid([PredicateDiagnostic])
        /// The first thing wrong with it — a syntax error, an unknown key path, a refused function.
        case invalid(PredicateDiagnostic)
    }

    private let context: ProjectContext

    /// What is in the field. Checked as it changes; not applied until ``apply()``.
    var text: String = "" {
        didSet {
            guard text != oldValue else { return }
            validate()
        }
    }
    private(set) var status: Status = .empty
    /// The entity the field is about — the one the grid shows.
    private(set) var entity: String?
    /// The saved predicate the grid shows the entity through, whose text the field then holds (PRD-3).
    private(set) var savedPredicate: UUID?
    /// Whether the visual builder is open under the field (M2-03). The text stays the predicate either way:
    /// the builder is another way of writing it, not a second filter.
    var isShowingBuilder = false
    /// The key paths the builder offers for ``entity``.
    private(set) var schema: BuilderSchema?

    @ObservationIgnored private var validator: PredicateValidator?
    @ObservationIgnored private var completer: PredicateCompleter?
    @ObservationIgnored private var shownSession: ObjectIdentifier?
    /// The applied filter as it was when the field was last set from it. It is what tells a filter changed
    /// elsewhere — reverting the project, another pane clearing it — from the user's own typing, which must
    /// never be overwritten.
    @ObservationIgnored private var synced: String?

    init(context: ProjectContext) {
        self.context = context
    }

    // MARK: Following the context

    /// Keeps the field on the entity the grid shows. Called from an observation loop, so it runs again whenever
    /// one of the things it reads has changed.
    func follow() {
        let entity = context.selectedEntity
        let savedPredicate = context.navigation.current?.savedPredicate
        let session = context.session.map(ObjectIdentifier.init)
        let applied = context.shownLayout.filter?.format

        guard entity == self.entity, savedPredicate == self.savedPredicate, session == shownSession else {
            // Another entity, another saved predicate or another store: this is somebody else's predicate now.
            self.entity = entity
            self.savedPredicate = savedPredicate
            shownSession = session
            let model = context.model
            validator = model.map(PredicateValidator.init)
            completer = model.map(PredicateCompleter.init)
            schema = model.flatMap { model in entity.map { BuilderSchema(model: model, entity: $0) } }
            synced = applied
            text = applied ?? ""
            // The same text against another model can mean something else, so it is checked again either way.
            validate()
            return
        }
        guard applied != synced else { return }
        synced = applied
        text = applied ?? ""
    }

    // MARK: What the text says

    private func validate() {
        let format = trimmed
        guard !format.isEmpty, let validator, let entity else {
            status = .empty
            return
        }
        let result = validator.validate(format, entity: entity)
        status = result.errors.first.map(Status.invalid) ?? .valid(result.warnings)
    }

    var trimmed: String { text.trimmingCharacters(in: .whitespacesAndNewlines) }

    /// The filter the grid is showing.
    var appliedFilter: PredicateSource? { entity == nil ? nil : context.shownLayout.filter }
    var isFiltering: Bool { appliedFilter != nil }
    /// Whether what is typed is what the grid is showing — nothing to apply, and nothing to revert.
    var isApplied: Bool { trimmed == appliedFilter?.format ?? "" }

    var canApply: Bool {
        switch status {
        case .invalid: false
        // Applying an emptied field is how a filter is taken off with the keyboard alone.
        case .empty, .valid: !isApplied
        }
    }

    /// What to say under the field: what is wrong with it, or what is merely worth knowing about it.
    var message: String? {
        switch status {
        case .empty: nil
        case .valid(let warnings): warnings.first?.message
        case .invalid(let diagnostic): diagnostic.message
        }
    }

    var isShowingError: Bool {
        if case .invalid = status { true } else { false }
    }

    /// What to try instead, from the diagnostic the message comes from.
    var suggestions: [String] {
        switch status {
        case .empty: []
        case .valid(let warnings): warnings.first?.suggestions ?? []
        case .invalid(let diagnostic): diagnostic.suggestions
        }
    }

    // MARK: The builder

    /// What the builder shows for the text as it stands.
    enum BuilderContent: Equatable {
        /// Rows: a tree shaped for `NSPredicateEditor`, and the schema its templates come from — the entity's
        /// own, with any deeper key path the predicate names added.
        case rows(PredicateAST, BuilderSchema)
        /// The predicate can only be written as text, for these reasons.
        case text([String])
    }

    /// `nil` when there is no model to build rows from.
    var builderContent: BuilderContent? {
        guard let schema else { return nil }
        let format = trimmed
        guard !format.isEmpty else { return .rows(.and([]), schema) }
        if case .invalid(let diagnostic) = status { return .text([diagnostic.message]) }
        let ast: PredicateAST
        do {
            ast = try PredicateAST.parse(format)
        } catch {
            return .text([error.localizedDescription])
        }
        switch schema.presentation(of: ast) {
        case .rows(let shaped): return .rows(shaped, schema.including(shaped))
        case .custom(let obstacles): return .text(obstacles.map(\.message))
        }
    }

    /// Writes what the builder says into the field. An empty builder is no filter, which is an empty field.
    func takeFromBuilder(_ predicate: NSPredicate) {
        let ast = PredicateAST(predicate)
        switch ast {
        case .all, .and([]):
            text = ""
        default:
            // A predicate the builder made always formats; were one not to, the field keeps what it had.
            if let format = try? ast.formatString() { text = format }
        }
    }

    // MARK: What the user does

    /// Filters the grid by what is typed, or — when it is empty — stops filtering it.
    func apply() {
        guard entity != nil, canApply else { return }
        let format = trimmed
        // What is applied is what was checked: the field keeps the tidied text, not the stray spaces.
        text = format
        let filter = format.isEmpty ? nil : PredicateSource(format: format)
        synced = filter?.format
        context.setShownFilter(filter)
    }

    /// Starts a predicate from nothing (PRD-3): the entity's own rows, one row in the builder on its `name` or
    /// `title`, and nothing applied until there is a value to filter by. Saving it is a separate step.
    ///
    /// - Returns: whether there was a row to start on — an entity with no such field starts with an empty
    ///   builder, and the keyboard goes to the field instead.
    @discardableResult
    func startNewPredicate() -> Bool {
        guard let location = context.navigation.current else { return false }
        if location.savedPredicate != nil { context.select(entity: location.entity) }
        follow()
        isShowingBuilder = true
        guard let starter = schema?.starterPredicate, let format = try? starter.formatString() else {
            text = ""
            return false
        }
        text = format
        return true
    }

    /// Empties the field and shows every row again.
    func clear() {
        text = ""
        apply()
    }

    /// Puts the applied predicate back, for a change the user has thought better of.
    func revert() {
        text = appliedFilter?.format ?? ""
    }

    /// What can be typed at `caret`, a UTF-16 offset into `text` (M2-02).
    func completions(in text: String, at caret: Int) -> PredicateCompletions {
        guard let completer, let entity else { return PredicateCompletions(range: caret..<caret, items: []) }
        return completer.completions(in: text, at: caret, entity: entity)
    }
}
