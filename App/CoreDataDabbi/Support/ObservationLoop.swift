import Observation

/// Runs `apply` now, and again after any `@Observable` value it read has changed — what SwiftUI does for its
/// views, for AppKit ones.
///
/// `apply` is kept for as long as the loop is; capture the view weakly. Changes made within one turn of the main
/// run loop lead to one call, not one each.
@MainActor
final class ObservationLoop {
    private var apply: (@MainActor () -> Void)?

    init(_ apply: @escaping @MainActor () -> Void) {
        self.apply = apply
        run()
    }

    func cancel() { apply = nil }

    private func run() {
        guard let apply else { return }
        withObservationTracking {
            apply()
        } onChange: { [weak self] in
            // `onChange` is called before the value changes, and from wherever it is changed.
            Task { @MainActor in self?.run() }
        }
    }
}
