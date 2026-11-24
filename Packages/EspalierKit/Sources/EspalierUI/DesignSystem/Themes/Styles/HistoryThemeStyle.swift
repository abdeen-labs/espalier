/// History: its rows, ref tags, the working copy row and header, the branch
/// name over the list, and the merge call to action; the commit header,
/// Commit Info, line counts, and the pull request overview.
nonisolated public struct HistoryThemeStyle: Sendable, Equatable {
    /// How ref tags and other branch names are drawn.
    public enum RefTags: Sendable, Equatable {
        /// Candy pills: bold sans on a tint of the ref's color, filled
        /// symbols.
        case pills
        /// Mono labels: monospaced semibold in rounded rectangles, remote
        /// branches outlined, tags neutral gray, plain symbols.
        case monoLabels
    }

    /// How a group of facts or a header sits on its pane.
    public enum Surface: Sendable, Equatable {
        /// On its own card.
        case card
        /// Straight on the pane, set apart by hairlines.
        case plain
    }

    /// How a small count or detail beside a title is drawn.
    public enum Detail: Sendable, Equatable {
        /// On a pill.
        case pill
        /// As plain text.
        case text
    }

    /// The weights of History rows' titles.
    public enum RowTitleWeights: Sendable, Equatable {
        /// Medium titles; bold for HEAD's commit.
        case mediumAndBold
        /// Regular titles; semibold for HEAD's commit.
        case regularAndSemibold
    }

    /// The size of History's commit rows and the graph's nodes.
    public enum Rows: Sendable, Equatable {
        /// 42-point rows (at the default text size), 22-point avatars, and
        /// large nodes.
        case roomy
        /// 32-point rows (at the default text size), 20-point avatars, and
        /// small nodes.
        case compact
    }

    /// The branch name over the History list.
    public enum BranchName: Sendable, Equatable {
        /// The pane heading, after the Branches place's symbol.
        case heading
        /// A semibold row title, after a small branch symbol.
        case row
    }

    /// Ref tags in rows, the header, and Commit Info; a pull request's
    /// branch names.
    public var refTags: RefTags
    /// The header over a commit's (or the working copy's) files: a card
    /// with a large avatar, or a plain header over a hairline.
    public var commitHeader: Surface
    /// Commit Info: a card per kind of fact, or label and value rows.
    public var commitInfo: Surface
    /// The working copy row's "3 changed files".
    public var workingCopyDetail: Detail
    public var rowTitleWeights: RowTitleWeights
    public var rows: Rows
    public var branchName: BranchName
    /// The merge call to action on a branch's Ahead.
    public var mergeCallToAction: Surface
    /// A pull request's overview: three cards, or one column.
    public var pullRequestOverview: Surface
    /// "+10 −2" in headers.
    public var lineCounts: Detail

    /// Default's.
    public static let `default` = HistoryThemeStyle(
        refTags: .pills,
        commitHeader: .card,
        commitInfo: .card,
        workingCopyDetail: .pill,
        rowTitleWeights: .mediumAndBold,
        rows: .roomy,
        branchName: .heading,
        mergeCallToAction: .card,
        pullRequestOverview: .card,
        lineCounts: .pill
    )

    /// Frost's.
    public static let frost = HistoryThemeStyle(
        refTags: .monoLabels,
        commitHeader: .plain,
        commitInfo: .plain,
        workingCopyDetail: .text,
        rowTitleWeights: .regularAndSemibold,
        rows: .compact,
        branchName: .row,
        mergeCallToAction: .plain,
        pullRequestOverview: .plain,
        lineCounts: .text
    )
}
