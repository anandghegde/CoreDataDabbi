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
    /// The property the content viewer reads, within the inspected object (CNT-1). Looking at another column is
    /// not somewhere to go back to, so unlike the entity and the row it is not part of the history.
    private(set) var focusedProperty: String?
    /// The entity `focusedProperty` belongs to. Moving down a column keeps reading it; another entity has other
    /// columns, and the one being read is gone with it.
    @ObservationIgnored private var focusedPropertyEntity: String?
    /// The object the inspector and the content viewer read: the grid's selection, or — while one is picked in
    /// the relationships panel — a related object the grid is not showing (REL-1).
    private(set) var inspectedObject: ObjectRef?
    /// Whose store this is, for the status capsule: `nil` for a store picked as a file, whose path says it.
    private(set) var locationOrigin: String?

    @ObservationIgnored var onChange: ((Change) -> Void)?
    /// Where simulators are looked for; the tests have a device set of their own.
    @ObservationIgnored var devicesDirectory: URL?
    @ObservationIgnored var workingCopiesDirectory: URL?
    /// Who knows which simulators this Mac has, for naming the device a store belongs to. The app's one index,
    /// so that a browser already open has answered this before it is asked.
    @ObservationIgnored var simulators: (any SimulatorBrowsing)? = Simulators.index

    @ObservationIgnored private var openTask: Task<Void, Never>?
    @ObservationIgnored private var countsTask: Task<Void, Never>?
    @ObservationIgnored private var originTask: Task<Void, Never>?
    @ObservationIgnored private var attempt = 0
    /// The entity tracking was on when the store was reopened, so it can be picked up again on the new session.
    @ObservationIgnored private var resumeTracking: String?

    init(package: ProjectPackage = ProjectPackage()) {
        self.package = package
        // The file being watched was replaced, so the open session reads something that is gone: reopen, and
        // start tracking again on what is there now (Appendix D).
        tracking.onStoreReplaced = { [weak self] in self?.openStore() }
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
    var model: ModelDescription? { session?.info.model }
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
        adoptStore(at: url)
        onChange?(.project)
        openStore()
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
        inspect(object)
        guard navigation.current?.focus != object else { return }
        navigation.amend { $0.focus = object }
    }

    /// A related object was picked in the relationships panel: the inspector and the content viewer follow it,
    /// and the grid stays where it is (REL-1). Revealing it is a separate, deliberate step.
    func inspect(_ object: ObjectRef?) {
        guard inspectedObject != object else { return }
        // Another entity's object has other properties; the one that was being read is not among them. Losing
        // the selection altogether is not the same thing: the next row brings the same column back.
        if let entity = object?.entity, entity != focusedPropertyEntity { forgetProperty() }
        inspectedObject = object
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
        inspect(navigation.current?.focus)
        updateSelection { $0.entity = navigation.current?.entity }
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
    func openStore() {
        hasStarted = true
        openTask?.cancel()
        attempt += 1
        let attempt = attempt
        let previous = openedStore
        entityCounts = [:]
        // Keys, prior values and materialised objects all belong to the session that is about to close.
        resumeTracking = tracking.isRunning ? tracking.entity : nil
        tracking.close()

        guard let location = project.store else {
            storeState = .none
            locationOrigin = nil
            inspect(nil)
            if let previous { Task { await previous.close() } }
            return
        }
        storeState = .opening
        describeOrigin(of: location)

        // Bookmarks are this machine's; the resolver gets a copy of them as they are now.
        let local = package.local
        let opener = StoreOpener(
            resolver: StoreLocationResolver(devicesDirectory: devicesDirectory) { local.resolve($0)?.url },
            workingCopiesDirectory: workingCopiesDirectory)
        let model = project.model

        openTask = Task { [weak self] in
            await previous?.close()
            let result: Result<OpenedStore, DabbiError>
            do {
                result = .success(try await opener.open(location, model: model))
            } catch let error as DabbiError {
                result = .failure(error)
            } catch {
                result = .failure(DabbiError(.internal, "The store could not be opened.", underlying: error))
            }
            guard let self, self.attempt == attempt else {
                // Closed or pointed elsewhere in the meantime.
                if case .success(let store) = result { await store.close() }
                return
            }
            self.finishOpening(result)
        }
    }

    private func finishOpening(_ result: Result<OpenedStore, DabbiError>) {
        switch result {
        case .failure(let error):
            storeState = .failed(error)
            inspect(nil)
        case .success(let store):
            storeState = .open(store)
            refreshReference(to: store.storeURL)
            let model = store.session.info.model
            // Reloading keeps the place; another store, or a first opening, starts where the project was left.
            if navigation.current.flatMap({ model.entity(named: $0.entity) }) == nil {
                let remembered = local.selection.entity.flatMap(model.entity(named:))?.name
                navigation.reset(to: (remembered ?? Self.firstEntity(of: model)).map { BrowseLocation(entity: $0) })
            }
            // A related object picked before the reload belongs to the session that has just gone.
            inspect(navigation.current?.focus)
            loadCounts(of: store.session)
            if let entity = resumeTracking, model.entity(named: entity) != nil {
                tracking.start(on: store.session, entity: entity, filter: layout(of: entity).filter)
            }
            resumeTracking = nil
        }
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
        await openTask?.value
        await countsTask?.value
        await originTask?.value
        await tracking.whenStarted()
    }

    /// The document is closing.
    func shutDown() {
        tracking.close()
        openTask?.cancel()
        originTask?.cancel()
        attempt += 1
        let store = openedStore
        storeState = .none
        if let store { Task { await store.close() } }
    }

    /// The first entity that has rows of its own to show, by name — what the sidebar has at its top.
    static func firstEntity(of model: ModelDescription) -> String? {
        let names = model.entities.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
        return (names.first { !$0.isAbstract } ?? names.first)?.name
    }
}
