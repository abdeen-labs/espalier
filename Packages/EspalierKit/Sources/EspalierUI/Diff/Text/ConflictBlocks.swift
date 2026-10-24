// A conflicted file drawn as blocks in the diff table, in place of its diff
// of markers: the file's text divided by its markers (`ConflictedFileText`)
// and how each block's header shows its side. A side is named by its branch
// ("Current" or "Incoming" without one) and drawn in that branch's color as
// the graph draws it: the branch the operation changes (the current branch)
// in the accent, the default branch in the theme's trunk color, others in
// their own. Its header, one line of the code's, holds its Use <branch>'s
// Version button, its title in the branch's color, while the file still
// needs the user. The common ancestor's block (the diff3 and zdiff3 styles)
// is "Base", neutral, without a button.

import AppKit
import EspalierCore
import EspalierSupport
import GitKit

/// A conflicted file's conflicts as blocks.
struct ConflictBlocks: Equatable {
    /// How a side's blocks show.
    struct Side: Equatable {
        /// Its branch, or "Current" or "Incoming".
        var name: String
        /// Its branch's color.
        var color: NSColor
        /// "Use main's Version"; nil while the header has no button (a side
        /// is chosen for the whole file).
        var buttonTitle: String?
    }

    /// The file, divided by its markers.
    var file: ConflictedFileText
    var ours: Side
    var theirs: Side

    /// The common ancestor's block's name: git's ("base", the diff3
    /// style's section).
    static let baseName = "Base"

    /// The side a block shows; nil for the common ancestor's.
    func side(_ region: ConflictRegion) -> Side? {
        switch region {
        case .ours: ours
        case .theirs: theirs
        case .base, .marker: nil
        }
    }

    /// A block's name: its side's, or "Base".
    func name(_ region: ConflictRegion) -> String {
        side(region)?.name ?? Self.baseName
    }

    /// The blocks for a conflicted file in `repository`: an operation's
    /// conflicts (its row offers sides) in a file whose markers make at
    /// least one whole conflict; nil otherwise. The headers have their
    /// buttons while the file has markers and no side chosen for the whole
    /// of it.
    @MainActor
    static func make(_ file: ConflictedFileText, row: ConflictFileRowContent, repository: RepositoryModel) -> ConflictBlocks? {
        guard !file.conflicts.isEmpty, row.oursVersionTitle != nil else {
            return nil
        }
        let branches = repository.operations.conflictBranches
        let offersButtons: Bool = if case .markers = row.state { true } else { false }
        return ConflictBlocks(
            file: file,
            ours: Side(
                name: ConflictFileRowContent.sideName(branches?.ours, side: .ours),
                color: color(of: branches?.ours, side: .ours, otherSide: branches?.theirs, repository: repository),
                buttonTitle: offersButtons ? row.oursVersionTitle : nil
            ),
            theirs: Side(
                name: ConflictFileRowContent.sideName(branches?.theirs, side: .theirs),
                color: color(of: branches?.theirs, side: .theirs, otherSide: branches?.ours, repository: repository),
                buttonTitle: offersButtons ? row.theirsVersionTitle : nil
            )
        )
    }

    /// A side's color: the branch the operation changes in the accent (a
    /// rebase's branch too, while HEAD is detached), the default branch's
    /// color, else the branch's as the graph draws it. Without a branch,
    /// ours is the accent (HEAD), unless the other side's branch has it (a
    /// rebase's onto a commit no branch is at), and theirs a color no
    /// branch has; the two sides never share the accent.
    @MainActor
    static func color(of branch: String?, side: ManualConflictResolution, otherSide: String?, repository: RepositoryModel) -> NSColor {
        let colors = BranchColors.of(repository)
        let target = repository.operations.conflictState?.targetBranchName
        let isTarget = { (name: String?) in
            guard let name, let target else {
                return false
            }
            return ExactString(target) == ExactString(name)
        }
        guard let branch, !branch.isEmpty else {
            return side == .ours && !isTarget(otherSide)
                ? Palette.accent
                : colors.color(forMergedBranch: nil, isPullRequest: false, merge: ConflictFileRowContent.sideName(nil, side: side))
        }
        if isTarget(branch) {
            return Palette.accent
        }
        if let defaultBranch = colors.defaultBranch, ExactString(defaultBranch) == ExactString(branch) {
            return TrackPalette.trunk
        }
        return colors.color(forMergedBranch: branch, isPullRequest: false, merge: branch)
    }
}

extension DiffTableMetrics {
    /// Space between a conflict block's name and its button.
    static let conflictHeaderSpacing: CGFloat = 12
    /// Space on each side of a conflict block button's title, which the
    /// button's click takes too.
    static let conflictButtonInset: CGFloat = Metrics.grid

    /// A conflict block header's height: one line of the code's.
    static func conflictHeaderHeight(lineHeight: CGFloat) -> CGFloat {
        lineHeight
    }
}
