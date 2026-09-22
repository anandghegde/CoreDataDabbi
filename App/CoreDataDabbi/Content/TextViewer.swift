import AppKit
import SwiftUI

/// A read-only monospaced text view (CNT-1).
///
/// `NSTextView` rather than `Text`: a field can hold megabytes of JSON, and this is the only thing in the
/// toolbox that lays that out lazily — and it brings selection, Find and copy along.
struct TextViewer: NSViewRepresentable {
    var text: String
    var isMonospaced = true

    /// Beyond this the viewer shows a prefix and says so: TextKit will lay out more, but not quickly.
    static let maximumCharacters = 4 * 1024 * 1024

    func makeNSView(context: Context) -> NSScrollView {
        let scrollView = NSTextView.scrollableTextView()
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.drawsBackground = false
        guard let textView = scrollView.documentView as? NSTextView else { return scrollView }
        textView.isEditable = false
        textView.isSelectable = true
        textView.isRichText = false
        textView.drawsBackground = false
        textView.textContainerInset = NSSize(width: 8, height: 8)
        textView.isHorizontallyResizable = true
        textView.textContainer?.widthTracksTextView = false
        textView.textContainer?.containerSize = NSSize(
            width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        textView.setAccessibilityLabel(String(localized: "Field content"))
        apply(to: textView)
        return scrollView
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        guard let textView = scrollView.documentView as? NSTextView else { return }
        apply(to: textView)
    }

    private func apply(to textView: NSTextView) {
        let shown =
            text.count > Self.maximumCharacters
            ? String(text.prefix(Self.maximumCharacters))
                + "\n\n"
                + String(localized: "… \(text.count - Self.maximumCharacters) more characters not shown.")
            : text
        guard textView.string != shown else { return }
        textView.string = shown
        textView.font =
            isMonospaced
            ? .monospacedSystemFont(ofSize: NSFont.systemFontSize, weight: .regular)
            : .systemFont(ofSize: NSFont.systemFontSize)
        textView.textColor = .textColor
        textView.sizeToFit()
        textView.scroll(.zero)
    }
}

/// Rich text a field turned out to hold — RTF, an attributed string out of an archive (CNT-4).
struct AttributedViewer: View {
    var text: AttributedString

    var body: some View {
        ScrollView([.vertical, .horizontal]) {
            Text(text)
                .textSelection(.enabled)
                .padding(10)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}
