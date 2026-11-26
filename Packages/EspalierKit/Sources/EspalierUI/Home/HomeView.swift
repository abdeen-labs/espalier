// Home's look, value-driven (`HomeContent`): the heading with Fetch All and
// Push All, Needs You's cards (or, where the theme draws plainly, its rows),
// In Progress's rows, and the Quiet line; or, with status off, why Home
// can't say anything. It scrolls when it doesn't fit, pinned against the
// overscroll bug. One card has the focus: its button is the prominent one,
// Return takes it, and the arrow keys move the focus. Counts roll, and
// cards and rows arrive and leave with the app's motion; under Reduce
// Motion nothing animates.

import EspalierCore
import GitKit
import SwiftUI

/// What Home's controls do.
struct HomeViewActions {
    /// Takes a card's next step.
    var takeStep: (HomeCard) -> Void = { _ in }
    /// Opens a piece of work at its last place.
    var open: (WorktreeKey) -> Void = { _ in }
    /// Opens a quiet repository.
    var openRepository: (RepositoryID) -> Void = { _ in }
    /// Moves the focus to a card.
    var focus: (WorktreeKey) -> Void = { _ in }
    var fetchAll: () -> Void = {}
    var stopFetchAll: () -> Void = {}
    var pushAll: () -> Void = {}
    /// Turns status on (`preferences.repositoryIndicatorsEnabled`).
    var turnOnStatus: () -> Void = {}
    /// A piece of work's context menu.
    var menu: (WorktreeKey) -> MenuContent = { _ in MenuContent() }
}

/// Home's screen, from values.
struct HomeView: View {
    let content: HomeContent
    @Binding var isQuietOpen: Bool
    var actions = HomeViewActions()
    /// How many columns of cards fit, for the arrow keys.
    @State private var columns = 1
    /// Whether Home has keyboard focus, for captures; nil reads it.
    var hasKeyboardFocus: Bool?
    /// The arrow keys and Return reach Home through a view behind it that
    /// takes keyboard focus. It holds the focus itself, so the controls on
    /// Home don't read it as theirs and draw their rings.
    @FocusState private var hasFocus: Bool
    @Environment(\.appearsActive) private var appearsActive
    @Environment(\.motion) private var motion

    var body: some View {
        if content.isStatusOff {
            HomeStatusOffView(turnOn: actions.turnOnStatus)
        } else {
            board
        }
    }

    private var board: some View {
        let style = HomeThemeStyle.current
        return ScrollView(.vertical) {
            VStack(alignment: .leading, spacing: 0) {
                HomeHeading(content: content, actions: actions)
                if !content.cards.isEmpty {
                    HomeSectionLabel("Needs You", count: content.cards.count)
                    needsYou(style)
                        .padding(.bottom, Metrics.Home.sectionSpacing)
                        .transition(motion.animates ? .opacity : .identity)
                }
                if !content.inProgress.isEmpty {
                    HomeSectionLabel("In Progress", count: content.inProgress.count)
                    HomeProgressList(rows: content.inProgress, actions: actions)
                        .padding(.bottom, Metrics.Home.sectionSpacing)
                        .transition(motion.animates ? .opacity : .identity)
                }
                if !content.quiet.isEmpty {
                    HomeQuietSection(content: content, isOpen: $isQuietOpen, openRepository: actions.openRepository)
                        .transition(motion.animates ? .opacity : .identity)
                }
            }
            .padding(.horizontal, Metrics.Home.pageInset)
            .padding(.top, Metrics.Home.topInset)
            .padding(.bottom, Metrics.Home.bottomInset)
            .frame(maxWidth: .infinity, alignment: .leading)
            .animation(motion.animation(Motion.arrive), value: content.cards.map(\.id))
            .animation(motion.animation(Motion.arrive), value: content.inProgress.map(\.id))
            .animation(motion.animation(Motion.arrive), value: content.quiet.isEmpty)
            .unbouncedScrollContent()
        }
        .scrollIndicators(.automatic)
        .background {
            Color.clear
                .focusable()
                .focusEffectDisabled()
                .focused($hasFocus)
                .onKeyPress(keys: [.leftArrow, .rightArrow, .upArrow, .downArrow, .return]) { press in
                    handle(press.key)
                }
                .accessibilityHidden(true)
        }
        // With a card to take its step, Home takes the keyboard as it shows
        // and whenever its window becomes key with nothing else holding the
        // keyboard; with none, nothing has it until the user moves it to a
        // control.
        .onAppear {
            hasFocus = !content.cards.isEmpty
        }
        .background {
            HomeKeyboardClaim {
                if !content.cards.isEmpty {
                    hasFocus = true
                }
            }
            .frame(width: 0, height: 0)
            .accessibilityHidden(true)
        }
        .fillingSpace()
    }

    @ViewBuilder
    private func needsYou(_ style: HomeThemeStyle) -> some View {
        switch style.needsYou {
        case .cards:
            HomeCardGrid(spacing: Metrics.Home.cardSpacing) {
                ForEach(content.cards) { card in
                    HomeCardView(card: card, showsFocusRing: showsFocusRing, actions: actions)
                        .transition(motion.animates ? .opacity.combined(with: .scale(scale: Metrics.Home.arrivalScale)) : .identity)
                }
            }
            .onGeometryChange(for: Int.self) { proxy in
                HomeCardGrid.columns(forWidth: proxy.size.width, spacing: Metrics.Home.cardSpacing)
            } action: { columns in
                self.columns = columns
            }
        case .rows:
            HomeHairlineList(content.cards) { card in
                HomeCardRow(card: card, actions: actions)
            }
            .onAppear {
                columns = 1
            }
        }
    }

    /// Whether the focused card shows the focus ring: while Home has the
    /// keyboard in the key window.
    private var showsFocusRing: Bool {
        (hasKeyboardFocus ?? hasFocus) && appearsActive
    }

    /// The arrow keys move the focus between cards; Return takes the
    /// focused card's step.
    private func handle(_ key: KeyEquivalent) -> KeyPress.Result {
        guard !content.cards.isEmpty else {
            return .ignored
        }
        let columns = HomeThemeStyle.current.needsYou == .rows ? 1 : columns
        let move: HomeFocusMove
        switch key {
        case .leftArrow: move = .left
        case .rightArrow: move = .right
        case .upArrow: move = .up
        case .downArrow: move = .down
        case .return:
            if let card = content.focusedCard, card.route != nil, !card.isRunning {
                actions.takeStep(card)
            }
            return .handled
        default:
            return .ignored
        }
        if let target = content.card(moving: move, columns: columns) {
            actions.focus(target)
        }
        return .handled
    }
}

// MARK: - Keyboard

/// Tells Home when its window is key and nothing in it holds the keyboard:
/// as Home shows in a key window, and each time its window becomes key. A
/// focus request made before the window is key (at launch) is lost, so Home
/// asks again then. It never asks while a field, a list, or another control
/// has the keyboard, or while a sheet or a panel is key in its place.
struct HomeKeyboardClaim: NSViewRepresentable {
    let claim: () -> Void

    func makeNSView(context: Context) -> HomeKeyboardClaimView {
        HomeKeyboardClaimView()
    }

    func updateNSView(_ view: HomeKeyboardClaimView, context: Context) {
        view.claim = claim
    }
}

/// `HomeKeyboardClaim`'s view.
final class HomeKeyboardClaimView: NSView {
    var claim: () -> Void = {}

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        // Observers by selector go when the view does.
        NotificationCenter.default.removeObserver(self, name: NSWindow.didBecomeKeyNotification, object: nil)
        guard let window else {
            return
        }
        NotificationCenter.default.addObserver(self, selector: #selector(windowDidBecomeKey), name: NSWindow.didBecomeKeyNotification, object: window)
        // The screen before Home lets go of the keyboard as it leaves, after
        // this view arrives.
        DispatchQueue.main.async { [weak self] in
            self?.claimWhenIdle()
        }
    }

    @objc private func windowDidBecomeKey(_ notification: Notification) {
        claimWhenIdle()
    }

    /// Claims the keyboard if the window is key and nothing in it holds the
    /// keyboard: its first responder is the window or its content view.
    private func claimWhenIdle() {
        guard let window, window.isKeyWindow else {
            return
        }
        let responder = window.firstResponder
        guard responder == nil || responder === window || responder === window.contentView else {
            return
        }
        claim()
    }
}

// MARK: - Heading

/// The count as a sentence, what's true under it, and Fetch All and Push
/// All.
struct HomeHeading: View {
    let content: HomeContent
    let actions: HomeViewActions
    @Environment(\.numberFormat) private var numberFormat
    @Environment(\.motion) private var motion

    var body: some View {
        let style = HomeThemeStyle.current
        let summary = content.summary(numberFormat)
        HStack(alignment: .bottom, spacing: Metrics.insetMedium) {
            VStack(alignment: .leading, spacing: Metrics.Home.headingLineSpacing) {
                Text(content.title(numberFormat))
                    .font(Typography.display(size: style.titleSize, weight: style.titleWeight))
                    .foregroundStyle(.text)
                    .contentTransition(motion.animates ? .numericText() : .identity)
                    .motion(Motion.kindChange, value: content.cards.count)
                    // Until every repository has told its status, the title
                    // keeps its room and claims nothing.
                    .opacity(content.isTitleWaiting ? 0 : 1)
                    .accessibilityHidden(content.isTitleWaiting)
                    .accessibilityAddTraits(.isHeader)
                Text(summary ?? " ")
                    .font(Typography.row)
                    .foregroundStyle(.text2)
                    .contentTransition(motion.animates ? .numericText() : .identity)
                    .motion(Motion.kindChange, value: summary)
                    .accessibilityHidden(summary == nil)
            }
            .lineLimit(1)
            .layoutPriority(1)
            Spacer(minLength: Metrics.insetMedium)
            HStack(spacing: Metrics.Home.headingButtonSpacing) {
                fetchAll
                if content.pushAllCount > 0 || content.batch.isPushingAll {
                    pushAll
                        .transition(motion.animates ? .opacity : .identity)
                }
            }
            .controlSize(.large)
            .fixedSize()
            .animation(motion.animation(Motion.arrive), value: content.pushAllCount > 0 || content.batch.isPushingAll)
        }
        .padding(.horizontal, Metrics.Home.labelInset)
        .padding(.bottom, Metrics.Home.headingBottom)
    }

    @ViewBuilder
    private var fetchAll: some View {
        if content.batch.isFetching {
            HStack(spacing: Metrics.insetSmall) {
                HStack(spacing: Metrics.Home.symbolSpacing) {
                    ArcProgress(.small, value: content.batch.fetch.flatMap(fraction))
                    Text(fetchingTitle)
                        .font(Typography.row)
                        .foregroundStyle(.text2)
                        .monospacedDigit()
                        .contentTransition(motion.animates ? .numericText() : .identity)
                        .motion(Motion.kindChange, value: content.batch.fetch)
                }
                .accessibilityElement(children: .combine)
                Button("Stop", action: actions.stopFetchAll)
                    .buttonStyle(.quiet)
                    .tooltip("Stop Fetch All")
            }
        } else {
            Button(action: actions.fetchAll) {
                Label("Fetch All", systemImage: "arrow.triangle.2.circlepath")
            }
            .buttonStyle(.quiet)
            .tooltip("Fetch every repository")
        }
    }

    private var pushAll: some View {
        Button(action: actions.pushAll) {
            HStack(spacing: Metrics.Home.symbolSpacing) {
                if content.batch.isPushingAll {
                    ArcProgress(.small)
                    Text("Pushing…")
                } else {
                    Label("Push All", systemImage: "arrow.up")
                    HomeCount(content.pushAllCount)
                }
            }
        }
        .buttonStyle(.quiet)
        .disabled(content.batch.isPushingAll)
        .tooltip("Push every branch with commits to push")
    }

    /// "Fetching 3 of 12".
    private var fetchingTitle: String {
        guard let progress = content.batch.fetch else {
            return "Fetching…"
        }
        return "Fetching \(formatCount(progress.completed, numberFormat)) of \(formatCount(progress.total, numberFormat))"
    }

    private func fraction(_ progress: FetchAllProgress) -> Double? {
        progress.total > 0 ? Double(progress.completed) / Double(progress.total) : nil
    }
}

/// A section's label and count, at the cards' text inset.
struct HomeSectionLabel: View {
    private let title: String
    private let count: Int
    @Environment(\.motion) private var motion

    init(_ title: String, count: Int) {
        self.title = title
        self.count = count
    }

    var body: some View {
        SectionLabel(title, count: count)
            .contentTransition(motion.animates ? .numericText() : .identity)
            .motion(Motion.kindChange, value: count)
            .padding(.horizontal, Metrics.Home.labelInset)
            .padding(.bottom, Metrics.Home.labelBottom)
    }
}

/// A count, in a pill or as text as the theme draws counts.
struct HomeCount: View {
    private let count: Int
    @Environment(\.numberFormat) private var numberFormat
    @Environment(\.motion) private var motion

    init(_ count: Int) {
        self.count = count
    }

    var body: some View {
        let text = formatCount(count, numberFormat)
        Group {
            switch Theme.current.style.sidebar.counts {
            case .pills:
                CountPill(text)
            case .text:
                Text(verbatim: text)
                    .font(Typography.count)
                    .foregroundStyle(.text2)
            }
        }
        .contentTransition(motion.animates ? .numericText() : .identity)
        .motion(Motion.kindChange, value: count)
    }
}

// MARK: - Layout

/// Cards in as many columns as fit, each row as tall as its tallest card.
struct HomeCardGrid: Layout {
    var spacing: CGFloat

    /// How many columns of cards fit in `width`: at least one, a card at
    /// least `Metrics.Home.cardMinWidth` wide.
    static func columns(forWidth width: CGFloat, spacing: CGFloat) -> Int {
        guard width.isFinite, width > 0 else {
            return 1
        }
        return max(1, Int((width + spacing) / (Metrics.Home.cardMinWidth + spacing)))
    }

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width = proposal.width.flatMap { $0.isFinite ? $0 : nil } ?? Metrics.Home.cardMinWidth
        let rows = rowHeights(width: width, subviews: subviews)
        return CGSize(width: width, height: rows.reduce(0, +) + spacing * CGFloat(max(rows.count - 1, 0)))
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let columns = Self.columns(forWidth: bounds.width, spacing: spacing)
        let columnWidth = self.columnWidth(bounds.width, columns: columns)
        let rows = rowHeights(width: bounds.width, subviews: subviews)
        var y = bounds.minY
        for (row, height) in rows.enumerated() {
            for column in 0..<columns {
                let index = row * columns + column
                guard subviews.indices.contains(index) else {
                    break
                }
                let x = bounds.minX + CGFloat(column) * (columnWidth + spacing)
                subviews[index].place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(width: columnWidth, height: height))
            }
            y += height + spacing
        }
    }

    private func columnWidth(_ width: CGFloat, columns: Int) -> CGFloat {
        ((width - spacing * CGFloat(columns - 1)) / CGFloat(columns)).rounded(.down)
    }

    /// Each row's height: its tallest card's.
    private func rowHeights(width: CGFloat, subviews: Subviews) -> [CGFloat] {
        let columns = Self.columns(forWidth: width, spacing: spacing)
        let columnWidth = self.columnWidth(width, columns: columns)
        return stride(from: 0, to: subviews.count, by: columns).map { start in
            subviews[start..<min(start + columns, subviews.count)]
                .map { $0.sizeThatFits(ProposedViewSize(width: columnWidth, height: nil)).height }
                .max() ?? 0
        }
    }
}

/// Rows split by hairlines, in a theme that draws plainly.
struct HomeHairlineList<Item: Identifiable, Row: View>: View {
    private let items: [Item]
    private let row: (Item) -> Row
    @Environment(\.motion) private var motion

    init(_ items: [Item], @ViewBuilder row: @escaping (Item) -> Row) {
        self.items = items
        self.row = row
    }

    var body: some View {
        VStack(spacing: 0) {
            Hairline()
            ForEach(items) { item in
                VStack(spacing: 0) {
                    row(item)
                    Hairline()
                }
                .transition(motion.animates ? .opacity : .identity)
            }
        }
    }
}

// MARK: - Status off

/// Status is off, so Home can't know anything: what to turn on.
struct HomeStatusOffView: View {
    let turnOn: () -> Void

    var body: some View {
        CenteredMessage(
            "Status Icons Are Off",
            systemImage: "eye.slash",
            description: "Home shows what needs you from each repository's status, which Espalier keeps up to date while status icons are on.",
            tint: .accent,
            tiles: .hand,
            isLarge: true
        ) {
            Button("Turn On Status Icons", action: turnOn)
                .buttonStyle(.prominent)
        }
        .fillingSpace()
    }
}

// MARK: - Metrics

extension Metrics {
    /// Home.
    nonisolated public enum Home {
        /// The page's sides, inside the detail area.
        public static let pageInset: CGFloat = 14
        /// Above the heading, under the toolbar.
        public static let topInset: CGFloat = 8
        /// Below the last section.
        public static let bottomInset: CGFloat = 20
        /// The heading's and the section labels' inset from the cards'
        /// edges.
        public static let labelInset: CGFloat = 6
        /// Between the title and the line under it.
        public static let headingLineSpacing: CGFloat = 4
        /// Under the heading.
        public static let headingBottom: CGFloat = 16
        /// Between Fetch All and Push All.
        public static let headingButtonSpacing: CGFloat = 9
        /// Under a section's label.
        public static let labelBottom: CGFloat = 9
        /// Between sections.
        public static let sectionSpacing: CGFloat = 18
        /// Between cards.
        public static let cardSpacing: CGFloat = 12
        /// The narrowest a card gets before a column goes.
        public static let cardMinWidth: CGFloat = 300
        /// The least a card is high.
        public static let cardMinHeight: CGFloat = 196
        /// Inside a card.
        public static let cardPadding = EdgeInsets(top: 15, leading: 16, bottom: 12, trailing: 16)
        /// Between a card's head, headline, and peek.
        public static let cardLineSpacing: CGFloat = 9
        /// Between a symbol and its text, and the parts of a line.
        public static let symbolSpacing: CGFloat = 7
        /// Between the peek's files.
        public static let peekSpacing: CGFloat = 5
        /// The status tiles in a card's peek.
        public static let peekTile: CGFloat = 19
        /// The mark before a headline.
        public static let markSize: CGFloat = 14
        /// The dot of unseen work.
        public static let unseenDot: CGFloat = 8
        /// A row of In Progress.
        public static let progressRowHeight: CGFloat = 40
        /// Inside In Progress's card.
        public static let progressInset: CGFloat = 6
        /// A row's sides.
        public static let rowPadding: CGFloat = 12
        /// Between the quiet repositories' names.
        public static let quietNameSpacing: CGFloat = 4
        /// How far a card or row starts from as it arrives.
        public static let arrivalScale: CGFloat = 0.97
        /// A plain row's top and bottom, where the theme draws plainly.
        public static let plainRowPadding: CGFloat = 10
    }
}
