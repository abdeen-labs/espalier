// Espalier's menu card: a floating card on the `quiet` fill with the
// floating ring and shadow, radius 14, its rows inside a 5-point inset
// with radius 9, concentric with it. Rows are 24 high: a check column
// (only in a menu with checkable items), a leading symbol in secondary
// text, the title (the error color for a destructive item) with an
// optional subtitle under it, and a chevron for a submenu. The highlighted
// row, under the pointer or the keyboard, is the soft accent in its
// rounded shape, its text staying primary; disabled rows fade and are
// never highlighted. Section headers look like the app's section labels;
// dividers are hairlines inset from the card's edges. A menu taller than
// the screen scrolls. The card fades and grows very slightly from its
// anchor as it opens, except under Reduce Motion and offscreen.

import SwiftUI

/// One row of a menu card.
struct MenuRow: Identifiable {
    enum Kind {
        case item(MenuItem)
        case header(String)
        case divider
    }

    let id: Int
    let kind: Kind

    var item: MenuItem? {
        if case .item(let item) = kind {
            return item
        }
        return nil
    }

    /// Whether the pointer or the keyboard can highlight it.
    var isSelectable: Bool {
        item?.isEnabled == true
    }

    /// The rows of tidied `content`.
    static func rows(_ content: MenuContent) -> [MenuRow] {
        content.tidied.entries.enumerated().compactMap { index, entry in
            switch entry {
            case .item(let item): MenuRow(id: index, kind: .item(item))
            case .header(let text): MenuRow(id: index, kind: .header(text))
            case .divider: MenuRow(id: index, kind: .divider)
            case .option: nil
            }
        }
    }
}

/// What one menu card shows, and its highlight: the root menu or an open
/// submenu.
@MainActor @Observable
final class MenuLevel {
    let rows: [MenuRow]
    /// Whether any item can be checked: the check column shows.
    let hasChecks: Bool
    /// Whether any item has a symbol: titles line up after the symbols.
    let hasSymbols: Bool
    /// The card is at least this wide (a pop-up's capsule).
    let minimumWidth: CGFloat
    /// The highlighted row, by ID.
    var highlighted: Int?
    /// The row whose submenu is open.
    var openSubmenu: Int?
    /// The card's height when it scrolls; nil when everything fits.
    var scrollHeight: CGFloat?
    /// A row the keyboard moved to, scrolled into view.
    var scrollTarget: Int?
    /// The point of the card it grows from as it opens.
    var growthAnchor: UnitPoint = .top
    /// The rows' frames in the card's root coordinates (its shadow margin
    /// included), as last laid out.
    @ObservationIgnored var rowFrames: [Int: CGRect] = [:]

    init(content: MenuContent, minimumWidth: CGFloat = 0) {
        rows = MenuRow.rows(content)
        hasChecks = rows.contains { $0.item?.isChecked != nil }
        hasSymbols = rows.contains { $0.item?.systemImage != nil }
        self.minimumWidth = minimumWidth
    }

    func row(_ id: Int) -> MenuRow? {
        rows.first { $0.id == id }
    }

    /// The selectable rows' IDs, in order.
    var selectableIDs: [Int] {
        rows.filter(\.isSelectable).map(\.id)
    }

    /// The checked row, if any (a pop-up's choice).
    var checkedID: Int? {
        rows.first { $0.item?.isChecked == true }?.id
    }

    /// The row whose frame contains `point` (in the card's root
    /// coordinates).
    func rowID(at point: CGPoint) -> Int? {
        rowFrames.first { $0.value.contains(point) }?.key
    }
}

/// A menu level drawn as Espalier's card.
struct MenuCard: View {
    let level: MenuLevel
    @Environment(\.motion) private var motion
    @State private var hasAppeared = false
    /// Which ends of a scrolling menu have more rows past them.
    @State private var scrollEdges = MenuScrollEdges()

    static let coordinateSpace = "Espalier.MenuCard"

    var body: some View {
        let isShown = hasAppeared || !motion.animates
        card
            .scaleEffect(isShown ? 1 : Metrics.Menu.growthScale, anchor: level.growthAnchor)
            .opacity(isShown ? 1 : 0)
            .padding(EdgeInsets(Metrics.Menu.shadowInsets))
            .coordinateSpace(.named(Self.coordinateSpace))
            .onPreferenceChange(MenuRowFrames.self) { [level] frames in
                MainActor.assumeIsolated {
                    level.rowFrames = frames
                }
            }
            .onAppear {
                withMotion(motion, Motion.menuArrive) {
                    hasAppeared = true
                }
            }
            .accessibilityHidden(true)
    }

    @ViewBuilder
    private var card: some View {
        Group {
            if let scrollHeight = level.scrollHeight {
                ScrollViewReader { proxy in
                    ScrollView(.vertical) {
                        rows
                    }
                    .scrollIndicators(.never)
                    .onScrollGeometryChange(for: MenuScrollEdges.self) { geometry in
                        MenuScrollEdges(geometry)
                    } action: { _, edges in
                        scrollEdges = edges
                    }
                    .mask {
                        MenuScrollFade(edges: scrollEdges)
                    }
                    .frame(height: scrollHeight)
                    .onAppear {
                        if let target = level.scrollTarget ?? level.checkedID {
                            proxy.scrollTo(target, anchor: .center)
                        }
                    }
                    .onChange(of: level.scrollTarget) { _, target in
                        if let target {
                            proxy.scrollTo(target)
                        }
                    }
                }
            } else {
                rows
            }
        }
        .frame(minWidth: max(level.minimumWidth, Metrics.Menu.minimumWidth), alignment: .leading)
        .fixedSize(horizontal: true, vertical: false)
        .surface(.quiet, elevation: .floating, in: RoundedRectangle(cornerRadius: Metrics.Radius.card, style: .continuous))
    }

    private var rows: some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(level.rows) { row in
                MenuRowView(row: row, level: level)
            }
        }
        .padding(Metrics.Menu.inset)
    }
}

/// One row of the card.
private struct MenuRowView: View {
    let row: MenuRow
    let level: MenuLevel

    var body: some View {
        switch row.kind {
        case .item(let item):
            itemRow(item)
                .background {
                    GeometryReader { proxy in
                        Color.clear.preference(key: MenuRowFrames.self, value: [row.id: proxy.frame(in: .named(MenuCard.coordinateSpace))])
                    }
                }
        case .header(let text):
            Text(text)
                .font(Typography.sectionLabel)
                .tracking(Typography.sectionLabelTracking)
                .textCase(Theme.current.sectionLabel.isUppercase ? .uppercase : nil)
                .foregroundStyle(Color(nsColor: Theme.current.sectionLabel.color ?? Palette.text3))
                .lineLimit(1)
                .padding(.leading, Metrics.Menu.rowPadding + leadingColumnsWidth)
                .padding(.trailing, Metrics.Menu.rowPadding)
                .padding(.top, Metrics.Menu.headerTopPadding)
                .padding(.bottom, Metrics.Menu.headerBottomPadding)
                .frame(maxWidth: .infinity, alignment: .leading)
        case .divider:
            // The card's ring color: the panes' line color is the card's
            // own fill in dark.
            Rectangle()
                .fill(Color(nsColor: Elevation.floating.ring ?? Palette.line))
                .frame(height: 1)
                .padding(.horizontal, Metrics.Menu.dividerInset - Metrics.Menu.inset)
                .padding(.vertical, Metrics.Menu.dividerSpacing)
        }
    }

    /// The check and symbol columns' width, before the titles.
    private var leadingColumnsWidth: CGFloat {
        (level.hasChecks ? Metrics.Menu.checkColumnWidth + Metrics.Menu.columnSpacing : 0)
            + (level.hasSymbols ? Metrics.Menu.symbolColumnWidth + Metrics.Menu.columnSpacing : 0)
    }

    private func itemRow(_ item: MenuItem) -> some View {
        let isHighlighted = item.isEnabled && (level.highlighted == row.id || level.openSubmenu == row.id)
        // The check, the symbol, and the chevron line up with the title.
        return HStack(alignment: .firstTextBaseline, spacing: Metrics.Menu.columnSpacing) {
            if level.hasChecks {
                Image(systemName: "checkmark")
                    .font(.system(size: Metrics.Menu.checkSize, weight: .semibold))
                    .foregroundStyle(Color.accent)
                    .opacity(item.isChecked == true ? 1 : 0)
                    .frame(width: Metrics.Menu.checkColumnWidth)
            }
            if level.hasSymbols {
                // An item without a symbol keeps the column, empty.
                Image(systemName: item.systemImage ?? "circle")
                    .font(Typography.row)
                    .foregroundStyle(.text2)
                    .opacity(item.systemImage == nil ? 0 : 1)
                    .frame(width: Metrics.Menu.symbolColumnWidth)
            }
            VStack(alignment: .leading, spacing: Metrics.Menu.subtitleSpacing) {
                Text(item.title)
                    .font(item.titleFont ?? Typography.row)
                    .foregroundStyle(item.isDestructive ? Color(espalier: Palette.error) : .text)
                    .lineLimit(1)
                    .truncationMode(.middle)
                if let subtitle = item.subtitle {
                    WrappingLayout(maximumWidth: Metrics.Menu.subtitleMaximumWidth) {
                        Text(subtitle)
                            .font(Typography.secondary)
                            .foregroundStyle(.text3)
                            .lineLimit(Metrics.Menu.subtitleLineLimit)
                    }
                }
            }
            .frame(maxWidth: Metrics.Menu.titleMaximumWidth, alignment: .leading)
            Spacer(minLength: Metrics.Menu.trailingSpacing)
            if item.submenu != nil {
                Image(systemName: "chevron.right")
                    .font(.system(size: Metrics.Menu.chevronSize, weight: .semibold))
                    .foregroundStyle(.text3)
            }
        }
        .padding(.horizontal, Metrics.Menu.rowPadding)
        .padding(.vertical, item.subtitle == nil ? 0 : Metrics.Menu.subtitleRowPadding)
        .frame(minHeight: Metrics.Menu.rowHeight)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: Metrics.Radius.row, style: .continuous)
                .fill(isHighlighted ? AnyShapeStyle(.accentSoft) : AnyShapeStyle(.clear))
        )
        .opacity(item.isEnabled ? 1 : Palette.disabledOpacity)
    }
}

/// Which ends of a scrolling menu (or suggestion list) have rows past them.
struct MenuScrollEdges: Equatable {
    var top = false
    var bottom = false

    init() {}

    init(_ geometry: ScrollGeometry) {
        top = geometry.contentOffset.y > 1
        bottom = geometry.contentOffset.y + geometry.containerSize.height < geometry.contentSize.height - 1
    }
}

/// A scrolling menu's (or suggestion list's) mask: its rows fade out toward
/// an end with more rows past it.
struct MenuScrollFade: View {
    let edges: MenuScrollEdges

    var body: some View {
        VStack(spacing: 0) {
            LinearGradient(colors: [.clear, .black], startPoint: .top, endPoint: .bottom)
                .frame(height: edges.top ? Metrics.Menu.scrollFadeHeight : 0)
            Color.black
            LinearGradient(colors: [.black, .clear], startPoint: .top, endPoint: .bottom)
                .frame(height: edges.bottom ? Metrics.Menu.scrollFadeHeight : 0)
        }
    }
}

/// Text that keeps to one line up to `maximumWidth` and wraps past it,
/// reporting the wrapped height even when it's asked for its ideal size
/// (in the card, whose width is its rows' ideal).
private struct WrappingLayout: Layout {
    let maximumWidth: CGFloat

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        guard let text = subviews.first else {
            return .zero
        }
        let ideal = text.sizeThatFits(.unspecified)
        let width = min(proposal.width ?? ideal.width, ideal.width, maximumWidth)
        return text.sizeThatFits(ProposedViewSize(width: width, height: nil))
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        subviews.first?.place(at: bounds.origin, proposal: ProposedViewSize(width: bounds.width, height: bounds.height))
    }
}

/// The rows' frames, by row ID.
private struct MenuRowFrames: PreferenceKey {
    static let defaultValue: [Int: CGRect] = [:]

    static func reduce(value: inout [Int: CGRect], nextValue: () -> [Int: CGRect]) {
        value.merge(nextValue()) { $1 }
    }
}

extension EdgeInsets {
    init(_ insets: NSEdgeInsets) {
        self.init(top: insets.top, leading: insets.left, bottom: insets.bottom, trailing: insets.right)
    }
}

extension Metrics {
    /// Menus: the card, its rows, and where it opens.
    public enum Menu {
        /// The card's padding around its rows: rows' radius 9 sits
        /// concentric in the card's 14.
        public static let inset: CGFloat = 5
        /// An item row's height (one line).
        public static let rowHeight: CGFloat = 24
        /// Space inside a row before its first column and after its last.
        public static let rowPadding: CGFloat = 8
        /// Space between a row's columns.
        public static let columnSpacing: CGFloat = 6
        /// The check column.
        public static let checkColumnWidth: CGFloat = 12
        public static let checkSize: CGFloat = 11
        /// The leading symbol column.
        public static let symbolColumnWidth: CGFloat = 16
        /// The least space between a title and the chevron or the card's
        /// edge.
        public static let trailingSpacing: CGFloat = 16
        /// The submenu chevron's point size.
        public static let chevronSize: CGFloat = 10
        /// Between a title and its subtitle, and above and below a row
        /// with one.
        public static let subtitleSpacing: CGFloat = 1
        public static let subtitleRowPadding: CGFloat = 5
        /// A subtitle wraps at this width, on at most this many lines.
        public static let subtitleMaximumWidth: CGFloat = 280
        public static let subtitleLineLimit = 3
        /// A title is cut in its middle past this width.
        public static let titleMaximumWidth: CGFloat = 380
        /// A section header's space above and below its text.
        public static let headerTopPadding: CGFloat = 6
        public static let headerBottomPadding: CGFloat = 3
        /// A divider's inset from the card's edges, and its space above
        /// and below.
        public static let dividerInset: CGFloat = 10
        public static let dividerSpacing: CGFloat = 4
        /// The narrowest a card gets.
        public static let minimumWidth: CGFloat = 120
        /// Between a pull-down or pop-up and its menu.
        public static let gap: CGFloat = 4
        /// A menu stays this far in from the screen's visible edges.
        public static let screenMargin: CGFloat = 6
        /// The card grows from this scale as it opens.
        public static let growthScale: CGFloat = 0.98
        /// The transparent margin around the card where its shadow draws:
        /// the floating shadow's blur, more below, where it falls.
        public static let shadowInsets = NSEdgeInsets(top: 20, left: 28, bottom: 40, right: 28)
        /// A submenu's card overlaps its parent's edge by this much.
        public static let submenuOverlap: CGFloat = 2
        /// A press that opened a menu has dragged once the pointer is this
        /// far from where it began: releasing it over an item chooses it.
        public static let dragThreshold: CGFloat = 4
        /// How far a scrolling menu's rows fade toward an end with more
        /// rows past it.
        public static let scrollFadeHeight: CGFloat = 18
        /// The ring a list row shows while it's a context menu's target.
        public static let contextTargetLineWidth: CGFloat = 1.5
    }
}
