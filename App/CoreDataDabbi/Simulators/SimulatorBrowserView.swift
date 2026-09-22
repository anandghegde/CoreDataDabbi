import AppKit
import DabbiKit
import SwiftUI

/// The simulator browser (PRJ-8): devices by runtime on the left, what the selected one holds on the right.
struct SimulatorBrowserView: View {
    @Bindable var model: SimulatorBrowserModel

    var body: some View {
        NavigationSplitView {
            devices
                .navigationSplitViewColumnWidth(min: 220, ideal: 260, max: 360)
        } detail: {
            contents
        }
        .searchable(text: $model.search, placement: .toolbar, prompt: Text("Device, app or store"))
        .toolbar { toolbar }
        .task {
            model.load()
            model.watchForChanges()
        }
    }

    // MARK: Devices

    private var devices: some View {
        List(selection: $model.selectedDevice) {
            ForEach(model.groups) { group in
                Section(group.name) {
                    ForEach(group.devices) { device in
                        DeviceRow(
                            device: device, storeCount: model.storeCount(of: device),
                            isScanning: model.isScanning(device)
                        )
                        .tag(device.udid)
                    }
                }
            }
        }
        .listStyle(.sidebar)
        .overlay {
            if model.groups.isEmpty { noDevices }
        }
        .safeAreaInset(edge: .bottom) { listingFooter }
    }

    private var noDevices: some View {
        InspectorMessage(
            symbol: model.isLoadingDevices ? "ellipsis" : "iphone.slash",
            title: model.isLoadingDevices
                ? String(localized: "Looking for simulators…")
                : (model.devices.isEmpty
                    ? String(localized: "No simulators") : String(localized: "No device matches")),
            detail: model.devices.isEmpty && !model.isLoadingDevices
                ? String(localized: "Install a simulator runtime in Xcode, or open a store file instead.") : nil)
    }

    /// Says so when the device list is the folders' word rather than `simctl`'s: a booted state read from
    /// `device.plist` can lag behind, and it is better to know why.
    @ViewBuilder private var listingFooter: some View {
        if model.origin == .deviceFiles, !model.devices.isEmpty {
            HStack(spacing: 6) {
                Image(systemName: "info.circle")
                    .accessibilityHidden(true)
                Text("Read from the simulator folders; simctl could not be asked.")
                    .fixedSize(horizontal: false, vertical: true)
            }
            .font(.caption)
            .foregroundStyle(.secondary)
            .padding(8)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(.bar)
            .help(model.listingIssue?.message ?? "")
        }
    }

    // MARK: Contents

    @ViewBuilder private var contents: some View {
        if let device = model.device {
            let rows = model.appRows
            List {
                ForEach(rows) { row in
                    Section {
                        ForEach(row.stores) { store in
                            StoreRow(store: store, open: { model.open(store) })
                        }
                    } header: {
                        AppHeader(row: row)
                    }
                }
                if !model.isComplete(device) {
                    Text("A container was too large to search to the end; some stores may be missing.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .listStyle(.inset)
            .alternatingRowBackgrounds()
            .overlay {
                if rows.isEmpty { emptyDevice(device) }
            }
            // The window keeps its own name; which device is being looked at belongs above its stores.
            .safeAreaInset(edge: .top, spacing: 0) { header(device) }
        } else {
            InspectorMessage(symbol: "iphone", title: String(localized: "Select a simulator"), detail: nil)
        }
    }

    private func header(_ device: SimulatorDevice) -> some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 6) {
                        Text(device.name)
                            .font(.headline)
                        if device.state == .booted {
                            Badge(text: String(localized: "Booted"), tint: .green)
                        }
                    }
                    Text(summary(of: device))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 8)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(.bar)
            Divider()
        }
        .accessibilityElement(children: .combine)
    }

    private func summary(of device: SimulatorDevice) -> String {
        var parts = [device.runtimeName]
        if let apps = model.installedAppCount(of: device) {
            parts.append(
                apps == 1 ? String(localized: "1 app installed") : String(localized: "\(apps) apps installed"))
        }
        if let stores = model.storeCount(of: device) {
            parts.append(stores == 1 ? String(localized: "1 store") : String(localized: "\(stores) stores"))
        }
        if !device.isAvailable { parts.append(String(localized: "runtime not installed")) }
        return parts.joined(separator: " · ")
    }

    private func emptyDevice(_ device: SimulatorDevice) -> some View {
        if model.isScanning(device) {
            return InspectorMessage(
                symbol: "ellipsis", title: String(localized: "Looking inside \(device.name)…"), detail: nil)
        }
        if model.installedAppCount(of: device) == 0 {
            return InspectorMessage(
                symbol: "tray", title: String(localized: "No apps installed"),
                detail: String(localized: "Run an app on this simulator, and its stores will show up here."))
        }
        return InspectorMessage(
            symbol: "tray", title: String(localized: "No stores"),
            detail: String(
                localized: "None of this device's apps has a Core Data or SwiftData store the filters allow."))
    }

    // MARK: Toolbar

    @ToolbarContentBuilder private var toolbar: some ToolbarContent {
        ToolbarItemGroup {
            Toggle(isOn: $model.bootedOnly) {
                Label(String(localized: "Booted Only"), systemImage: "power")
            }
            .help(String(localized: "Show only simulators that are running"))

            Menu {
                Toggle(String(localized: "Show Other Databases"), isOn: $model.showsOtherDatabases)
            } label: {
                Label(String(localized: "Options"), systemImage: "line.3.horizontal.decrease.circle")
            }
            .help(String(localized: "What the browser lists"))

            Button {
                model.load(refresh: true)
            } label: {
                Label(String(localized: "Refresh"), systemImage: "arrow.clockwise")
            }
            .keyboardShortcut("r")
            .help(String(localized: "Look at every simulator again"))
        }
    }
}

// MARK: - Rows

private struct DeviceRow: View {
    var device: SimulatorDevice
    var storeCount: Int?
    var isScanning: Bool

    var body: some View {
        HStack(spacing: 6) {
            VStack(alignment: .leading, spacing: 1) {
                Text(device.name)
                    .lineLimit(1)
                Text(subtitle)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer(minLength: 4)
            if device.state == .booted {
                // The badge PRJ-8 asks for; shape as well as colour, for Differentiate Without Color.
                Image(systemName: "power.circle.fill")
                    .foregroundStyle(.green)
                    .help(String(localized: "Booted"))
                    .accessibilityLabel(String(localized: "Booted"))
            }
        }
        .accessibilityElement(children: .combine)
    }

    private var subtitle: String {
        if !device.isAvailable { return String(localized: "Runtime not installed") }
        if isScanning { return String(localized: "Looking…") }
        switch storeCount {
        case nil: return String(localized: "Not looked at yet")
        case 0: return String(localized: "No stores")
        case 1: return String(localized: "1 store")
        case let count?: return String(localized: "\(count) stores")
        }
    }
}

private struct AppHeader: View {
    var row: SimulatorBrowserModel.AppRow

    var body: some View {
        HStack(spacing: 8) {
            AppIcon(url: row.app?.iconURL)
            VStack(alignment: .leading, spacing: 1) {
                HStack(spacing: 6) {
                    Text(row.name)
                        .font(.headline)
                    if row.usesSwiftData {
                        // PRJ-11: the app ships no model, so its stores are read with their cached one.
                        Badge(text: String(localized: "SwiftData"), tint: .purple)
                    }
                }
                if let bundleID = row.bundleID {
                    Text(bundleID)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                } else {
                    Text("App groups no installed app claims")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(.vertical, 2)
        .textCase(nil)
    }
}

private struct StoreRow: View {
    var store: StoreCandidate
    var open: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "cylinder.split.1x2")
                .foregroundStyle(.secondary)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(store.url.lastPathComponent)
                        .lineLimit(1)
                    if store.kind == .plainSQLite {
                        Badge(text: String(localized: "SQLite"), tint: .secondary)
                    }
                }
                Text(where: store.location)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            Spacer(minLength: 8)
            VStack(alignment: .trailing, spacing: 2) {
                Text(store.byteCount.formatted(.byteCount(style: .file)))
                    .monospacedDigit()
                if let modifiedAt = store.modifiedAt {
                    Text(modifiedAt.formatted(date: .abbreviated, time: .shortened))
                }
            }
            .font(.caption)
            .foregroundStyle(.secondary)
            Button(String(localized: "Open"), action: open)
                .help(String(localized: "Open this store in a new project"))
        }
        .padding(.vertical, 3)
        .contentShape(Rectangle())
        .onTapGesture(count: 2, perform: open)
        .contextMenu {
            Button(String(localized: "Open"), action: open)
            Button(String(localized: "Show in Finder")) {
                NSWorkspace.shared.activateFileViewerSelecting([store.url])
            }
            Button(String(localized: "Copy Path")) {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(store.url.path, forType: .string)
            }
        }
        .accessibilityElement(children: .combine)
    }
}

extension Text {
    /// Where inside the app a store sits: the container, then the folders within it.
    fileprivate init(where location: StoreLocation) {
        guard case .simulator(_, _, let container, let relativePath) = location else {
            self.init(verbatim: location.fileName)
            return
        }
        let folder = (relativePath as NSString).deletingLastPathComponent
        let place =
            switch container {
            case .data: String(localized: "Data container")
            case .group(let identifier): identifier
            }
        self.init(verbatim: folder.isEmpty ? place : "\(place) › \(folder)")
    }
}

/// The app's icon as the simulator stored it, or a placeholder. Icons are small PNGs; reading one per app row is
/// cheaper than keeping a cache alive for a window that is open for a minute.
private struct AppIcon: View {
    var url: URL?

    var body: some View {
        Group {
            if let url, let image = NSImage(contentsOf: url) {
                Image(nsImage: image)
                    .resizable()
                    .interpolation(.high)
            } else {
                Image(systemName: "app.dashed")
                    .resizable()
                    .foregroundStyle(.tertiary)
            }
        }
        .aspectRatio(contentMode: .fit)
        .frame(width: 26, height: 26)
        .clipShape(RoundedRectangle(cornerRadius: 6))
        .accessibilityHidden(true)
    }
}

private struct Badge: View {
    var text: String
    var tint: Color

    var body: some View {
        Text(text)
            .font(.caption2.weight(.medium))
            .padding(.horizontal, 5)
            .padding(.vertical, 1)
            .background(tint.opacity(0.18), in: Capsule())
            .foregroundStyle(tint)
    }
}
