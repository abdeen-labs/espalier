// The sidebar's icons style (Settings ▸ Appearance ▸ Sidebar ▸ Icons): a
// rail at the window's leading edge, below the toolbar, in place of the
// sidebar's column. Changes and History are its first icons, Changes with
// its count on a quiet capsule (a warning while conflicts exist); after a
// hairline, an icon for each section the repository's sidebar shows
// (Branches, Pull Requests, Tags, Stashes), which opens the section in a
// popover beside it. A section's icon is selected while one of its places
// is.
//
// A popover holds the sidebar's filter over the section's list, on the
// popover's `background`, its rows as the sidebar has them (selecting a
// place, their menus, Return and a double-click), the section always
// expanded, and is as tall as its rows up to a limit
// (`SidebarListHeight`). The filter clears as it closes.
//
// The rail is flat: the `sidebar` color with a hairline on its trailing
// edge (on the backdrop with none in the floating layout), its icons 36
// square with the row radius, the hover wash under the pointer, and the selected
// one in the sidebar's selection with its symbol in the selection's color.

import AppKit
import EspalierCore
import SwiftUI

extension Metrics {
    /// The icons style's rail.
    public enum Rail {
        public static let width: CGFloat = 52
        /// An icon's side.
        public static let item: CGFloat = 36
        /// The space between icons.
        public static let spacing: CGFloat = 4
        /// The space above the first icon.
        public static let topInset: CGFloat = 8
        /// The hairline between History and the sections.
        public static let dividerWidth: CGFloat = 20
        /// A popover's width: the sidebar's ideal.
        public static let popoverWidth: CGFloat = Column.sidebar.ideal + 40
        /// The tallest a popover's list gets before it scrolls.
        public static let popoverMaxHeight: CGFloat = 440
    }
}

/// A section of the sidebar that the rail opens in a popover.
enum RailSection: String, CaseIterable, Identifiable, Sendable {
    case branches, pullRequests, tags, stashes

    var id: Self {
        self
    }

    var title: String {
        switch self {
        case .branches: "Branches"
        case .pullRequests: "Pull Requests"
        case .tags: "Tags"
        case .stashes: "Stashes"
        }
    }

    var systemImage: String {
        switch self {
        case .branches: "arrow.trianglehead.branch"
        case .pullRequests: PullRequestGlyph.systemImage
        case .tags: "tag"
        case .stashes: "tray.full"
        }
    }

    /// Whether `place` is one of the section's.
    func contains(_ place: SidebarPlace?) -> Bool {
        switch (self, place) {
        case (.branches, .branch?), (.pullRequests, .pullRequest?), (.tags, .tag?), (.stashes, .stash?): true
        default: false
        }
    }

    /// The sections the repository's sidebar shows, in its order: Branches,
    /// Pull Requests for a GitHub repository with a matching account, and
    /// Tags and Stashes when it has any.
    @MainActor
    static func shown(in repository: RepositoryModel, accounts: AccountsModel) -> [RailSection] {
        var sections: [RailSection] = [.branches]
        if PullRequestsSection.isShown(repository, accounts: accounts) {
            sections.append(.pullRequests)
        }
        if !(repository.gitState.tags ?? [:]).isEmpty {
            sections.append(.tags)
        }
        if !repository.gitState.stashes.entries.isEmpty {
            sections.append(.stashes)
        }
        return sections
    }

    /// About how many rows the section's list has (its header's included),
    /// for its popover's height until the list has measured itself: Branches
    /// counts its groups' rows but the remote branches', whose group starts
    /// collapsed.
    @MainActor
    func estimatedRowCount(in repository: RepositoryModel, filter: String) -> Int {
        switch self {
        case .branches:
            let content = BranchesSectionContent.make(repository, upstreamStates: repository.branches.upstreamStates, filter: filter)
            var rows = 1
            rows += content.detachedSHA == nil ? 0 : 1
            rows += content.unbornBranch == nil ? 0 : 1
            rows += content.defaultBranch == nil ? 0 : 2
            rows += content.recent.isEmpty ? 0 : content.recent.count + 1
            rows += content.other.isEmpty ? 0 : content.other.count + 1
            rows += content.remotes.isEmpty ? 0 : 1
            return rows
        case .pullRequests:
            return 1 + max(PullRequestsSection.filtered(repository.gitHub.openPullRequests, by: filter).count, 1)
        case .tags:
            let tags = Array((repository.gitState.tags ?? [:]).keys)
            return 1 + TagRowContent.rows(tags: tags, tagsToPush: [], filter: filter).count
        case .stashes:
            return 1 + StashRowContent.rows(repository, filter: filter).count
        }
    }
}

// MARK: - The rail

/// The rail.
struct SidebarRail: View {
    @Environment(WindowContext.self) private var context

    var body: some View {
        VStack(spacing: Metrics.Rail.spacing) {
            if let repository {
                let place = context.state.place
                ChangesRailButton(content: ChangesPlaceRowContent(repository), isSelected: place == .changes) {
                    context.select(.changes)
                }
                RailButton(
                    "History",
                    systemImage: "clock.arrow.circlepath",
                    shortcut: ActionKind.showHistory.shortcut?.symbols,
                    isSelected: place == .history
                ) {
                    context.select(.history)
                }
                Hairline()
                    .frame(width: Metrics.Rail.dividerWidth)
                    .padding(.vertical, Metrics.Rail.spacing)
                ForEach(RailSection.shown(in: repository, accounts: context.app.accounts)) { section in
                    RailSectionButton(section: section, repository: repository)
                }
            }
        }
        .padding(.top, Metrics.Rail.topInset)
        .frame(width: Metrics.Rail.width)
        .frame(maxHeight: .infinity, alignment: .top)
        .background(Color(espalier: Palette.sidebar))
        .overlay(alignment: .trailing) {
            // The floating layout's rail sits on the backdrop, beside the
            // cards.
            Hairline(.vertical)
                .opacity(PaneCards.floats ? 0 : 1)
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Sidebar")
    }

    private var repository: RepositoryModel? {
        guard context.app.loadState == .ready, let repository = context.repository, repository.isUsable else {
            return nil
        }
        return repository
    }
}

/// Changes' icon, with its count or a warning at its top trailing corner.
private struct ChangesRailButton: View {
    let content: ChangesPlaceRowContent
    let isSelected: Bool
    let action: () -> Void

    var body: some View {
        RailButton(
            "Changes",
            systemImage: "plus.forwardslash.minus",
            shortcut: ActionKind.showChanges.shortcut?.symbols,
            accessibilityValue: accessibilityValue,
            isSelected: isSelected,
            action: action
        ) {
            if content.hasConflicts {
                WarningGlyph()
                    .font(.system(size: 10))
            } else if let badge = content.badge {
                Text(badge)
                    .font(Typography.tinyCount)
                    .foregroundStyle(.text2)
                    .padding(.horizontal, 4)
                    .frame(minWidth: 16, minHeight: 16)
                    .surface(.quiet, elevation: .quiet)
            }
        }
    }

    /// What VoiceOver hears after "Changes".
    private var accessibilityValue: String? {
        if content.hasConflicts {
            return "Conflicts"
        }
        return content.badge.map { content.changedFileCount == 1 ? "1 changed file" : "\($0) changed files" }
    }
}

/// A section's icon, which opens the section's popover.
private struct RailSectionButton: View {
    let section: RailSection
    let repository: RepositoryModel
    @Environment(WindowContext.self) private var context

    var body: some View {
        RailButton(section.title, systemImage: section.systemImage, isSelected: section.contains(context.state.place)) {
            context.state.railPopover = section
        }
        .popoverCard(isPresented: isPresented, edge: .trailing, title: section.title) {
            RailSectionPopover(section: section, repository: repository)
                .windowEnvironment(context)
        }
    }

    /// Whether the section's popover is open; closing it clears the
    /// filter.
    private var isPresented: Binding<Bool> {
        let state = context.state
        return Binding(
            get: { state.railPopover == section },
            set: { isPresented in
                if isPresented {
                    state.railPopover = section
                } else if state.railPopover == section {
                    state.railPopover = nil
                    state.sidebarFilter = ""
                }
            }
        )
    }
}

/// A rail icon: its symbol in a 36-point square, the hover wash under the
/// pointer, the sidebar's selection while selected, and what it badges at
/// its top trailing corner. Its tooltip is its title and shortcut.
struct RailButton<Badge: View>: View {
    private let title: String
    private let systemImage: String
    private let shortcut: String?
    private let accessibilityValue: String?
    private let isSelected: Bool
    private let action: () -> Void
    private let badge: Badge
    @State private var isHovered = false

    /// - Parameter accessibilityValue: What VoiceOver hears of the badge.
    init(
        _ title: String,
        systemImage: String,
        shortcut: String? = nil,
        accessibilityValue: String? = nil,
        isSelected: Bool,
        action: @escaping () -> Void,
        @ViewBuilder badge: () -> Badge = { EmptyView() }
    ) {
        self.title = title
        self.systemImage = systemImage
        self.shortcut = shortcut
        self.accessibilityValue = accessibilityValue
        self.isSelected = isSelected
        self.action = action
        self.badge = badge()
    }

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: Metrics.Radius.row, style: .continuous)
        Button(action: action) {
            Image(systemName: systemImage)
                .font(.system(size: 15))
                .foregroundStyle(.sidebarRowIcon(isSelected: isSelected))
                .frame(width: Metrics.Rail.item, height: Metrics.Rail.item)
                .background {
                    shape
                        .fill(isHovered && !isSelected ? Color(espalier: Palette.hover) : .clear)
                        .hoverMotion(isHovered)
                }
                .background {
                    if isSelected {
                        SidebarSelectionFill()
                    }
                }
                .contentShape(shape)
        }
        .buttonStyle(.bare(.rounded(Metrics.Radius.row)))
        .overlay(alignment: .topTrailing) {
            badge
                .offset(x: 4, y: -4)
                .allowsHitTesting(false)
                .accessibilityHidden(true)
        }
        .onHover { isHovered = $0 }
        .tooltip([title, shortcut].compactMap(\.self).joined(separator: " "))
        .accessibilityLabel(title)
        .accessibilityValue(accessibilityValue ?? "")
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }
}

// MARK: - The popover

/// A section's popover: the sidebar's filter over the section's list.
struct RailSectionPopover: View {
    let section: RailSection
    let repository: RepositoryModel
    @Environment(WindowContext.self) private var context
    @Environment(\.closeEnclosingPopover) private var closePopover
    /// The list's height, once it has measured its rows.
    @State private var listHeight: CGFloat?

    var body: some View {
        let selection = Binding<SidebarPlace?>(
            get: { context.state.place },
            set: { place in
                if let place {
                    context.select(place)
                }
            }
        )
        VStack(spacing: 0) {
            SidebarFilterField(surface: Palette.background)
            List(selection: selection) {
                switch section {
                case .branches:
                    BranchesSection(repository: repository)
                case .pullRequests:
                    PullRequestsSection(repository: repository)
                case .tags:
                    TagsSection(repository: repository)
                case .stashes:
                    StashesSection(repository: repository)
                }
            }
            .sidebarListStyle(surface: Palette.background)
            .environment(\.sidebarSelection, selection.wrappedValue)
            .environment(\.sidebarSectionsCollapse, false)
            .contextMenuCard(forSelectionType: SidebarPlace.self, selection: selection.wrappedValue.map { [$0] } ?? []) { [context] places in
                SidebarContextMenu.content(places: places, context: context)
            } primaryAction: { places in
                closePopover?()
                SidebarContainer.primaryAction(places, context: context)
            }
            .background {
                SidebarListHeight { height in
                    listHeight = height
                }
                .frame(width: 0, height: 0)
                .accessibilityHidden(true)
            }
            .frame(height: height)
        }
        .padding(.bottom, Metrics.insetSmall)
        .frame(width: Metrics.Rail.popoverWidth)
        .background(Color(espalier: Palette.background))
    }

    /// The list's height: its rows', or about that until it has measured
    /// them, at least a row and at most `popoverMaxHeight`.
    private var height: CGFloat {
        let estimate = CGFloat(section.estimatedRowCount(in: repository, filter: context.state.sidebarFilter)) * Metrics.RowHeight.sidebar
            + Metrics.insetMedium
        return min(max(listHeight ?? estimate, Metrics.RowHeight.sidebar), Metrics.Rail.popoverMaxHeight)
    }
}

/// Reports the height of the list beside it, its rows' and its insets, as
/// it changes: when the list lays out or grows, and when a row comes or
/// goes (`SidebarListStyler.rowsDidChange`). A list's table is at least as
/// tall as its scroll view, so the rows are measured, not the table.
struct SidebarListHeight: NSViewRepresentable {
    let onChange: (CGFloat) -> Void

    func makeNSView(context: Context) -> ReaderView {
        ReaderView()
    }

    func updateNSView(_ view: ReaderView, context: Context) {
        view.onChange = onChange
        view.scheduleMeasure()
    }

    final class ReaderView: NSView {
        var onChange: ((CGFloat) -> Void)?
        private weak var table: NSTableView?
        private var observers: [any NSObjectProtocol] = []
        private var isMeasureScheduled = false
        private var reported: CGFloat?

        override func hitTest(_ point: NSPoint) -> NSView? {
            nil
        }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            if window == nil {
                detach()
            } else {
                scheduleMeasure()
            }
        }

        override func layout() {
            super.layout()
            scheduleMeasure()
        }

        /// Measures on the next turn, once the list has laid its rows out.
        func scheduleMeasure() {
            guard !isMeasureScheduled else {
                return
            }
            isMeasureScheduled = true
            DispatchQueue.main.async { [weak self] in
                guard let self else {
                    return
                }
                isMeasureScheduled = false
                measure()
            }
        }

        private func measure() {
            guard window != nil, let table = table ?? attach() else {
                return
            }
            let rows = table.numberOfRows
            let content = rows > 0 ? table.rect(ofRow: rows - 1).maxY : 0
            let insets = table.enclosingScrollView?.contentInsets ?? NSEdgeInsetsZero
            let height = ceil(content + insets.top + insets.bottom)
            guard height != reported else {
                return
            }
            reported = height
            onChange?(height)
        }

        /// Finds the list's table beside this view and follows it.
        private func attach() -> NSTableView? {
            guard let table = nearestTable() else {
                return nil
            }
            self.table = table
            table.postsFrameChangedNotifications = true
            let center = NotificationCenter.default
            for name in [NSView.frameDidChangeNotification, SidebarListStyler.rowsDidChange] {
                observers.append(center.addObserver(forName: name, object: table, queue: .main) { [weak self] _ in
                    MainActor.assumeIsolated {
                        self?.scheduleMeasure()
                    }
                })
            }
            return table
        }

        private func detach() {
            for observer in observers {
                NotificationCenter.default.removeObserver(observer)
            }
            observers = []
            table = nil
        }

        private func nearestTable() -> NSTableView? {
            var child: NSView = self
            while let parent = child.superview {
                for sibling in parent.subviews where sibling !== child {
                    if let table = Self.table(in: sibling) {
                        return table
                    }
                }
                child = parent
            }
            return nil
        }

        private static func table(in view: NSView) -> NSTableView? {
            if let table = view as? NSTableView {
                return table
            }
            for subview in view.subviews {
                if let table = table(in: subview) {
                    return table
                }
            }
            return nil
        }
    }
}
