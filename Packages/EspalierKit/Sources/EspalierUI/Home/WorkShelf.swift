// The shelf: a strip of tabs under the toolbar, one per piece of work with
// something in it, across every repository, above the detail area while the
// window shows a repository. It reads `AppModel.shelf`.
//
// A tab has the repository's title, the headline's mark where the work
// stopped or its pull request needs the user (or the arc or the clock while
// it's in progress), the pending counts as the repository popover draws
// them, and a dot while it's unseen; under it, the branch. The open work's
// tab is raised, as a segmented control's selected segment. Under Needs You,
// the work in progress follows a hairline as compact tabs of just its mark.
// "23 quiet" at the trailing end opens the repository popover. A click opens
// the work; the context menu pins its repository and has the repository's
// menu, and a linked worktree's. More tabs than fit scroll sideways, fading
// at an end with more beyond it.

import EspalierCore
import EspalierSupport
import GitKit
import SwiftUI

// MARK: - Content

/// One tab of the shelf.
nonisolated struct ShelfTabContent: Sendable, Equatable, Identifiable {
    /// The piece of work.
    let id: WorktreeKey
    /// The repository's title.
    var title: String
    /// Its branch, or its short SHA when HEAD is detached; empty before a
    /// status or a worktree list has told.
    var branch: String
    /// Whether `branch` is a SHA.
    var isDetached: Bool
    /// The mark after the title: the headline's where the work stopped,
    /// its pull request needs the user, or it merged; the arc or the clock
    /// while it's in progress; nil otherwise.
    var mark: WorkMark?
    var changedFiles: Int
    var ahead: Int
    var behind: Int
    var isUnseen: Bool
    /// Whether the window has it open: the selected tab.
    var isOpen: Bool
    /// Whether its repository is pinned.
    var isPinned: Bool
    /// The repository's folder.
    var path: String
    /// The worktree, when it's a linked one: its menu follows the
    /// repository's.
    var linkedWorktree: WorktreeRowContent?
    /// The tooltip, which VoiceOver reads too: the repository, the branch,
    /// and what the work is doing, as one sentence.
    var summary: String

    /// The pending counts, as the repository popover's row has them.
    var statusCounts: RepositoryRowContent {
        RepositoryRowContent(
            id: .repository(id.repositoryID),
            title: title,
            subtitle: nil,
            icon: .repository,
            changedFileCount: changedFiles,
            ahead: ahead,
            behind: behind,
            showsStatus: true,
            fullName: title,
            alias: nil,
            path: path
        )
    }
}

/// What the shelf shows (`ShelfContents`, arranged).
nonisolated struct ShelfContent: Sendable, Equatable {
    /// The full tabs, in the shelf's order.
    var tabs: [ShelfTabContent]
    /// Under Needs You, the work in progress other than the open one, as
    /// compact tabs after a hairline; empty under Recent Activity.
    var compactTabs: [ShelfTabContent]
    /// How many repositories are quiet ("23 quiet").
    var quietRepositoryCount: Int

    /// The content of `shelf` under `arrangement`. Under Recent Activity,
    /// every piece of work is a full tab, in the shelf's order. Under Needs
    /// You, the work in progress is a compact tab after the others, except
    /// the open one, which stays a full tab where the shelf has it.
    static func make(_ shelf: ShelfContents, arrangement: RepositoryArrangement, format: NumberFormat) -> ShelfContent {
        var tabs: [ShelfTabContent] = []
        var compactTabs: [ShelfTabContent] = []
        for piece in shelf.work {
            let tab = ShelfTabContent(piece, format: format)
            if arrangement == .needsYou, case .inProgress = piece.phase, !piece.isOpen {
                compactTabs.append(tab)
            } else {
                tabs.append(tab)
            }
        }
        return ShelfContent(tabs: tabs, compactTabs: compactTabs, quietRepositoryCount: shelf.quietRepositoryCount)
    }

    /// Whether it has a tab besides the open work's: the shelf shows only
    /// then.
    var hasOtherWork: Bool {
        (tabs + compactTabs).contains { !$0.isOpen }
    }

    /// The open work's tab, if it has one.
    var openTabID: WorktreeKey? {
        tabs.first(where: \.isOpen)?.id
    }

    /// Whether a window showing `destination` shows the shelf, with status
    /// on or off (Settings ▸ Advanced): while it shows a repository and
    /// status is on; never on Home or without a repository.
    static func windowShowsShelf(_ destination: DetailDestination, isStatusOn: Bool) -> Bool {
        guard isStatusOn else {
            return false
        }
        switch destination {
        case .changes, .history, .pullRequest, .stash, .missing, .unsafe:
            return true
        case .launching, .getStarted, .noRepositorySelected, .home, .cloning:
            return false
        }
    }
}

nonisolated extension ShelfTabContent {
    /// The tab of `piece`.
    init(_ piece: PieceOfWork, format: NumberFormat) {
        let (branch, isDetached) = Self.branch(of: piece)
        let linkedWorktree: WorktreeRowContent? = if let entry = piece.entry, entry.type == .linked {
            WorktreeRowContent(entry, isCurrent: piece.isOpen, isMissing: false)
        } else {
            nil
        }
        self.init(
            id: piece.id,
            title: piece.title,
            branch: branch,
            isDetached: isDetached,
            mark: Self.mark(of: piece),
            changedFiles: piece.changedFilesCount,
            ahead: piece.aheadBehind?.ahead ?? 0,
            behind: piece.aheadBehind?.behind ?? 0,
            isUnseen: piece.isUnseen,
            isOpen: piece.isOpen,
            isPinned: piece.isPinned,
            path: piece.path,
            linkedWorktree: linkedWorktree,
            summary: Self.summary(of: piece, branch: branch, isDetached: isDetached, format: format)
        )
    }

    /// The branch, or the short SHA of a detached HEAD: as its status has
    /// it, else as the worktree list does.
    private static func branch(of piece: PieceOfWork) -> (String, isDetached: Bool) {
        switch piece.head {
        case .branch(let name)?: return (name, false)
        case .unborn(let name)?: return (name, false)
        case .detached(let sha)?: return (JSCompat.prefix(sha, 7), true)
        case nil: break
        }
        guard let entry = piece.entry else {
            return ("", false)
        }
        if let branch = entry.branch, !branch.isEmpty {
            let prefix = "refs/heads/"
            return (branch.hasPrefix(prefix) ? String(branch.dropFirst(prefix.count)) : branch, false)
        }
        return entry.head.isEmpty ? ("", false) : (JSCompat.prefix(entry.head, 7), true)
    }

    /// The mark: the arc or the clock while it's in progress; the
    /// headline's when it stopped, its pull request needs the user, or it
    /// merged.
    private static func mark(of piece: PieceOfWork) -> WorkMark? {
        if case .inProgress(let progress) = piece.phase {
            return progress.mark
        }
        switch piece.headline {
        case .operationStopped?, .checksFailing?, .changesRequested?, .merged?:
            return piece.headline?.mark
        case .filesChanged?, .commitsToPush?, .commitsToPull?, .pushedWithoutPullRequest?, nil:
            return nil
        }
    }

    /// "harbor on feature/charts: checks failing on #142.", "pier-api at
    /// a1b2c3d: changing now, 6 files so far.", "docs-site on main: nothing
    /// to do."
    private static func summary(of piece: PieceOfWork, branch: String, isDetached: Bool, format: NumberFormat) -> String {
        let place = branch.isEmpty ? piece.title : "\(piece.title) \(isDetached ? "at" : "on") \(branch)"
        return "\(place): \(state(of: piece, format: format))."
    }

    /// What the work is doing, starting in lowercase.
    private static func state(of piece: PieceOfWork, format: NumberFormat) -> String {
        if case .inProgress(let progress) = piece.phase {
            switch progress {
            case .changingNow:
                return sentence(progress.title, progress.detail(format), separator: ", ")
            case .waitingOnChecks(let pullRequest):
                return lowercasingFirst(progress.title) + " for #\(pullRequest)"
            }
        }
        guard let headline = piece.headline else {
            return "nothing to do"
        }
        let separator = switch headline {
        case .checksFailing, .changesRequested, .merged: " "
        case .operationStopped, .filesChanged, .commitsToPush, .commitsToPull, .pushedWithoutPullRequest: ", "
        }
        return sentence(headline.title(format), headline.detail(format), separator: separator)
    }

    private static func sentence(_ title: String, _ detail: String?, separator: String) -> String {
        lowercasingFirst(title) + (detail.map { separator + $0 } ?? "")
    }

    /// "Rebase stopped" as "rebase stopped".
    private static func lowercasingFirst(_ text: String) -> String {
        guard let first = text.first else {
            return text
        }
        return first.lowercased() + text.dropFirst()
    }
}

// MARK: - The shelf in the window

/// The shelf, above the detail area. It grows in and out, what's below
/// moving with it, as work comes and goes; it shows and hides at once as
/// the window goes to or from a repository, as navigation does.
struct WorkShelf: View {
    @Environment(WindowContext.self) private var context
    @Environment(\.numberFormat) private var numberFormat
    @Environment(\.motion) private var motion
    @State private var isShown: Bool?
    /// The shelf's leading edge from the window's, which the sidebar moves.
    @State private var minX: CGFloat = 0

    /// Whether the window shows the shelf, and whether there's work for it.
    private struct Visibility: Equatable {
        var windowShowsShelf: Bool
        var hasOtherWork: Bool

        var isShown: Bool {
            windowShowsShelf && hasOtherWork
        }
    }

    var body: some View {
        let app = context.app
        let windowShowsShelf = ShelfContent.windowShowsShelf(
            DetailDestination.make(app: app, isShowingHome: context.state.isShowingHome, place: context.state.place),
            isStatusOn: app.preferences.repositoryIndicatorsEnabled
        )
        let content = windowShowsShelf
            ? ShelfContent.make(app.shelf, arrangement: app.preferences.repositoryArrangement, format: numberFormat)
            : nil
        let visibility = Visibility(windowShowsShelf: windowShowsShelf, hasOtherWork: content?.hasOtherWork ?? false)
        VStack(spacing: 0) {
            if isShown ?? visibility.isShown, let content {
                WorkShelfView(content, leadingInset: Metrics.Shelf.leadingInset(minX: minX)) { [context] key in
                    context.actions.perform(.openWork(key, place: nil))
                } showQuiet: { [context] in
                    context.actions.perform(.switchRepository)
                } menu: { [context] tab in
                    WorkShelf.menu(tab, context: context)
                }
                .barTransition()
            }
        }
        .onGeometryChange(for: CGFloat.self) { proxy in
            proxy.frame(in: .global).minX
        } action: { minX in
            self.minX = minX
        }
        .onChange(of: visibility) { old, new in
            // Work coming and going moves; the window's navigation doesn't.
            if old.windowShowsShelf == new.windowShowsShelf {
                withMotion(motion, new.isShown ? Motion.arrive : Motion.leave) {
                    isShown = new.isShown
                }
            } else {
                isShown = new.isShown
            }
        }
    }

    /// A tab's context menu: Pin Repository or Unpin Repository, the
    /// repository popover's menu for its repository, and a linked
    /// worktree's menu.
    @MenuBuilder
    static func menu(_ tab: ShelfTabContent, context: WindowContext) -> MenuContent {
        let activity = context.app.worktreeActivity
        let id = tab.id.repositoryID
        if activity.isPinned(id) {
            MenuAction("Unpin Repository") {
                activity.unpin(id)
            }
        } else {
            MenuAction("Pin Repository") {
                activity.pin(id)
            }
        }
        MenuDivider()
        RepositoryContextMenu.content(entry: .repository(id), context: context)
        if let worktree = tab.linkedWorktree {
            MenuDivider()
            WorktreeContextMenu.content(worktree, context: context)
        }
    }
}

// MARK: - The shelf's look

/// The shelf's look, value-driven (`ShelfContent`): the tabs, scrolling
/// sideways when they don't fit, then "23 quiet".
struct WorkShelfView: View {
    private let content: ShelfContent
    private let open: (WorktreeKey) -> Void
    private let showQuiet: () -> Void
    private let menu: (ShelfTabContent) -> MenuContent
    private let leadingInset: CGFloat

    /// - Parameter leadingInset: From the leading edge to the first tab,
    ///   where the cards below start; the window's edge margin by default.
    init(
        _ content: ShelfContent,
        leadingInset: CGFloat = Metrics.Shelf.edgeInset,
        open: @escaping (WorktreeKey) -> Void = { _ in },
        showQuiet: @escaping () -> Void = {},
        menu: @escaping (ShelfTabContent) -> MenuContent = { _ in MenuContent() }
    ) {
        self.content = content
        self.leadingInset = leadingInset
        self.open = open
        self.showQuiet = showQuiet
        self.menu = menu
    }

    var body: some View {
        HStack(spacing: Metrics.Shelf.spacing) {
            ScrollViewReader { proxy in
                OverflowScrollView(.horizontal, fadesEdges: true) {
                    tabs
                        .padding(.vertical, Metrics.Shelf.shadowRoom)
                        .padding(.horizontal, Metrics.Shelf.shadowRoom)
                }
                // The open work's tab is kept in view.
                .onChange(of: content.openTabID, initial: true) {
                    if let id = content.openTabID {
                        proxy.scrollTo(id)
                    }
                }
            }
            .padding(.horizontal, -Metrics.Shelf.shadowRoom)
            if content.quietRepositoryCount > 0 {
                QuietRepositoriesButton(count: content.quietRepositoryCount, action: showQuiet)
            }
        }
        .padding(.leading, leadingInset)
        .padding(.trailing, Metrics.Shelf.edgeInset)
        .padding(.bottom, Metrics.Shelf.bottomInset)
        .frame(height: Metrics.Shelf.height, alignment: .top)
    }

    private var tabs: some View {
        HStack(spacing: Metrics.Shelf.tabSpacing) {
            ForEach(Array(content.tabs.enumerated()), id: \.element.id) { index, tab in
                if index > 0 {
                    TabSeparator(isBesideSelection: tab.isOpen || content.tabs[index - 1].isOpen)
                }
                ShelfTab(content: tab, open: open, menu: menu)
                    .id(tab.id)
            }
            if !content.compactTabs.isEmpty {
                Rectangle()
                    .fill(.line2)
                    .frame(width: 1, height: Metrics.Shelf.hairlineHeight)
                    .accessibilityHidden(true)
                    .padding(.horizontal, Metrics.Shelf.hairlineSpacing)
                ForEach(content.compactTabs) { tab in
                    CompactShelfTab(content: tab, open: open, menu: menu)
                        .id(tab.id)
                }
            }
        }
    }
}

/// Between two full tabs where the tabs are flat: a hairline, but beside
/// the raised one, as a segmented control's separators.
private struct TabSeparator: View {
    let isBesideSelection: Bool

    var body: some View {
        if Theme.current.style.toolbar.shelfTabs == .flat {
            Hairline(.vertical)
                .frame(height: Metrics.Shelf.hairlineHeight)
                .opacity(isBesideSelection ? 0 : 1)
        }
    }
}

/// A full tab: the title, the mark, the counts, and the unseen dot; under
/// them, the branch.
private struct ShelfTab: View {
    let content: ShelfTabContent
    let open: (WorktreeKey) -> Void
    let menu: (ShelfTabContent) -> MenuContent

    var body: some View {
        let isFlat = Theme.current.style.toolbar.shelfTabs == .flat
        let branchFont = isFlat || content.isDetached ? Metrics.Shelf.codeBranchFont : Metrics.Shelf.branchFont
        ShelfTabButton(content: content, width: Metrics.Shelf.tabWidth...Metrics.Shelf.maximumTabWidth, open: open, menu: menu) {
            // The first line sets the tab's width; the branch fits in it.
            VStack(alignment: .leading, spacing: 1) {
                HStack(spacing: Metrics.Shelf.markSpacing) {
                    Text(content.title)
                        .font(Metrics.Shelf.titleFont)
                        .foregroundStyle(.text)
                        .lineLimit(1)
                    if let mark = content.mark {
                        ShelfMark(mark: mark)
                    }
                    RepositoryStatusIndicators(content: content.statusCounts)
                    Spacer(minLength: 0)
                    if content.isUnseen {
                        Circle()
                            .fill(.accent)
                            .frame(width: Metrics.Shelf.dot, height: Metrics.Shelf.dot)
                            .accessibilityHidden(true)
                    }
                }
                if !content.branch.isEmpty {
                    Text(verbatim: " ")
                        .font(branchFont)
                        .hidden()
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .overlay(alignment: .leading) {
                            Text(content.branch)
                                .font(branchFont)
                                .foregroundStyle(.text2)
                                .lineLimit(1)
                                .truncationMode(.middle)
                        }
                }
            }
            .padding(.horizontal, Metrics.Shelf.tabPadding)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

/// A compact tab: just the mark of the work in progress.
private struct CompactShelfTab: View {
    let content: ShelfTabContent
    let open: (WorktreeKey) -> Void
    let menu: (ShelfTabContent) -> MenuContent

    var body: some View {
        ShelfTabButton(content: content, width: Metrics.Shelf.compactWidth...Metrics.Shelf.compactWidth, open: open, menu: menu) {
            if let mark = content.mark {
                ShelfMark(mark: mark, isAlone: true)
            }
        }
    }
}

/// The mark: its symbol in its color, or the turning arc.
private struct ShelfMark: View {
    let mark: WorkMark
    var isAlone = false

    var body: some View {
        Group {
            if let systemImage = mark.systemImage {
                Image(systemName: systemImage)
                    .font(.system(size: isAlone ? 13 : 11, weight: .semibold))
                    .foregroundStyle(Color(nsColor: mark.color))
            } else {
                ArcProgress(isAlone ? .small : .mini, tint: mark.color)
            }
        }
        .accessibilityHidden(true)
    }
}

/// A tab's button: its surface (soft, flat, or raised while it's open),
/// the hover wash, the tooltip, and the context menu.
private struct ShelfTabButton<Label: View>: View {
    let content: ShelfTabContent
    /// From its narrowest to its widest: as wide as its label needs
    /// between them.
    let width: ClosedRange<CGFloat>
    let open: (WorktreeKey) -> Void
    let menu: (ShelfTabContent) -> MenuContent
    @ViewBuilder let label: Label
    @State private var isHovered = false

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: Metrics.Shelf.radius, style: .continuous)
        Button {
            open(content.id)
        } label: {
            label
                .frame(minWidth: width.lowerBound, maxWidth: width.upperBound, minHeight: Metrics.Shelf.tabHeight, maxHeight: Metrics.Shelf.tabHeight)
                .background {
                    ShelfTabSurface(isSelected: content.isOpen, isHovered: isHovered, shape: shape)
                }
                .contentShape(shape)
        }
        .buttonStyle(.bare(.rounded(Metrics.Shelf.radius)))
        .onHover { isHovered = $0 }
        .tooltip(content.summary)
        .accessibilityLabel(content.summary)
        .accessibilityAddTraits(content.isOpen ? .isSelected : [])
        .contextMenuCard { [content, menu] in
            menu(content)
        }
    }
}

/// A tab's surface: raised as a segmented control's selected segment while
/// it's open; else a soft card (Default) or nothing (Frost), with the hover
/// wash.
private struct ShelfTabSurface: View {
    let isSelected: Bool
    let isHovered: Bool
    let shape: RoundedRectangle

    var body: some View {
        let theme = Theme.current
        if isSelected {
            shape
                .fill(Color(nsColor: theme.segmentSelection))
                .shadow(color: Color(nsColor: theme.raisedShadow), radius: Metrics.Shelf.shadowRadius, y: 1)
                .overlay(shape.strokeBorder(Color(nsColor: theme.raisedRing), lineWidth: 1))
        } else {
            ZStack {
                if theme.style.toolbar.shelfTabs == .cards {
                    shape.fill(Color(nsColor: theme.background).opacity(Metrics.Shelf.cardOpacity))
                }
                shape
                    .fill(isHovered ? Color(nsColor: theme.hover) : .clear)
                    .hoverMotion(isHovered)
            }
        }
    }
}

/// "23 quiet": the quiet repositories' count, which opens the repository
/// popover.
private struct QuietRepositoriesButton: View {
    let count: Int
    let action: () -> Void
    @State private var isHovered = false
    @Environment(\.numberFormat) private var numberFormat

    var body: some View {
        Button(action: action) {
            Text("\(formatCount(count, numberFormat)) quiet")
                .font(Metrics.Shelf.quietFont)
                .foregroundStyle(.text2)
                .lineLimit(1)
                .padding(.horizontal, Metrics.LocationControl.segmentPadding)
                .frame(height: Metrics.ControlHeight.regular)
                .background {
                    Capsule(style: .circular)
                        .fill(isHovered ? Color(nsColor: Palette.hover) : .clear)
                        .hoverMotion(isHovered)
                }
                .contentShape(Capsule(style: .circular))
        }
        .buttonStyle(.bare(.capsule))
        .onHover { isHovered = $0 }
        .fixedSize()
        .tooltip(ActionKind.switchRepository.title)
        .accessibilityLabel(count == 1 ? "1 quiet repository" : "\(formatCount(count, numberFormat)) quiet repositories")
    }
}

extension Metrics {
    /// The shelf, in the theme's tabs (`ToolbarThemeStyle.shelfTabs`).
    enum Shelf {
        private static var isFlat: Bool {
            Theme.current.style.toolbar.shelfTabs == .flat
        }

        /// A full tab's narrowest width and its widest, past which its
        /// title truncates; a compact one's width.
        static var tabWidth: CGFloat { isFlat ? 150 : 154 }
        static var maximumTabWidth: CGFloat { isFlat ? 240 : 250 }
        static let compactWidth: CGFloat = 40
        static var tabHeight: CGFloat { isFlat ? 40 : 46 }
        static var radius: CGFloat { isFlat ? Theme.current.radii.row : 14 }
        /// Between tabs: room for the hairline where tabs are flat.
        static var tabSpacing: CGFloat { isFlat ? 4 : 8 }
        /// Inside a tab's ends.
        static var tabPadding: CGFloat { isFlat ? 10 : 12 }
        /// Between the title, the mark, and the counts.
        static let markSpacing: CGFloat = 6
        /// The unseen dot.
        static let dot: CGFloat = 7
        /// The hairline before the compact tabs, and the flat tabs'.
        static let hairlineHeight: CGFloat = 22
        static let hairlineSpacing: CGFloat = 4
        /// An unselected card's opacity.
        static let cardOpacity: CGFloat = 0.62
        /// The raised tab's shadow.
        static var shadowRadius: CGFloat { isFlat ? 1 : 3 }
        /// Room around the tabs for the raised one's shadow.
        static let shadowRoom: CGFloat = 4
        /// Between the scrolling tabs and "23 quiet".
        static let spacing: CGFloat = 8
        /// From the window's trailing edge, where the cards are.
        static var edgeInset: CGFloat {
            PaneCards.detailMargins(minX: 0, beforeInspector: false).trailing + (PaneCards.floats ? PaneCards.inset : 0)
        }

        /// From the shelf's leading edge, `minX` from the window's, to where
        /// the cards below it start.
        static func leadingInset(minX: CGFloat) -> CGFloat {
            PaneCards.detailMargins(minX: minX, beforeInspector: false).leading + (PaneCards.floats ? PaneCards.inset : 0)
        }
        /// Below the tabs, before the cards.
        static var bottomInset: CGFloat { isFlat ? 8 : 10 }
        /// The shelf's height.
        static var height: CGFloat { tabHeight + bottomInset }

        static var titleFont: Font {
            isFlat
                ? Typography.sans(size: 12, weight: .semibold, relativeTo: .body)
                : Typography.sans(size: 12.5, weight: .bold, relativeTo: .body)
        }
        static var branchFont: Font {
            Typography.sans(size: 11.5, weight: .medium, relativeTo: .subheadline)
        }
        static var codeBranchFont: Font {
            Typography.mono(size: 11, weight: .regular)
        }
        static var quietFont: Font {
            isFlat ? Typography.button : Typography.sans(size: 12.5, weight: .semibold, relativeTo: .body)
        }
    }
}
