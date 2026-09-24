import AppKit
import DabbiKit

/// One cell of the grid. A label, and the three ways a label can mean something else (BRW-3).
@MainActor
final class GridCellView: NSTableCellView {
    private let label = NSTextField(labelWithString: "")
    /// Shown when the staged value breaks a rule of the model (EDT-2): a symbol, not only a colour.
    private let badge = NSImageView()
    private var labelTrailing: NSLayoutConstraint?

    init() {
        super.init(frame: .zero)
        identifier = .gridCell
        label.lineBreakMode = .byTruncatingTail
        label.font = .systemFont(ofSize: NSFont.systemFontSize)
        label.translatesAutoresizingMaskIntoConstraints = false
        label.cell?.usesSingleLineMode = true
        addSubview(label)
        textField = label

        badge.image = NSImage(systemSymbolName: "exclamationmark.triangle.fill", accessibilityDescription: nil)
        badge.contentTintColor = .systemRed
        badge.translatesAutoresizingMaskIntoConstraints = false
        badge.isHidden = true
        badge.setAccessibilityElement(false)
        addSubview(badge)

        let trailing = label.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -2)
        labelTrailing = trailing
        NSLayoutConstraint.activate([
            label.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 2),
            trailing,
            label.centerYAnchor.constraint(equalTo: centerYAnchor),
            badge.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -2),
            badge.centerYAnchor.constraint(equalTo: centerYAnchor),
            badge.widthAnchor.constraint(equalToConstant: Self.badgeWidth),
            badge.heightAnchor.constraint(equalToConstant: Self.badgeWidth),
        ])
    }

    private static let badgeWidth: CGFloat = 13

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("not in a nib") }

    /// `column` is the column's title: what VoiceOver says before the value, since a cell out of its row says
    /// nothing about which field it holds (§8.4). `issue` is the rule of the model the staged value breaks, in
    /// words (EDT-2): the cell is marked, and the words are its tooltip and its accessibility help.
    func show(_ value: GridValue, trailing: Bool, column: String = "", issue: String? = nil) {
        label.alignment = trailing ? .right : .left
        switch value.emphasis {
        case .value:
            label.stringValue = value.text
            label.textColor = .labelColor
            label.font = .systemFont(ofSize: NSFont.systemFontSize)
        case .absent:
            // Italic and grey: "nil" the value can never be mistaken for "nil" the string.
            label.stringValue = value.text
            label.textColor = .tertiaryLabelColor
            label.font = .italicSystemFont(ofSize: NSFont.systemFontSize)
        case .reference:
            // A link's colour, not the accent: it is the one AppKit keeps legible against text in both
            // appearances, and it is what a thing to follow looks like everywhere else on the Mac.
            let font = NSFont.systemFont(ofSize: NSFont.systemFontSize)
            label.font = font
            label.attributedStringValue = Self.reference(value.text, font: font)
        }
        badge.isHidden = issue == nil
        labelTrailing?.constant = issue == nil ? -2 : -(4 + Self.badgeWidth)
        let tips = [issue, value.tooltip].compactMap { $0 }
        toolTip = tips.isEmpty ? nil : tips.joined(separator: "\n")
        // The cell is the element VoiceOver lands on; the label inside it has nothing to add.
        label.setAccessibilityElement(false)
        setAccessibilityElement(true)
        setAccessibilityRole(.staticText)
        setAccessibilityLabel(column.isEmpty ? nil : column)
        setAccessibilityValue(value.accessibleText)
        setAccessibilityHelp(issue)
    }

    /// Whether the cell is marked as breaking a rule. For the tests.
    var showsIssue: Bool { !badge.isHidden }

    /// Underlines what can be followed when colour is not to be relied on (§8.4, Differentiate Without Color).
    private static func reference(_ text: String, font: NSFont) -> NSAttributedString {
        var attributes: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: NSColor.linkColor]
        if NSWorkspace.shared.accessibilityDisplayShouldDifferentiateWithoutColor {
            attributes[.underlineStyle] = NSUnderlineStyle.single.rawValue
        }
        return NSAttributedString(string: text, attributes: attributes)
    }
}

extension NSFont {
    fileprivate static func italicSystemFont(ofSize size: CGFloat) -> NSFont {
        let font = NSFont.systemFont(ofSize: size)
        return NSFontManager.shared.convert(font, toHaveTrait: .italicFontMask)
    }
}

/// The bar under the grid: how many rows there are, and the way to ask for more (BRW-11).
@MainActor
final class GridFooterView: NSView {
    enum State: Equatable {
        case empty
        case loading
        case rows(count: Int, hasMore: Bool)
        case failed(DabbiError)
    }

    var onLoadMore: (() -> Void)?

    private let label = NSTextField(labelWithString: "")
    private let spinner = NSProgressIndicator()
    private let loadMore = NSButton(title: "", target: nil, action: nil)

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        label.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        label.textColor = .secondaryLabelColor
        label.lineBreakMode = .byTruncatingTail

        spinner.style = .spinning
        spinner.controlSize = .small
        spinner.isDisplayedWhenStopped = false

        loadMore.title = String(localized: "Load More")
        loadMore.bezelStyle = .accessoryBarAction
        loadMore.controlSize = .small
        loadMore.target = self
        loadMore.action = #selector(loadMoreClicked)
        loadMore.isHidden = true

        let stack = NSStackView(views: [spinner, label, NSView(), loadMore])
        stack.spacing = 8
        stack.alignment = .centerY
        stack.edgeInsets = NSEdgeInsets(top: 4, left: 10, bottom: 4, right: 10)
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)

        let separator = NSBox()
        separator.boxType = .separator
        separator.translatesAutoresizingMaskIntoConstraints = false
        addSubview(separator)

        NSLayoutConstraint.activate([
            separator.topAnchor.constraint(equalTo: topAnchor),
            separator.leadingAnchor.constraint(equalTo: leadingAnchor),
            separator.trailingAnchor.constraint(equalTo: trailingAnchor),
            stack.topAnchor.constraint(equalTo: separator.bottomAnchor),
            stack.leadingAnchor.constraint(equalTo: leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("not in a nib") }

    @objc private func loadMoreClicked() {
        onLoadMore?()
    }

    private(set) var state: State = .empty

    func show(_ state: State) {
        self.state = state
        switch state {
        case .empty:
            spinner.stopAnimation(nil)
            label.stringValue = ""
            loadMore.isHidden = true
        case .loading:
            spinner.startAnimation(nil)
            label.stringValue = String(localized: "Reading…")
            loadMore.isHidden = true
        case .rows(let count, let hasMore):
            spinner.stopAnimation(nil)
            label.stringValue =
                hasMore
                ? String(localized: "First \(count) rows", comment: "Row count cut short by the fetch limit")
                : String(localized: "\(count) rows")
            label.textColor = .secondaryLabelColor
            loadMore.isHidden = !hasMore
        case .failed(let error):
            spinner.stopAnimation(nil)
            label.stringValue = error.errorDescription ?? String(localized: "The rows could not be read.")
            label.textColor = .systemRed
            loadMore.isHidden = true
        }
    }
}
