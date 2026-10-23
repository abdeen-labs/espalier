// The sidebar's column, in the hidden style (Settings ▸ Appearance ▸
// Sidebar; the icons style's rail is SidebarRail.swift). It shows the
// current repository's places you select (Changes, History, branches, pull
// requests, tags, stashes), and a filter field at the bottom, as in Xcode's
// navigators; the repository popover switches repositories and worktrees. Each section after the first is a
// feature's view. After a switch, the repository's sections keep showing
// the previous repository until the selected one has loaded
// (`SidebarSectionsHold`).
//
// The sidebar is flat: the `sidebar` color with a hairline on its trailing
// edge, the theme's section labels after their chevrons (a collapsed
// section's with its count), rows 28 high with the row radius, hairline
// dividers between groups of a section's rows, and the selected item in the
// theme's sidebar selection
// (`Palette.sidebarSelection`), its title in the selected weight
// (`SidebarRowFont`) and its symbol in the theme's selection symbol color
// (the list's own selection drawing is off before it first draws:
// `SidebarListStyler`). Selected branch, tag, stash, and pull request rows
// take the selected weight too (`isSidebarRowSelected`).
//
// A section's rows ease in and out as its chevron turns; a collapsed
// section's count and the Changes count roll to a new value over 0.2 s, and
// the Changes count and its warning fade in and out; the hover wash and a
// drop target's fill fade; a header button's press eases back. Selection is
// instant, as are the filter's changes, a switch of repository (and the
// sections catching up with it), and a repository's first load
// (`sidebarMotionScope`).

import AppKit
import EspalierCore
import GitKit
import SwiftUI

/// The sidebar column.
struct SidebarContainer: View {
    @Environment(WindowContext.self) private var context
    /// Which repository the repository's sections show.
    @State private var hold = SidebarSectionsHold()
    /// Bumped once a switch's hold is over, so the sections show the
    /// selected repository however far it has loaded.
    @State private var holdEnds = 0

    var body: some View {
        // Read so that the hold's end draws again.
        let _ = holdEnds
        let selected = context.app.loadState == .ready ? context.repository.flatMap { $0.isUsable ? $0 : nil } : nil
        let shown = hold.repository(showing: selected, in: context.app, now: .now)
        let isHolding = shown?.id != selected?.id
        let selection = placeSelection(isHolding: isHolding)
        List(selection: selection) {
            if context.app.loadState == .ready {
                if let selected {
                    PlacesSection(repository: selected)
                }
                if let shown {
                    BranchesSection(repository: shown)
                    PullRequestsSection(repository: shown)
                    TagsSection(repository: shown)
                    StashesSection(repository: shown)
                }
            }
        }
        .sidebarListStyle()
        .unbouncedList()
        .sidebarMotionScope([selected?.id, shown?.id], loading: selected)
        .environment(\.sidebarSelection, selection.wrappedValue)
        .contextMenuCard(forSelectionType: SidebarPlace.self, selection: selection.wrappedValue.map { [$0] } ?? []) { [context] places in
            SidebarContextMenu.content(places: Self.actionable(places, isHolding: isHolding), context: context)
        } primaryAction: { places in
            primaryAction(Self.actionable(places, isHolding: isHolding))
        }
        .task(id: selected?.id) { [isSelected = selected != nil] in
            guard isSelected else {
                return
            }
            do {
                try await Task.sleep(for: Timing.sidebarHold)
            } catch {
                return
            }
            holdEnds &+= 1
        }
        .safeAreaInset(edge: .bottom, spacing: 0) {
            SidebarFilterField()
        }
        .background(Color(espalier: Palette.sidebar).ignoresSafeArea())
        .overlay(alignment: .trailing) {
            // The floating layout's sidebar sits on the backdrop, beside
            // the cards.
            Hairline(.vertical)
                .ignoresSafeArea()
                .opacity(PaneCards.floats ? 0 : 1)
        }
    }

    /// The places a click, a menu, or Return acts on: while the sections
    /// still show the previous repository, only the selected one's Changes
    /// and History.
    private static func actionable(_ places: Set<SidebarPlace>, isHolding: Bool) -> Set<SidebarPlace> {
        isHolding ? places.filter { $0 == .changes || $0 == .history } : places
    }

    private func primaryAction(_ places: Set<SidebarPlace>) {
        Self.primaryAction(places, context: context)
    }

    /// Double-click or Return on a place: check out a branch or pull
    /// request, restore a stash.
    static func primaryAction(_ places: Set<SidebarPlace>, context: WindowContext) {
        guard places.count == 1, let place = places.first, let repository = context.repository else {
            return
        }
        switch place {
        case .branch(let ref):
            let current = repository.gitState.tip.branch?.ref
            guard ref != current, let match = repository.gitState.branches.all.first(where: { $0.ref == ref }) else {
                return
            }
            context.actions.perform(.checkoutBranch(name: match.name))
        case .pullRequest(let number):
            context.actions.perform(.checkoutPullRequest(number: number))
        case .stash(let sha):
            context.actions.perform(.restoreStash(sha: sha))
        case .changes, .history, .tag:
            break
        }
    }

    /// The selected place; choosing one remembers it for the repository.
    /// Without places (a missing or unsafe repository) nothing is selected:
    /// a selection whose row goes away with its section would stay drawn
    /// where the row was. While the sections still show the previous
    /// repository, their rows can't be chosen.
    private func placeSelection(isHolding: Bool) -> Binding<SidebarPlace?> {
        Binding(
            get: { context.repository?.isUsable == true ? context.state.place : nil },
            set: { place in
                if let place, !Self.actionable([place], isHolding: isHolding).isEmpty {
                    context.select(place)
                }
            }
        )
    }
}

/// Which repository the sidebar's repository sections show (Branches, Pull
/// Requests, Tags, Stashes): the selected one's, except just after a
/// switch. Then they keep showing the repository they showed until the
/// selected one has loaded what they show
/// (`hasLoadedSidebarSections(accounts:)`), for at most
/// `Timing.sidebarHold`, and change in one step. A repository that hasn't
/// loaded has none of it: its sections would vanish and come back, moving
/// the sections below them and the row just clicked.
///
/// The sidebar asks it as it draws. It isn't observable: what it remembers
/// changes only what a later draw shows.
@MainActor
final class SidebarSectionsHold {
    /// The repository whose sections the sidebar showed last.
    private var shownID: RepositoryID?
    /// The selected repository, and when the sidebar first drew it
    /// selected.
    private var selectedID: RepositoryID?
    private var selectedSince = ContinuousClock.now

    /// The repository whose sections show while `selected` is selected.
    ///
    /// - Parameters:
    ///   - selected: The selected repository, nil when none is selected or
    ///     it isn't usable (no sections show).
    ///   - now: The time of the draw.
    func repository(showing selected: RepositoryModel?, in app: AppModel, now: ContinuousClock.Instant) -> RepositoryModel? {
        guard let selected else {
            shownID = nil
            selectedID = nil
            return nil
        }
        if selectedID != selected.id {
            selectedID = selected.id
            selectedSince = now
        }
        if let shownID, shownID != selected.id, now - selectedSince < Timing.sidebarHold,
           !selected.hasLoadedSidebarSections(accounts: app.accounts),
           let shown = app.repository(shownID), shown.isUsable {
            return shown
        }
        shownID = selected.id
        return selected
    }
}

extension RepositoryModel {
    /// Whether the repository has loaded what its sidebar sections show: a
    /// refresh pass's status, remotes, and refs (branches, tags, stashes),
    /// and its open pull requests where Pull Requests shows.
    func hasLoadedSidebarSections(accounts: AccountsModel) -> Bool {
        gitState.loaded.isSuperset(of: [.status, .remotes, .refs])
            && (gitHub.hasLoadedPullRequests || !PullRequestsSection.isShown(self, accounts: accounts))
    }
}

/// Changes and History, the first section (no header).
struct PlacesSection: View {
    let repository: RepositoryModel
    @Environment(WindowContext.self) private var context

    var body: some View {
        PlacesSectionRows(changes: ChangesPlaceRowContent(repository), selection: context.state.place)
    }
}

/// Changes and History, value-driven.
struct PlacesSectionRows: View {
    let changes: ChangesPlaceRowContent
    let selection: SidebarPlace?

    var body: some View {
        Section {
            ChangesPlaceRow(content: changes, isSelected: selection == .changes)
                .sidebarRow(.changes)
                .tag(SidebarPlace.changes)
            SidebarRowLabel("History", systemImage: "clock.arrow.circlepath", isSelected: selection == .history)
                .sidebarRow(.history)
                .tag(SidebarPlace.history)
        }
    }
}

/// The context menu of the place right-clicked: each feature's menu for its
/// rows.
enum SidebarContextMenu {
    @MenuBuilder
    static func content(places: Set<SidebarPlace>, context: WindowContext) -> MenuContent {
        if places.count == 1, let place = places.first {
            switch place {
            case .changes:
                context.actions.menuAction(.stashAllChanges)
                context.actions.menuAction(.discardAllChanges)
            case .history:
                Submenu("History Scope") {
                    for scope in HistoryScope.allCases {
                        context.actions.menuToggle(.setHistoryScope(scope))
                    }
                }
            case .branch(let ref):
                BranchContextMenu.content(ref: ref, context: context)
            case .pullRequest(let number):
                PullRequestContextMenu.content(number: number, context: context)
            case .tag(let name):
                TagContextMenu.content(name: name, context: context)
            case .stash(let sha):
                StashContextMenu.content(sha: sha, context: context)
            }
        }
    }
}

/// What the Changes row shows.
nonisolated struct ChangesPlaceRowContent: Sendable, Hashable {
    /// The changed files, or nil for none.
    var changedFileCount: Int
    /// Whether conflicts exist: a warning replaces the count.
    var hasConflicts: Bool

    init(changedFileCount: Int, hasConflicts: Bool) {
        self.changedFileCount = changedFileCount
        self.hasConflicts = hasConflicts
    }

    @MainActor
    init(_ repository: RepositoryModel) {
        let files = repository.changes.workingDirectory.files
        self.init(
            changedFileCount: files.count,
            hasConflicts: repository.operations.conflictState != nil
                || files.contains { if case .conflicted = $0.status { true } else { false } }
        )
    }

    /// The badge's text: the count, capped at "999+".
    var badge: String? {
        guard changedFileCount > 0 else {
            return nil
        }
        return changedFileCount > 999 ? "999+" : "\(changedFileCount)"
    }
}

/// The Changes row: its count in SF Mono, or a warning while conflicts
/// exist. The count rolls to a new value, and the count and the warning
/// fade in and out, over 0.2 s.
struct ChangesPlaceRow: View {
    let content: ChangesPlaceRowContent
    var isSelected = false
    @Environment(\.motion) private var motion

    var body: some View {
        let fade = motion.animates ? AnyTransition.opacity : .identity
        SidebarRowLabel("Changes", systemImage: "plus.forwardslash.minus", isSelected: isSelected) {
            if content.hasConflicts || content.badge != nil {
                // The count and the warning crossfade in place.
                ZStack(alignment: .trailing) {
                    if content.hasConflicts {
                        WarningGlyph()
                            .tooltip("Conflicts")
                            .transition(fade)
                    } else if let badge = content.badge {
                        Text(badge)
                            .font(Typography.count)
                            .foregroundStyle(.sidebarRowCount(isSelected: isSelected))
                            .contentTransition(motion.animates ? .numericText(value: Double(content.changedFileCount)) : .identity)
                            .transition(fade)
                    }
                }
                .transition(fade)
            }
        }
        .motion(Motion.kindChange, value: content)
    }
}

// MARK: - Rows

/// A sidebar row's look: a symbol (the accent when the row is selected,
/// secondary text otherwise), the title (medium when selected), and what
/// trails it.
struct SidebarRowLabel<Trailing: View>: View {
    private let title: String
    private let systemImage: String
    private let isSelected: Bool
    private let isEmphasized: Bool
    private let truncationMode: Text.TruncationMode
    private let trailing: Trailing
    @Environment(\.isSidebarRowSelected) private var isRowSelected

    /// - Parameters:
    ///   - isSelected: Draws the row as selected; a row that selects a
    ///     place (`sidebarRow(_:)`) is also selected while its place is.
    ///   - isEmphasized: Semibold, as the current branch is.
    ///   - truncationMode: Where a long title is cut: the middle for names
    ///     (a branch's start and end both tell), the tail for text read
    ///     from its start.
    init(
        _ title: String,
        systemImage: String,
        isSelected: Bool = false,
        isEmphasized: Bool = false,
        truncationMode: Text.TruncationMode = .middle,
        @ViewBuilder trailing: () -> Trailing = { EmptyView() }
    ) {
        self.title = title
        self.systemImage = systemImage
        self.isSelected = isSelected
        self.isEmphasized = isEmphasized
        self.truncationMode = truncationMode
        self.trailing = trailing()
    }

    var body: some View {
        let isSelected = isSelected || isRowSelected
        HStack(spacing: Metrics.insetSmall) {
            Image(systemName: systemImage)
                .font(Typography.row)
                .foregroundStyle(.sidebarRowIcon(isSelected: isSelected))
                .frame(width: Metrics.Sidebar.symbolWidth)
                .accessibilityHidden(true)
            Text(title)
                .font(SidebarRowFont.title(isSelected: isSelected, isEmphasized: isEmphasized))
                .foregroundStyle(.sidebarRowText(isSelected: isSelected))
                .lineLimit(1)
                .truncationMode(truncationMode)
            Spacer(minLength: Metrics.grid)
            trailing
        }
        .accessibilityElement(children: .combine)
    }
}

/// A quiet divider between groups of a section's rows (the branches that
/// lead the Branches section, and its Other and Remote Branches): a hairline
/// across the rows' content, in a short row of its own that takes no hover
/// or selection.
struct SidebarDivider: View {
    var body: some View {
        Hairline()
            .frame(maxWidth: .infinity)
            .padding(.vertical, Metrics.grid)
            .selectionDisabled()
            .accessibilityHidden(true)
    }
}

/// A sidebar row title's weight: bold while the row is selected in a theme
/// whose selection is bold (`Theme.sidebarSelectionIsBold`); semibold for
/// the current branch and its pull request; medium while the row is
/// selected; regular otherwise.
enum SidebarRowFont {
    static func title(isSelected: Bool, isEmphasized: Bool = false) -> Font {
        if isSelected, Theme.current.sidebarSelectionIsBold {
            return Typography.row.weight(.bold)
        }
        if isEmphasized {
            return Typography.row.weight(.semibold)
        }
        return isSelected ? Typography.row.weight(.medium) : Typography.row
    }
}

extension EnvironmentValues {
    /// The sidebar's selected place, which its row draws in the sidebar's
    /// selection.
    @Entry var sidebarSelection: SidebarPlace?
    /// Whether the row this is in selects the sidebar's selected place
    /// (`sidebarRow(_:)` sets it): its title is in the selected weight and
    /// its symbol in the theme's selection symbol color.
    @Entry var isSidebarRowSelected = false
}

/// The pointer's row, for the rows' hover wash.
@MainActor @Observable
final class SidebarHover {
    var row: AnyHashable?
}

extension Metrics.Sidebar {
    /// The column a row's symbol or dot sits in, so titles line up.
    public static let symbolWidth: CGFloat = 16
    /// The list's disclosure column, before a disclosure row's symbol: a
    /// section header's chevron sits in it, so the label after it lines up
    /// with the rows' symbols.
    public static let disclosureWidth: CGFloat = 11
    /// The part of the disclosure column a chevron is centered in.
    public static let disclosureChevronWidth: CGFloat = 8
}

extension View {
    /// A sidebar row: 28 high, its background the sidebar's selection or
    /// the hover wash, inset 10 from the sidebar's edges with the row radius.
    ///
    /// - Parameters:
    ///   - place: The place the row selects, if any.
    ///   - id: What identifies a row that isn't a place, for the hover.
    ///   - isDropTarget: Dragged commits are over the row and it takes
    ///     them: the row fills with the soft accent, in its own shape.
    func sidebarRow(_ place: SidebarPlace?, id: AnyHashable? = nil, isDropTarget: Bool = false) -> some View {
        modifier(SidebarRowModifier(place: place, id: id ?? place.map(AnyHashable.init), isDropTarget: isDropTarget))
    }

    /// The sidebar's list: the sidebar style, opaque on `surface` (the
    /// `sidebar` color; a rail popover's `background`), small rows, and the
    /// list's own selection drawing off (the rows draw theirs).
    func sidebarListStyle(surface: NSColor = Palette.sidebar) -> some View {
        self
            .listStyle(.sidebar)
            .scrollContentBackground(.hidden)
            .environment(\.sidebarRowSize, .small)
            .background {
                SidebarListStyler()
                    .frame(width: 0, height: 0)
                    .accessibilityHidden(true)
            }
            .background(Color(espalier: surface))
            .modifier(SidebarHoverProvider())
    }

    /// Draws no motion below for the update in which `scope` (the
    /// repositories shown) changes, nor until `repository` has loaded its
    /// status, remotes, and refs, nor for the update in which it has: the
    /// sidebar shows another repository, and a repository's first state, at
    /// once, as navigation between repositories does.
    func sidebarMotionScope(_ scope: some Hashable, loading repository: RepositoryModel?) -> some View {
        modifier(SidebarMotionScope(scope: AnyHashable(scope), hasLoaded: repository?.gitState.hasLoadedRemoteState == true))
    }
}

/// Gives the list's rows their shared hover state.
private struct SidebarHoverProvider: ViewModifier {
    @State private var hover = SidebarHover()

    func body(content: Content) -> some View {
        content.environment(hover)
    }
}

/// Turns motion off below while the repository loads, and for the update
/// in which the scope changes or the loading ends (`sidebarMotionScope`).
private struct SidebarMotionScope: ViewModifier {
    let scope: AnyHashable
    let hasLoaded: Bool
    @Environment(\.motionSuppressed) private var isSuppressed

    func body(content: Content) -> some View {
        content
            .motionScope(AnyHashable(Key(scope: scope, hasLoaded: hasLoaded)))
            .environment(\.motionSuppressed, isSuppressed || !hasLoaded)
    }

    /// The scope and whether it has loaded: either changing is a new scope.
    private struct Key: Hashable {
        let scope: AnyHashable
        let hasLoaded: Bool
    }
}

/// The row's height, background, and hover, and whether its content draws
/// as selected.
private struct SidebarRowModifier: ViewModifier {
    let place: SidebarPlace?
    let id: AnyHashable?
    let isDropTarget: Bool
    @Environment(SidebarHover.self) private var hover: SidebarHover?
    @Environment(\.sidebarSelection) private var selection

    func body(content: Content) -> some View {
        placeMenu(content)
            .environment(\.isSidebarRowSelected, place != nil && place == selection)
            .background {
                // Inside the row, so the list's table exists when it joins
                // the window: its highlight is off before any row draws.
                SidebarListStyler(searchesBeside: false)
                    .frame(width: 0, height: 0)
                    .accessibilityHidden(true)
            }
            .frame(minHeight: Metrics.RowHeight.sidebar - 8)
            .listRowBackground(SidebarRowBackground(place: place, id: id, isDropTarget: isDropTarget))
            .onHover { isInside in
                guard let id, let hover else {
                    return
                }
                if isInside {
                    hover.row = id
                } else if hover.row == id {
                    hover.row = nil
                }
            }
    }

    /// A place's row is a row of the list's context menu
    /// (`SidebarContextMenu`); rows that aren't places carry their own
    /// menus.
    @ViewBuilder
    private func placeMenu(_ content: Content) -> some View {
        if let place {
            content.contextMenuRow(place)
        } else {
            content
        }
    }
}

/// A row's background: the soft accent under dragged commits it takes, the
/// sidebar's selection (`Palette.sidebarSelection`), the hover wash,
/// or nothing; and the ring while the row is the open context menu's
/// target.
struct SidebarRowBackground: View {
    let place: SidebarPlace?
    let id: AnyHashable?
    var isDropTarget = false
    @Environment(\.sidebarSelection) private var selection
    @Environment(SidebarHover.self) private var hover: SidebarHover?
    @Environment(ContextMenuTarget.self) private var contextMenuTarget: ContextMenuTarget?

    var body: some View {
        // Hover and a drop target fade in over 0.08 s and out over 0.15 s;
        // selection is instant.
        RoundedRectangle(cornerRadius: Metrics.Radius.row, style: .continuous)
            .fill(fill)
            .hoverMotion(isHovered || isDropTarget)
            .background {
                if isSelected, !isDropTarget {
                    SidebarSelectionFill()
                }
            }
            .contextTargetRing(isContextMenuTarget)
            .padding(.horizontal, Metrics.Sidebar.rowInset)
    }

    private var isContextMenuTarget: Bool {
        guard let place, let target = contextMenuTarget?.id else {
            return false
        }
        return target == AnyHashable(place)
    }

    private var isSelected: Bool {
        place != nil && place == selection
    }

    private var isHovered: Bool {
        id != nil && hover?.row == id
    }

    private var fill: Color {
        if isDropTarget {
            return Color(espalier: Palette.accentSoft)
        }
        if isSelected {
            // `SidebarSelectionFill`, under it.
            return .clear
        }
        if isHovered {
            return Color(espalier: Palette.hover)
        }
        return .clear
    }
}

/// Turns off the sidebar list's own selection drawing: rows draw their
/// selection themselves (`SidebarRowBackground`), and the list's highlight
/// (solid accent when focused) would draw over it and turn its text white.
///
/// It applies before the list first draws: the rows carry one
/// (`sidebarRow`), which finds the table it's in the moment a row joins it,
/// as the table lays its rows out; the one beside the list
/// (`sidebarListStyle()`) applies when it joins the window and whenever it
/// lays out, which comes before drawing. A run loop turn later is a frame
/// too late: the list's highlight can flash.
struct SidebarListStyler: NSViewRepresentable {
    /// Posted with a list's table as a row joins or leaves it: a row's
    /// styler goes in and out of the window with the row.
    static let rowsDidChange = Notification.Name("EspalierSidebarListRowsDidChange")

    /// Whether it looks beside itself for the table (beside the list), or
    /// only around itself (in a row: a row's search would cover every other
    /// row).
    var searchesBeside = true

    func makeNSView(context: Context) -> StylerView {
        StylerView(searchesBeside: searchesBeside)
    }

    func updateNSView(_ view: StylerView, context: Context) {
        view.apply()
    }

    final class StylerView: NSView {
        private let searchesBeside: Bool

        init(searchesBeside: Bool = true) {
            self.searchesBeside = searchesBeside
            super.init(frame: .zero)
        }

        @available(*, unavailable)
        required init?(coder: NSCoder) {
            fatalError("init(coder:) is not supported")
        }

        override func viewDidMoveToSuperview() {
            super.viewDidMoveToSuperview()
            apply()
        }

        override func viewWillMove(toWindow newWindow: NSWindow?) {
            super.viewWillMove(toWindow: newWindow)
            if newWindow == nil {
                postRowsDidChange()
            }
        }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            guard window != nil else {
                return
            }
            postRowsDidChange()
            if !apply() {
                // The table isn't there yet: the layout pass that makes it
                // runs before the first draw, and lays this view out too
                // (the next turn of the run loop is a last resort).
                needsLayout = true
                DispatchQueue.main.async { [weak self] in
                    self?.apply()
                }
            }
        }

        override func layout() {
            super.layout()
            apply()
        }

        /// A row's styler tells its table's height reader
        /// (`SidebarListHeight`) that a row came or went.
        private func postRowsDidChange() {
            guard !searchesBeside, let table = enclosingTable() else {
                return
            }
            NotificationCenter.default.post(name: SidebarListStyler.rowsDidChange, object: table)
        }

        /// Finds the list's table, the one this view is in or else the
        /// nearest one beside it, and turns its highlight off.
        ///
        /// - Returns: Whether there was a table.
        @discardableResult
        func apply() -> Bool {
            guard let table = enclosingTable() ?? (searchesBeside ? nearestTable() : nil) else {
                return false
            }
            if table.selectionHighlightStyle != .none {
                table.selectionHighlightStyle = .none
            }
            return true
        }

        /// The table this view is in (a row's), if any.
        private func enclosingTable() -> NSTableView? {
            var view = superview
            while let candidate = view {
                if let table = candidate as? NSTableView {
                    return table
                }
                view = candidate.superview
            }
            return nil
        }

        private func nearestTable() -> NSTableView? {
            var child: NSView = self
            while let parent = child.superview {
                for sibling in parent.subviews where sibling !== child {
                    if let table = Self.table(in: sibling) {
                        return table
                    }
                }
                if parent is NSSplitView {
                    return nil
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

// MARK: - Sections

/// A sidebar section whose expansion is remembered (UI state, not a
/// setting), or always expanded where sections don't collapse
/// (`sidebarSectionsCollapse`). Its header's chevron, before its label,
/// expands and collapses it, and the label has the section's count while
/// it's collapsed (`SidebarSectionHeader`); the list's own chevron isn't
/// used: on hover, it takes the header's trailing edge, where the header's
/// buttons are, and narrows the header, which moves them.
///
/// The rows follow the expansion the chevron sets, a state change it makes
/// inside its animation, so the list animates them in and out; the
/// remembered expansion, in user defaults, follows it once that change has
/// drawn. A change made elsewhere (the section in another window) reaches
/// the remembered expansion first, and the shown one follows it.
public struct SidebarSection<Content: View, Header: View>: View {
    private let content: Content
    private let header: Header
    @AppStorage private var rememberedExpansion: Bool
    /// The expansion the chevron set, or nil before it sets one.
    @State private var chosenExpansion: Bool?
    @Environment(\.sidebarSectionsCollapse) private var collapses

    /// - Parameters:
    ///   - id: Names the remembered expansion (`sidebar.expanded.<id>`).
    ///   - isExpandedByDefault: The expansion before the user changes it.
    public init(id: String, isExpandedByDefault: Bool = true, @ViewBuilder content: () -> Content, @ViewBuilder header: () -> Header) {
        self.content = content()
        self.header = header()
        _rememberedExpansion = AppStorage(wrappedValue: isExpandedByDefault, "sidebar.expanded.\(id)")
    }

    public var body: some View {
        if collapses {
            collapsibleSection
        } else {
            Section {
                content
            } header: {
                header
            }
            .collapsible(false)
        }
    }

    private var collapsibleSection: some View {
        Section {
            if chosenExpansion ?? rememberedExpansion {
                content
            }
        } header: {
            header
                .environment(\.sidebarSectionExpansion, expansion)
                .onChange(of: chosenExpansion) { _, chosen in
                    if let chosen {
                        rememberedExpansion = chosen
                    }
                }
                .onChange(of: rememberedExpansion) { _, remembered in
                    chosenExpansion = remembered
                }
        }
        .collapsible(false)
    }

    /// The expansion shown, which the chevron sets.
    private var expansion: Binding<Bool> {
        let chosen = $chosenExpansion
        let remembered = $rememberedExpansion
        return Binding(
            get: { chosen.wrappedValue ?? remembered.wrappedValue },
            set: { chosen.wrappedValue = $0 }
        )
    }
}

extension EnvironmentValues {
    /// Whether `SidebarSection`s collapse: in a rail's popover, which holds
    /// one section, they're always expanded, with no chevron or count.
    @Entry var sidebarSectionsCollapse = true
    /// The expansion of the `SidebarSection` whose header this is, which
    /// the header's chevron toggles.
    @Entry var sidebarSectionExpansion: Binding<Bool>?
    /// Whether this is in a sidebar section header's accessory, whose
    /// buttons are the sidebar's tertiary text.
    @Entry var isInSidebarSectionHeader = false
}

/// A section's header: the theme's section label and what trails it (New
/// Branch's plus). In a `SidebarSection` that collapses, a chevron is
/// always before the label, as the list's own chevron is before a
/// disclosure row's symbol, and the label has the section's count while
/// it's collapsed ("TAGS 3"), so a collapsed section doesn't read as empty.
/// Without a chevron, the label lines up with the rows' symbols. The count
/// fades in and out as the chevron turns, and rolls to a new value over 0.2
/// s as the section's rows change; the filter's changes draw at once.
struct SidebarSectionHeader<Accessory: View>: View {
    private let title: String
    private let count: Int?
    private let accessory: Accessory
    @Environment(\.sidebarSectionExpansion) private var expansion
    @Environment(\.motion) private var motion
    @Environment(WindowContext.self) private var context: WindowContext?

    /// - Parameter count: The section's rows, which the label shows while
    ///   the section is collapsed; nil shows none.
    init(_ title: String, count: Int? = nil, @ViewBuilder accessory: () -> Accessory = { EmptyView() }) {
        self.title = title
        self.count = count
        self.accessory = accessory()
    }

    var body: some View {
        HStack(spacing: Metrics.grid) {
            HStack(spacing: 0) {
                if let expansion {
                    SidebarSectionChevron(title: title, isExpanded: expansion)
                }
                SectionLabel(title, count: expansion?.wrappedValue == false ? count : nil)
                    .contentTransition(motion.animates ? .numericText() : .identity)
                    .transaction(value: context?.state.sidebarFilter) { $0.animation = nil }
                    .motion(Motion.kindChange, value: count)
            }
            Spacer(minLength: Metrics.grid)
            accessory
                .font(Typography.subheadline.weight(.semibold))
                .foregroundStyle(.sidebarText3)
                .environment(\.isInSidebarSectionHeader, true)
        }
        // The chevron in the list's disclosure column, else the label
        // aligned with the rows' symbols; what trails it, with their
        // trailing counts.
        .padding(.leading, expansion == nil ? Metrics.grid : 0)
        .padding(.trailing, Metrics.Sidebar.rowInset)
        .contentShape(Rectangle())
    }
}

/// A section header's chevron: right while the section is collapsed, down
/// while it's expanded, turning between them, in the list's disclosure
/// column (`Metrics.Sidebar.disclosureWidth`) before the label.
private struct SidebarSectionChevron: View {
    let title: String
    @Binding var isExpanded: Bool
    @Environment(\.motion) private var motion

    var body: some View {
        Button {
            withMotion(motion, isExpanded ? Motion.leave : Motion.arrive) {
                isExpanded.toggle()
            }
        } label: {
            // The list's own chevron's size and weight, centered where the
            // list centers its chevrons.
            Image(systemName: "chevron.right")
                .font(Typography.row.weight(.semibold))
                .imageScale(.small)
                .foregroundStyle(.sidebarText3)
                .rotationEffect(.degrees(isExpanded ? 90 : 0))
                .motion(Motion.leave, value: isExpanded)
                .frame(width: Metrics.Sidebar.disclosureChevronWidth, height: Metrics.Sidebar.glyphSize)
                .contentShape(Rectangle())
        }
        .buttonStyle(.bare(.rounded(Metrics.Radius.small)))
        .frame(width: Metrics.Sidebar.disclosureWidth, alignment: .leading)
        .tooltip(isExpanded ? "Collapse" : "Expand")
        .accessibilityLabel(isExpanded ? "Collapse \(title)" : "Expand \(title)")
    }
}

/// A header's symbol button (New Branch's plus, the More menu, the
/// repository popover's New Worktree…), with the focus ring around it.
struct SidebarHeaderButtonStyle: PrimitiveButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        FocusRingButton(configuration: configuration, style: SidebarHeaderButtonDrawing())
    }
}

/// Draws a header's symbol button.
private struct SidebarHeaderButtonDrawing: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        SidebarHeaderButtonBody(label: configuration.label, isPressed: configuration.isPressed)
    }
}

private struct SidebarHeaderButtonBody<Label: View>: View {
    let label: Label
    let isPressed: Bool
    /// Whether the button has keyboard focus.
    @Environment(\.isFocused) private var isFocused
    @Environment(\.isInSidebarSectionHeader) private var isInSidebarSectionHeader
    @Environment(\.isMenuOpen) private var isMenuOpen

    var body: some View {
        let isPressed = self.isPressed || isMenuOpen
        label
            .font(Typography.subheadline.weight(.semibold))
            .foregroundStyle(isInSidebarSectionHeader ? Color.sidebarText3 : Color.text3)
            .frame(width: Metrics.Sidebar.glyphSize, height: Metrics.Sidebar.glyphSize)
            .contentShape(Rectangle())
            .opacity(isPressed ? 0.6 : 1)
            .pressMotion(isPressed)
            .focusRing(isFocused, in: RoundedRectangle(cornerRadius: Metrics.Radius.small, style: .continuous), outset: 0)
    }
}

/// The filter at the bottom of the sidebar (⌥⌘J), and at the top of a rail
/// popover: narrows every section but the first.
struct SidebarFilterField: View {
    /// What it's on: the `sidebar` color, or a rail popover's
    /// `background`.
    var surface: NSColor = Palette.sidebar
    @Environment(WindowContext.self) private var context

    var body: some View {
        @Bindable var state = context.state
        CapsuleSearchField(
            "Filter",
            text: $state.sidebarFilter,
            systemImage: "line.3.horizontal.decrease",
            focusRequest: $state.isSidebarFilterFocused
        )
        .controlSize(.regular)
        .environment(\.searchFieldIsRaised, PaneCards.floats)
        .padding(.horizontal, Metrics.Sidebar.rowInset)
        .padding(.vertical, Metrics.insetSmall)
        .background(Color(espalier: surface))
        .announcesFilterResults(state.sidebarFilter) { [context] in
            Self.resultCount(in: context)
        }
    }

    /// The rows the filter leaves in the sections it narrows, as each
    /// section lists them (collapsed sections included).
    static func resultCount(in context: WindowContext) -> Int {
        let app = context.app
        guard app.loadState == .ready, let repository = context.repository, repository.isUsable else {
            return 0
        }
        let filter = context.state.sidebarFilter
        let state = repository.gitState
        let branches = BranchesSectionContent.make(repository, upstreamStates: repository.branches.upstreamStates, filter: filter)
        var count = branches.allRows.count + (branches.detachedSHA == nil ? 0 : 1) + (branches.unbornBranch == nil ? 0 : 1)
        if PullRequestsSection.isShown(repository, accounts: app.accounts) {
            count += PullRequestsSection.filtered(repository.gitHub.openPullRequests, by: filter).count
        }
        if let tags = state.tags {
            count += TagRowContent.rows(tags: Array(tags.keys), tagsToPush: [], filter: filter).count
        }
        count += StashRowContent.rows(repository, filter: filter).count
        return count
    }
}

/// A button that runs an action, titled and enabled as its menu item is.
public struct ActionButton: View {
    private let action: ActionID
    private let title: String?
    @Environment(WindowContext.self) private var context

    public init(_ action: ActionID, title: String? = nil) {
        self.action = action
        self.title = title
    }

    public var body: some View {
        Button(title ?? context.actions.title(for: action)) {
            context.actions.perform(action)
        }
        .disabled(!context.actions.canPerform(action))
    }
}
