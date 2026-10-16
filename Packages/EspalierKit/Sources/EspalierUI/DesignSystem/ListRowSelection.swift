// Lists whose rows draw their own selection (rows have generous corners,
// and a selected row is `accent soft`, the popovers' highlighted row too).
// A SwiftUI `List` on macOS is a table that paints its own
// highlight across the row; `rowsDrawSelection()` turns the table's off, as
// the sidebar's `SidebarListStyler` does, and `turnsRowHighlightOff()` (in
// every `selectableRow`) turns off the row's it's in, keeping the table's
// selection, keyboard, and VoiceOver behavior.

import AppKit
import SwiftUI

extension View {
    /// Turns the enclosing list's own selection drawing off: its rows draw
    /// theirs (`selectableRow(isSelected:)`). Apply it to the `List`.
    public func rowsDrawSelection() -> some View {
        background {
            ListHighlightStyler()
                .accessibilityHidden(true)
        }
    }

    /// A list row that draws its selection: padded, the row radius,
    /// `accent soft` while selected, not the list's highlight; while it's
    /// a context menu's target (`contextMenuRow(_:)`), the target's ring. Put
    /// `.listRowBackground(Color.clear)` and the row insets on it as the
    /// list needs.
    ///
    /// - Parameter showsSelectionBar: A file list's row: selected, it shows
    ///   the theme's bar at its leading edge, as History's and the sidebar's
    ///   do (`SelectionBar`).
    public func selectableRow(isSelected: Bool, showsSelectionBar: Bool = false) -> some View {
        padding(.horizontal, Metrics.ListRow.horizontalPadding)
            .frame(minHeight: Metrics.ListRow.height)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(SelectableRowBackground(isSelected: isSelected, showsSelectionBar: showsSelectionBar))
            .turnsRowHighlightOff()
            .contentShape(RoundedRectangle(cornerRadius: Metrics.Radius.row, style: .continuous))
    }

    /// Turns off the selection drawing of the list row this view is in,
    /// before the row draws. It looks no further than its row, so it suits
    /// a list beside other tables (a pane's, next to a diff).
    func turnsRowHighlightOff() -> some View {
        background {
            RowHighlightRemover()
                .frame(width: 0, height: 0)
                .accessibilityHidden(true)
        }
    }
}

extension Metrics {
    /// Rows of lists inside sheets and panes.
    public enum ListRow {
        public static let height: CGFloat = 30
        public static let horizontalPadding: CGFloat = 8
        /// The rows' inset from the list's edges.
        public static let inset: CGFloat = 6

        /// A row's list insets: `inset` at the sides and 1 above and below,
        /// with `inset` above the list's first row and below its last.
        public static func insets(isFirst: Bool = false, isLast: Bool = false) -> EdgeInsets {
            EdgeInsets(top: isFirst ? inset : 1, leading: inset, bottom: isLast ? inset : 1, trailing: inset)
        }
    }
}

/// A selectable row's background: the soft accent while selected, and the
/// ring while it's a context menu's target.
private struct SelectableRowBackground: View {
    let isSelected: Bool
    let showsSelectionBar: Bool
    @Environment(\.isContextMenuTarget) private var isContextMenuTarget

    var body: some View {
        RoundedRectangle(cornerRadius: Metrics.Radius.row, style: .continuous)
            .fill(isSelected ? AnyShapeStyle(.accentSoft) : AnyShapeStyle(.clear))
            .overlay {
                if isSelected, showsSelectionBar {
                    SelectionBar()
                }
            }
            .contextTargetRing(isContextMenuTarget)
    }
}

/// Turns off the selection drawing of the list row this view is in: the
/// row's, not the table's, since changing the table's while it makes its
/// rows leaves them blank. It applies as the row joins the table, before it
/// draws, and on every update.
private struct RowHighlightRemover: NSViewRepresentable {
    func makeNSView(context: Context) -> RemoverView {
        RemoverView()
    }

    func updateNSView(_ view: RemoverView, context: Context) {
        view.apply()
    }

    final class RemoverView: NSView {
        override func viewDidMoveToSuperview() {
            super.viewDidMoveToSuperview()
            apply()
        }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            apply()
        }

        /// Clicks go to the row.
        override func hitTest(_ point: NSPoint) -> NSView? {
            nil
        }

        /// Turns off the enclosing row's selection drawing.
        func apply() {
            var view = superview
            while let current = view {
                if let row = current as? NSTableRowView {
                    if row.selectionHighlightStyle != .none {
                        row.selectionHighlightStyle = .none
                    }
                    return
                }
                view = current.superview
            }
        }
    }
}

/// Turns the list's own selection drawing off whenever the list lays out,
/// so no frame shows the table's highlight behind the row's.
private struct ListHighlightStyler: NSViewRepresentable {
    func makeNSView(context: Context) -> StylerView {
        StylerView()
    }

    func updateNSView(_ view: StylerView, context: Context) {
        view.apply()
    }

    final class StylerView: NSView {
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            apply()
            // The list's table may come after this view joins the window.
            DispatchQueue.main.async { [weak self] in
                self?.apply()
            }
        }

        override func layout() {
            super.layout()
            apply()
        }

        /// The list's table, the nearest one beside this view, without its
        /// highlight.
        func apply() {
            guard let table = nearestTable() else {
                return
            }
            if table.selectionHighlightStyle != .none {
                table.selectionHighlightStyle = .none
            }
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

// MARK: - Selection marks

extension Metrics {
    /// The bar some themes (Pop) draw at a selected row's leading edge.
    public enum SelectionBar {
        public static let width: CGFloat = 3
        /// Its inset from the row's top and bottom.
        public static let verticalInset: CGFloat = 7
        public static let cornerRadius: CGFloat = 1.5
    }
}

/// The bar in the accent at a selected row's leading edge, in themes that
/// draw one (`Theme.selectionBar`). Put it over the row's selection, in the
/// selection's frame.
struct SelectionBar: View {
    var body: some View {
        if Theme.current.selectionBar {
            RoundedRectangle(cornerRadius: Metrics.SelectionBar.cornerRadius, style: .continuous)
                .fill(Color.accent)
                .frame(width: Metrics.SelectionBar.width)
                .padding(.vertical, Metrics.SelectionBar.verticalInset)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
                .accessibilityHidden(true)
        }
    }
}

/// The selection bar for AppKit rows.
@MainActor
enum SelectionBarDrawing {
    /// Draws the bar at the leading edge of `rect`, a selected row's
    /// selection, when the theme has one.
    static func draw(in rect: CGRect) {
        guard Theme.current.selectionBar, rect.height > Metrics.SelectionBar.verticalInset * 2 else {
            return
        }
        let bar = CGRect(
            x: rect.minX,
            y: rect.minY + Metrics.SelectionBar.verticalInset,
            width: Metrics.SelectionBar.width,
            height: rect.height - Metrics.SelectionBar.verticalInset * 2
        )
        Palette.accent.setFill()
        NSBezierPath(roundedRect: bar, xRadius: Metrics.SelectionBar.cornerRadius, yRadius: Metrics.SelectionBar.cornerRadius).fill()
    }
}

/// The sidebar's selected row: the theme's selection fill in the row's
/// shape; a card raised off the sidebar by a soft shadow and a ring
/// (Orchard); and the accent bar at its leading edge (Pop).
struct SidebarSelectionFill: View {
    var body: some View {
        let theme = Theme.current
        let shape = RoundedRectangle(cornerRadius: Metrics.Radius.row, style: .continuous)
        shape
            .fill(Color(nsColor: theme.sidebarSelection))
            .background {
                if theme.sidebarSelectionStyle == .raisedCard {
                    shape
                        .fill(Color(nsColor: theme.sidebarSelection))
                        .shadow(color: Color(nsColor: theme.raisedShadow), radius: 1, y: 1)
                }
            }
            .overlay {
                if theme.sidebarSelectionStyle == .raisedCard {
                    shape.strokeBorder(Color(nsColor: theme.raisedRing), lineWidth: 1)
                }
            }
            .overlay {
                SelectionBar()
            }
    }
}

extension ShapeStyle where Self == Color {
    /// A sidebar row's title: the theme's selection text while the row is
    /// selected, else primary text.
    static func sidebarRowText(isSelected: Bool) -> Color {
        guard isSelected, let text = Theme.current.sidebarSelectionText else {
            return .text
        }
        return Color(nsColor: text)
    }

    /// A sidebar row's symbol: the theme's selection symbol color (Classic's
    /// accent) while the row is selected, else secondary text.
    static func sidebarRowIcon(isSelected: Bool) -> Color {
        isSelected ? Color(nsColor: Theme.current.sidebarSelectionIcon) : .text2
    }

    /// A sidebar row's count (Changes', a stash's, a branch's behind count,
    /// a pull request's number): the theme's selection text while the row
    /// is selected in a theme whose counts take it
    /// (`sidebarSelectionTintsCounts`), else the sidebar's tertiary text.
    static func sidebarRowCount(isSelected: Bool) -> Color {
        let theme = Theme.current
        if isSelected, theme.sidebarSelectionTintsCounts, let text = theme.sidebarSelectionText {
            return Color(nsColor: text)
        }
        return .sidebarText3
    }

    /// The sidebar's tertiary text: the theme's (`Theme.sidebarText3`), else
    /// tertiary text.
    static var sidebarText3: Color {
        Theme.current.sidebarText3.map { Color(nsColor: $0) } ?? .text3
    }

    /// An ahead count ("↑2"): the theme's (`Theme.aheadText`), else the
    /// accent.
    static var aheadText: Color {
        Theme.current.aheadText.map { Color(nsColor: $0) } ?? .accent
    }
}
