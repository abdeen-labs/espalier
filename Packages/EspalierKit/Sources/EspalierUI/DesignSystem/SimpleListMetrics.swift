// The metrics and fonts of History's simple list: rows 54 high, each a
// commit's row (`Metrics.CommitRow`) on two lines, the title over a meta line,
// beside the rail, 40 wide, with the branch as one line whose nodes are the
// graph's; a merge's chevron last.

import AppKit

extension Metrics {
    /// History's simple list.
    public enum SimpleList {
        /// A commit's row: the title over the meta line, 54 at the default
        /// text size.
        public static var rowHeight: CGFloat {
            let lines = AppKitTypography.layoutLineHeight(of: AppKitTypography.row) + lineSpacing
                + AppKitTypography.layoutLineHeight(of: AppKitTypography.simpleMeta)
            return max(ceil(lines + rowPadding), minimumRowHeight)
        }

        /// The space above and below a row's two lines, together.
        static let rowPadding: CGFloat = 19
        static let minimumRowHeight: CGFloat = 54
        /// The line under an expanded merge's commits (loading, failed,
        /// more than shown).
        public static let statusRowHeight: CGFloat = 28
        /// The merge symbol's point size, in the avatar's circle.
        public static let mergeSymbolSize: CGFloat = 10
        /// The rail at the row's leading edge.
        public static let railWidth: CGFloat = 40
        /// The branch's line, from the rail's leading edge, and a merge's
        /// commits' line, 16 to its right.
        public static let lineX: CGFloat = 18
        public static let mergedLineX: CGFloat = 34
        /// A merged commit's avatar sits this much further in.
        public static let mergedIndent: CGFloat = 6
        /// Between the title and the meta line.
        public static let lineSpacing: CGFloat = 3
        /// The chevron's column on a merge's row, kept on its commits' rows
        /// so their times line up with the merge's.
        public static let disclosureWidth: CGFloat = 14
        /// The disclosure chevron's point size.
        public static let disclosureSize: CGFloat = 10
        /// The click area around the disclosure chevron.
        public static let disclosureHitWidth: CGFloat = 28
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
    /// A simple list row's meta line (12).
    public static var simpleMeta: NSFont {
        secondary
    }
}
