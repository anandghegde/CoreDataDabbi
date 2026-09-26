import AppKit

/// The grid's table: an `NSTableView` that also answers Return, which a view-based table otherwise ignores.
///
/// Return opens the editor over the selected row's cell, as a double-click does (EDT-3): the keyboard's way into
/// it (§8.4). When there is nothing to edit — a locked store, a row not read yet — the key goes on as usual.
final class GridTableView: NSTableView {
    /// Says whether it did something with the key.
    var onReturn: (() -> Bool)?

    override func keyDown(with event: NSEvent) {
        let isReturn = event.keyCode == Self.returnKey || event.keyCode == Self.enterKey
        let modifiers = event.modifierFlags.intersection(.deviceIndependentFlagsMask).subtracting([
            .numericPad, .function,
        ])
        if isReturn, modifiers.isEmpty, onReturn?() == true { return }
        super.keyDown(with: event)
    }

    private static let returnKey: UInt16 = 36
    private static let enterKey: UInt16 = 76
}
