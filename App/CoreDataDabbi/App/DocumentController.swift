import AppKit
import DabbiKit

/// Opens projects — and stores, as projects that have not been saved yet (PRJ-3, PRJ-13).
///
/// A store is not a document of ours: it is never written through `NSDocument`. Opening one makes an untitled
/// project that points at it, which the user may save to keep the layout, or close without being asked anything.
final class DocumentController: NSDocumentController {
    /// The imported type every store is opened as, whatever its extension (Info.plist).
    static let storeTypeIdentifier = "org.coredatadabbi.sqlite-store"

    static var current: DocumentController? { NSDocumentController.shared as? DocumentController }

    // MARK: Opening

    /// Stores are called `Model.sqlite`, `default.store`, `data`, or whatever the developer liked (PRJ-15), and
    /// another app may have claimed the extension with a type of its own. Whatever is not a project is a store.
    override func typeForContents(of url: URL) throws -> String {
        url.pathExtension.lowercased() == ProjectPackage.fileExtension
            ? ProjectPackage.typeIdentifier : Self.storeTypeIdentifier
    }

    override func makeDocument(withContentsOf url: URL, ofType typeName: String) throws -> NSDocument {
        guard typeName != ProjectPackage.typeIdentifier else {
            return try super.makeDocument(withContentsOf: url, ofType: typeName)
        }
        let document = try ProjectDocument(type: ProjectPackage.typeIdentifier)
        document.context.adoptStore(at: url)
        return document
    }

    override func openDocument(
        withContentsOf url: URL, display displayDocument: Bool,
        completionHandler: @escaping (NSDocument?, Bool, (any Error)?) -> Void
    ) {
        let isProject = url.pathExtension.lowercased() == ProjectPackage.fileExtension
        // An untitled project has no URL to be found by, so a store that is open already is looked for here.
        if !isProject, let open = untitledProject(showing: .file(FileReference(lastKnownPath: url.path))) {
            if displayDocument { open.showWindows() }
            completionHandler(open, true, nil)
            return
        }
        super.openDocument(withContentsOf: url, display: displayDocument) { document, wasOpen, error in
            // Recents are noted by document URL, which an untitled project does not have.
            if !isProject, document != nil { self.noteNewRecentDocumentURL(url) }
            completionHandler(document, wasOpen, error)
        }
    }

    /// A new project for a store found by identity rather than by path — a simulator app's (PRJ-8).
    @discardableResult
    func openProject(for location: StoreLocation) throws -> ProjectDocument {
        if let open = untitledProject(showing: location) {
            open.showWindows()
            return open
        }
        let document = try ProjectDocument(type: ProjectPackage.typeIdentifier)
        document.context.adopt(location)
        addDocument(document)
        document.makeWindowControllers()
        document.showWindows()
        return document
    }

    /// Anything open at all is more use than the welcome window (PRJ-16).
    override func addDocument(_ document: NSDocument) {
        super.addDocument(document)
        WelcomeWindowController.closeIfOpen()
    }

    private func untitledProject(showing location: StoreLocation) -> ProjectDocument? {
        documents.lazy.compactMap { $0 as? ProjectDocument }.first { document in
            document.fileURL == nil && document.context.shows(location)
        }
    }

    // MARK: Actions

    /// Any file may be a store, so the panel does not filter — which is all that sets it apart from Open….
    @IBAction func openDatabase(_ sender: Any?) {
        let panel = NSOpenPanel()
        panel.message = String(localized: "Choose a Core Data or SwiftData store.")
        panel.prompt = String(localized: "Open")
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = false
        // Stores sit inside document packages and app bundles too.
        panel.treatsFilePackagesAsDirectories = true
        panel.showsHiddenFiles = true
        panel.begin { response in
            guard response == .OK else { return }
            for url in panel.urls {
                self.openDocument(withContentsOf: url, display: true) { _, _, error in
                    if let error { self.presentError(error) }
                }
            }
        }
    }

    @IBAction func browseSimulators(_ sender: Any?) {
        SimulatorBrowserWindowController.shared.showWindow(sender)
    }

    @IBAction func showWelcomeWindow(_ sender: Any?) {
        WelcomeWindowController.show()
    }
}
