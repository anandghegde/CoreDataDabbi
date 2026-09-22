import AppKit
import DabbiKit

/// The *Change* cell: the glyph, the word, which side of the filter the row crossed, and the triangle that folds
/// an object's earlier versions away (TRK-1, TRK-2, TRK-7, TRK-9).
@MainActor
final class TrackingBadgeCellView: NSTableCellView {
    /// The triangle was clicked.
    var onFold: (() -> Void)?

    private let fold = NSButton()
    private let glyph = NSTextField(labelWithString: "")
    private let title = NSTextField(labelWithString: "")
    private let transition = NSTextField(labelWithString: "")
    private var indent: NSLayoutConstraint!

    init() {
        super.init(frame: .zero)
        identifier = .trackingBadgeCell

        fold.bezelStyle = .disclosure
        fold.setButtonType(.onOff)
        fold.title = ""
        fold.target = self
        fold.action = #selector(foldClicked)
        fold.translatesAutoresizingMaskIntoConstraints = false

        glyph.font = TrackingAppearance.glyphFont
        glyph.alignment = .center
        glyph.translatesAutoresizingMaskIntoConstraints = false

        for label in [title, transition] {
            label.font = .systemFont(ofSize: NSFont.systemFontSize)
            label.lineBreakMode = .byTruncatingTail
            label.cell?.usesSingleLineMode = true
            label.translatesAutoresizingMaskIntoConstraints = false
        }
        transition.textColor = .secondaryLabelColor
        transition.setContentCompressionResistancePriority(.defaultHigh, for: .horizontal)

        addSubview(fold)
        addSubview(glyph)
        addSubview(title)
        addSubview(transition)
        textField = title

        indent = fold.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 2)
        NSLayoutConstraint.activate([
            indent,
            fold.centerYAnchor.constraint(equalTo: centerYAnchor),
            fold.widthAnchor.constraint(equalToConstant: 13),
            glyph.leadingAnchor.constraint(equalTo: fold.trailingAnchor, constant: 3),
            glyph.centerYAnchor.constraint(equalTo: centerYAnchor),
            glyph.widthAnchor.constraint(equalToConstant: 14),
            title.leadingAnchor.constraint(equalTo: glyph.trailingAnchor, constant: 5),
            title.centerYAnchor.constraint(equalTo: centerYAnchor),
            transition.leadingAnchor.constraint(greaterThanOrEqualTo: title.trailingAnchor, constant: 6),
            transition.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -4),
            transition.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("not in a nib") }

    @objc private func foldClicked() {
        onFold?()
    }

    func show(_ badge: TrackingBadge) {
        // A version row is indented under the object it belongs to, so a column of them reads as one object's
        // history rather than as more objects.
        indent.constant = badge.isVersion ? 20 : 2
        fold.isHidden = !badge.canFold
        fold.state = badge.isExpanded ? .on : .off
        fold.setAccessibilityLabel(
            badge.isExpanded
                ? String(localized: "Hide earlier versions") : String(localized: "Show earlier versions"))

        let colour = TrackingAppearance.colour(for: badge.kind)
        glyph.stringValue = TrackingLog.glyph(for: badge.kind)
        glyph.textColor = colour
        title.stringValue = badge.title
        // The version rows say what happened in the colour; the object's own row is the object as it stands.
        title.textColor = badge.isVersion ? colour : .labelColor
        title.font =
            badge.isVersion
            ? .systemFont(ofSize: NSFont.systemFontSize)
            : .systemFont(ofSize: NSFont.systemFontSize, weight: .medium)

        if let crossing = badge.transition {
            transition.stringValue =
                "\(TrackingLog.glyph(for: crossing)) \(TrackingLog.word(for: crossing))"
            transition.isHidden = false
        } else {
            transition.stringValue = ""
            transition.isHidden = true
        }

        toolTip = badge.detail
        for label in [glyph, title, transition] { label.setAccessibilityElement(false) }
        setAccessibilityElement(true)
        setAccessibilityRole(.staticText)
        setAccessibilityLabel(String(localized: "Change"))
        setAccessibilityValue(badge.spoken)
    }
}

/// A value cell of the log: what the row reads in one column, drawn strong where the change touched it and
/// dimmed where it did not (TRK-2).
@MainActor
final class TrackingValueCellView: NSTableCellView {
    private let label = NSTextField(labelWithString: "")

    init() {
        super.init(frame: .zero)
        identifier = .trackingValueCell
        label.lineBreakMode = .byTruncatingTail
        label.cell?.usesSingleLineMode = true
        label.translatesAutoresizingMaskIntoConstraints = false
        addSubview(label)
        textField = label
        NSLayoutConstraint.activate([
            label.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 2),
            label.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -2),
            label.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("not in a nib") }

    func show(_ cell: TrackingCell, trailing: Bool, column: String) {
        label.alignment = trailing ? .right : .left
        label.stringValue = cell.value.text
        let size = NSFont.systemFontSize
        switch cell.weight {
        case .normal:
            label.font = .systemFont(ofSize: size)
            label.textColor = cell.value.emphasis == .absent ? .tertiaryLabelColor : .labelColor
        case .strong:
            // Weight, not colour: the colour of the row already says what happened to it, and a value that is
            // also coloured stops being a value.
            label.font = .systemFont(ofSize: size, weight: .semibold)
            label.textColor = .labelColor
        case .dim:
            label.font = .systemFont(ofSize: size)
            label.textColor = .tertiaryLabelColor
        }
        toolTip = cell.value.tooltip
        label.setAccessibilityElement(false)
        setAccessibilityElement(true)
        setAccessibilityRole(.staticText)
        setAccessibilityLabel(column)
        setAccessibilityValue(cell.spoken(column: column))
    }
}

/// A row of the log, washed with the colour of what happened to it (TRK-1).
@MainActor
final class TrackingRowView: NSTableRowView {
    var kind: ChangeEvent.Kind? {
        didSet { if kind != oldValue { needsDisplay = true } }
    }

    override func drawBackground(in dirtyRect: NSRect) {
        super.drawBackground(in: dirtyRect)
        guard let kind, !isSelected else { return }
        TrackingAppearance.rowTint(for: kind).setFill()
        dirtyRect.fill(using: .sourceOver)
    }
}

/// The bar under the log: what is being tracked, what has been seen, and what could not be tracked exactly.
@MainActor
final class TrackingFooterView: NSView {
    struct Summary: Equatable {
        var state: TrackingSession.State = .idle
        var entity: String?
        var counts = TrackingLog.Counts()
        var limitations: [ScanLimitation] = []
        var droppedObjects = 0
        var latency: Duration?
        var storeWasReplaced = false
    }

    /// The user wants the rows back.
    var onShowRows: (() -> Void)?

    private let label = NSTextField(labelWithString: "")
    private let warning = NSTextField(labelWithString: "")
    private let spinner = NSProgressIndicator()
    private let showRows = NSButton(title: "", target: nil, action: nil)

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        for text in [label, warning] {
            text.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
            text.textColor = .secondaryLabelColor
            text.lineBreakMode = .byTruncatingTail
        }
        warning.textColor = .systemOrange

        spinner.style = .spinning
        spinner.controlSize = .small
        spinner.isDisplayedWhenStopped = false

        showRows.title = String(localized: "Show Rows", comment: "Leaves the change log for the grid")
        showRows.bezelStyle = .accessoryBarAction
        showRows.controlSize = .small
        showRows.target = self
        showRows.action = #selector(showRowsClicked)

        let stack = NSStackView(views: [spinner, label, warning, NSView(), showRows])
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

    @objc private func showRowsClicked() {
        onShowRows?()
    }

    private(set) var summary = Summary()

    func show(_ summary: Summary) {
        self.summary = summary
        if case .starting = summary.state { spinner.startAnimation(nil) } else { spinner.stopAnimation(nil) }

        if case .failed(let error) = summary.state {
            label.stringValue = error.errorDescription ?? String(localized: "Changes could not be tracked.")
            label.textColor = .systemRed
        } else {
            label.stringValue = Self.text(of: summary)
            label.textColor = .secondaryLabelColor
        }
        label.toolTip = summary.latency.map {
            String(
                localized: "Last change: \($0.milliseconds) ms from save to screen",
                comment: "Tracking latency in the footer tooltip")
        }

        warning.stringValue = Self.warningText(of: summary) ?? ""
        warning.isHidden = warning.stringValue.isEmpty
        warning.toolTip = summary.limitations.isEmpty ? nil : Self.limitationDetail(summary.limitations)
        setAccessibilityLabel([label.stringValue, warning.stringValue].filter { !$0.isEmpty }.joined(separator: ", "))
    }

    private static func text(of summary: Summary) -> String {
        let what = summary.entity ?? ""
        let head: String =
            switch summary.state {
            case .idle: ""
            case .starting: String(localized: "Reading \(what)…", comment: "Tracking is establishing a baseline")
            case .tracking: String(localized: "Tracking \(what)")
            case .paused: String(localized: "Paused")
            case .stopped: String(localized: "Stopped")
            case .failed: ""
            }
        let counts = summary.counts
        guard !counts.isEmpty else {
            return head.isEmpty ? String(localized: "No changes yet") : head
        }
        let tally = String(
            localized: "\(counts.created) created, \(counts.updated) updated, \(counts.deleted) deleted",
            comment: "Tracking log totals")
        return head.isEmpty ? tally : "\(head) · \(tally)"
    }

    private static func warningText(of summary: Summary) -> String? {
        if summary.storeWasReplaced {
            return String(
                localized: "The store file was replaced — reopening",
                comment: "Shown when the watched app reinstalled or restored its store")
        }
        if !summary.limitations.isEmpty {
            return String(
                localized: "Some changes cannot be tracked exactly",
                comment: "Footer warning for reduced-fidelity tracking")
        }
        if summary.droppedObjects > 0 {
            return String(localized: "\(summary.droppedObjects) older objects dropped from the log")
        }
        return nil
    }

    private static func limitationDetail(_ limitations: [ScanLimitation]) -> String {
        limitations.map { "\($0.subject): \(sentence(for: $0.reason))" }.joined(separator: "\n")
    }

    private static func sentence(for reason: ScanLimitation.Reason) -> String {
        switch reason {
        case .unverifiedTable: String(localized: "its table could not be confirmed, so it is not watched")
        case .missingTable: String(localized: "its table is not in this database")
        case .noOptimisticLockColumn:
            String(localized: "it has no save counter, so updates cannot be told apart; inserts and deletes are exact")
        case .noEntityColumn: String(localized: "its rows cannot be attributed to an entity")
        case .unmappedEntityNumber: String(localized: "some rows belong to an entity this model does not describe")
        case .unverifiedJoinTable: String(localized: "a relationship's join table could not be confirmed")
        }
    }
}

extension Duration {
    /// Whole milliseconds, for the places a duration is read rather than measured.
    var milliseconds: Int {
        let parts = components
        return Int(parts.seconds * 1_000) + Int(parts.attoseconds / 1_000_000_000_000_000)
    }
}

extension NSUserInterfaceItemIdentifier {
    static let trackingBadgeCell = NSUserInterfaceItemIdentifier("tracking.badge")
    static let trackingValueCell = NSUserInterfaceItemIdentifier("tracking.value")
}
