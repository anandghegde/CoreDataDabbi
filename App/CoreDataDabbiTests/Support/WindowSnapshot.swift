import AppKit

/// Renders a window — title bar and toolbar included — to a PNG, for a person to look at.
///
/// Nothing is compared: these are not reference images, they are how a change to the UI gets seen without
/// driving the app by hand. `DABBI_SNAPSHOT_DIR` says where they go (`TEST_RUNNER_DABBI_SNAPSHOT_DIR` on
/// xcodebuild's side); without it nothing is written.
///
/// The window's layer tree is what gets drawn, not `cacheDisplay(in:to:)`: every view in a window is
/// layer-backed nowadays, and what SwiftUI and the visual effect views put in their layers never reaches a
/// view's `draw(_:)`. Materials still come out flat — the render server blurs what is behind the window, and
/// there is nothing behind this one — and a scroll view is drawn back in by hand afterwards, which is what
/// `drawScrolledContent` is for.
///
/// What a scroll view keeps in its edge pocket is lost with the blur: a bar put there by `safeAreaInset`, a
/// pinned section header. The pocket shows them through a portal layer, and a portal has no contents of its
/// own to draw. They are on screen in the running app; only these pictures are missing them.
@MainActor
enum WindowSnapshot {
    static var directory: URL? {
        ProcessInfo.processInfo.environment["DABBI_SNAPSHOT_DIR"].map { URL(fileURLWithPath: $0, isDirectory: true) }
    }

    @discardableResult
    static func write(
        _ window: NSWindow, named name: String, appearance: NSAppearance.Name = .aqua
    ) async throws -> URL? {
        guard let directory, let frame = window.contentView?.superview else { return nil }
        window.appearance = NSAppearance(named: appearance)
        window.layoutIfNeeded()
        frame.layoutSubtreeIfNeeded()
        frame.displayIfNeeded()
        // Layer contents are drawn a turn or two later, SwiftUI's above all.
        try await Task.sleep(for: .milliseconds(200))

        // Drawing a layer off-screen resolves dynamic colours against whatever appearance is current, not the
        // window's: without this the dark window comes out with light control backgrounds.
        // A scroll view reaches under the title bar and the toolbar, which are drawn over it: redrawing it has
        // to stop where they begin, or it paints them out.
        let usable = window.contentView.map { $0.convert(window.contentLayoutRect, to: frame) } ?? frame.bounds
        var rendered: Data?
        window.effectiveAppearance.performAsCurrentDrawingAppearance {
            rendered = png(
                of: frame, background: window.backgroundColor, within: usable, scale: window.backingScaleFactor)
        }
        guard let png = rendered else { return nil }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appendingPathComponent("\(name).png")
        try png.write(to: url)
        return url
    }

    private static func png(of view: NSView, background: NSColor, within usable: CGRect, scale: CGFloat) -> Data? {
        let bounds = view.bounds
        guard let layer = view.layer, bounds.width > 0, bounds.height > 0,
            let context = CGContext(
                data: nil, width: Int(bounds.width * scale), height: Int(bounds.height * scale),
                bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue)
        else { return nil }
        context.scaleBy(x: scale, y: scale)
        layer.render(in: context)
        drawScrolledContent(under: view, into: context, root: layer, background: background, within: usable)
        guard let image = context.makeImage() else { return nil }
        return NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:])
    }

    /// Puts back what a scroll view loses. A scroll view's edge effect is drawn with backdrop and portal
    /// layers, which are the render server's to resolve; `render(in:)` knows nothing of either and leaves the
    /// whole scroll view blank, rows and all. What it scrolls is an ordinary layer subtree underneath, so it
    /// is drawn again over the hole, clipped to what the scroll view actually shows.
    private static func drawScrolledContent(
        under view: NSView, into context: CGContext, root: CALayer, background: NSColor, within usable: CGRect
    ) {
        for scroll in scrollViews(under: view) {
            guard let documentView = scroll.documentView, let document = documentView.layer,
                let clip = scroll.contentView.layer
            else { continue }
            // The title bar and the toolbar are drawn over the scroll view, and correctly: what is under them
            // stays as the window's own rendering left it.
            let shown = clip.convert(clip.bounds, to: root).intersection(usable)
            guard !shown.isNull, !shown.isEmpty else { continue }
            context.saveGState()
            context.clip(to: shown)
            // What the scroll view shows is a hole in the rendering, down to nothing at all: the window's
            // background goes back in it, and then the scroll view's own, if it has one.
            context.setFillColor(background.cgColor)
            context.fill(shown)
            if scroll.drawsBackground {
                context.setFillColor(scroll.backgroundColor.cgColor)
                context.fill(shown)
            }
            let placed = document.convert(document.bounds, to: root)
            // A scroll view's document is flipped — first row at the top — and the window's layer is not, so
            // the rows come out upside down unless the axis is turned over with them.
            if documentView.isFlipped {
                context.translateBy(x: placed.minX, y: placed.maxY)
                context.scaleBy(x: 1, y: -1)
            } else {
                context.translateBy(x: placed.minX, y: placed.minY)
            }
            document.render(in: context)
            context.restoreGState()
        }
    }

    private static func scrollViews(under view: NSView) -> [NSScrollView] {
        var found: [NSScrollView] = []
        for subview in view.subviews {
            if let scroll = subview as? NSScrollView { found.append(scroll) }
            found += scrollViews(under: subview)
        }
        return found
    }
}
