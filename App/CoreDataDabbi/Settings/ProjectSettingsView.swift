import DabbiKit
import SwiftUI

/// What the project points at and how it shows it (PRJ-12): the store, the model, the time zone.
///
/// It is also where a lost store is repaired. When the store is not where the project says, the sheet leads
/// with what was found, what can be done, and the places the store may be now — a pick away from being the
/// project's store again.
struct ProjectSettingsView: View {
    /// What the sheet cannot do by itself: panels and dismissal are the controller's.
    @MainActor
    final class Actions {
        var chooseStore: () -> Void = {}
        var chooseModel: () -> Void = {}
        var done: () -> Void = {}
    }

    let context: ProjectContext
    let actions: Actions

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Form {
                storeSection
                if !context.repairs.isEmpty { repairSection }
                modelSection
                displaySection
            }
            .formStyle(.grouped)
            .scrollBounceBehavior(.basedOnSize)

            HStack {
                Spacer()
                Button(String(localized: "Done"), action: actions.done)
                    .keyboardShortcut(.cancelAction)
            }
            .padding([.horizontal, .bottom], 20)
            .padding(.top, 4)
        }
        .frame(width: 560)
        .frame(minHeight: 360, idealHeight: 520, maxHeight: 720)
    }

    // MARK: Store

    private var storeSection: some View {
        Section(String(localized: "Store")) {
            LabeledContent(String(localized: "Location")) {
                VStack(alignment: .trailing, spacing: 2) {
                    if let origin = context.locationOrigin {
                        Text(origin)
                    }
                    Text(verbatim: storePath ?? String(localized: "None"))
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                        .multilineTextAlignment(.trailing)
                        .lineLimit(3)
                        .truncationMode(.middle)
                }
            }
            if case .failed(let error) = context.storeState {
                problem(error)
            } else {
                LabeledContent(String(localized: "Status"), value: statusLine)
            }
            HStack {
                Spacer()
                if context.project.store != nil {
                    Button(String(localized: "Try Again")) { context.openStore() }
                        .disabled(isOpening)
                }
                Button(String(localized: "Choose Store…"), action: actions.chooseStore)
            }
        }
    }

    /// The file for a plain file; the path within the container for anything remembered by identity.
    private var storePath: String? {
        if let url = context.storeURL { return url.path }
        switch context.project.store {
        case .file(let reference): return reference.lastKnownPath
        case .simulator(_, _, _, let path), .macApp(_, _, let path), .container(_, let path),
            .devicePull(_, _, let path):
            return path
        case nil: return nil
        }
    }

    private var isOpening: Bool {
        if case .opening = context.storeState { true } else { false }
    }

    private var statusLine: String {
        switch context.storeState {
        case .none: String(localized: "No store")
        case .opening: String(localized: "Opening…")
        case .open(let store):
            store.isWorkingCopy ? String(localized: "Open, as a copy") : String(localized: "Open")
        case .failed: String(localized: "Not open")
        }
    }

    private func problem(_ error: DabbiError) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Label {
                Text(error.message)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
            } icon: {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(.yellow)
                    .accessibilityHidden(true)
            }
            .font(.headline)
            lines(String(localized: "What was found"), error.diagnosis)
            lines(String(localized: "What you can do"), error.recovery)
        }
        .accessibilityElement(children: .combine)
    }

    @ViewBuilder
    private func lines(_ title: String, _ lines: [String]) -> some View {
        if !lines.isEmpty {
            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                    .font(.subheadline.weight(.semibold))
                ForEach(lines, id: \.self) { line in
                    Text(line)
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }

    // MARK: Suggested fixes

    private var repairSection: some View {
        Section {
            ForEach(Array(context.repairs.enumerated()), id: \.element.id) { index, repair in
                HStack(alignment: .firstTextBaseline) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(Self.title(of: repair))
                        Text(Self.detail(of: repair))
                            .font(.callout)
                            .foregroundStyle(.secondary)
                            .lineLimit(2)
                            .truncationMode(.middle)
                    }
                    Spacer()
                    Button(String(localized: "Use This Store")) { context.apply(repair) }
                        .keyboardShortcut(index == 0 ? .defaultAction : nil)
                        .accessibilityLabel(String(localized: "Use \(Self.title(of: repair))"))
                }
            }
        } header: {
            Text(
                context.repairs.count == 1
                    ? String(localized: "Suggested Fix") : String(localized: "Suggested Fixes"))
        }
    }

    static func title(of repair: StoreRepair) -> String {
        switch repair.reason {
        case .otherDevice:
            let device =
                repair.device.map { "\($0.name) (\($0.runtimeName))" } ?? String(localized: "another simulator")
            return String(localized: "\(repair.url.lastPathComponent) on \(device)")
        case .elsewhereInContainer, .sameFolder:
            return repair.url.lastPathComponent
        }
    }

    static func detail(of repair: StoreRepair) -> String {
        let why: String
        switch repair.reason {
        case .otherDevice: why = String(localized: "The same app, at the same path, on another simulator.")
        case .elsewhereInContainer:
            let path: String
            if case .simulator(_, _, _, let relativePath) = repair.location { path = relativePath } else { path = "" }
            why = String(localized: "Elsewhere in the app’s container: \(path)")
        case .sameFolder: why = String(localized: "In the folder the store used to be in.")
        }
        guard let modified = repair.modifiedAt else { return why }
        let when = modified.formatted(.relative(presentation: .named))
        return why + " " + String(localized: "Written \(when).")
    }

    // MARK: Model

    private var modelSection: some View {
        Section(String(localized: "Model")) {
            LabeledContent(String(localized: "Read With")) {
                switch context.project.model {
                case .storeCache:
                    Text("The model cached in the store")
                case .file(let reference):
                    VStack(alignment: .trailing, spacing: 2) {
                        Text(verbatim: reference.lastKnownURL.lastPathComponent)
                        Text(verbatim: reference.lastKnownPath)
                            .font(.callout)
                            .foregroundStyle(.secondary)
                            .textSelection(.enabled)
                            .lineLimit(2)
                            .truncationMode(.middle)
                    }
                }
            }
            HStack {
                Spacer()
                Button(String(localized: "Use Cached Model")) { context.useCachedModel() }
                    .disabled(context.project.model == .storeCache)
                Button(String(localized: "Choose Model…"), action: actions.chooseModel)
            }
        }
    }

    // MARK: Display

    private var displaySection: some View {
        Section(String(localized: "Display")) {
            Picker(String(localized: "Time Zone"), selection: timeZone) {
                Text("UTC").tag("utc")
                Text("This Mac’s (\(TimeZone.autoupdatingCurrent.identifier))").tag("local")
                Divider()
                ForEach(TimeZone.knownTimeZoneIdentifiers, id: \.self) { identifier in
                    Text(verbatim: identifier).tag(identifier)
                }
            }
        }
    }

    private var timeZone: Binding<String> {
        Binding {
            switch context.project.display.timeZone {
            case .utc: "utc"
            case .local: "local"
            case .custom(let identifier): identifier
            }
        } set: { tag in
            switch tag {
            case "utc": context.setTimeZone(.utc)
            case "local": context.setTimeZone(.local)
            default: context.setTimeZone(.custom(tag))
            }
        }
    }
}
