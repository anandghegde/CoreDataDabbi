import AppKit

extension NSViewController {
    /// The first controller of a kind below this one, depth-first. Saves the tests from knowing how the window
    /// nests its split views, which is the window's business and changes with the layout.
    @MainActor
    func firstDescendant<T: NSViewController>(of type: T.Type) -> T? {
        for child in children {
            if let found = child as? T { return found }
            if let found = child.firstDescendant(of: type) { return found }
        }
        return nil
    }
}

extension NSWindow {
    @MainActor
    func firstController<T: NSViewController>(of type: T.Type) -> T? {
        guard let root = contentViewController else { return nil }
        return root as? T ?? root.firstDescendant(of: type)
    }
}
