// The metrics and fonts of History's simple list: rows 54 high with radius
// 12; the rail, 40 wide, with the branch as one 3-point line; a 24-point
// avatar; the title at 14 semibold over a meta line at 12; the time in SF
// Mono 11 in a 44-wide column; a merge's chevron last.

import AppKit

extension Metrics {
    /// History's simple list.
    public enum SimpleList {
        /// A commit's row: the title over the meta line, 54 at the default
        /// text size.
        public static var rowHeight: CGFloat {
            let layout = NSLayoutManager()
            let lines = layout.defaultLineHeight(for: AppKitTypography.simpleTitle) + lineSpacing
                + layout.defaultLineHeight(for: AppKitTypography.simpleMeta)
            return max(ceil(lines + rowPadding), minimumRowHeight)
        }

        /// The space above and below a row's two lines, together.
        static let rowPadding: CGFloat = 19
        static let minimumRowHeight: CGFloat = 54
        /// The line under an expanded merge's commits (loading, failed,
        /// more than shown).
        public static let statusRowHeight: CGFloat = 28
        /// The avatar, and the merge symbol's circle.
        public static let avatarSize: CGFloat = 24
        /// A merged commit's avatar.
        public static let mergedAvatarSize: CGFloat = 22
        /// The merge symbol's point size.
        public static let mergeSymbolSize: CGFloat = 11
        /// The selection's inset from the column's sides.
        public static let rowInset: CGFloat = 6
        /// The selection's inset from the row's top and bottom.
        public static let rowVerticalInset: CGFloat = 1
        /// The rail at the row's leading edge.
        public static let railWidth: CGFloat = 40
        /// The branch's line, from the rail's leading edge, and a merge's
        /// commits' line, 16 to its right.
        public static let lineX: CGFloat = 13
        public static let mergedLineX: CGFloat = 29
        /// Between the rail, the avatar, the text, the time, and the
        /// chevron.
        public static let spacing: CGFloat = 10
        /// A merged commit's avatar sits this much further in.
        public static let mergedIndent: CGFloat = 6
        /// After the last column.
        public static let trailingPadding: CGFloat = 12
        /// Between the title and the meta line.
        public static let lineSpacing: CGFloat = 3
        /// The "Not pushed" arrow.
        public static let unpushedGlyphSize: CGFloat = 9
        /// The time's column, its text right-aligned.
        public static let timeWidth: CGFloat = 44
        /// The chevron's column on a merge's row, kept on its commits' rows
        /// so their times line up with the merge's.
        public static let disclosureWidth: CGFloat = 14
        /// The disclosure chevron's point size.
        public static let disclosureSize: CGFloat = 10
        /// The click area around the disclosure chevron.
        public static let disclosureHitWidth: CGFloat = 28

        /// The rail's line, and its nodes: the tip a bold ring with a dot;
        /// an unpushed commit a hollow ring; a pushed one a solid dot with
        /// a 2-point ring of the background; a merged commit a smaller dot.
        public static let lineStroke: CGFloat = 3
        public static let tipRadius: CGFloat = 7
        public static let tipStroke: CGFloat = 3.25
        public static let tipDotRadius: CGFloat = 2.75
        public static let nodeRadius: CGFloat = 5.25
        public static let nodeStroke: CGFloat = 3
        public static let mergedNodeRadius: CGFloat = 4.25
        /// An unpushed merged commit's ring.
        public static let mergedRingRadius: CGFloat = 3.5
        public static let mergedRingStroke: CGFloat = 2.5
        /// The ring of background around a dot.
        public static let dotRing: CGFloat = 2
        /// A merge's stub leaves its node on a short diagonal, then turns
        /// down: the diagonal's length, and where the turn ends, below the
        /// node.
        public static let stubDiagonal: CGFloat = 4
        public static let stubTurnEnd: CGFloat = 14
        /// A fading line fades from this far below the node to the row's
        /// bottom.
        public static let fadeStart: CGFloat = 6
    }
}

extension AppKitTypography {
    /// A simple list row's title: a point over the body size, semibold
    /// (14).
    public static var simpleTitle: NSFont {
        .systemFont(ofSize: row.pointSize + 1, weight: .semibold)
    }

    /// The branch after a merge's title, in text3: the title's size,
    /// medium.
    public static var simpleTitleDetail: NSFont {
        .systemFont(ofSize: row.pointSize + 1, weight: .medium)
    }

    /// A simple list row's meta line (12).
    public static var simpleMeta: NSFont {
        secondary
    }

    /// A simple list row's time: SF Mono 11, medium.
    public static var simpleTime: NSFont {
        count(size: 11)
    }
}
