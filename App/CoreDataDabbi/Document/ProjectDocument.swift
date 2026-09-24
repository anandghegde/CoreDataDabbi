import AppKit
import DabbiKit

/// A `.dabbi` project as a document: reads and writes the package, and owns the project's context (PRJ-1).
///
/// Autosave in place, Versions, tabs and Rename/Move To come with `NSDocument`. There is no undo yet: nothing a
/// viewer does to a project is worth undoing, and edits to the store (M3) get an undo manager of their own.
final class ProjectDocument: NSDocument {
    let context = ProjectContext()

    /// The package as it was read, so that writing leaves alone what this version of the app does not know
    /// about, and does not rewrite what has not changed.
    ///
    /// `nonisolated(unsafe)`: written by `read`, which AppKit declares nonisolated but calls on the main
    /// thread as long as `canConcurrentlyReadDocuments` says no.
    private nonisolated(unsafe) var packageWrapper: FileWrapper?

    override init() {
        super.init()
        hasUndoManager = false
        context.onChange = { [weak self] change in
            // An untitled project is a look at a store. Nothing that can be done to it so far is worth the
            // question "do you want to keep this document?" — it is kept when the user saves it, as it is then.
            // A saved one autosaves in place, layout included, without asking either.
            guard let self, self.fileURL != nil else { return }
            self.updateChangeCount(change == .project ? .changeDone : .changeDiscardable)
        }
    }

    override class var autosavesInPlace: Bool { true }

    override class func canConcurrentlyReadDocuments(ofType typeName: String) -> Bool { false }

    // MARK: Reading and writing

    override nonisolated func read(from fileWrapper: FileWrapper, ofType typeName: String) throws {
        let package = try ProjectPackage.read(from: fileWrapper)
        packageWrapper = fileWrapper
        MainActor.assumeIsolated { context.replace(package) }
    }

    override func fileWrapper(ofType typeName: String) throws -> FileWrapper {
        var package = context.package
        package.local.pruneBookmarks(keeping: package.project)
        let wrapper = try package.fileWrapper(updating: packageWrapper)
        if package.project.localStatePlacement == .applicationSupport {
            try package.writeExternalLocalState()
        }
        packageWrapper = wrapper
        return wrapper
    }

    // MARK: Windows

    override func makeWindowControllers() {
        addWindowController(ProjectWindowController(context: context))
        context.openStoreIfNeeded()
    }

    /// Staged edits are not the document's, so `NSDocument` does not know to ask about them: the window asks
    /// whether to commit or discard them before it closes, or the app quits (EDT-8).
    override func canClose(
        withDelegate delegate: Any, shouldClose shouldCloseSelector: Selector?, contextInfo: UnsafeMutableRawPointer?
    ) {
        guard context.editing.hasChanges else {
            super.canClose(withDelegate: delegate, shouldClose: shouldCloseSelector, contextInfo: contextInfo)
            return
        }
        let delegate = delegate as AnyObject
        context.leaveChanges(
            { [weak self] in
                self?.canCloseAfterChanges(delegate: delegate, selector: shouldCloseSelector, contextInfo: contextInfo)
            },
            cancelled: { [weak self] in
                guard let self, let shouldCloseSelector else { return }
                Self.answer(delegate, shouldCloseSelector, self, false, contextInfo)
            })
    }

    private func canCloseAfterChanges(delegate: AnyObject, selector: Selector?, contextInfo: UnsafeMutableRawPointer?) {
        super.canClose(withDelegate: delegate, shouldClose: selector, contextInfo: contextInfo)
    }

    /// `document:shouldClose:contextInfo:`, the old-fashioned way AppKit asks for it.
    private static func answer(
        _ delegate: AnyObject, _ selector: Selector, _ document: NSDocument, _ shouldClose: Bool,
        _ contextInfo: UnsafeMutableRawPointer?
    ) {
        typealias Callback = @convention(c) (AnyObject, Selector, NSDocument, Bool, UnsafeMutableRawPointer?) -> Void
        guard let method = delegate.method(for: selector) else { return }
        unsafeBitCast(method, to: Callback.self)(delegate, selector, document, shouldClose, contextInfo)
    }

    override func close() {
        context.shutDown()
        super.close()
    }

    // MARK: Names

    /// An untitled project is known by its store.
    override var displayName: String! {
        get { fileURL == nil ? (context.project.store?.fileName ?? super.displayName) : super.displayName }
        set { super.displayName = newValue }
    }

    override func defaultDraftName() -> String {
        guard let name = context.project.store?.fileName else { return super.defaultDraftName() }
        return (name as NSString).deletingPathExtension
    }
}
