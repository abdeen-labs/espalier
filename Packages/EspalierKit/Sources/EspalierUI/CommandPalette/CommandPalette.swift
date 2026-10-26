// The command palette (View ▸ Command Palette…, ⌘K): Espalier's popover
// card, centered across the main window a little way below the toolbar.
// Along its top the search field, with the magnifying glass and ⌘K; then
// the results under their sections' labels (Actions, Repositories,
// Branches), each row with its symbol, its title with the characters the
// query matched in the accent, what trails it (an action's menu, a
// repository's owner or folder), a check mark for a checked item, and its
// shortcut; along the bottom the keys: ↑↓ Navigate, ↩ Open, esc Close.
// The card keeps one size, so typing never moves it; nothing matching
// shows "No Results".
//
// Typing filters, and the first row is highlighted. The arrow keys move
// the highlight at once, scrolling it into view; the pointer moves it as
// it moves (not as rows scroll or change under it), the highlight fading
// from row to row as hover does. The highlight is the selection's soft
// fill in the row's rounded shape, as a menu's is. Return or a click runs
// the row and closes the palette; Escape or a click outside closes it. The
// card fades in and settles as popovers do, except under Reduce Motion.

import AppKit
import SwiftUI

extension Metrics {
    /// The command palette.
    public enum CommandPalette {
        public static let width: CGFloat = 560
        /// The search field's band.
        public static let headerHeight: CGFloat = 48
        /// The results, which scroll inside this height.
        public static let resultsHeight: CGFloat = 360
        /// The keys' band.
        public static let footerHeight: CGFloat = 34
        /// What trails a row's title is cut in its middle past this width.
        public static let detailMaximumWidth: CGFloat = 220
        /// Between a key hint's caps and its label, and between hints.
        public static let hintSpacing: CGFloat = 4
        public static let hintsSpacing: CGFloat = 14
        /// The card's height, hairlines included.
        public static var height: CGFloat {
            headerHeight + 1 + resultsHeight + 1 + footerHeight
        }

        /// How far below the toolbar the card's top sits in a window whose
        /// content under the toolbar is `available` high: a quarter of the
        /// room the card leaves, and at least the large inset.
        public static func topInset(available: CGFloat) -> CGFloat {
            max(Metrics.insetLarge, (available - height) / 4)
        }
    }
}

extension Typography {
    /// The palette's search text (15).
    static var paletteField: Font { sans(.title3) }
}

/// Where the main window's palette opens: a strip across the window under
/// the toolbar, which takes no clicks. The palette is open while
/// `WindowState.commandPalette` holds its state.
struct CommandPaletteAnchor: View {
    @Environment(WindowContext.self) private var context

    var body: some View {
        @Bindable var state = context.state
        GeometryReader { proxy in
            Color.clear
                .frame(height: 1)
                .frame(maxWidth: .infinity)
                .popoverCard(item: $state.commandPalette, title: "Command Palette") { model in
                    CommandPalette(model: model)
                        .windowEnvironment(context)
                }
                .padding(.top, Metrics.CommandPalette.topInset(available: proxy.size.height))
        }
        .allowsHitTesting(false)
    }
}

/// The palette in its popover: it runs the row it's given and closes.
struct CommandPalette: View {
    let model: CommandPaletteModel
    @Environment(WindowContext.self) private var context
    @Environment(\.closeEnclosingPopover) private var closePopover

    var body: some View {
        CommandPaletteView(model: model) { row in
            // At once, so a sheet or popover the row opens finds the
            // window focused.
            closePopover?()
            CommandPaletteActions.run(row.item.command, in: context)
        }
    }
}

/// The palette's look, driven by its model.
struct CommandPaletteView: View {
    let model: CommandPaletteModel
    var activate: (CommandPaletteRow) -> Void = { _ in }
    @FocusState private var isFieldFocused: Bool
    /// Where the pointer was when rows last came under it without its
    /// moving (the palette opened, the keyboard scrolled the list, the
    /// query changed the rows): a row coming under a pointer that hasn't
    /// moved since doesn't take the highlight.
    @State private var restingPointer: CGPoint?

    var body: some View {
        VStack(spacing: 0) {
            header
            Hairline()
            results
                .frame(height: Metrics.CommandPalette.resultsHeight)
            Hairline()
            footer
        }
        .frame(width: Metrics.CommandPalette.width)
        .background(Color(espalier: Palette.background))
        .announcesFilterResults(model.query) { [model] in
            model.rowIDs.count
        }
        .onAppear {
            restingPointer = NSEvent.mouseLocation
            isFieldFocused = true
        }
        .onChange(of: model.query) {
            restingPointer = NSEvent.mouseLocation
        }
    }

    // MARK: Search field

    private var header: some View {
        @Bindable var model = model
        return HStack(spacing: Metrics.insetSmall + 2) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 15, weight: .medium))
                .foregroundStyle(.text3)
                .accessibilityHidden(true)
            TextField("Search", text: $model.query, prompt: Text("Search actions, repositories, and branches").fieldPrompt())
                .textFieldStyle(.plain)
                .font(Typography.paletteField)
                .foregroundStyle(.text)
                .lineLimit(1)
                .focused($isFieldFocused)
                .focusEffectDisabled()
                .onKeyPress(.downArrow) {
                    moveHighlight(by: 1)
                    return .handled
                }
                .onKeyPress(.upArrow) {
                    moveHighlight(by: -1)
                    return .handled
                }
                .onSubmit {
                    if let row = model.highlightedRow {
                        activate(row)
                    }
                }
                .accessibilityLabel("Command Palette")
            if let shortcut = ActionKind.showCommandPalette.shortcut {
                KeyCap(shortcut.symbols)
            }
        }
        .padding(.horizontal, Metrics.insetLarge)
        .frame(height: Metrics.CommandPalette.headerHeight)
    }

    private func moveHighlight(by offset: Int) {
        restingPointer = NSEvent.mouseLocation
        model.move(by: offset)
    }

    // MARK: Results

    @ViewBuilder
    private var results: some View {
        if model.sections.isEmpty {
            CenteredMessage(
                "No Results",
                systemImage: "magnifyingglass",
                description: "Try the name of an action, a repository, or a branch."
            )
            .fillingSpace()
        } else {
            ScrollViewReader { proxy in
                OverflowScrollView {
                    VStack(alignment: .leading, spacing: 0) {
                        ForEach(model.sections) { section in
                            ListGroupLabel(section.kind.title)
                                .padding(.horizontal, Metrics.ListRow.inset)
                                .id(PaletteScrollID.section(section.kind))
                            ForEach(section.rows) { row in
                                rowButton(row)
                            }
                        }
                    }
                    .padding(.bottom, Metrics.ListRow.inset)
                }
                // Another query's results start at the top.
                .id(model.query)
                .onChange(of: model.highlighted) {
                    guard !model.highlightFollowsPointer, let highlighted = model.highlighted else {
                        return
                    }
                    proxy.scrollTo(PaletteScrollID.row(highlighted))
                    // A section's first row brings its label into view too.
                    if let section = model.sections.first(where: { $0.rows.first?.id == highlighted }) {
                        proxy.scrollTo(PaletteScrollID.section(section.kind))
                    }
                }
            }
        }
    }

    private func rowButton(_ row: CommandPaletteRow) -> some View {
        let isHighlighted = model.highlighted == row.id
        return Button {
            activate(row)
        } label: {
            CommandPaletteRowView(row: row, isHighlighted: isHighlighted, fades: model.highlightFollowsPointer)
        }
        .buttonStyle(.bare(.rounded(Metrics.Radius.row)))
        // The field keeps the keyboard.
        .focusable(false)
        .padding(.horizontal, Metrics.ListRow.inset)
        .padding(.vertical, 1)
        .id(PaletteScrollID.row(row.id))
        .onContinuousHover { phase in
            guard case .active = phase else {
                return
            }
            if let pointer = restingPointer {
                guard NSEvent.mouseLocation != pointer else {
                    return
                }
                restingPointer = nil
            }
            model.point(at: row.id)
        }
        .accessibilityAddTraits(isHighlighted ? .isSelected : [])
    }

    // MARK: Keys

    private var footer: some View {
        HStack(spacing: Metrics.CommandPalette.hintsSpacing) {
            hint(["↑", "↓"], "Navigate")
            hint(["↩"], "Open")
            hint(["esc"], "Close")
            Spacer(minLength: 0)
        }
        .padding(.horizontal, Metrics.insetLarge)
        .frame(height: Metrics.CommandPalette.footerHeight)
        .accessibilityHidden(true)
    }

    private func hint(_ keys: [String], _ label: String) -> some View {
        HStack(spacing: Metrics.CommandPalette.hintSpacing) {
            ForEach(keys, id: \.self) { key in
                KeyCap(key)
            }
            Text(label)
                .font(Typography.subheadline)
                .foregroundStyle(.text3)
                .padding(.leading, 2)
        }
    }
}

/// What the results scroll to: a section's label or a row.
private enum PaletteScrollID: Hashable {
    case section(CommandPaletteSection.Kind)
    case row(CommandPaletteItem.ID)
}

/// One row: the symbol, the title with its matched characters in the
/// accent, what trails it, a check mark, and the shortcut, on the neutral
/// wash while highlighted.
struct CommandPaletteRowView: View {
    let row: CommandPaletteRow
    let isHighlighted: Bool
    /// Whether the highlight fades in and out (the pointer moved it).
    let fades: Bool
    @Environment(\.motion) private var motion

    var body: some View {
        let item = row.item
        HStack(spacing: Metrics.insetSmall) {
            Image(systemName: item.systemImage)
                .font(Typography.row)
                .foregroundStyle(.text2)
                .frame(width: Metrics.Sidebar.glyphSize)
                .accessibilityHidden(true)
            Text(title)
                .font(Typography.row)
                .foregroundStyle(.text)
                .lineLimit(1)
                .truncationMode(.middle)
                .layoutPriority(1)
            Spacer(minLength: Metrics.insetMedium)
            if let detail = item.detail {
                Text(detail)
                    .font(Typography.secondary)
                    .foregroundStyle(.text3)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .frame(maxWidth: Metrics.CommandPalette.detailMaximumWidth, alignment: .trailing)
            }
            if item.isChecked {
                Image(systemName: "checkmark")
                    .font(.system(size: Metrics.Menu.checkSize, weight: .semibold))
                    .foregroundStyle(Color.accent)
                    .accessibilityHidden(true)
            }
            if let shortcut = item.shortcut {
                KeyCap(shortcut)
            }
        }
        .padding(.horizontal, Metrics.ListRow.horizontalPadding)
        .frame(minHeight: Metrics.ListRow.height)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: Metrics.Radius.row, style: .continuous)
                .fill(isHighlighted ? Color.accentSoft : .clear)
                .animation(fades ? motion.hover(isHighlighted) : nil, value: isHighlighted)
        )
        .contentShape(RoundedRectangle(cornerRadius: Metrics.Radius.row, style: .continuous))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(item.title.text)
        .accessibilityValue(accessibilityValue)
    }

    /// The title, the characters the query matched in the accent.
    private var title: AttributedString {
        let text = row.item.title.text
        guard !row.positions.isEmpty else {
            return AttributedString(text)
        }
        let matched = Set(row.positions)
        var result = AttributedString()
        var run = String.UnicodeScalarView()
        var runIsMatched = false
        func flush() {
            guard !run.isEmpty else {
                return
            }
            var part = AttributedString(String(run))
            if runIsMatched {
                part.foregroundColor = Color.accent
            }
            result += part
            run = String.UnicodeScalarView()
        }
        for (offset, scalar) in text.unicodeScalars.enumerated() {
            let isMatched = matched.contains(offset)
            if isMatched != runIsMatched {
                flush()
                runIsMatched = isMatched
            }
            run.append(scalar)
        }
        flush()
        return result
    }

    /// The menu, whether it's checked, and the shortcut, for VoiceOver.
    private var accessibilityValue: String {
        let item = row.item
        var parts: [String] = []
        if let detail = item.detail {
            parts.append(detail)
        }
        if item.isChecked {
            parts.append("Checked")
        }
        if let shortcut = item.shortcut {
            parts.append(shortcut)
        }
        return parts.joined(separator: ", ")
    }
}
