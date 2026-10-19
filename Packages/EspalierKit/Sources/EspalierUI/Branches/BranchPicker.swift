// Ported in part from desktop/app/src/ui/branches/branch-list.tsx
//
// The branch popover, the Integrate and Cherry-pick sheets, Go to Commit,
// and Preview Pull Request's base-branch picker use the picker.

import EspalierCore
import EspalierSupport
import GitKit
import SwiftUI

// MARK: - Content

/// The branch list's groups, filtered.
nonisolated public struct BranchPickerContent: Sendable, Equatable {
    /// A group: "Default Branch", "Recent Branches", "Other Branches", or
    /// "Remote Branches".
    public struct Group: Sendable, Equatable, Identifiable {
        public var title: String
        public var branches: [Branch]

        public var id: String {
            title
        }
    }

    public var groups: [Group]
    /// The filter's text, trimmed.
    public var filter: String

    /// Whether nothing matches.
    public var isEmpty: Bool {
        groups.allSatisfy(\.branches.isEmpty)
    }

    /// The branches in list order.
    public var branches: [Branch] {
        groups.flatMap(\.branches)
    }

    /// The groups for `filter`, with the remote branches in their own group
    /// at the end, without the branches of Espalier's fork remotes
    /// (`forkRemoteNames`). With `candidates`, only those branches are listed: the
    /// default and recent branches among them in their groups, the others
    /// after.
    public static func make(
        branches: [Branch],
        defaultBranch: Branch?,
        recentBranches: [Branch],
        forkRemoteNames: Set<ExactString>,
        includesRemoteBranches: Bool,
        filter: String,
        candidates: [Branch]? = nil
    ) -> BranchPickerContent {
        var branches = branches
        var defaultBranch = defaultBranch
        var recentBranches = recentBranches
        if let candidates {
            let refs = candidates.map(\.ref).exactSet
            branches = candidates
            defaultBranch = defaultBranch.flatMap { refs.contains(ExactString($0.ref)) ? $0 : nil }
            recentBranches = recentBranches.filter { refs.contains(ExactString($0.ref)) }
        }
        let filter = filter.trimmingCharacters(in: .whitespaces)
        var groups: [Group] = []
        for group in groupBranches(defaultBranch, nil, branches, recentBranches, forkRemoteNames: forkRemoteNames) {
            switch group.identifier {
            case .defaultBranch:
                groups.append(Group(title: "Default Branch", branches: group.branches.filter { includesRemoteBranches || $0.type == .local }))
            case .recent:
                groups.append(Group(title: "Recent Branches", branches: group.branches.filter { includesRemoteBranches || $0.type == .local }))
            case .other:
                groups.append(Group(title: "Other Branches", branches: group.branches.filter { $0.type == .local }))
                if includesRemoteBranches {
                    groups.append(Group(title: "Remote Branches", branches: group.branches.filter { $0.type == .remote }))
                }
            }
        }
        if !filter.isEmpty {
            groups = groups.map { group in
                let scored = group.branches.enumerated().compactMap { index, branch -> (score: Int, index: Int, branch: Branch)? in
                    BranchFilter.score(branch.name, filter).map { ($0, index, branch) }
                }
                let ordered = scored.sorted { $0.score != $1.score ? $0.score > $1.score : $0.index < $1.index }
                return Group(title: group.title, branches: ordered.map(\.branch))
            }
        }
        return BranchPickerContent(groups: groups.filter { !$0.branches.isEmpty }, filter: filter)
    }
}

/// How well a branch name matches a filter: prefix, word start, anywhere,
/// or the filter's characters in order.
nonisolated enum BranchFilter {
    /// Higher is better; nil when it doesn't match.
    static func score(_ name: String, _ filter: String) -> Int? {
        guard !filter.isEmpty else {
            return 0
        }
        if let score = asciiScore(name, filter) {
            return score
        }
        let options: String.CompareOptions = [.caseInsensitive, .diacriticInsensitive]
        if name.range(of: filter, options: options.union(.anchored)) != nil {
            return 4
        }
        if let range = name.range(of: filter, options: options) {
            let previous = name[name.index(before: range.lowerBound)]
            return previous == "/" || previous == "-" || previous == "_" || previous == "." ? 3 : 2
        }
        // The filter's characters in order.
        var remaining = filter.lowercased()[...]
        for character in name.lowercased() where character == remaining.first {
            remaining = remaining.dropFirst()
            if remaining.isEmpty {
                return 1
            }
        }
        return nil
    }

    /// `score` for a name and a filter in ASCII without a carriage return,
    /// on bytes: there every character is one byte (a carriage return and a
    /// line feed would be one), folding case and diacritics only lowercases
    /// letters, and so does `lowercased()`. The picker scores every branch
    /// on every keystroke, and `range(of:options:)` transforms each
    /// character. Nil when either has other characters; `.some(nil)` when
    /// the name doesn't match.
    static func asciiScore(_ name: String, _ filter: String) -> Int?? {
        var name = name
        var filter = filter
        return name.withUTF8 { name -> Int?? in
            filter.withUTF8 { filter -> Int?? in
                func isPlain(_ bytes: UnsafeBufferPointer<UInt8>) -> Bool {
                    bytes.allSatisfy { $0 < 0x80 && $0 != 0x0D }
                }
                guard isPlain(name), isPlain(filter) else {
                    return nil
                }
                func lower(_ byte: UInt8) -> UInt8 {
                    byte >= 0x41 && byte <= 0x5A ? byte | 0x20 : byte
                }
                func matches(at start: Int) -> Bool {
                    for offset in 0..<filter.count where lower(name[start + offset]) != lower(filter[offset]) {
                        return false
                    }
                    return true
                }
                if filter.count <= name.count {
                    if matches(at: 0) {
                        return 4
                    }
                    for start in 1..<(name.count - filter.count + 1) where matches(at: start) {
                        let previous = name[start - 1]
                        let isWordStart = previous == UInt8(ascii: "/") || previous == UInt8(ascii: "-")
                            || previous == UInt8(ascii: "_") || previous == UInt8(ascii: ".")
                        return isWordStart ? 3 : 2
                    }
                }
                // The filter's characters in order.
                var next = 0
                for byte in name where lower(byte) == lower(filter[next]) {
                    next += 1
                    if next == filter.count {
                        return 1
                    }
                }
                return .some(nil)
            }
        }
    }
}

// MARK: - The picker

/// A filterable list of a repository's branches, grouped Default Branch,
/// Recent Branches, Other Branches, then Remote Branches.
public struct BranchPicker: View {
    private let repository: RepositoryModel
    @Binding private var selection: Branch?
    private let includesRemoteBranches: Bool
    private let onActivate: ((Branch) -> Void)?
    private let onCreateBranch: ((String) -> Void)?
    private let onFilterChange: ((String) -> Void)?
    private let candidates: [Branch]?
    private let comparesWithCurrentBranch: Bool
    private let style: BranchPickerStyle
    private let filterAccessory: AnyView?
    private let branchMenu: ((Branch) -> MenuContent)?
    @State private var filter = ""
    @State private var dates: [String: Date] = [:]

    /// - Parameters:
    ///   - repository: Whose branches.
    ///   - selection: The chosen branch (in the popover, the highlighted
    ///     one).
    ///   - includesRemoteBranches: Whether remote-only branches are listed.
    ///   - onActivate: Return, or a double-click on a branch (a click in the
    ///     popover).
    ///   - onCreateBranch: "Create New Branch" for a filter that matches
    ///     nothing, with the filter's text; nil offers none.
    ///   - onFilterChange: The filter's text as it changes.
    ///   - candidates: The only branches to list (a pull request's possible
    ///     bases, say), grouped as usual; nil lists the repository's
    ///     branches.
    ///   - comparesWithCurrentBranch: Whether each row shows how far the
    ///     current branch is behind and ahead of it (Compare's list).
    ///   - style: The branch popover's, else a capsule filter over a
    ///     bordered list (inside sheets).
    ///   - filterAccessory: What sits beside the filter (the popover's New
    ///     Branch…).
    ///   - branchMenu: A branch's context menu, in the popover; nil gives
    ///     the rows none.
    public init(
        repository: RepositoryModel,
        selection: Binding<Branch?>,
        includesRemoteBranches: Bool = true,
        onActivate: ((Branch) -> Void)? = nil,
        onCreateBranch: ((String) -> Void)? = nil,
        onFilterChange: ((String) -> Void)? = nil,
        candidates: [Branch]? = nil,
        comparesWithCurrentBranch: Bool = false,
        style: BranchPickerStyle = .embedded,
        filterAccessory: AnyView? = nil,
        branchMenu: ((Branch) -> MenuContent)? = nil
    ) {
        self.style = style
        self.filterAccessory = filterAccessory
        self.branchMenu = branchMenu
        self.comparesWithCurrentBranch = comparesWithCurrentBranch
        self.repository = repository
        _selection = selection
        self.includesRemoteBranches = includesRemoteBranches
        self.onActivate = onActivate
        self.onCreateBranch = onCreateBranch
        self.onFilterChange = onFilterChange
        self.candidates = candidates
    }

    public var body: some View {
        let state = repository.gitState
        let listed = candidates ?? state.branches.all
        let content = UISignposts.measure(.branchPickerFilter) {
            BranchPickerContent.make(
                branches: state.branches.all,
                defaultBranch: state.branches.defaultBranch,
                recentBranches: state.branches.recent,
                forkRemoteNames: state.remotes.forkRemoteNames,
                includesRemoteBranches: includesRemoteBranches,
                filter: filter,
                candidates: candidates
            )
        }
        BranchPickerList(
            content: content,
            currentBranch: state.tip.branch?.name,
            dates: dates,
            filter: $filter,
            selection: $selection,
            onActivate: onActivate,
            onCreateBranch: onCreateBranch,
            comparison: comparesWithCurrentBranch ? BranchComparison.make(repository) : nil,
            style: style,
            dotColor: { [repository] branch in
                BranchPicker.dotColor(of: branch, in: repository)
            },
            filterAccessory: filterAccessory,
            branchMenu: branchMenu
        )
        .task(id: listed.map(\.tip.sha)) {
            dates = await repository.branches.tipDates(for: listed)
        }
        .onChange(of: filter) {
            onFilterChange?(filter)
            // Keep a visible branch selected while filtering.
            if let selected = selection, !content.branches.contains(where: { $0.ref == selected.ref }) {
                selection = content.branches.first
            } else if selection == nil, !content.filter.isEmpty {
                selection = content.branches.first
            }
        }
    }

    /// A branch's dot: its color in the sidebar and the graph.
    static func dotColor(of branch: Branch, in repository: RepositoryModel) -> NSColor {
        let state = repository.gitState
        let row = BranchRowContent(
            ref: branch.ref,
            name: branch.name,
            isCurrent: branch.ref == state.tip.branch?.ref,
            isRemote: branch.type == .remote,
            tipSHA: branch.tip.sha,
            isDefault: branch.ref == state.branches.defaultBranch?.ref
        )
        return BranchSidebarRow.dotColor(row, in: repository)
    }
}

/// How a branch picker looks.
nonisolated public enum BranchPickerStyle: Sendable, Equatable {
    /// The branch popover: the filter across the top, a hairline under it,
    /// and rows a click activates.
    case popover
    /// Inside a sheet: the filter over a bordered list whose rows a click
    /// selects.
    case embedded
}

/// The picker's look, value-driven: the filter field, the grouped list,
/// and the empty state. Rows draw their own selection in the soft accent
/// (the list's own selection drawing is off).
struct BranchPickerList: View {
    let content: BranchPickerContent
    let currentBranch: String?
    let dates: [String: Date]
    @Binding var filter: String
    @Binding var selection: Branch?
    var onActivate: ((Branch) -> Void)?
    var onCreateBranch: ((String) -> Void)?
    /// How each branch compares with the current one, when the rows show
    /// it.
    var comparison: BranchComparison?
    var style: BranchPickerStyle
    /// A branch's dot color; nil uses its color by name.
    var dotColor: ((Branch) -> NSColor)?
    /// What sits beside the filter.
    var filterAccessory: AnyView?
    /// A branch's context menu, in the popover.
    var branchMenu: ((Branch) -> MenuContent)?
    @FocusState private var isFilterFocused: Bool
    /// The branch the pointer highlighted last in the popover, which the
    /// list doesn't scroll to.
    @State private var hoveredRef: String?

    init(
        content: BranchPickerContent,
        currentBranch: String?,
        dates: [String: Date],
        filter: Binding<String>,
        selection: Binding<Branch?>,
        onActivate: ((Branch) -> Void)? = nil,
        onCreateBranch: ((String) -> Void)? = nil,
        comparison: BranchComparison? = nil,
        style: BranchPickerStyle = .embedded,
        dotColor: ((Branch) -> NSColor)? = nil,
        filterAccessory: AnyView? = nil,
        branchMenu: ((Branch) -> MenuContent)? = nil
    ) {
        self.content = content
        self.currentBranch = currentBranch
        self.dates = dates
        _filter = filter
        _selection = selection
        self.onActivate = onActivate
        self.onCreateBranch = onCreateBranch
        self.comparison = comparison
        self.style = style
        self.dotColor = dotColor
        self.filterAccessory = filterAccessory
        self.branchMenu = branchMenu
    }

    var body: some View {
        VStack(spacing: style == .popover ? 0 : Metrics.insetSmall) {
            HStack(spacing: Metrics.insetSmall) {
                filterField
                filterAccessory
            }
            .padding(style == .popover ? Metrics.insetMedium : 0)
            if style == .popover {
                Hairline()
            }
            Group {
                if content.isEmpty {
                    noBranches
                } else {
                    switch style {
                    case .popover: popoverList
                    case .embedded: embeddedList
                    }
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .modifier(EmbeddedListChrome(isEmbedded: style == .embedded))
        }
        .announcesFilterResults(filter) { [content] in
            content.branches.count
        }
        .onAppear {
            isFilterFocused = true
        }
    }

    /// The filter: the arrow keys move the highlight, and Return activates
    /// it or, matching nothing, creates the branch.
    private var filterField: some View {
        TextField("Filter", text: $filter, prompt: Text("Filter").fieldPrompt())
            .textFieldStyle(.capsule(systemImage: "magnifyingglass"))
            .focused($isFilterFocused)
            .onKeyPress(.downArrow) {
                moveSelection(by: 1)
                return .handled
            }
            .onKeyPress(.upArrow) {
                moveSelection(by: -1)
                return .handled
            }
            .onSubmit {
                if let selection {
                    onActivate?(selection)
                } else if content.isEmpty, !content.filter.isEmpty {
                    onCreateBranch?(content.filter)
                }
            }
    }

    /// A branch's row, with how the current branch compares with it where
    /// the list shows that.
    @ViewBuilder
    private func row(_ branch: Branch) -> some View {
        if let comparison, branch.name != currentBranch {
            ComparedBranchPickerRow(branch: branch, date: dates[branch.tip.sha], comparison: comparison, dotColor: dotColor?(branch))
        } else {
            BranchPickerRow(
                branch: branch,
                isCurrent: branch.name == currentBranch,
                date: dates[branch.tip.sha],
                dotColor: dotColor?(branch)
            )
        }
    }

    /// The popover's rows, as a menu's: a click activates a branch, the
    /// pointer highlights the row it's on, and a right-click opens the
    /// branch's context menu. A list that fits doesn't scroll, and the
    /// highlight scrolls into view unless the pointer put it there.
    private var popoverList: some View {
        ScrollViewReader { proxy in
            OverflowScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    ForEach(content.groups) { group in
                        ListGroupLabel(group.title)
                            .padding(.horizontal, Metrics.ListRow.inset)
                        ForEach(group.branches, id: \.ref) { branch in
                            popoverRow(branch)
                        }
                    }
                }
                .padding(.bottom, Metrics.ListRow.inset)
            }
            .onChange(of: selection?.ref) {
                if let ref = selection?.ref, ref != hoveredRef {
                    proxy.scrollTo(ref)
                }
            }
            .onChange(of: filter) {
                hoveredRef = nil
            }
            .onAppear {
                if let ref = selection?.ref {
                    proxy.scrollTo(ref)
                }
            }
        }
    }

    private func popoverRow(_ branch: Branch) -> some View {
        let isHighlighted = branch.ref == selection?.ref
        return Button {
            onActivate?(branch)
        } label: {
            row(branch)
                .selectableRow(isSelected: isHighlighted)
        }
        .buttonStyle(.bare(.rounded(Metrics.Radius.row)))
        .contextMenuCard { [branchMenu] in
            if let branchMenu {
                branchMenu(branch)
            }
        }
        .padding(.horizontal, Metrics.ListRow.inset)
        .padding(.vertical, 1)
        .id(branch.ref)
        .onHover { isHovering in
            if isHovering {
                hoveredRef = branch.ref
                selection = branch
            }
        }
        .accessibilityAddTraits(isHighlighted ? .isSelected : [])
    }

    /// A sheet's list: a click selects a branch, Return or a double-click
    /// activates it.
    private var embeddedList: some View {
        ScrollViewReader { proxy in
            List(selection: selectedRef) {
                ForEach(content.groups) { group in
                    // The group's label is a row of its own, not a section
                    // header: a plain list's floating header draws a line.
                    ListGroupLabel(group.title)
                        .listRowInsets(EdgeInsets(top: 0, leading: Metrics.ListRow.inset, bottom: 0, trailing: Metrics.ListRow.inset))
                        .listRowSeparator(.hidden)
                        .listRowBackground(Color.clear)
                    ForEach(group.branches, id: \.ref) { branch in
                        row(branch)
                            .selectableRow(isSelected: branch.ref == selection?.ref)
                            .tag(branch.ref)
                            .id(branch.ref)
                            .listRowInsets(EdgeInsets(top: 1, leading: Metrics.ListRow.inset, bottom: 1, trailing: Metrics.ListRow.inset))
                            .listRowSeparator(.hidden)
                            .listRowBackground(Color.clear)
                    }
                }
            }
            .listStyle(.plain)
            .scrollContentBackground(.hidden)
            // The rows draw the selection; the table's own is off.
            .rowsDrawSelection()
            .unbouncedList()
            .listPrimaryAction(forSelectionType: String.self) { refs in
                if let ref = refs.first, let branch = content.branches.first(where: { $0.ref == ref }) {
                    onActivate?(branch)
                }
            }
            .onChange(of: selection?.ref) {
                if let ref = selection?.ref {
                    proxy.scrollTo(ref)
                }
            }
        }
    }

    /// "No Matching Branches" for a filter, with Create New Branch… when the
    /// picker offers it; "No Branches" without one.
    private var noBranches: some View {
        let isFiltered = !content.filter.isEmpty
        let offersCreate = onCreateBranch != nil && isFiltered
        return CenteredMessage(
            isFiltered ? "No Matching Branches" : "No Branches",
            systemImage: isFiltered ? "magnifyingglass" : "arrow.trianglehead.branch",
            description: offersCreate ? "Do you want to create a new branch instead?" : nil
        ) {
            if offersCreate {
                Button("Create New Branch…") {
                    onCreateBranch?(content.filter)
                }
                .buttonStyle(.quiet)
            }
        }
        .fillingSpace()
    }

    private var selectedRef: Binding<String?> {
        Binding(
            get: { selection?.ref },
            set: { ref in
                selection = content.branches.first { $0.ref == ref }
            }
        )
    }

    private func moveSelection(by offset: Int) {
        let branches = content.branches
        guard !branches.isEmpty else {
            return
        }
        hoveredRef = nil
        guard let selection, let index = branches.firstIndex(where: { $0.ref == selection.ref }) else {
            self.selection = offset > 0 ? branches.first : branches.last
            return
        }
        self.selection = branches[min(max(index + offset, 0), branches.count - 1)]
    }
}

/// Inside a sheet, the list sits in a rounded border.
private struct EmbeddedListChrome: ViewModifier {
    let isEmbedded: Bool

    func body(content: Content) -> some View {
        if isEmbedded {
            content
                .sheetListCard()
        } else {
            content
        }
    }
}

/// A branch in the picker: its dot, its name (the current one semibold),
/// how the current branch compares with it (Compare's list), and the date
/// of its last commit.
struct BranchPickerRow: View {
    let branch: Branch
    let isCurrent: Bool
    let date: Date?
    var counts: BranchComparisonCounts?
    /// The dot's color; nil uses its color by name.
    var dotColor: NSColor?
    @Environment(\.numberFormat) private var numberFormat

    var body: some View {
        HStack(spacing: Metrics.insetSmall) {
            Circle()
                .fill(Color(nsColor: dotColor ?? TrackPalette.color(forBranch: branch.name, isCurrent: isCurrent, isDefault: false)))
                .frame(width: Metrics.Sidebar.dotSize, height: Metrics.Sidebar.dotSize)
                .accessibilityHidden(true)
            Text(branch.name)
                .font(isCurrent ? Typography.row.weight(.semibold) : Typography.row)
                .foregroundStyle(.text)
                .lineLimit(1)
                .truncationMode(.middle)
                .accessibilityLabel(isCurrent ? "\(branch.name), current branch" : branch.name)
            Spacer(minLength: Metrics.insetSmall)
            if let counts {
                Text(counts.text(numberFormat))
                    .font(Typography.secondaryCount)
                    .foregroundStyle(.text2)
                    .lineLimit(1)
                    .fixedSize()
                    .tooltip(counts.description(numberFormat))
                    .accessibilityLabel(counts.description(numberFormat))
            }
            if let date {
                RelativeTimeText(date)
                    .font(Typography.meta)
                    .foregroundStyle(.text3)
                    .lineLimit(1)
            }
        }
        .tooltip(branch.name)
    }
}

// MARK: - Comparing with the current branch

/// How far the current branch is behind and ahead of a branch: "↓3 ↑2", as
/// the comparison's Ahead and Behind count them.
nonisolated struct BranchComparisonCounts: Sendable, Equatable {
    /// The commits only the listed branch has.
    var behind: Int
    /// The commits only the current branch has.
    var ahead: Int
    var currentBranch: String

    init(_ aheadBehind: AheadBehind, currentBranch: String) {
        behind = aheadBehind.behind
        ahead = aheadBehind.ahead
        self.currentBranch = currentBranch
    }

    /// "↓3 ↑2", in `numberFormat`.
    func text(_ numberFormat: NumberFormat) -> String {
        "↓\(formatCount(behind, numberFormat)) ↑\(formatCount(ahead, numberFormat))"
    }

    /// What the tooltip and VoiceOver say, counts in `numberFormat`.
    func description(_ numberFormat: NumberFormat) -> String {
        "\(currentBranch) is \(commits(behind, numberFormat)) behind and \(commits(ahead, numberFormat)) ahead"
    }

    private func commits(_ count: Int, _ numberFormat: NumberFormat) -> String {
        count == 1 ? "1 commit" : "\(formatCount(count, numberFormat)) commits"
    }
}

/// Where a picker's rows get how the current branch compares with each
/// branch: `BranchesModel`'s ahead/behind cache, filled one comparison at a
/// time off the main actor, for the rows on screen.
struct BranchComparison {
    /// The current branch's name and tip, which the counts are relative to.
    var currentBranch: String
    var from: String
    /// The counts already known, for a row's first paint.
    var cached: (Branch) -> AheadBehind?
    /// Counts the commits (nil when cancelled or when git failed).
    var load: (Branch) async -> AheadBehind?

    /// The comparison with `repository`'s current branch; nil when HEAD
    /// isn't on a branch.
    static func make(_ repository: RepositoryModel) -> BranchComparison? {
        guard let current = repository.gitState.tip.branch else {
            return nil
        }
        let branches = repository.branches
        let from = current.tip.sha
        return BranchComparison(
            currentBranch: current.name,
            from: from,
            cached: { branches.cachedAheadBehind(from: from, to: $0.tip.sha) },
            load: { await branches.aheadBehind(from: from, to: $0.tip.sha) }
        )
    }
}

/// A picker row that shows how the current branch compares with its
/// branch, counted while the row is on screen: a row scrolled away cancels
/// its count before git runs.
struct ComparedBranchPickerRow: View {
    let branch: Branch
    let date: Date?
    let comparison: BranchComparison
    var dotColor: NSColor?
    @State private var loaded: (key: String, value: AheadBehind)?

    var body: some View {
        let key = "\(comparison.from)...\(branch.tip.sha)"
        let aheadBehind = loaded?.key == key ? loaded?.value : comparison.cached(branch)
        BranchPickerRow(
            branch: branch,
            isCurrent: false,
            date: date,
            counts: aheadBehind.map { BranchComparisonCounts($0, currentBranch: comparison.currentBranch) },
            dotColor: dotColor
        )
        .task(id: key) {
            guard let value = await comparison.load(branch), !Task.isCancelled else {
                return
            }
            loaded = (key, value)
        }
    }
}
