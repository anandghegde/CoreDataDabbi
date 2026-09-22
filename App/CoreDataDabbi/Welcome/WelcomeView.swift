import AppKit
import DabbiKit
import SwiftUI

/// The welcome window (PRJ-16): the three ways in on the left, what was open last on the right, and anything
/// dropped on it opened.
struct WelcomeView: View {
    @Bindable var model: WelcomeModel
    @State private var isTargeted = false

    var body: some View {
        HStack(spacing: 0) {
            ways
                .frame(width: 320)
            Divider()
            recents
                .frame(minWidth: 280)
        }
        .background(.background)
        .dropDestination(for: URL.self) { urls, _ in
            model.accept(urls)
            return true
        } isTargeted: {
            isTargeted = $0
        }
        .overlay {
            if isTargeted { dropHighlight }
        }
    }

    // MARK: The ways in

    private var ways: some View {
        VStack(spacing: 0) {
            VStack(spacing: 6) {
                Image(nsImage: NSApp.applicationIconImage ?? NSImage())
                    .resizable()
                    .frame(width: 96, height: 96)
                    .accessibilityHidden(true)
                Text(Self.appName)
                    .font(.system(size: 26, weight: .semibold))
                Text(Self.versionLine)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
            }
            .padding(.top, 34)

            Spacer(minLength: 20)

            VStack(alignment: .leading, spacing: 4) {
                WayIn(
                    symbol: "iphone", title: String(localized: "Browse Simulators"),
                    detail: String(localized: "Pick an app's store from a simulator"), action: model.browseSimulators)
                WayIn(
                    symbol: "cylinder.split.1x2", title: String(localized: "Open Database"),
                    detail: String(localized: "Any Core Data or SwiftData store file"), action: model.openDatabase)
                WayIn(
                    symbol: "folder", title: String(localized: "Open Project"),
                    detail: String(localized: "A .dabbi project saved earlier"), action: model.openProject)
            }
            .padding(.horizontal, 22)

            Spacer(minLength: 16)

            Toggle(String(localized: "Show this window when CoreDataDabbi opens"), isOn: $model.showsAtLaunch)
                .toggleStyle(.checkbox)
                .font(.caption)
                .padding(.bottom, 16)
                .padding(.horizontal, 22)
        }
        .frame(maxHeight: .infinity)
    }

    // MARK: Recents

    private var recents: some View {
        VStack(spacing: 0) {
            ScrollView {
                // Not lazy: recents are a handful of rows, and a screen reader walking the list wants all of
                // them, whether or not they have been scrolled to.
                VStack(spacing: 0) {
                    ForEach(model.recents) { recent in
                        RecentRow(recent: recent, open: { model.open(recent) })
                        Divider()
                    }
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .overlay {
                if model.recents.isEmpty { nothingYet }
            }
            .safeAreaInset(edge: .top, spacing: 0) { recentsHeader }
            dropHint
        }
    }

    private var recentsHeader: some View {
        VStack(spacing: 0) {
            Text("Recents")
                .font(.headline)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 16)
                .padding(.vertical, 10)
                .background(.bar)
            Divider()
        }
    }

    private var nothingYet: some View {
        InspectorMessage(
            symbol: "clock", title: String(localized: "Nothing yet"),
            detail: String(localized: "Stores and projects you open will be listed here."))
    }

    /// Says what the window takes, and what came of the last thing dropped on it.
    @ViewBuilder private var dropHint: some View {
        Divider()
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Image(systemName: model.problem == nil ? "arrow.down.doc" : "exclamationmark.triangle.fill")
                .foregroundStyle(model.problem == nil ? AnyShapeStyle(.secondary) : AnyShapeStyle(.yellow))
                .accessibilityHidden(true)
            if model.isSearching {
                Text("Looking for stores in what you dropped…")
            } else if let problem = model.problem {
                VStack(alignment: .leading, spacing: 2) {
                    Text(problem.message)
                    ForEach(problem.recovery, id: \.self) { line in
                        Text(line).foregroundStyle(.secondary)
                    }
                }
            } else {
                Text("Drop a store, an app bundle or an .xcappdata container here.")
            }
            Spacer(minLength: 0)
        }
        .font(.caption)
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.bar)
        .accessibilityElement(children: .combine)
    }

    private var dropHighlight: some View {
        RoundedRectangle(cornerRadius: 10)
            .strokeBorder(Color.accentColor, style: StrokeStyle(lineWidth: 3, dash: [8, 5]))
            .padding(6)
            .allowsHitTesting(false)
    }

    // MARK: The app itself

    private static var appName: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleName") as? String ?? "CoreDataDabbi"
    }

    /// "Version 0.1 (12)" — what a bug report needs, where a bug report's author will look for it.
    private static var versionLine: String {
        let short = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0"
        let build = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "0"
        return String(localized: "Version \(short) (\(build))")
    }
}

// MARK: - Rows

/// One of the three ways into a store: a big, obvious target rather than a button in a row of buttons.
private struct WayIn: View {
    var symbol: String
    var title: String
    var detail: String
    var action: () -> Void

    @State private var isHovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 12) {
                Image(systemName: symbol)
                    .font(.system(size: 20))
                    .foregroundStyle(Color.accentColor)
                    .frame(width: 30)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 1) {
                    Text(title)
                        .font(.body.weight(.medium))
                    Text(detail)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(isHovering ? AnyShapeStyle(.quaternary) : AnyShapeStyle(.clear), in: .rect(cornerRadius: 8))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { isHovering = $0 }
        .accessibilityHint(detail)
    }
}

private struct RecentRow: View {
    var recent: WelcomeModel.Recent
    var open: () -> Void

    @State private var isHovering = false

    var body: some View {
        // A button, so that Tab reaches the row and Return opens it — one click is still all it takes (§8.4).
        Button(action: open) {
            HStack(spacing: 8) {
                Image(nsImage: NSWorkspace.shared.icon(forFile: recent.url.path))
                    .resizable()
                    .frame(width: 22, height: 22)
                    .opacity(recent.isMissing ? 0.4 : 1)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 1) {
                    Text(recent.name)
                        .lineLimit(1)
                    Text(recent.isMissing ? String(localized: "Not where it was") : recent.folder)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 7)
            .frame(maxWidth: .infinity, alignment: .leading)
            .opacity(recent.isMissing ? 0.6 : 1)
            .background(isHovering ? AnyShapeStyle(.quaternary) : AnyShapeStyle(.clear))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { isHovering = $0 }
        .contextMenu {
            Button(String(localized: "Open"), action: open)
            Button(String(localized: "Show in Finder")) {
                NSWorkspace.shared.activateFileViewerSelecting([recent.url])
            }
        }
        .accessibilityLabel(
            recent.isMissing
                ? String(localized: "\(recent.name), not where it was") : "\(recent.name), \(recent.folder)"
        )
        .accessibilityHint(String(localized: "Opens it"))
    }
}
