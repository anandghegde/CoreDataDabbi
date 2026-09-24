import DabbiKit
import Foundation
import Observation

/// One project's state, and the composition root of its window (ARCHITECTURE.md §8).
///
/// The document owns it and saves what it holds; the window's panes read it and tell it what the user did.
/// It knows neither of them, which is what lets the tests drive it without a window.
@MainActor
@Observable
final class ProjectContext {
    /// What a change means for the document.
    enum Change {
        /// The project says something else now: another store, another model.
        case project
        /// Layout and selection. Saved along, but never worth asking the user about.
        case layout
    }

    enum StoreState {
        /// The project names no store.
        case none
        case opening
        case open(OpenedStore)
        case failed(DabbiError)
    }

    private(set) var package: ProjectPackage
    private(set) var storeState: StoreState = .none
    /// By entity name. Empty until the counts are in: they are not waited for (§7, "Open a store").
    private(set) var entityCounts: [String: EntityCount] = [:]
    /// Where the main grid is, and where it has been (REL-3).
    let navigation = NavigationHistory()
    /// Change tracking for this window (TRK-1). While it is showing, the log takes the grid's place in the
    /// centre; the window drives it, and everything else that watches the window reads its state from here.
    @ObservationIgnored let tracking = TrackingSession()
    /// Staged edits, while the store is open editable (EDT-8). Empty, and with nothing to undo, otherwise.
    @ObservationIgnored let editing = EditingSession()
    /// The open store's snapshots and backups (§7.3).
    @ObservationIgnored let snapshots = SnapshotsSession()
    /// The property the content viewer reads, within the inspected object (CNT-1). Looking at another column is
    /// not somewhere to go back to, so unlike the entity and the row it is not part of the history.
    private(set) var focusedProperty: String?
    /// The entity `focusedProperty` belongs to. Moving down a column keeps reading it; another entity has other
    /// columns, and the one being read is gone with it.
    @ObservationIgnored private var focusedPropertyEntity: String?
    /// The object the inspector and the content viewer read: the grid's selection, or — while one is picked in
    /// the relationships panel — a related object the grid is not showing (REL-1), or one only inserted, which
    /// no grid shows until it is committed (EDT-3).
    private(set) var inspectedObject: PendingObjectID?
    /// Whose store this is, for the status capsule: `nil` for a store picked as a file, whose path says it.
    private(set) var locationOrigin: String?
    /// Where the store may be now, when it is not where the project says (PRJ-12). Empty otherwise.
    private(set) var repairs: [StoreRepair] = []

    @ObservationIgnored var onChange: ((Change) -> Void)?
    /// The store — or the model — is not where the project says, and was until now: the window shows Project
    /// Settings (PRJ-12). Called once each time it goes missing, not each time it is looked for again.
    @ObservationIgnored var onStoreLost: (() -> Void)?
    /// The user unlocked the project, and the store cannot be written where it is (EDT-1). It is open read-only
    /// again, and the project still says read-only; this is for the window to say why.
    @ObservationIgnored var onEditingRefused: ((DabbiError) -> Void)?
    /// There are staged edits, and the user asked for something that would lose them: reopening the store,
    /// locking it, pointing the project elsewhere, closing. The window asks whether to commit them first, discard
    /// them, or not go ahead, and hands the answer to `decide`. Without it nothing that would lose them is done.
    @ObservationIgnored var onLeavingChanges: ((_ decide: @escaping @MainActor (LeavingChanges) -> Void) -> Void)?
    /// A snapshot is to be restored, and other processes have the store open (§7.3). The window names them,
    /// offers to quit them when `canQuit`, and hands `decide` whether to. Without it the restore is refused.
    @ObservationIgnored var onStoreInUse:
        ((_ holders: [LiveProcess], _ canQuit: Bool, _ decide: @escaping @MainActor (Bool) -> Void) -> Void)?
    /// How the holders of a store are asked to quit; the tests stop their own. `nil` is ``StoreHolders``.
    @ObservationIgnored var quitHolders: (@MainActor (_ holders: [LiveProcess], _ store: URL) async throws -> Void)?
    /// Where simulators are looked for; the tests have a device set of their own.
    @ObservationIgnored var devicesDirectory: URL?
    @ObservationIgnored var workingCopiesDirectory: URL?
    /// Where pre-commit backups go; the tests keep theirs apart from the user's.
    @ObservationIgnored var backupsDirectory: URL?
    /// Who knows which simulators this Mac has, for naming the device a store belongs to. The app's one index,
    /// so that a browser already open has answered this before it is asked.
    @ObservationIgnored var simulators: (any SimulatorBrowsing)? = Simulators.index

    @ObservationIgnored private var openTask: Task<Void, Never>?
    /// The last opening that had something to do with the store closed first.
    @ObservationIgnored private var preparing: Task<Void, Never>?
    /// Quitting whoever has the store open, before a restore.
    @ObservationIgnored private var quitTask: Task<Void, Never>?
    @ObservationIgnored private var countsTask: Task<Void, Never>?
    @ObservationIgnored private var originTask: Task<Void, Never>?
    @ObservationIgnored private var checkTask: Task<Void, Never>?
    @ObservationIgnored private var repairTask: Task<Void, Never>?
    /// `onStoreLost` has been called since the store was last open.
    @ObservationIgnored private var lossReported = false
    @ObservationIgnored private var attempt = 0
    /// Tracking was on when the store was reopened, so it can be picked up again on the new session.
    @ObservationIgnored private var resumeTracking: Bool = false
    /// The access mode the user just asked for, until the store has been reopened in it. The project takes it
    /// only then, so a store that cannot be edited leaves the project as it was.
    @ObservationIgnored private var requestedAccess: AccessMode?
    /// What each fetch-request template was last run with, by name, for the prompt to start from. This window's
    /// only: the values are the user's rows, and the project file is not the place for them.
    @ObservationIgnored private var fetchRequestValues: [String: [String: PredicateLiteral]] = [:]

    init(package: ProjectPackage = ProjectPackage()) {
        self.package = package
        // The file being watched was replaced, so the open session reads something that is gone: reopen, and
        // start tracking again on what is there now (Appendix D).
        tracking.onStoreReplaced = { [weak self] in self?.openStore() }
        // The first commit of a session backs the store up, and the sidebar lists backups.
        editing.onCommitFinished = { [weak self] in
            self?.snapshots.refresh()
            self?.followCommittedObject()
        }
    }

    // MARK: Reading

    var project: Project { package.project }
    var local: LocalState { package.local }

    var openedStore: OpenedStore? {
        if case .open(let store) = storeState { store } else { nil }
    }
    var session: StoreSession? { openedStore?.session }
    /// The user's file — not the copy that is read when it could not be opened where it is.
    var storeURL: URL? { openedStore?.storeURL }
    /// The entity the main grid shows.
    var selectedEntity: String? { navigation.current?.entity }
    /// The saved predicate the main grid shows its entity through, if it does.
    var shownPredicate: SavedPredicate? { navigation.current?.savedPredicate.flatMap(savedPredicate(_:)) }
    var model: ModelDescription? { session?.info.model }
    /// How the open store was opened — which is the project's access mode, unless the store could not be opened
    /// editable. `nil` while nothing is open.
    var accessMode: AccessMode? { session?.info.accessMode }
    var timeZone: TimeZone { project.display.timeZone.timeZone }

    func shows(_ location: StoreLocation) -> Bool {
        switch (project.store, location) {
        case (.file(let mine), .file(let other)):
            mine.lastKnownURL.standardizedFileURL == other.lastKnownURL.standardizedFileURL
        case (let mine?, let other):
            mine == other
        case (nil, _):
            false
        }
    }

    // MARK: The project

    /// The document was read, or reverted to another version.
    func replace(_ package: ProjectPackage) {
        let pointsElsewhere = package.project.store != project.store || package.project.model != project.model
        self.package = package
        // A saved predicate the other version does not have leaves its entity on screen, unfiltered by it.
        if let id = navigation.current?.savedPredicate, savedPredicate(id) == nil {
            navigation.amend { $0.savedPredicate = nil }
        }
        if pointsElsewhere, hasStarted { openStore() }
    }

    func adoptStore(at url: URL) {
        let reference = package.local.remember(url)
        package.project.store = .file(reference)
    }

    func adopt(_ location: StoreLocation) {
        package.project.store = location
    }

    /// Points the project at another store, as the user's doing.
    func chooseStore(at url: URL) {
        leaveChanges { [weak self] in
            guard let self else { return }
            self.adoptStore(at: url)
            self.onChange?(.project)
            self.openStore()
        }
    }

    func updateLayout(of entity: String, _ update: (inout EntityLayout) -> Void) {
        var layout = package.project.display.entities[entity] ?? EntityLayout()
        update(&layout)
        guard layout != package.project.display.entities[entity] else { return }
        package.project.display.entities[entity] = layout == EntityLayout() ? nil : layout
        onChange?(.layout)
    }

    /// Filters an entity's grid by a predicate the user wrote (§7.1). `nil` shows every row again.
    ///
    /// It is kept with the layout, so it comes back with the entity and travels with the project file; the grid
    /// picks it up through the same observation as the sort.
    func setFilter(_ filter: PredicateSource?, of entity: String) {
        updateLayout(of: entity) { $0.filter = filter }
    }

    func layout(of entity: String) -> EntityLayout {
        project.display.entities[entity] ?? EntityLayout()
    }

    /// The layout the grid is seen through at a place: the saved predicate's when it shows one, the entity's
    /// otherwise (BRW-3). The display attribute is the entity's either way — it is how its objects are named.
    func layout(at location: BrowseLocation) -> EntityLayout {
        if let run = location.fetchRequest {
            var layout = layout(of: location.entity)
            layout.filter = run.filter
            if !run.sort.isEmpty { layout.sort = run.sort }
            return layout
        }
        guard let predicate = location.savedPredicate.flatMap(savedPredicate(_:)) else {
            return layout(of: location.entity)
        }
        var layout = predicate.layout
        layout.displayAttribute = self.layout(of: location.entity).displayAttribute
        return layout
    }

    /// The layout of what the main grid shows. Empty when it shows nothing.
    var shownLayout: EntityLayout {
        navigation.current.map(layout(at:)) ?? EntityLayout()
    }

    /// Changes the columns, sort or filter of what the main grid shows — a saved predicate's own, when it is one.
    ///
    /// A saved predicate's filter is what it *is*, so changing it is an edit to the project the user is asked
    /// about on closing; its columns and sort are how it is looked at, and are saved along like an entity's.
    func updateShownLayout(_ update: (inout EntityLayout) -> Void) {
        guard let location = navigation.current else { return }
        if var run = location.fetchRequest {
            // The run's filter and sort are its own; the columns it is seen through are the entity's.
            var layout = layout(at: location)
            update(&layout)
            updateLayout(of: location.entity) {
                $0.columns = layout.columns
                $0.displayAttribute = layout.displayAttribute
            }
            run.filter = layout.filter
            run.sort = layout.sort
            if run != location.fetchRequest { navigation.amend { $0.fetchRequest = run } }
            return
        }
        guard let id = location.savedPredicate, var predicate = savedPredicate(id) else {
            updateLayout(of: location.entity, update)
            return
        }
        var layout = predicate.layout
        update(&layout)
        guard layout != predicate.layout else { return }
        let filterChanged = layout.filter != predicate.predicate
        predicate.layout = layout
        replaceSavedPredicate(predicate, as: filterChanged ? .project : .layout)
    }

    /// Filters what the main grid shows (§7.1): the entity, or the saved predicate it is seen through.
    func setShownFilter(_ filter: PredicateSource?) {
        updateShownLayout { $0.filter = filter }
    }

    // MARK: The quick filter (PRD-6)

    /// What the quick filter can search at a place: `nil` without a model, or for an entity it does not have.
    func quickFilter(at location: BrowseLocation) -> QuickFilter? {
        model.flatMap { QuickFilter(model: $0, entity: location.entity) }
    }

    /// The quick filter for what the main grid shows.
    var shownQuickFilter: QuickFilter? { navigation.current.flatMap(quickFilter(at:)) }

    /// What the grid fetches at a place, and what tracking is scoped by: the place's filter, narrowed by what is
    /// typed in its quick filter. The predicate bar still shows the filter alone — the quick filter is a search
    /// within it, not an edit to it.
    func fetchFilter(at location: BrowseLocation) -> PredicateSource? {
        let filter = layout(at: location).filter
        guard let quick = quickFilter(at: location) else { return filter }
        return quick.narrowing(filter, by: location.quickFilter)
    }

    /// What the main grid fetches.
    var shownFetchFilter: PredicateSource? { navigation.current.flatMap(fetchFilter(at:)) }

    /// Searches the rows the main grid shows for a term, or — when it is empty — stops searching them. The same
    /// place, seen through a search: nothing to go back to, and nothing the project keeps.
    func setQuickFilter(_ term: String) {
        guard let location = navigation.current, location.quickFilter != term else { return }
        navigation.amend { $0.quickFilter = term }
    }

    func updateWindow(_ update: (inout WindowState) -> Void) {
        var window = package.local.window
        update(&window)
        guard window != package.local.window else { return }
        package.local.window = window
        onChange?(.layout)
    }

    func updateSelection(_ update: (inout SelectionState) -> Void) {
        var selection = package.local.selection
        update(&selection)
        guard selection != package.local.selection else { return }
        package.local.selection = selection
        onChange?(.layout)
    }

    /// Shows an entity from its first row, as a click in the sidebar does.
    func select(entity: String) {
        show(BrowseLocation(entity: entity))
    }

    /// Shows a saved predicate's rows, as a click on it in the sidebar does (PRD-3).
    func show(savedPredicate id: UUID) {
        guard let predicate = savedPredicate(id) else { return }
        show(BrowseLocation(entity: predicate.entity, savedPredicate: id))
    }

    func show(_ location: BrowseLocation) {
        if location.entity != navigation.current?.entity, location.entity != focusedPropertyEntity {
            forgetProperty()
        }
        navigation.show(location)
        arrive()
    }

    /// Follows a relationship into the grid: "Reveal in Entity" (REL-3).
    ///
    /// `label` names the object the relationship was followed from, for the breadcrumb. The trail grows while
    /// the drilling continues from where the last step landed, and starts again when it does not.
    func reveal(_ object: ObjectRef, from source: ObjectRef?, labelled label: String, through relationship: String) {
        var trail = navigation.current?.trail ?? []
        if trail.isEmpty || source == nil || source != navigation.current?.focus { trail = [label] }
        trail.append(relationship)
        show(BrowseLocation(entity: object.entity, focus: object, trail: trail))
    }

    /// The grid's selection moved. The same place, seen differently — not somewhere to go back to (REL-3).
    func focus(on object: ObjectRef?) {
        inspect(object.map(PendingObjectID.init))
        guard navigation.current?.focus != object else { return }
        navigation.amend { $0.focus = object }
    }

    /// A related object was picked in the relationships panel, or an object in the Pending Changes panel: the
    /// inspector and the content viewer follow it, and the grid stays where it is (REL-1). Revealing it is a
    /// separate, deliberate step.
    func inspect(_ object: PendingObjectID?) {
        guard inspectedObject != object else { return }
        // Another entity's object has other properties; the one that was being read is not among them. Losing
        // the selection altogether is not the same thing: the next row brings the same column back.
        if let entity = object?.entity, entity != focusedPropertyEntity { forgetProperty() }
        inspectedObject = object
    }

    /// The inspected object's reference; `nil` while it is only inserted, and has none yet. What has no
    /// reference has no relationships to follow and no stored bytes to read.
    var inspectedRef: ObjectRef? { inspectedObject?.ref }

    /// Whether New Object can stage one: the store is open for editing, and the grid shows an entity that can
    /// have objects of its own.
    var canInsertObject: Bool {
        guard editing.isEditable, let entity = selectedEntity.flatMap({ model?.entity(named: $0) }) else {
            return false
        }
        return !entity.isAbstract
    }

    /// Stages a new object of the grid's entity and shows it in the inspector, where its fields are filled in
    /// (EDT-3). The grid does not list it until it is committed.
    func insertObject() {
        guard canInsertObject, let entity = selectedEntity else { return }
        editing.insertObject(of: entity) { [weak self] object in self?.inspect(object) }
    }

    /// The inspector was showing an object only inserted, and the commit gave it a reference: it goes on
    /// showing it, now by that reference.
    private func followCommittedObject() {
        guard let object = inspectedObject, object.isInserted,
            let ref = editing.lastCommit?.insertedRefs[object]
        else { return }
        inspectedObject = PendingObjectID(ref)
    }

    /// A cell was clicked: the same row, read through another column (CNT-1).
    func focus(onProperty property: String?) {
        guard focusedProperty != property else { return }
        focusedProperty = property
        focusedPropertyEntity = property == nil ? nil : (inspectedObject?.entity ?? navigation.current?.entity)
    }

    private func forgetProperty() {
        focusedProperty = nil
        focusedPropertyEntity = nil
    }

    func goBack() {
        navigation.goBack()
        arrive()
    }

    func goForward() {
        navigation.goForward()
        arrive()
    }

    /// Goes back to the place a breadcrumb names: the nearest one behind that was reached by fewer steps
    /// through relationships than the one shown (REL-3).
    func goBack(toTrailLength length: Int) {
        while navigation.canGoBack, (navigation.current?.trail.count ?? 0) > length {
            navigation.goBack()
        }
        arrive()
    }

    /// The grid is somewhere else now: remember where, and read what is selected there.
    private func arrive() {
        inspect(navigation.current?.focus.map(PendingObjectID.init))
        updateSelection { $0.entity = navigation.current?.entity }
    }

    // MARK: Fetch-request templates (BRW-1)

    /// The model's templates, each read against it, by name.
    var fetchRequestPlans: [FetchTemplatePlan] {
        guard let model else { return [] }
        return model.fetchRequestTemplates.map { FetchTemplatePlan(template: $0, model: model) }
    }

    /// The template the main grid shows its entity through, if it does.
    var shownFetchRequest: FetchRequestRun? { navigation.current?.fetchRequest }

    /// What a template's prompt starts from: the values it was last run with in this window.
    func lastValues(forFetchRequest name: String) -> [String: PredicateLiteral] {
        fetchRequestValues[name] ?? [:]
    }

    /// Runs a template with values for its variables, and shows its entity through the result (BRW-1).
    ///
    /// - Throws: ``DabbiError`` when the template cannot run, or a value is missing or of the wrong kind.
    func run(fetchRequest plan: FetchTemplatePlan, values: [String: PredicateLiteral] = [:]) throws {
        let filter = try plan.predicate(with: values)
        guard let entity = plan.entity else { return }
        let used = values.filter { name, _ in plan.variables.contains { $0.name == name } }
        if !used.isEmpty { fetchRequestValues[plan.name] = used }
        show(
            BrowseLocation(
                entity: entity,
                fetchRequest: FetchRequestRun(
                    name: plan.name, values: used, filter: filter, sort: plan.sort, limit: plan.limit)))
    }

    // MARK: Saved predicates (PRD-3, PRD-5)

    /// By name, as the sidebar lists them.
    var savedPredicates: [SavedPredicate] {
        package.predicates.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    func savedPredicate(_ id: UUID) -> SavedPredicate? {
        package.predicates.first { $0.id == id }
    }

    /// Whether a saved predicate still fits the model the store was opened with (PRD-5). Without a model there
    /// is nothing to hold it against, and it is taken to be fine.
    func check(_ predicate: SavedPredicate) -> SavedPredicateCheck {
        guard let model else { return .fine }
        return PredicateValidator(model: model).check(
            entity: predicate.entity, predicate: predicate.predicate, sort: predicate.sort)
    }

    /// Whether ``saveShownPredicate()`` has something to save: an entity seen through its own layout, or through
    /// a fetch-request template it was run with.
    var canSavePredicate: Bool {
        guard let location = navigation.current else { return false }
        return location.savedPredicate == nil && model?.entity(named: location.entity) != nil
    }

    /// Keeps what the grid shows as a saved predicate, and goes to it (PRD-3).
    ///
    /// It takes the entity's filter, columns and sort with it, and the entity's own filter is cleared: the rows
    /// the user filtered their way to are the predicate's now, and the entity is back to all of its rows. The
    /// name is the first condition's, until the user gives it another. A template's run is kept the same way,
    /// under the template's name, with its values in it; the entity's own filter was never involved.
    ///
    /// - Returns: the new predicate, for the sidebar to start renaming.
    @discardableResult
    func saveShownPredicate() -> SavedPredicate? {
        guard canSavePredicate, let location = navigation.current else { return nil }
        let entity = location.entity
        let layout = layout(at: location)
        let name = SavedPredicate.uniqueName(
            location.fetchRequest?.name ?? SavedPredicateNaming.defaultName(for: layout.filter, entity: entity),
            among: package.predicates.map(\.name))
        let predicate = SavedPredicate(
            name: name, entity: entity, predicate: layout.filter, columns: layout.columns, sort: layout.sort)
        package.predicates.append(predicate)
        if location.fetchRequest == nil { updateLayout(of: entity) { $0.filter = nil } }
        onChange?(.project)
        show(BrowseLocation(entity: entity, savedPredicate: predicate.id))
        return predicate
    }

    /// A copy under the next free name, shown as the original is left alone.
    @discardableResult
    func duplicate(savedPredicate id: UUID) -> SavedPredicate? {
        guard var copy = savedPredicate(id) else { return nil }
        copy.id = UUID()
        copy.name = SavedPredicate.uniqueName(copy.name, among: package.predicates.map(\.name))
        package.predicates.append(copy)
        onChange?(.project)
        show(savedPredicate: copy.id)
        return copy
    }

    /// Renames a saved predicate. An empty name is not one; a taken one gets a number.
    func rename(savedPredicate id: UUID, to name: String) {
        let name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty, var predicate = savedPredicate(id), predicate.name != name else { return }
        predicate.name = SavedPredicate.uniqueName(
            name, among: package.predicates.filter { $0.id != id }.map(\.name))
        replaceSavedPredicate(predicate, as: .project)
    }

    /// Deletes a saved predicate. Were its rows on screen, the grid goes back to its entity.
    func delete(savedPredicate id: UUID) {
        guard package.predicates.contains(where: { $0.id == id }) else { return }
        package.predicates.removeAll { $0.id == id }
        onChange?(.project)
        guard let location = navigation.current, location.savedPredicate == id else { return }
        show(BrowseLocation(entity: location.entity))
    }

    private func replaceSavedPredicate(_ predicate: SavedPredicate, as change: Change) {
        guard let index = package.predicates.firstIndex(where: { $0.id == predicate.id }),
            package.predicates[index] != predicate
        else { return }
        package.predicates[index] = predicate
        onChange?(change)
    }

    // MARK: The store

    @ObservationIgnored private var hasStarted = false

    /// Called when the project gets a window; a project that is only read — by a test, by Quick Look one day —
    /// opens nothing.
    func openStoreIfNeeded() {
        guard !hasStarted else { return }
        hasStarted = true
        openStore()
    }

    /// Opens the project's store, again if it is open: the way to see what the app has written since.
    ///
    /// - Parameter prepare: Run once the store that was open is closed, and before it is opened again: what
    ///   has to be done with nothing of this process holding it — a restore.
    func openStore(preparing prepare: (@MainActor () async -> Void)? = nil) {
        hasStarted = true
        openTask?.cancel()
        attempt += 1
        let attempt = attempt
        let previous = openedStore
        entityCounts = [:]
        // Keys, prior values and materialised objects all belong to the session that is about to close.
        resumeTracking = tracking.isRunning
        tracking.close()
        // Whatever was staged lives in the session that is about to close (EDT-8).
        editing.detach()

        guard let location = project.store else {
            snapshots.detach()
            storeState = .none
            locationOrigin = nil
            repairs = []
            inspect(nil)
            if let previous { Task { await previous.close() } }
            return
        }
        storeState = .opening
        describeOrigin(of: location)

        let opener = StoreOpener(resolver: makeResolver(), workingCopiesDirectory: workingCopiesDirectory)
        let model = project.model
        let access: StoreAccess = (requestedAccess ?? project.accessMode) == .editable ? .editable(.app) : .readOnly

        // A reopening asked for while a restore is under way waits for it: the files are not whole until then.
        let earlier = preparing
        openTask = Task { [weak self] in
            await previous?.close()
            await earlier?.value
            await prepare?()
            var refusal: DabbiError?
            var result = await Self.open(location, model: model, access: access, with: opener)
            // A store that cannot be edited can still be read, and reading it is what the window is for.
            if case .failure(let error) = result, error.code == .storeNotWritable {
                refusal = error
                result = await Self.open(location, model: model, access: .readOnly, with: opener)
            }
            guard let self, self.attempt == attempt else {
                // Closed or pointed elsewhere in the meantime.
                if case .success(let store) = result { await store.close() }
                return
            }
            self.finishOpening(result, editingRefused: refusal)
        }
        if prepare != nil { preparing = openTask }
    }

    private static func open(
        _ location: StoreLocation, model: ModelReference, access: StoreAccess, with opener: StoreOpener
    ) async -> Result<OpenedStore, DabbiError> {
        do {
            return .success(try await opener.open(location, model: model, access: access))
        } catch let error as DabbiError {
            return .failure(error)
        } catch {
            return .failure(DabbiError(.internal, "The store could not be opened.", underlying: error))
        }
    }

    private func finishOpening(_ result: Result<OpenedStore, DabbiError>, editingRefused refusal: DabbiError? = nil) {
        // Only an unlock the user asked for is worth an alert: a project saved unlocked, reopened where its store
        // cannot be written, opens read-only and says so in the status capsule.
        let requested = requestedAccess
        requestedAccess = nil
        if let requested, case .success(let store) = result, store.session.info.accessMode == requested,
            project.accessMode != requested
        {
            package.project.accessMode = requested
            onChange?(.project)
        }
        if let refusal, requested == .editable { onEditingRefused?(refusal) }

        switch result {
        case .failure(let error):
            storeState = .failed(error)
            snapshots.detach()
            inspect(nil)
            guard Self.isLoss(error) else { break }
            if let location = project.store, error.code == .locationUnresolved { findRepairs(for: location) }
            if !lossReported {
                lossReported = true
                onStoreLost?()
            }
        case .success(let store):
            storeState = .open(store)
            repairs = []
            lossReported = false
            refreshReference(to: store.storeURL)
            if store.session.info.accessMode == .editable {
                editing.attach(
                    store.session,
                    backup: PreCommitBackup(
                        for: store.session, storeURL: store.storeURL,
                        root: backupsDirectory ?? PreCommitBackup.defaultRoot,
                        name: String(localized: "Before editing")))
            }
            snapshots.attach(
                store: store.storeURL,
                library: PreCommitBackup.library(
                    forStoreUUID: store.session.info.metadata.storeUUID, at: store.storeURL,
                    under: backupsDirectory ?? PreCommitBackup.defaultRoot))
            let model = store.session.info.model
            // Reloading keeps the place; another store, or a first opening, starts where the project was left.
            if navigation.current.flatMap({ model.entity(named: $0.entity) }) == nil {
                let remembered = local.selection.entity.flatMap(model.entity(named:))?.name
                navigation.reset(to: (remembered ?? Self.firstEntity(of: model)).map { BrowseLocation(entity: $0) })
            }
            // A related object picked before the reload belongs to the session that has just gone.
            inspect(navigation.current?.focus.map(PendingObjectID.init))
            loadCounts(of: store.session)
            // Tracking follows the grid, so it starts again on what the grid is showing now (TRK-7).
            if resumeTracking, let location = navigation.current, model.entity(named: location.entity) != nil {
                tracking.start(on: store.session, entity: location.entity, filter: fetchFilter(at: location))
            }
            resumeTracking = false
        }
    }

    /// Bookmarks are this machine's; the resolver gets a copy of them as they are now.
    private func makeResolver() -> StoreLocationResolver {
        let local = package.local
        return StoreLocationResolver(devicesDirectory: devicesDirectory) { local.resolve($0)?.url }
    }

    /// Says whose store this is, as far as it can be said at once, and then asks for the device's name: the
    /// index answers from what it knows, so a browser that has just been used costs nothing here.
    private func describeOrigin(of location: StoreLocation) {
        originTask?.cancel()
        locationOrigin = StoreStatus.origin(of: location, devices: [])
        guard case .simulator = location, let simulators else { return }
        let attempt = attempt
        originTask = Task { [weak self] in
            let listing = await simulators.devices(refresh: false)
            guard let self, self.attempt == attempt else { return }
            self.locationOrigin = StoreStatus.origin(of: location, devices: listing.devices)
        }
    }

    /// The store was found by bookmark somewhere else than it used to be: remember where, for people who read
    /// the project file and for machines that have no bookmark.
    private func refreshReference(to url: URL) {
        guard case .file(let reference) = project.store, reference.lastKnownURL.standardizedFileURL != url else {
            return
        }
        package.project.store = .file(package.local.remember(url, as: reference.bookmarkID))
        onChange?(.layout)
    }

    private func loadCounts(of session: StoreSession) {
        let attempt = attempt
        countsTask = Task { [weak self] in
            guard let counts = try? await session.entityCounts(), let self, self.attempt == attempt else { return }
            self.entityCounts = Dictionary(counts.map { ($0.entity, $0) }, uniquingKeysWith: { first, _ in first })
        }
    }

    /// Returns once the store is open or has failed to, and its counts are in. Nothing in the app waits for
    /// that; the tests do.
    func whenSettled() async {
        await quitTask?.value
        await checkTask?.value
        await openTask?.value
        await repairTask?.value
        await countsTask?.value
        await originTask?.value
        await tracking.whenSettled()
        await editing.whenSettled()
        await snapshots.whenSettled()
    }

    /// The document is closing.
    func shutDown() {
        tracking.close()
        editing.detach()
        snapshots.detach()
        openTask?.cancel()
        originTask?.cancel()
        checkTask?.cancel()
        repairTask?.cancel()
        attempt += 1
        let store = openedStore
        storeState = .none
        if let store { Task { await store.close() } }
    }

    // MARK: Auto-repair (PRJ-12)

    /// Whether `error` means the project points at something that is not there, rather than at a store that
    /// could not be read.
    static func isLoss(_ error: DabbiError) -> Bool {
        error.code == .locationUnresolved || error.code == .modelNotFound
    }

    /// The window became key: is the store still where the project says?
    ///
    /// A store that moved — a reinstall gives a simulator app new containers — is opened where it is now; one
    /// that is gone is "reopened" too, which fails and says why. A store that could not be found is looked for
    /// again, and opened if it is back: the app was run again, the simulator was booted. Resolving is a few
    /// directory listings, cheap enough to do on every activation, and it is done off the main thread anyway.
    func checkReachability() {
        guard hasStarted, let location = project.store else { return }
        let shown: URL?
        switch storeState {
        case .open(let store): shown = store.storeURL
        case .failed(let error) where error.code == .locationUnresolved: shown = nil
        case .none, .opening, .failed: return
        }
        checkTask?.cancel()
        let resolver = makeResolver()
        let attempt = attempt
        checkTask = Task { [weak self] in
            let found = await Task.detached(priority: .userInitiated) { try? resolver.resolve(location) }.value
            guard let self, self.attempt == attempt, !Task.isCancelled else { return }
            switch (shown, found) {
            case (let shown?, let found):
                if found?.standardizedFileURL != shown.standardizedFileURL {
                    DabbiLog.logger(.locator).notice("the store moved or went away; reopening")
                    self.openStore()
                }
            case (nil, _?):
                DabbiLog.logger(.locator).notice("the store is back; opening it")
                self.openStore()
            case (nil, nil):
                self.findRepairs(for: location)
            }
        }
    }

    /// Looks for where the store may be now, for Project Settings to suggest.
    private func findRepairs(for location: StoreLocation) {
        repairTask?.cancel()
        let repairer = StoreLocationRepairer(devicesDirectory: devicesDirectory)
        let attempt = attempt
        repairTask = Task { [weak self] in
            let found = await Task.detached(priority: .utility) { repairer.suggestions(for: location) }.value
            guard let self, self.attempt == attempt, !Task.isCancelled else { return }
            self.repairs = found
        }
    }

    /// Points the project at a store Project Settings suggested.
    func apply(_ repair: StoreRepair) {
        leaveChanges { [weak self] in
            guard let self else { return }
            if let location = repair.location {
                self.adopt(location)
            } else {
                self.adoptStore(at: repair.url)
            }
            self.onChange?(.project)
            self.openStore()
        }
    }

    // MARK: Project Settings

    /// Reads the store with the model in `url` — a `.mom`, a `.momd` or an app — rather than the one cached in
    /// it (PRJ-3, PRJ-7).
    func chooseModel(at url: URL) {
        leaveChanges { [weak self] in
            guard let self else { return }
            self.package.project.model = .file(self.package.local.remember(url))
            self.onChange?(.project)
            self.openStore()
        }
    }

    func useCachedModel() {
        guard project.model != .storeCache else { return }
        leaveChanges { [weak self] in
            guard let self else { return }
            self.package.project.model = .storeCache
            self.onChange?(.project)
            self.openStore()
        }
    }

    // MARK: Access mode (EDT-1)

    /// Whether the lock can be turned: there is a store open to reopen the other way.
    var canChangeAccessMode: Bool { session != nil }

    /// Locks or unlocks the project. The store is reopened in the new mode — `NSReadOnlyPersistentStoreOption` is
    /// an open-time option — keeping the place, and tracking if it was on.
    func setAccessMode(_ mode: AccessMode) {
        guard canChangeAccessMode, mode != accessMode else { return }
        // Locking closes the edit context, and what is staged in it (EDT-8).
        leaveChanges { [weak self] in
            guard let self, mode != self.accessMode else { return }
            self.requestedAccess = mode
            self.openStore()
        }
    }

    // MARK: Staged edits (EDT-8)

    /// Reopens the store as the user asked — Reload Store — asking first about any staged edits.
    func reloadStore() {
        leaveChanges { [weak self] in self?.openStore() }
    }

    /// Runs `proceed` once no staged edits stand in its way: at once if there are none, after they are
    /// committed or discarded if the user says so. A commit that fails, or a Cancel, runs `cancelled` instead,
    /// and everything stays staged.
    func leaveChanges(_ proceed: @escaping @MainActor () -> Void, cancelled: (@MainActor () -> Void)? = nil) {
        guard editing.hasChanges else {
            proceed()
            return
        }
        guard let ask = onLeavingChanges else {
            cancelled?()
            return
        }
        ask { [weak self] decision in
            guard let self else { return }
            switch decision {
            case .cancel:
                cancelled?()
            case .discard:
                // Closing the session is what throws them away; there is nothing to write.
                self.editing.detach()
                proceed()
            case .commit:
                let commit = self.editing.commit()
                Task {
                    if await commit.value { proceed() } else { cancelled?() }
                }
            }
        }
    }

    // MARK: Snapshots (§7.3)

    /// Copies the store as it is on disk into its library, under `name`.
    @discardableResult
    func takeSnapshot(name: String, note: String = "") -> Task<SnapshotManifest?, Never>? {
        snapshots.take(name: name, note: note)
    }

    /// Whether a snapshot can be put back now: a store is open to put it back into, and nothing else is being
    /// done with it.
    var canRestore: Bool {
        storeURL != nil && snapshots.isAttached && !snapshots.isBusy && !editing.isCommitting
    }

    /// Puts a snapshot back in place of the store, backing the store up first, and reopens it (§7.3).
    ///
    /// Staged edits are asked about first — the store they were staged against is about to go. Other processes
    /// that have the store open are asked to quit, if the user says so; the restore does not go ahead while
    /// anything holds the store.
    func restore(_ snapshot: SnapshotManifest) {
        guard canRestore else { return }
        leaveChanges { [weak self] in self?.restoreWhenFree(snapshot) }
    }

    /// Looks for other processes that have the store open — a walk over every process's files, a quarter of a
    /// second, so not on the main thread — and asks them to quit if the user says so, before the restore.
    private func restoreWhenFree(_ snapshot: SnapshotManifest) {
        guard canRestore, let store = storeURL, snapshots.beginRestoring() else { return }
        let location = project.store
        let devices = devicesDirectory
        quitTask = Task { [weak self] in
            let holders = await Task.detached(priority: .userInitiated) { LiveProcesses.holding(store) }.value
            guard let self else { return }
            guard !holders.isEmpty else { return self.replaceStore(with: snapshot) }
            guard let ask = self.onStoreInUse else {
                return self.snapshots.endRestoring(LiveProcesses.inUse(store, by: holders))
            }
            let canQuit = StoreHolders.canQuit(holders, of: location)
            let quit = await withCheckedContinuation { answer in ask(holders, canQuit) { answer.resume(returning: $0) }
            }
            guard quit, self.storeURL == store else { return self.snapshots.endRestoring() }
            let quitHolders =
                self.quitHolders ?? { holders, store in
                    try await StoreHolders.quit(holders, of: location, store: store, devicesDirectory: devices)
                }
            do {
                try await quitHolders(holders, store)
            } catch {
                return self.snapshots.endRestoring(error)
            }
            guard self.storeURL == store else { return self.snapshots.endRestoring() }
            self.replaceStore(with: snapshot)
        }
    }

    /// Closes the store, restores the snapshot over it, and opens what is there then — the snapshot, or the store
    /// as it was if the restore did not happen.
    private func replaceStore(with snapshot: SnapshotManifest) {
        guard let store = storeURL, let library = snapshots.library else { return snapshots.endRestoring() }
        let backupName = String(
            localized: "Before restoring “\(snapshot.name)”",
            comment: "Name of the backup taken before a snapshot is restored; the argument is the snapshot's name")
        openStore { [snapshots] in
            do {
                try await Restorer.restore(
                    snapshot, from: library, over: store, backingUpInto: library, backupName: backupName)
                snapshots.endRestoring()
            } catch {
                snapshots.endRestoring(error)
            }
        }
    }

    func toggleAccessMode() {
        setAccessMode(accessMode == .editable ? .readOnly : .editable)
    }

    func setTimeZone(_ choice: TimeZoneChoice) {
        guard project.display.timeZone != choice else { return }
        package.project.display.timeZone = choice
        onChange?(.project)
    }

    /// The first entity that has rows of its own to show, by name — what the sidebar has at its top.
    static func firstEntity(of model: ModelDescription) -> String? {
        let names = model.entities.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
        return (names.first { !$0.isAbstract } ?? names.first)?.name
    }
}

/// What to do with staged edits before something that would lose them.
enum LeavingChanges {
    case commit, discard, cancel
}
