// Changes | History in the middle of the toolbar while the sidebar is
// hidden (its column, or the icons style's rail), so the two places are
// always one click away: two tabs, each with its place's symbol and name,
// Changes with its count (a warning while conflicts exist). The place you're in sits on the butter
// highlight; in another place (a branch, a stash) neither tab does. A
// tab's press sinks and eases back; the highlight moves at once, as
// navigation does.

import EspalierCore
import SwiftUI

/// Changes | History, for the toolbar.
struct PlaceSwitcher: View {
    let repository: RepositoryModel
    @Environment(WindowContext.self) private var context

    var body: some View {
        let changes = ChangesPlaceRowContent(repository)
        PlaceTabs(selection: context.state.place, changes: changes) { place in
            context.select(place)
        }
        .fixedSize()
        // The toolbar measures its item once: a new identity when the count
        // changes makes it measure again.
        .id(changes)
    }
}

/// The two tabs, value-driven.
struct PlaceTabs: View {
    let selection: SidebarPlace?
    let changes: ChangesPlaceRowContent
    var select: (SidebarPlace) -> Void = { _ in }

    var body: some View {
        HStack(spacing: Metrics.PlaceTabs.spacing) {
            PlaceTab(
                "Changes",
                place: .changes,
                shortcut: ActionKind.showChanges.shortcut?.symbols,
                isSelected: selection == .changes,
                accessibilityValue: changesValue
            ) {
                select(.changes)
            } accessory: {
                if changes.hasConflicts {
                    WarningGlyph()
                        .font(.system(size: 11))
                } else if let badge = changes.badge {
                    Text(badge)
                        .font(Typography.count)
                        .foregroundStyle(.text3)
                }
            }
            PlaceTab(
                "History",
                place: .history,
                shortcut: ActionKind.showHistory.shortcut?.symbols,
                isSelected: selection == .history
            ) {
                select(.history)
            }
        }
        .padding(Metrics.PlaceTabs.trackInset)
        .background(Capsule(style: .circular).fill(Color(espalier: Palette.hover)))
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Place")
    }

    /// What VoiceOver hears after "Changes".
    private var changesValue: String? {
        if changes.hasConflicts {
            return "Conflicts"
        }
        return changes.badge.map { changes.changedFileCount == 1 ? "1 changed file" : "\($0) changed files" }
    }
}

/// One tab: its place's symbol, its name, and what follows it, on the
/// butter highlight while it's the place you're in.
private struct PlaceTab<Accessory: View>: View {
    private let title: String
    private let place: PlaceIdentity
    private let shortcut: String?
    private let isSelected: Bool
    private let accessibilityValue: String?
    private let action: () -> Void
    private let accessory: Accessory
    @State private var isHovered = false

    init(
        _ title: String,
        place: PlaceIdentity,
        shortcut: String?,
        isSelected: Bool,
        accessibilityValue: String? = nil,
        action: @escaping () -> Void,
        @ViewBuilder accessory: () -> Accessory = { EmptyView() }
    ) {
        self.title = title
        self.place = place
        self.shortcut = shortcut
        self.isSelected = isSelected
        self.accessibilityValue = accessibilityValue
        self.action = action
        self.accessory = accessory()
    }

    var body: some View {
        Button(action: action) {
            HStack(spacing: Metrics.PlaceTabs.symbolSpacing) {
                Image(systemName: place.systemImage)
                    .foregroundStyle(Color.sidebarRowIcon(isSelected: isSelected))
                    .accessibilityHidden(true)
                Text(title)
                    .font(Typography.row.weight(isSelected ? .semibold : .medium))
                    .foregroundStyle(isSelected ? Color.sidebarRowText(isSelected: true) : .text2)
                    .lineLimit(1)
                accessory
            }
            .padding(.leading, Metrics.PlaceTabs.leadingPadding)
            .padding(.trailing, Metrics.PlaceTabs.trailingPadding)
            .frame(height: Metrics.PlaceTabs.height)
            .background {
                Capsule(style: .circular)
                    .fill(isHovered && !isSelected ? Color(espalier: Palette.hover) : .clear)
                    .hoverMotion(isHovered)
            }
            .background {
                if isSelected {
                    Capsule(style: .circular)
                        .fill(Color(nsColor: Theme.current.sidebarSelection))
                }
            }
            // Selection draws at once, though the click that makes it also
            // ends a press, whose release eases.
            .transaction(value: isSelected) { $0.animation = nil }
            .contentShape(Capsule(style: .circular))
        }
        .buttonStyle(.bare(.capsule))
        .onHover { isHovered = $0 }
        .tooltip([title, shortcut].compactMap(\.self).joined(separator: " "))
        .accessibilityLabel(title)
        .accessibilityValue(accessibilityValue ?? "")
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }
}

extension Metrics {
    /// The toolbar's Changes | History tabs.
    public enum PlaceTabs {
        public static let height: CGFloat = 30
        public static let spacing: CGFloat = 2
        public static let trackInset: CGFloat = 2
        public static let symbolSpacing: CGFloat = 7
        public static let leadingPadding: CGFloat = 12
        public static let trailingPadding: CGFloat = 12
    }
}
