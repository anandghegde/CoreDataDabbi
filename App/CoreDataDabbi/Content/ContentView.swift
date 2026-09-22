import DabbiKit
import PDFKit
import SwiftUI
import UniformTypeIdentifiers

/// The content viewer: one field, three ways (CNT-1…CNT-5).
struct ContentView: View {
    @Bindable var model: ContentModel

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            body(of: model.state)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .task(id: Trigger(model: model)) { model.refresh() }
    }

    /// Everything a read depends on, so that SwiftUI restarts the task when any of it moves.
    private struct Trigger: Equatable {
        var field: ContentModel.Field?
        var session: ObjectIdentifier?

        @MainActor
        init(model: ContentModel) {
            field = model.field
            session = model.sessionIdentity
        }
    }

    // MARK: The bar

    private var header: some View {
        HStack(spacing: 8) {
            title
            Spacer(minLength: 8)
            if case .ready(_, let report) = model.state {
                facts(of: report)
                decodeAs(report)
                copyButton(report)
            }
            Picker("", selection: $model.mode) {
                ForEach(ContentModel.Mode.allCases) { mode in
                    Text(mode.title).tag(mode)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .fixedSize()
            .accessibilityLabel(String(localized: "Content mode"))
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
    }

    @ViewBuilder
    private var title: some View {
        if let field = model.field {
            HStack(spacing: 6) {
                Text(field.property)
                    .font(.callout.weight(.medium))
                    .lineLimit(1)
                if let typeName = field.typeName {
                    Text(typeName)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
            .help(field.ref.description)
        } else {
            Text("Content")
                .font(.callout.weight(.medium))
                .foregroundStyle(.secondary)
        }
    }

    /// What it turned out to be, and how big: the two things worth knowing before looking (CNT-1).
    private func facts(of report: ContentReport) -> some View {
        HStack(spacing: 6) {
            ForEach(report.wrappers, id: \.rawValue) { wrapper in
                badge(wrapper.displayName, systemImage: "shippingbox")
            }
            if let type = report.type {
                badge(type.displayName, systemImage: model.forcedType == nil ? nil : "hand.point.up.left")
            }
            Text(report.byteCount.formatted(.byteCount(style: .file)))
                .font(.caption)
                .foregroundStyle(.secondary)
                .help(String(localized: "SHA-256 \(report.sha256)"))
        }
    }

    private func badge(_ text: String, systemImage: String? = nil) -> some View {
        HStack(spacing: 3) {
            if let systemImage {
                Image(systemName: systemImage).font(.caption2).accessibilityHidden(true)
            }
            Text(text).font(.caption)
        }
        .padding(.horizontal, 5)
        .padding(.vertical, 1)
        .background(.quaternary, in: Capsule())
        .foregroundStyle(.secondary)
    }

    /// The magic bytes are a guess; the user gets the last word (CNT-2).
    @ViewBuilder
    private func decodeAs(_ report: ContentReport) -> some View {
        let others = report.alternatives.filter { $0 != report.type }
        if !others.isEmpty || model.forcedType != nil {
            Menu {
                Button(String(localized: "Detect Automatically")) { model.decode(as: nil) }
                    .disabled(model.forcedType == nil)
                Divider()
                ForEach(others, id: \.rawValue) { type in
                    Button(type.displayName) { model.decode(as: type) }
                }
            } label: {
                Image(systemName: "wand.and.stars")
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
            .help(String(localized: "Decode as another kind of content"))
            .accessibilityLabel(String(localized: "Decode as"))
        }
    }

    private func copyButton(_ report: ContentReport) -> some View {
        Button {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(ContentText.text(of: report, mode: model.mode), forType: .string)
        } label: {
            Image(systemName: "doc.on.doc")
        }
        .buttonStyle(.borderless)
        .help(String(localized: "Copy what is shown"))
        .accessibilityLabel(String(localized: "Copy"))
    }

    // MARK: The body

    @ViewBuilder
    private func body(of state: ContentModel.State) -> some View {
        switch state {
        case .noField:
            InspectorMessage(
                symbol: "square.dashed",
                title: String(localized: "No field selected"),
                detail: String(localized: "Click a cell in the grid to see what it holds."))

        case .loading:
            ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)

        case .empty(_, let reason):
            InspectorMessage(symbol: "square.dashed", title: reason)

        case .plain(let field, let value):
            InspectorMessage(
                symbol: "textformat.123",
                title: value,
                detail: field.typeName.map { String(localized: "\($0) — there is nothing to decode.") })

        case .failed(_, let error):
            InspectorMessage(
                symbol: "exclamationmark.triangle",
                title: error.errorDescription ?? String(localized: "The field could not be read."),
                detail: error.recoverySuggestion)

        case .ready(_, let report):
            switch model.mode {
            case .rendered: rendered(report)
            case .text: TextViewer(text: ContentText.text(of: report, mode: .text))
            case .hex: TextViewer(text: HexDump.text(of: report.payload))
            }
        }
    }

    @ViewBuilder
    private func rendered(_ report: ContentReport) -> some View {
        switch report.content {
        case .text(let text, _):
            TextViewer(text: text)

        case .tree(let node, _, _):
            ContentTreeView(root: node)

        case .image(let data):
            if let image = NSImage(data: data) {
                imageView(image, byteCount: report.byteCount)
            } else {
                unreadable(String(localized: "The image could not be read."), report)
            }

        case .pdf(let data):
            if let document = PDFDocument(data: data) {
                PDFViewer(document: document)
            } else {
                unreadable(String(localized: "The PDF could not be read."), report)
            }

        case .media(let data, let type):
            media(type, byteCount: data.count)

        case .rtf(let data):
            if let rich = NSAttributedString(rtf: data, documentAttributes: nil) {
                AttributedViewer(text: AttributedString(rich))
            } else {
                unreadable(String(localized: "The rich text could not be read."), report)
            }

        case .web(let html):
            // A web view that fetches what the page asks for is the project's decision to make, and there is
            // nowhere to record it yet (CNT-3): until then the source is shown, and nothing is loaded.
            VStack(spacing: 0) {
                notice(String(localized: "Shown as source. Rendering HTML will come with a per-project choice."))
                TextViewer(text: html)
            }

        case .link(let url):
            link(url)

        case .wrapped, .opaque:
            // Nothing claimed it, or everything that did failed: hex is always something (CNT-5).
            VStack(spacing: 0) {
                if let issue = report.issues.last {
                    notice(
                        String(
                            localized: "\(issue.decoder.displayName): \(issue.error.errorDescription ?? "")"))
                }
                TextViewer(text: HexDump.text(of: report.payload))
            }
        }
    }

    private func imageView(_ image: NSImage, byteCount: Int) -> some View {
        VStack(spacing: 6) {
            Image(nsImage: image)
                .resizable()
                .scaledToFit()
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .accessibilityLabel(String(localized: "The image this field holds"))
            Text(
                "\(Int(image.size.width).formatted()) × \(Int(image.size.height).formatted()) · "
                    + byteCount.formatted(.byteCount(style: .file))
            )
            .font(.caption)
            .foregroundStyle(.secondary)
        }
        .padding(10)
    }

    private func media(_ type: UTType, byteCount: Int) -> some View {
        InspectorMessage(
            symbol: "play.rectangle",
            title: type.localizedDescription ?? type.identifier,
            detail: String(localized: "\(byteCount.formatted(.byteCount(style: .file))) — playback comes later."))
    }

    private func link(_ url: URL) -> some View {
        VStack(spacing: 10) {
            Text(url.absoluteString)
                .font(.system(.body, design: .monospaced))
                .textSelection(.enabled)
                .multilineTextAlignment(.center)
            // Opening it leaves the app, so it is never done without a click (CNT-3).
            Button(String(localized: "Open in Browser")) { NSWorkspace.shared.open(url) }
                .disabled(!["http", "https"].contains(url.scheme ?? ""))
        }
        .padding(24)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func unreadable(_ message: String, _ report: ContentReport) -> some View {
        VStack(spacing: 0) {
            notice(message)
            TextViewer(text: HexDump.text(of: report.payload))
        }
    }

    private func notice(_ message: String) -> some View {
        Text(message)
            .font(.caption)
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .background(.quaternary.opacity(0.4))
    }
}

/// A PDF a field turned out to hold. `PDFView` renders it without anything being written to disk.
private struct PDFViewer: NSViewRepresentable {
    var document: PDFDocument

    func makeNSView(context: Context) -> PDFView {
        let view = PDFView()
        view.autoScales = true
        view.document = document
        return view
    }

    func updateNSView(_ view: PDFView, context: Context) {
        if view.document !== document { view.document = document }
    }
}

/// The Text mode of a report, and what Copy puts on the pasteboard (CNT-1, CNT-5).
enum ContentText {
    static func text(of report: ContentReport, mode: ContentModel.Mode) -> String {
        switch mode {
        case .hex:
            return HexDump.text(of: report.payload)
        case .rendered, .text:
            switch report.content {
            case .text(let text, _):
                return text
            case .tree(let node, let source, _):
                return source ?? node.outline()
            case .web(let html):
                return html
            case .link(let url):
                return url.absoluteString
            case .rtf(let data):
                return NSAttributedString(rtf: data, documentAttributes: nil)?.string ?? strings(of: report)
            case .image, .pdf, .media, .wrapped, .opaque:
                // Nothing readable — but a blob nearly always has a few readable runs in it, and they are
                // usually what the question was about (CNT-5).
                return strings(of: report)
            }
        }
    }

    private static func strings(of report: ContentReport) -> String {
        let found = HexDump.strings(in: report.payload)
        guard !found.isEmpty else { return String(localized: "There is no text in these bytes.") }
        return found.map { "\(String(format: "%08x", $0.offset))  \($0.text)" }.joined(separator: "\n")
    }
}
