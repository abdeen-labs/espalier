// Lists whose rows draw their own selection (rows have generous corners, a
// selected row is `accent soft`, and the branch picker's highlighted row is
// the accent). A SwiftUI `List` on macOS is a table that paints its own
// highlight across the row; `rowsDrawSelection()` turns the table's off, as
// the sidebar's `SidebarListStyler` does, and `turnsRowHighlightOff()` (in
// every `selectableRow`) turns off the row's it's in, keeping the table's
// selection, keyboard, and VoiceOver behavior.

import AppKit
import SwiftUI

extension View {
    /// Turns the enclosing list's own selection drawing off: its rows draw
    /// theirs (`selectableRow(isSelected:)`, `paletteRow(isHighlighted:)`).
    /// Apply it to the `List`.
    public func rowsDrawSelection() -> some View {
        background {
            ListHighlightStyler()
                .accessibilityHidden(true)
        }
    }

    /// A list row that draws its selection: padded, radius 9, `accent soft`
    /// while selected, and never the list's highlight. Put
    /// `.listRowBackground(Color.clear)` and the row insets on it as the
    /// list needs.
    public func selectableRow(isSelected: Bool) -> some View {
        padding(.horizontal, Metrics.ListRow.horizontalPadding)
            .frame(minHeight: Metrics.ListRow.height)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: Metrics.Radius.row, style: .continuous)
                    .fill(isSelected ? AnyShapeStyle(.accentSoft) : AnyShapeStyle(.clear))
            )
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
