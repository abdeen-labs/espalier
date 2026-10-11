// A group of branch rows in the sidebar that opens and closes: Default
// Branch, Recent Branches, Other Branches, Remote Branches, each remote,
// and each folder. Its row has Espalier's disclosure chevron; its rows are
// rows of the sidebar's list, a level in.

import SwiftUI

/// A group of rows whose expansion is remembered; open while the sidebar
/// filter shows matches. Its row is the chevron and the label, one button
/// that opens and closes it (→ and ← too, while the row has keyboard
/// focus); its rows follow it, a level in, each a row of the list. The
/// section's own groups (Default Branch, Recent Branches, ...) are labeled
/// by name alone, in secondary text; a remote and a folder have their
/// symbol.
///
/// As in `SidebarSection`, the rows follow the expansion the row sets, a
/// state change made inside its animation, so the list animates them in and
/// out; the remembered expansion follows it once that change has drawn, and
/// a change made elsewhere (another window) reaches the remembered one
/// first.
struct BranchGroupDisclosure<Content: View>: View {
    let title: String
    let systemImage: String?
    let isFiltering: Bool
    let content: Content
    @AppStorage private var rememberedExpansion: Bool
    /// The expansion the row set, or nil before it sets one.
    @State private var chosenExpansion: Bool?
    @Environment(\.motion) private var motion

    /// - Parameters:
    ///   - id: Names the remembered expansion (`sidebar.expanded.<id>`).
    ///   - systemImage: The row's symbol; nil for one of the section's
    ///     groups.
    ///   - isExpandedByDefault: The expansion before the user changes it.
    init(id: String, title: String, systemImage: String? = nil, isExpandedByDefault: Bool = false, isFiltering: Bool, @ViewBuilder content: () -> Content) {
        self.title = title
        self.systemImage = systemImage
        self.isFiltering = isFiltering
        self.content = content()
        _rememberedExpansion = AppStorage(wrappedValue: isExpandedByDefault, "sidebar.expanded.\(id)")
    }

    var body: some View {
        let isOpen = BranchGroupExpansion.isOpen(chosen: chosenExpansion, remembered: rememberedExpansion, isFiltering: isFiltering)
        BranchGroupRow(title: title, systemImage: systemImage, isExpanded: isOpen) { expanded in
            setExpanded(expanded)
        }
        .sidebarRow(nil, id: "group:\(title)")
        .onChange(of: chosenExpansion) { _, chosen in
            if let chosen {
                rememberedExpansion = chosen
            }
        }
        .onChange(of: rememberedExpansion) { _, remembered in
            chosenExpansion = remembered
        }
        if isOpen {
            // Each row inside, folders' rows and theirs included, a level in.
            content
                .padding(.leading, Metrics.Sidebar.disclosureIndent)
        }
    }

    /// Opens or closes the group, animating its rows in or out; while the
    /// filter shows matches it stays open.
    private func setExpanded(_ expanded: Bool) {
        let current = chosenExpansion ?? rememberedExpansion
        guard let next = BranchGroupExpansion.change(to: expanded, from: current, isFiltering: isFiltering) else {
            return
        }
        withMotion(motion, next ? Motion.arrive : Motion.leave) {
            chosenExpansion = next
        }
    }
}

/// When a branch group shows its rows, and what opening or closing it
/// changes.
nonisolated enum BranchGroupExpansion {
    /// Whether the group shows its rows: as the row set it, else as
    /// remembered, and always while the filter shows matches.
    static func isOpen(chosen: Bool?, remembered: Bool, isFiltering: Bool) -> Bool {
        isFiltering || (chosen ?? remembered)
    }

    /// The expansion to set when the user opens (`expanded`) or closes the
    /// group: nil when nothing changes, as while the filter holds it open.
    static func change(to expanded: Bool, from current: Bool, isFiltering: Bool) -> Bool? {
        guard !isFiltering, expanded != current else {
            return nil
        }
        return expanded
    }
}

/// A group's row: the chevron, then the label, as one button. VoiceOver
/// sees a disclosure triangle, open or closed.
private struct BranchGroupRow: View {
    let title: String
    let systemImage: String?
    let isExpanded: Bool
    let setExpanded: (Bool) -> Void

    var body: some View {
        Button {
            setExpanded(!isExpanded)
        } label: {
            HStack(spacing: Metrics.Sidebar.disclosureSpacing) {
                DisclosureChevron(isExpanded: isExpanded)
                    .frame(width: Metrics.Sidebar.disclosureWidth)
                label
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(.bare(.rounded(Metrics.Radius.row)))
        .onKeyPress(.rightArrow) {
            setExpanded(true)
            return .handled
        }
        .onKeyPress(.leftArrow) {
            setExpanded(false)
            return .handled
        }
        .accessibilityRepresentation {
            DisclosureGroup(isExpanded: Binding(get: { isExpanded }, set: { setExpanded($0) })) {
                EmptyView()
            } label: {
                Text(title)
            }
        }
    }

    @ViewBuilder
    private var label: some View {
        if let systemImage {
            SidebarRowLabel(title, systemImage: systemImage)
        } else {
            Text(title)
                .font(Typography.row.weight(.medium))
                .foregroundStyle(.text2)
                .lineLimit(1)
        }
    }
}

extension Metrics.Sidebar {
    /// A branch group's chevron column, before its label.
    public static let disclosureWidth: CGFloat = 10
    /// Between a group's chevron and its label.
    public static let disclosureSpacing: CGFloat = 4
    /// How far a group's rows sit in from its own: under its label.
    public static let disclosureIndent: CGFloat = disclosureWidth + disclosureSpacing
}
