// The sidebar. It shows the current repository's places you select
// (Changes, History, branches, pull requests, tags, stashes), and a filter
// field at the bottom, as in Xcode's navigators; the repository popover
// switches repositories and worktrees. Each section after the first is a
// feature's view. After a switch, the repository's sections keep showing
// the previous repository until the selected one has loaded
// (`SidebarSectionsHold`).
//
// The sidebar is flat: the `sidebar` color with a hairline on its trailing
// edge, uppercase section labels (no counts), rows 28 high with radius 9,
// and the selected item in a neutral wash (`Palette.sidebarSelection`) in
// medium weight with its symbol in the accent, which keeps the sidebar
// neutral (the list's own selection drawing is off before it first draws:
// `SidebarListStyler`). Selected branch, tag, stash, and pull request rows
// are medium too (`isSidebarRowSelected`).

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

    /// Double-click or Return on a place: check out a branch or pull
    /// request, restore the current branch's stash.
    private func primaryAction(_ places: Set<SidebarPlace>) {
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
        case .stash(let stashBranch):
            if stashBranch == repository.gitState.tip.branch?.name {
                context.actions.perform(.restoreStash(branch: stashBranch))
            }
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
            case .stash(let stashBranch):
                StashContextMenu.content(branch: stashBranch, context: context)
            }
        }
    }
}

/// What the Changes row shows.
nonisolated struct ChangesPlaceRowContent: Sendable, Equatable {
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
/// exist.
struct ChangesPlaceRow: View {
    let content: ChangesPlaceRowContent
    var isSelected = false

    var body: some View {
        SidebarRowLabel("Changes", systemImage: "plus.forwardslash.minus", isSelected: isSelected) {
            if content.hasConflicts {
                WarningGlyph()
                    .tooltip("Conflicts")
            } else if let badge = content.badge {
                Text(badge)
                    .font(Typography.count)
                    .foregroundStyle(.sidebarRowCount(isSelected: isSelected))
            }
        }
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
    private let trailing: Trailing
    @Environment(\.isSidebarRowSelected) private var isRowSelected

    /// - Parameters:
    ///   - isSelected: Draws the row as selected; a row that selects a
    ///     place (`sidebarRow(_:)`) is also selected while its place is.
    ///   - isEmphasized: Semibold, as the current branch is.
    init(_ title: String, systemImage: String, isSelected: Bool = false, isEmphasized: Bool = false, @ViewBuilder trailing: () -> Trailing = { EmptyView() }) {
        self.title = title
        self.systemImage = systemImage
        self.isSelected = isSelected
        self.isEmphasized = isEmphasized
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
                .truncationMode(.middle)
            Spacer(minLength: Metrics.grid)
            trailing
        }
        .accessibilityElement(children: .combine)
    }
}

/// A sidebar row title's weight: bold while the row is selected in a theme
/// whose selection is bold (`Theme.sidebarSelectionIsBold`); semibold for
/// the current branch and its pull request (the one way the sidebar marks
/// what's current); medium while the row is selected; regular otherwise.
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
    /// The sidebar's selected place, which its row draws in the neutral wash.
    @Entry var sidebarSelection: SidebarPlace?
    /// Whether the row this is in selects the sidebar's selected place
    /// (`sidebarRow(_:)` sets it): its title is medium and its symbol in
    /// the accent.
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
}

extension View {
    /// A sidebar row: 28 high, its background the selection's neutral wash
    /// or the hover wash, inset 10 from the sidebar's edges with radius 9.
    ///
    /// - Parameters:
    ///   - place: The place the row selects, if any.
    ///   - id: What identifies a row that isn't a place, for the hover.
    ///   - isDropTarget: Dragged commits are over the row and it takes
    ///     them: the row fills with the soft accent, in its own shape.
    func sidebarRow(_ place: SidebarPlace?, id: AnyHashable? = nil, isDropTarget: Bool = false) -> some View {
        modifier(SidebarRowModifier(place: place, id: id ?? place.map(AnyHashable.init), isDropTarget: isDropTarget))
    }

    /// The sidebar's list: the sidebar style, opaque on the `sidebar`
    /// color, small rows, and the list's own selection drawing off (the
    /// rows draw theirs).
    func sidebarListStyle() -> some View {
        self
            .listStyle(.sidebar)
            .scrollContentBackground(.hidden)
            .environment(\.sidebarRowSize, .small)
            .background {
                SidebarListStyler()
                    .frame(width: 0, height: 0)
                    .accessibilityHidden(true)
            }
            .background(Color(espalier: Palette.sidebar))
            .modifier(SidebarHoverProvider())
    }
}

/// Gives the list's rows their shared hover state.
private struct SidebarHoverProvider: ViewModifier {
    @State private var hover = SidebarHover()

    func body(content: Content) -> some View {
        content.environment(hover)
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
/// selection's neutral wash (`Palette.sidebarSelection`), the hover wash,
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

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            guard window != nil else {
                return
            }
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
/// setting). Its header's chevron expands and collapses it
/// (`SidebarSectionHeader`), not the list's: on hover, the list's takes the
/// header's trailing edge, where the header's buttons are, and narrows the
/// header, which moves them.
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

    /// - Parameters:
    ///   - id: Names the remembered expansion (`sidebar.expanded.<id>`).
    ///   - isExpandedByDefault: The expansion before the user changes it.
    public init(id: String, isExpandedByDefault: Bool = true, @ViewBuilder content: () -> Content, @ViewBuilder header: () -> Header) {
        self.content = content()
        self.header = header()
        _rememberedExpansion = AppStorage(wrappedValue: isExpandedByDefault, "sidebar.expanded.\(id)")
    }

    public var body: some View {
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
    /// The expansion of the `SidebarSection` whose header this is, which
    /// the header's chevron toggles.
    @Entry var sidebarSectionExpansion: Binding<Bool>?
    /// Whether this is in a sidebar section header's accessory, whose
    /// buttons are the sidebar's tertiary text.
    @Entry var isInSidebarSectionHeader = false
}

/// A section's header: the uppercase label, with no count, and what
/// trails it (New Branch's plus). In a `SidebarSection`, a chevron shows
/// while the pointer is on the header, just before what trails it, in the
/// space the label leaves, so nothing in the header moves.
struct SidebarSectionHeader<Accessory: View>: View {
    private let title: String
    private let accessory: Accessory
    @Environment(\.sidebarSectionExpansion) private var expansion
    @State private var isHovered = false

    init(_ title: String, @ViewBuilder accessory: () -> Accessory = { EmptyView() }) {
        self.title = title
        self.accessory = accessory()
    }

    var body: some View {
        HStack(spacing: Metrics.grid) {
            SectionLabel(title)
            Spacer(minLength: Metrics.grid)
            if let expansion {
                SidebarSectionChevron(title: title, isExpanded: expansion, isHeaderHovered: isHovered)
            }
            accessory
                .font(Typography.subheadline.weight(.semibold))
                .foregroundStyle(.sidebarText3)
                .environment(\.isInSidebarSectionHeader, true)
        }
        // Aligned with the rows' symbols and their trailing counts.
        .padding(.leading, Metrics.grid)
        .padding(.trailing, Metrics.Sidebar.rowInset)
        .contentShape(Rectangle())
        .onHover { isHovered = $0 }
    }
}

/// A section header's chevron: right while the section is collapsed, down
/// while it's expanded, turning between them. It shows while the pointer is
/// on the header or it has keyboard focus.
private struct SidebarSectionChevron: View {
    let title: String
    @Binding var isExpanded: Bool
    let isHeaderHovered: Bool
    @Environment(\.motion) private var motion
    @FocusState private var isFocused: Bool

    var body: some View {
        Button {
            withMotion(motion, isExpanded ? Motion.leave : Motion.arrive) {
                isExpanded.toggle()
            }
        } label: {
            // The list's own chevron's size and weight. Hidden by color,
            // not opacity, so VoiceOver still finds it.
            Image(systemName: "chevron.right")
                .font(Typography.row.weight(.semibold))
                .imageScale(.small)
                .foregroundStyle(isShown ? Color.sidebarText3 : Color.clear)
                .rotationEffect(.degrees(isExpanded ? 90 : 0))
                .motion(Motion.leave, value: isExpanded)
                .hoverMotion(isShown)
        }
        .buttonStyle(SidebarHeaderButtonStyle())
        .focused($isFocused)
        .tooltip(isExpanded ? "Collapse" : "Expand")
        .accessibilityLabel(isExpanded ? "Collapse \(title)" : "Expand \(title)")
    }

    private var isShown: Bool {
        isHeaderHovered || isFocused
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

    var body: some View {
        label
            .font(Typography.subheadline.weight(.semibold))
            .foregroundStyle(isInSidebarSectionHeader ? Color.sidebarText3 : Color.text3)
            .frame(width: Metrics.Sidebar.badgeSize, height: Metrics.Sidebar.badgeSize)
            .contentShape(Rectangle())
            .opacity(isPressed ? 0.6 : 1)
            .focusRing(isFocused, in: RoundedRectangle(cornerRadius: Metrics.Radius.small, style: .continuous), outset: 0)
    }
}

/// The filter at the bottom of the sidebar (⌥⌘J): narrows every section
/// but the first.
struct SidebarFilterField: View {
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
        .background(Color(espalier: Palette.sidebar))
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
