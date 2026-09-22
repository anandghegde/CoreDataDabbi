import DabbiKit
import SwiftUI

/// The way here, above the grid: `Order #12 › customer › orders` (REL-3).
///
/// It appears only after a relationship has been followed — landing on an entity from the sidebar is not a
/// trail — and each crumb but the last goes back to where it names.
struct BreadcrumbView: View {
    let context: ProjectContext

    var body: some View {
        let trail = context.navigation.current?.trail ?? []
        if !trail.isEmpty {
            VStack(spacing: 0) {
                ScrollView(.horizontal) {
                    HStack(spacing: 3) {
                        ForEach(Array(trail.enumerated()), id: \.offset) { index, crumb in
                            if index > 0 {
                                Image(systemName: "chevron.compact.right")
                                    .font(.caption2)
                                    .foregroundStyle(.tertiary)
                                    .accessibilityHidden(true)
                            }
                            self.crumb(crumb, at: index, of: trail.count)
                        }
                    }
                    .padding(.horizontal, 10)
                    .padding(.vertical, 4)
                }
                .scrollIndicators(.never)
                Divider()
            }
            .accessibilityElement(children: .contain)
            .accessibilityLabel(String(localized: "Trail"))
        }
    }

    @ViewBuilder
    private func crumb(_ title: String, at index: Int, of count: Int) -> some View {
        if index == count - 1 {
            // Where the grid is now: nowhere to go.
            Text(title)
                .font(.caption.weight(.medium))
                .lineLimit(1)
        } else {
            Button {
                // The first crumb is the object the drilling started from, whose place has no trail at all;
                // every crumb after it is one step longer than its index.
                context.goBack(toTrailLength: index == 0 ? 0 : index + 1)
            } label: {
                Text(title).font(.caption).lineLimit(1)
            }
            .buttonStyle(.link)
            .help(String(localized: "Go back to \(title)"))
        }
    }
}
