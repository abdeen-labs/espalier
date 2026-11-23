// The "Stashed Changes" card under the Changes list, shown while the current
// branch has a stash: the stash symbol, the title, how many when it has
// more than one, and a chevron. Like View ▸ Show Stashed Changes (⌃H), it
// shows the branch's newest stash.

import SwiftUI

/// The card that shows the current branch's newest stash.
public struct StashedChangesRow: View {
    /// How many stashes the current branch has.
    private let count: Int
    private let action: () -> Void
    @Environment(\.numberFormat) private var numberFormat
    @State private var isHovered = false

    public init(count: Int, action: @escaping () -> Void) {
        self.count = count
        self.action = action
    }

    public var body: some View {
        Button(action: action) {
            HStack(spacing: Metrics.SoftBanner.spacing) {
                Image(systemName: "tray.full")
                    .font(.system(size: Metrics.SoftBanner.symbolSize, weight: .semibold))
                    .foregroundStyle(.text2)
                    .frame(width: Metrics.SoftBanner.mark)
                    .accessibilityHidden(true)
                Text("Stashed Changes")
                    .font(Typography.row.weight(.semibold))
                    .foregroundStyle(.text)
                Spacer(minLength: Metrics.insetSmall)
                if count > 1 {
                    TintedPill(formatCount(count, numberFormat), color: PlaceIdentity.stashes.color, font: Typography.count)
                }
                Image(systemName: "chevron.right")
                    .font(.system(size: 10, weight: .bold))
                    .foregroundStyle(.text3)
            }
            .padding(.leading, Metrics.SoftBanner.leadingPadding)
            .padding(.trailing, Metrics.insetMedium)
            .frame(height: Metrics.SoftBanner.minimumHeight)
            .background(
                RoundedRectangle(cornerRadius: Metrics.Radius.card, style: .continuous)
                    .fill(Color(nsColor: isHovered ? Palette.tint(PlaceIdentity.stashes.color, light: 0.18, dark: 0.28) : Palette.tint(PlaceIdentity.stashes.color, light: Metrics.SoftBanner.tint.light, dark: Metrics.SoftBanner.tint.dark)))
                    .hoverMotion(isHovered)
            )
            .contentShape(RoundedRectangle(cornerRadius: Metrics.Radius.card, style: .continuous))
        }
        .buttonStyle(.bare(.rounded(Metrics.Radius.card)))
        .onHover { isHovered = $0 }
        .tooltip(count > 1 ? "Show the newest changes stashed on this branch" : "Show the changes stashed on this branch")
        .accessibilityLabel(count > 1 ? "Stashed Changes, \(formatCount(count, numberFormat)) stashes" : "Stashed Changes")
        .accessibilityHint(count > 1 ? "Shows the newest changes stashed on this branch" : "Shows the changes stashed on this branch")
    }
}
