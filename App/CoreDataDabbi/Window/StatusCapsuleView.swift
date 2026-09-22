import AppKit

/// The capsule in the middle of the toolbar (PRD §8.1): the store, the model it is read with, the access mode —
/// and, when it applies, that what is shown is a copy. A click opens the path menu.
final class StatusCapsuleView: NSView {
    var status = StoreStatus() {
        didSet { if status != oldValue { update() } }
    }
    var onReload: (() -> Void)?

    private let icon = NSImageView()
    private let title = NSTextField(labelWithString: "")
    private let details = NSTextField(labelWithString: "")
    private let badge = PillLabel()
    private let spinner = NSProgressIndicator()

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true

        icon.imageScaling = .scaleProportionallyDown
        icon.symbolConfiguration = NSImage.SymbolConfiguration(pointSize: 13, weight: .medium)
        title.font = .systemFont(ofSize: NSFont.systemFontSize, weight: .medium)
        title.lineBreakMode = .byTruncatingMiddle
        details.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        details.textColor = .secondaryLabelColor
        details.lineBreakMode = .byTruncatingTail
        spinner.style = .spinning
        spinner.controlSize = .small
        spinner.isDisplayedWhenStopped = false

        let stack = NSStackView(views: [icon, spinner, title, details, badge])
        stack.orientation = .horizontal
        stack.alignment = .centerY
        stack.spacing = 6
        stack.setCustomSpacing(8, after: title)
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)

        // The name gives way last, the details first.
        title.setContentCompressionResistancePriority(.defaultHigh, for: .horizontal)
        details.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        badge.setContentCompressionResistancePriority(.required, for: .horizontal)
        for view in [icon, title, details, badge] { view.setContentHuggingPriority(.required, for: .horizontal) }

        translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            heightAnchor.constraint(equalToConstant: 28),
            widthAnchor.constraint(greaterThanOrEqualToConstant: 220),
            widthAnchor.constraint(lessThanOrEqualToConstant: 620),
            stack.centerXAnchor.constraint(equalTo: centerXAnchor),
            stack.centerYAnchor.constraint(equalTo: centerYAnchor),
            stack.leadingAnchor.constraint(greaterThanOrEqualTo: leadingAnchor, constant: 12),
            stack.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -12),
            icon.widthAnchor.constraint(equalToConstant: 16),
        ])

        setAccessibilityElement(true)
        setAccessibilityRole(.menuButton)
        setAccessibilityLabel(String(localized: "Store"))
        update()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("not in a nib") }

    // MARK: Appearance

    override var wantsUpdateLayer: Bool { true }

    override func updateLayer() {
        layer?.cornerRadius = bounds.height / 2
        layer?.cornerCurve = .continuous
        layer?.backgroundColor = NSColor.quaternarySystemFill.cgColor
    }

    override func layout() {
        super.layout()
        needsDisplay = true
    }

    private func update() {
        let symbol: String
        switch status.phase {
        case .none: symbol = "cylinder.split.1x2"
        case .opening: symbol = "cylinder.split.1x2"
        case .open: symbol = status.workingCopyDate == nil ? "cylinder.split.1x2.fill" : "doc.on.doc.fill"
        case .failed: symbol = "exclamationmark.triangle.fill"
        }
        icon.image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)
        icon.contentTintColor = status.phase == .failed ? .systemYellow : .secondaryLabelColor
        icon.isHidden = status.phase == .opening
        if status.phase == .opening { spinner.startAnimation(nil) } else { spinner.stopAnimation(nil) }

        title.stringValue = status.title
        details.stringValue = status.line.joined(separator: " · ")
        details.isHidden = status.line.isEmpty
        badge.isHidden = status.workingCopyDate == nil
        badge.text = String(localized: "Working Copy")

        var spoken = [status.title] + status.line
        var tip = status.storeURL?.path ?? ""
        if let date = status.workingCopyDate {
            let made = String(localized: "Reading a copy made at \(date.formatted(date: .omitted, time: .standard)).")
            spoken.append(made)
            tip += "\n" + made
        }
        if status.readsCachedModel {
            tip += "\n" + String(localized: "A cached model can lack the app's fetch request templates.")
        }
        setAccessibilityValue(spoken.joined(separator: ", "))
        toolTip = tip.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    // MARK: The path menu

    override func mouseDown(with event: NSEvent) {
        popUpMenu(with: event)
    }

    override func rightMouseDown(with event: NSEvent) {
        popUpMenu(with: event)
    }

    override func accessibilityPerformPress() -> Bool {
        makeMenu().popUp(positioning: nil, at: NSPoint(x: 0, y: bounds.maxY + 6), in: self)
        return true
    }

    private func popUpMenu(with event: NSEvent) {
        let menu = makeMenu()
        guard menu.numberOfItems > 0 else { return }
        menu.popUp(positioning: nil, at: NSPoint(x: bounds.midX - menu.size.width / 2, y: -6), in: self)
    }

    func makeMenu() -> NSMenu {
        let menu = NSMenu()
        menu.autoenablesItems = false

        // A simulator store's path is two UUIDs deep and says nothing; whose store it is belongs above it.
        if let origin = status.origin {
            menu.addItem(note(String(localized: "From \(origin)")))
            menu.addItem(.separator())
        }

        if let date = status.workingCopyDate {
            let made = date.formatted(date: .omitted, time: .standard)
            menu.addItem(note(String(localized: "Reading a copy of the store, made at \(made)")))
            menu.addItem(action(String(localized: "Copy Again"), #selector(reload(_:))))
            menu.addItem(.separator())
        }

        guard let url = status.storeURL else {
            return menu
        }
        // The file, then the folders it is in, as in a window's title menu.
        var ancestor = url
        var depth = 0
        while depth < 24 {
            let item = action(
                FileManager.default.displayName(atPath: ancestor.path), #selector(reveal(_:)), representing: ancestor)
            let image = NSWorkspace.shared.icon(forFile: ancestor.path)
            image.size = NSSize(width: 16, height: 16)
            item.image = image
            item.indentationLevel = 0
            menu.addItem(item)
            let parent = ancestor.deletingLastPathComponent()
            if parent.path == ancestor.path { break }
            ancestor = parent
            depth += 1
        }
        menu.addItem(.separator())
        menu.addItem(action(String(localized: "Show in Finder"), #selector(reveal(_:)), representing: url))
        menu.addItem(action(String(localized: "Copy Path"), #selector(copyPath(_:)), representing: url))
        if status.readsCachedModel {
            menu.addItem(.separator())
            menu.addItem(note(String(localized: "Read with the model cached in the store.")))
            menu.addItem(note(String(localized: "A cached model can lack the app's fetch request templates.")))
        }
        return menu
    }

    private func note(_ title: String) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        item.isEnabled = false
        return item
    }

    private func action(_ title: String, _ selector: Selector, representing object: Any? = nil) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: selector, keyEquivalent: "")
        item.target = self
        item.representedObject = object
        return item
    }

    @objc private func reload(_ sender: NSMenuItem) { onReload?() }

    @objc private func reveal(_ sender: NSMenuItem) {
        guard let url = sender.representedObject as? URL else { return }
        NSWorkspace.shared.activateFileViewerSelecting([url])
    }

    @objc private func copyPath(_ sender: NSMenuItem) {
        guard let url = sender.representedObject as? URL else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(url.path, forType: .string)
    }
}

/// A word on a tinted pill: a state worth a second look, such as "Working Copy".
final class PillLabel: NSView {
    private let label = NSTextField(labelWithString: "")

    var text: String {
        get { label.stringValue }
        set { label.stringValue = newValue }
    }
    var tint = NSColor.systemOrange {
        didSet { needsDisplay = true }
    }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        label.font = .systemFont(ofSize: NSFont.smallSystemFontSize - 1, weight: .semibold)
        label.translatesAutoresizingMaskIntoConstraints = false
        addSubview(label)
        NSLayoutConstraint.activate([
            label.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 6),
            label.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -6),
            label.topAnchor.constraint(equalTo: topAnchor, constant: 1),
            label.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -2),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("not in a nib") }

    override var wantsUpdateLayer: Bool { true }

    override func updateLayer() {
        layer?.cornerRadius = bounds.height / 2
        layer?.backgroundColor = tint.withAlphaComponent(0.2).cgColor
        label.textColor = tint.blended(withFraction: 0.35, of: .labelColor) ?? tint
    }
}
