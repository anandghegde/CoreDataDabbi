import AppKit
import DabbiKit

/// The colours and glyphs of the change log (TRK-1, §8.4).
///
/// Created is green, updated purple, deleted red — and none of it is told by colour alone: every row carries the
/// glyph `+`, `✎` or `−` and the word beside it, so the log reads the same to someone who cannot tell the three
/// apart, in print, and out loud.
///
/// The three are given explicitly for each appearance rather than taken from `NSColor.system*`, whose light
/// variants are tuned for filled controls and fall under 4.5:1 as text on white. These sit at or above it in
/// both appearances, which is what §8.4 asks of anything that carries meaning.
///
/// TRK-4 will let the user choose them; until it does, this is the one place they are written down.
@MainActor
enum TrackingAppearance {
    static func colour(for kind: ChangeEvent.Kind) -> NSColor {
        switch kind {
        case .inserted:
            dynamic(
                light: NSColor(srgbRed: 0.07, green: 0.42, blue: 0.21, alpha: 1),
                dark: NSColor(srgbRed: 0.45, green: 0.86, blue: 0.55, alpha: 1))
        case .updated:
            dynamic(
                light: NSColor(srgbRed: 0.40, green: 0.19, blue: 0.66, alpha: 1),
                dark: NSColor(srgbRed: 0.78, green: 0.63, blue: 0.99, alpha: 1))
        case .deleted:
            dynamic(
                light: NSColor(srgbRed: 0.67, green: 0.12, blue: 0.13, alpha: 1),
                dark: NSColor(srgbRed: 1.00, green: 0.55, blue: 0.52, alpha: 1))
        }
    }

    /// The wash behind a row. Faint on purpose: it is a hint beside the glyph, never the thing that says what
    /// happened, and it has to stay out of the way of the values printed on it.
    static func rowTint(for kind: ChangeEvent.Kind) -> NSColor {
        colour(for: kind).withAlphaComponent(isDark ? 0.16 : 0.09)
    }

    /// The glyph, in a font that keeps `+`, `✎` and `−` the same width so the column does not jitter.
    static let glyphFont = NSFont.monospacedSystemFont(ofSize: NSFont.systemFontSize, weight: .semibold)

    private static var isDark: Bool {
        NSApp.effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
    }

    private static func dynamic(light: NSColor, dark: NSColor) -> NSColor {
        NSColor(name: nil) { appearance in
            appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua ? dark : light
        }
    }
}
