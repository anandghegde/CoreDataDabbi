import DabbiKit
import SwiftUI

/// What the centre of the window shows while there are no rows to show: no store, a store being opened, a store
/// that could not be. The last is where `DabbiError`'s diagnosis and recovery earn their keep (PRD §8.1:
/// "empty/error states are instructive").
struct StoreStateView: View {
    let context: ProjectContext
    var chooseStore: () -> Void
    var browseSimulators: () -> Void

    var body: some View {
        Group {
            switch context.storeState {
            case .none:
                noStore
            case .opening:
                ProgressView(String(localized: "Opening \(context.project.store?.fileName ?? "")…"))
            case .failed(let error):
                failure(error)
            case .open:
                EmptyView()
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(nsColor: .controlBackgroundColor))
    }

    private var noStore: some View {
        VStack(spacing: 14) {
            Image(systemName: "cylinder.split.1x2")
                .font(.system(size: 44, weight: .light))
                .foregroundStyle(.secondary)
                .accessibilityHidden(true)
            Text("This project has no store yet")
                .font(.title2)
            Text("Open a Core Data or SwiftData store file, or pick an app from a simulator.")
                .foregroundStyle(.secondary)
            HStack {
                Button(String(localized: "Choose Store…"), action: chooseStore)
                    .keyboardShortcut(.defaultAction)
                Button(String(localized: "Browse Simulators…"), action: browseSimulators)
            }
            .padding(.top, 4)
        }
        .padding(32)
    }

    private func failure(_ error: DabbiError) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                HStack(alignment: .firstTextBaseline, spacing: 10) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundStyle(.yellow)
                        .accessibilityHidden(true)
                    Text(error.message)
                        .textSelection(.enabled)
                }
                .font(.title2)

                if !error.diagnosis.isEmpty {
                    section(String(localized: "What was found"), lines: error.diagnosis, symbol: "circle.fill")
                }
                if !error.recovery.isEmpty {
                    section(String(localized: "What you can do"), lines: error.recovery, symbol: "arrow.right")
                }
                if let underlying = error.underlying {
                    DisclosureGroup(String(localized: "Details")) {
                        Text(verbatim: "\(underlying)\n\(error.code.rawValue)")
                            .font(.system(.caption, design: .monospaced))
                            .foregroundStyle(.secondary)
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.top, 4)
                    }
                }
                HStack {
                    Button(String(localized: "Try Again")) { context.openStore() }
                        .keyboardShortcut(.defaultAction)
                    Button(String(localized: "Choose Store…"), action: chooseStore)
                    Button(String(localized: "Browse Simulators…"), action: browseSimulators)
                }
                .padding(.top, 4)
            }
            .frame(maxWidth: 560, alignment: .leading)
            .padding(40)
            .frame(maxWidth: .infinity)
        }
    }

    private func section(_ title: String, lines: [String], symbol: String) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title)
                .font(.headline)
            ForEach(lines, id: \.self) { line in
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Image(systemName: symbol)
                        .font(.system(size: symbol == "circle.fill" ? 5 : 10, weight: .semibold))
                        .foregroundStyle(.secondary)
                        .frame(width: 12)
                        .accessibilityHidden(true)
                    Text(line)
                        .textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }
}
