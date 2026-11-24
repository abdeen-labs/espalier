/// The main window's sidebar and its icons rail: section headers, group
/// dividers, rows, their counts and symbols.
nonisolated public struct SidebarThemeStyle: Sendable, Equatable {
    /// A section's header.
    public enum SectionHeader: Sendable, Equatable {
        /// Its name as a bold title, a collapsed section's count in a pill.
        case title
        /// The theme's section label, a collapsed section's count inline.
        case label
    }

    /// What sets groups of a section's rows apart.
    public enum GroupDivider: Sendable, Equatable {
        case space
        case hairline
    }

    /// How the current branch (and a worktree's dot) is marked.
    public enum CurrentBranch: Sendable, Equatable {
        /// Its name in a candy pill of its color, its dot haloed.
        case pill
        /// Its name semibold, its dot plain.
        case semibold
    }

    /// How rows show counts: ahead and behind, changed files, a stash's
    /// files.
    public enum Counts: Sendable, Equatable {
        /// In soft pills.
        case pills
        /// As plain colored text.
        case text
    }

    /// The symbols of tags, stashes, pull requests, and worktrees.
    public enum RowSymbols: Sendable, Equatable {
        /// Filled, in their place's color; worktrees have a dot.
        case colored
        /// Outlined, in secondary text; worktrees have none.
        case plain
    }

    /// Row and rail sizes.
    public enum Density: Sendable, Equatable {
        /// Roomy rows, room around headers, a larger rail.
        case roomy
        /// 28-point rows and a compact rail.
        case compact
    }

    public var sectionHeader: SectionHeader
    public var groupDivider: GroupDivider
    public var currentBranch: CurrentBranch
    public var counts: Counts
    public var rowSymbols: RowSymbols
    public var density: Density

    /// Default's.
    public static let `default` = SidebarThemeStyle(
        sectionHeader: .title,
        groupDivider: .space,
        currentBranch: .pill,
        counts: .pills,
        rowSymbols: .colored,
        density: .roomy
    )
    /// Frost's.
    public static let frost = SidebarThemeStyle(
        sectionHeader: .label,
        groupDivider: .hairline,
        currentBranch: .semibold,
        counts: .text,
        rowSymbols: .plain,
        density: .compact
    )
}
