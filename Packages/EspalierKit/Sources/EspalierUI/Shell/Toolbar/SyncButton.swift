// The sync button, a split button whose chevron lists the alternatives.
// `SyncAction` decides the state, read in one function
// (`SyncButtonState.make`); this file adds what the button shows besides:
// the counts, the last fetch, and the background failure.

import EspalierCore
import GitHubKit
import GitKit
import SwiftUI

/// The sync button's state: one of nine, in order (the first match wins),
/// or nothing until the repository's state has loaded.
nonisolated public struct SyncButtonState: Sendable, Equatable {
    /// Which of the nine states, or loading.
    public enum Kind: Sendable, Equatable {
        /// 1. A push, pull, or fetch runs: what it is ("Fetching origin"),
        /// git's step (or "Hang on…"), and how far it has got. The button
        /// shows `shown`, the state whose action runs, quiet or blue as it
        /// is, with the arc in its symbol's place; for an operation that
        /// isn't one of the button's (nil), the arc and `title`.
        indirect case progress(title: String, description: String, value: Double?, shown: Kind?)
        /// Then, until the repository's status, remotes, and refs have
        /// loaded: nothing shows.
        case loading
        /// 2. No remote: publish the repository.
        case publishRepository
        /// 3. An unborn branch: fetch.
        case fetchUnborn(remote: String)
        /// 4. A detached HEAD: nothing to publish.
        case detachedHead(rebaseInProgress: Bool)
        /// 5. The branch has no upstream: publish it.
        case publishBranch(isGitHubRepository: Bool, remote: String)
        /// 6. Rewritten history: force push.
        case forcePush(remote: String, aheadBehind: AheadBehind, tagsToPush: Int)
        /// 7. Behind: pull (diverged branches can also force push).
        case pull(remote: String, withRebase: Bool, aheadBehind: AheadBehind, tagsToPush: Int, canForcePush: Bool)
        /// 8. Ahead, or tags to push: push.
        case push(remote: String, aheadBehind: AheadBehind, tagsToPush: Int)
        /// 9. In sync: fetch.
        case fetch(remote: String)

        /// Whether `other` offers the same action: a fetch (on an unborn
        /// branch or not), a push (forced or not), a pull, or publishing the
        /// branch or the repository.
        nonisolated func offersSameAction(as other: Kind) -> Bool {
            switch (self, other) {
            case (.fetch, .fetch), (.fetch, .fetchUnborn), (.fetchUnborn, .fetch), (.fetchUnborn, .fetchUnborn),
                 (.push, .push), (.push, .forcePush), (.forcePush, .push), (.forcePush, .forcePush),
                 (.pull, .pull), (.publishBranch, .publishBranch), (.publishRepository, .publishRepository):
                true
            default:
                false
            }
        }
    }

    public var kind: Kind
    /// When the repository was last fetched.
    public var lastFetched: Date?
    /// The last background failure, shown as a badge.
    public var backgroundFailure: BackgroundFailureSummary?
    /// Whether a force push asks first (the menu item shows a warning when
    /// it doesn't).
    public var asksBeforeForcePush: Bool

    public init(kind: Kind, lastFetched: Date? = nil, backgroundFailure: BackgroundFailureSummary? = nil, asksBeforeForcePush: Bool = true) {
        self.kind = kind
        self.lastFetched = lastFetched
        self.backgroundFailure = backgroundFailure
        self.asksBeforeForcePush = asksBeforeForcePush
    }

    /// The state whose label the button shows: while a push, pull, or fetch
    /// runs, the one whose action runs (nil for another operation);
    /// otherwise this one.
    private var shownKind: Kind? {
        if case .progress(_, _, _, let shown) = kind { shown } else { kind }
    }

    /// The button's title: while an operation that isn't one of the
    /// button's runs, the operation's.
    public var title: String {
        switch kind {
        case .progress(let title, _, _, let shown): shown.map { SyncButtonState(kind: $0).title } ?? title
        case .loading: ""
        case .publishRepository: "Publish Repository"
        case .fetchUnborn(let remote), .fetch(let remote): "Fetch \(remote)"
        case .detachedHead, .publishBranch: "Publish Branch"
        case .forcePush(let remote, _, _): "Force Push \(remote)"
        case .pull(let remote, let withRebase, _, _, _): withRebase ? "Pull \(remote) with Rebase" : "Pull \(remote)"
        case .push(let remote, _, _): "Push \(remote)"
        }
    }

    /// While a push, pull, or fetch runs: what it is ("Fetching origin").
    public var activityTitle: String? {
        if case .progress(let title, _, _, _) = kind { title } else { nil }
    }

    /// The button's tooltip and the menu's header; while an operation runs,
    /// what it is and git's step ("Fetching origin", "Receiving objects").
    public func detail(now: Date, formatting: DateTimeFormatting = DateTimeFormatting(), timeZone: TimeZone = .current) -> String {
        switch kind {
        case .progress(let title, let description, _, _):
            return "\(title)\n\(description)"
        case .loading:
            return ""
        case .publishRepository:
            return "Publish this repository to GitHub"
        case .detachedHead(let rebaseInProgress):
            return rebaseInProgress ? "Rebase in progress" : "Can't publish a detached HEAD"
        case .publishBranch(let isGitHubRepository, _):
            return isGitHubRepository ? "Publish this branch to GitHub" : "Publish this branch to the remote"
        case .fetchUnborn, .forcePush, .pull, .push, .fetch:
            return RelativeTime.lastFetched(lastFetched, now: now, formatting: formatting, timeZone: timeZone)
        }
    }

    /// The symbol; while an operation runs, the one whose place the arc
    /// takes (none for an operation that isn't one of the button's). Nil
    /// while loading.
    public var systemImage: String? {
        switch shownKind {
        case .progress?, .loading?, nil: nil
        case .publishRepository?, .detachedHead?, .publishBranch?: "arrow.up.to.line"
        case .fetchUnborn?, .fetch?: "arrow.trianglehead.2.clockwise.rotate.90"
        case .forcePush?: "exclamationmark.arrow.trianglehead.counterclockwise.rotate.90"
        case .pull?: "arrow.down"
        case .push?: "arrow.up"
        }
    }

    /// Whether a push, pull, or fetch runs (state 1).
    public var isInProgress: Bool {
        if case .progress = kind { true } else { false }
    }

    /// Whether the repository's state is still loading: nothing shows.
    public var isLoading: Bool {
        if case .loading = kind { true } else { false }
    }

    /// The progress, 0 to 1, while one runs.
    public var progress: Double? {
        if case .progress(_, _, let value, _) = kind { value } else { nil }
    }

    /// Whether the button does anything: not while a network operation
    /// runs, while loading, nor on a detached HEAD.
    public var isEnabled: Bool {
        switch kind {
        case .progress, .loading, .detachedHead: false
        default: true
        }
    }

    /// Whether the button is the toolbar's one prominent item: when it has
    /// work to do (publish, push, pull, force push), and while that work
    /// runs.
    public var isProminent: Bool {
        switch shownKind {
        case .publishRepository?, .publishBranch?, .forcePush?, .pull?, .push?: true
        default: false
        }
    }

    /// The ahead count ("↑2"): commits plus tags to push, compact, in
    /// `numberFormat`; nil when zero.
    public func aheadCount(_ numberFormat: NumberFormat) -> String? {
        let (aheadBehind, tags): (AheadBehind?, Int) = switch shownKind {
        case .forcePush(_, let aheadBehind, let tags)?, .pull(_, _, let aheadBehind, let tags, _)?, .push(_, let aheadBehind, let tags)?: (aheadBehind, tags)
        default: (nil, 0)
        }
        guard let aheadBehind, aheadBehind.ahead + tags > 0 else {
            return nil
        }
        return formatCompactNumber(Double(aheadBehind.ahead + tags), CompactFormatOptions(numberFormat: numberFormat))
    }

    /// The behind count ("↓3"), compact, in `numberFormat`; nil when zero.
    public func behindCount(_ numberFormat: NumberFormat) -> String? {
        let aheadBehind: AheadBehind? = switch shownKind {
        case .forcePush(_, let aheadBehind, _)?, .pull(_, _, let aheadBehind, _, _)?, .push(_, let aheadBehind, _)?: aheadBehind
        default: nil
        }
        guard let aheadBehind, aheadBehind.behind > 0 else {
            return nil
        }
        return formatCompactNumber(Double(aheadBehind.behind), CompactFormatOptions(numberFormat: numberFormat))
    }

    /// The button's label: the title, then the counts in `numberFormat`
    /// ("Push origin ↑2"; "Pull origin ↓3 ↑2", behind first when pulling).
    public func label(_ numberFormat: NumberFormat) -> String {
        ([title] + [countsText(numberFormat)].compactMap { $0 }).joined(separator: " ")
    }

    /// What VoiceOver calls the button: its label, or while an operation
    /// runs, what it is ("Fetching origin").
    public func accessibilityTitle(_ numberFormat: NumberFormat) -> String {
        activityTitle ?? label(numberFormat)
    }

    /// The counts after the title in `numberFormat` ("↑2"; "↓3 ↑2", behind
    /// first when pulling); nil when there are none.
    public func countsText(_ numberFormat: NumberFormat) -> String? {
        let ahead = aheadCount(numberFormat).map { "↑\($0)" }
        let behind = behindCount(numberFormat).map { "↓\($0)" }
        let counts: [String?] = if case .pull? = shownKind { [behind, ahead] } else { [ahead, behind] }
        let shown = counts.compactMap { $0 }
        return shown.isEmpty ? nil : shown.joined(separator: " ")
    }

    /// Whether "Fetched 2 minutes ago" shows beside the button: when its
    /// detail is the last fetch and there was one.
    public var showsLastFetched: Bool {
        switch kind {
        case .fetchUnborn, .forcePush, .pull, .push, .fetch: lastFetched != nil
        case .progress, .loading, .publishRepository, .detachedHead, .publishBranch: false
        }
    }

    /// The chevron's items; while an operation runs, those of the state
    /// whose action runs, which the button shows but doesn't open.
    public var menuItems: [SyncMenuItem] {
        switch shownKind {
        case .publishBranch(_, let remote)?, .forcePush(let remote, _, _)?, .push(let remote, _, _)?:
            [.fetch(remote: remote)]
        case .pull(let remote, _, _, _, let canForcePush)?:
            canForcePush
                ? [.fetch(remote: remote), .forcePush(remote: remote, showsWarning: !asksBeforeForcePush)]
                : [.fetch(remote: remote)]
        default:
            []
        }
    }

    /// Whether the button has its chevron: with alternatives or a
    /// background failure, as the state whose action runs had it.
    public var hasMenu: Bool {
        shownKind != nil && (!menuItems.isEmpty || backgroundFailure != nil)
    }

    /// While a push, pull, or fetch runs: `settled`, the state the button
    /// showed before it started, with this progress, when the operation is
    /// the action it offered (or no action of the button's), so the button
    /// and the last fetch stay as they were. Otherwise this state.
    func keeping(_ settled: SyncButtonState?) -> SyncButtonState {
        guard case .progress(let title, let description, let value, let shown) = kind,
              let settled, !settled.isInProgress, !settled.isLoading,
              shown.map({ $0.offersSameAction(as: settled.kind) }) ?? true
        else {
            return self
        }
        return SyncButtonState(
            kind: .progress(title: title, description: description, value: value, shown: settled.kind),
            lastFetched: settled.lastFetched,
            backgroundFailure: settled.backgroundFailure,
            asksBeforeForcePush: settled.asksBeforeForcePush
        )
    }

    /// The state for a repository: its `SyncAction`, with the last fetch,
    /// the background failure, and whether a force push asks first.
    @MainActor
    public static func make(_ repository: RepositoryModel, preferences: Preferences) -> SyncButtonState {
        SyncButtonState(
            kind: kind(repository.sync.action, repository: repository),
            lastFetched: repository.gitState.lastFetched,
            backgroundFailure: repository.lastBackgroundFailure.map(BackgroundFailureSummary.init),
            asksBeforeForcePush: preferences.confirmForcePush
        )
    }

    /// The button's state for a `SyncAction`. The action has one fetch state
    /// for an unborn branch and for a branch with nothing to push or pull;
    /// the button tells them apart as 3 and 9.
    @MainActor
    private static func kind(_ action: SyncAction, repository: RepositoryModel) -> Kind {
        switch action {
        case .inProgress:
            return progress(repository.networkOperation, repository: repository)
        case .loading:
            return .loading
        case .publishRepository:
            return .publishRepository
        case .fetch(let remote):
            if case .unborn = repository.gitState.tip {
                return .fetchUnborn(remote: remote)
            }
            return .fetch(remote: remote)
        case .detachedHead(let rebaseInProgress):
            return .detachedHead(rebaseInProgress: rebaseInProgress)
        case .publishBranch(let remote, let isGitHubRepository):
            return .publishBranch(isGitHubRepository: isGitHubRepository, remote: remote)
        case .forcePush(let remote, let aheadBehind, let tagsToPush):
            return .forcePush(remote: remote, aheadBehind: aheadBehind, tagsToPush: tagsToPush)
        case .pull(let remote, let aheadBehind, let tagsToPush, let withRebase, let forcePushAvailable):
            return .pull(remote: remote, withRebase: withRebase, aheadBehind: aheadBehind, tagsToPush: tagsToPush, canForcePush: forcePushAvailable)
        case .push(let remote, let aheadBehind, let tagsToPush):
            return .push(remote: remote, aheadBehind: aheadBehind, tagsToPush: tagsToPush)
        }
    }

    /// State 1: the operation's progress. A push, pull, or fetch keeps its
    /// kind's title from start to end ("Fetching origin"), through the
    /// fetch after a push and the last step's "Refreshing Repository"; with
    /// the progress's description ("Receiving objects", "Fast-forwarding
    /// branches", or "Hang on…"), it's the tooltip. The button shows the
    /// operation's action, which `SyncButtonGroup` replaces with the state
    /// it showed before when that offered the same action.
    @MainActor
    private static func progress(_ operation: ActiveOperation?, repository: RepositoryModel) -> Kind {
        let remote = repository.gitState.remotes.currentRemote?.name ?? "origin"
        let nothing = AheadBehind(ahead: 0, behind: 0)
        let (title, shown): (String, Kind?) = switch operation?.kind {
        case .push?:
            ("Pushing to \(remote)", .push(remote: remote, aheadBehind: nothing, tagsToPush: 0))
        case .publishBranch?:
            ("Pushing to \(remote)", .publishBranch(isGitHubRepository: repository.record.gitHubRepository != nil, remote: remote))
        case .publishRepository?:
            ("Pushing to \(remote)", .publishRepository)
        case .pull?:
            (
                "Pulling \(remote)",
                .pull(remote: remote, withRebase: repository.gitState.branches.pullWithRebase ?? false, aheadBehind: nothing, tagsToPush: 0, canForcePush: false)
            )
        case .fetch?, .fetchRefspec?:
            ("Fetching \(remote)", .fetch(remote: remote))
        default:
            (operation?.progress?.title ?? "Refreshing Repository", nil)
        }
        let description = operation?.progress?.description.flatMap { $0.isEmpty ? nil : $0 } ?? "Hang on…"
        return .progress(title: title, description: description, value: operation?.progress?.value, shown: shown)
    }
}

/// An item in the sync button's menu.
nonisolated public enum SyncMenuItem: Sendable, Equatable {
    case fetch(remote: String)
    /// Force push; without the confirmation, the item shows a warning.
    case forcePush(remote: String, showsWarning: Bool)

    /// The action's title; a force push that asks first ends in an
    /// ellipsis, as the Repository menu's Force Push does.
    public var title: String {
        switch self {
        case .fetch(let remote): SyncAlternative.fetch(remote: remote).title
        case .forcePush(let remote, let showsWarning): SyncAlternative.forcePush(remote: remote).title + (showsWarning ? "" : "…")
        }
    }

    /// The action's description; a force push that doesn't ask first adds a
    /// warning.
    public var description: String {
        switch self {
        case .fetch(let remote):
            SyncAlternative.fetch(remote: remote).description
        case .forcePush(let remote, let showsWarning):
            SyncAlternative.forcePush(remote: remote).description
                + (showsWarning ? "\nWarning: \(SyncAlternative.forcePushWarning)" : "")
        }
    }

    public var systemImage: String {
        switch self {
        case .fetch: "arrow.trianglehead.2.clockwise.rotate.90"
        case .forcePush: "exclamationmark.arrow.trianglehead.counterclockwise.rotate.90"
        }
    }
}

// MARK: - The view

/// The sync button, value-driven: it draws `SyncButtonState`. A capsule:
/// prominent while there's something to push, pull, publish, or force
/// push, and while that runs; quiet otherwise. With alternatives (Fetch,
/// Force Push) or a background failure, a chevron opens its menu. While a
/// push, pull, or fetch runs, the button keeps its capsule, words, and
/// width, the arc turns or fills in its symbol's place, and it takes no
/// clicks. Nothing while the repository's state loads.
public struct SyncButtonView: View {
    private let state: SyncButtonState
    private let onPrimary: () -> Void
    private let onMenuItem: (SyncMenuItem) -> Void
    private let onShowFailure: () -> Void
    @Environment(\.dateTimeFormatting) private var formatting
    @Environment(\.timeZone) private var timeZone
    @Environment(\.numberFormat) private var numberFormat

    /// How far left of the button's trailing edge the capsules of a
    /// crossfade can reach: more than the widest capsule.
    private static let crossfadeReach: CGFloat = 640

    public init(
        _ state: SyncButtonState,
        onPrimary: @escaping () -> Void = {},
        onMenuItem: @escaping (SyncMenuItem) -> Void = { _ in },
        onShowFailure: @escaping () -> Void = {}
    ) {
        self.state = state
        self.onPrimary = onPrimary
        self.onMenuItem = onMenuItem
        self.onShowFailure = onShowFailure
    }

    /// Which capsule the button is, without its words: a change of it (quiet
    /// ↔ blue, the split chevron coming or going, progress starting or
    /// ending) crossfades the fill, label, and symbol over 0.2 s.
    private struct Look: Hashable {
        var kind: CapsuleButtonKind
        var hasMenu: Bool
        /// A push, pull, or fetch runs: the capsule shows it and takes no
        /// clicks.
        var isBusy: Bool
    }

    private var look: Look {
        Look(kind: state.isProminent ? .prominent : .quiet, hasMenu: state.hasMenu, isBusy: state.isInProgress)
    }

    public var body: some View {
        // Nothing while the repository's state loads; the button then shows
        // at once, with no crossfade.
        if !state.isLoading {
            // The capsule, unseen, sizes the button. The one seen is drawn
            // over it, in a frame reaching far left of the button's trailing
            // edge: a capsule crossfading out keeps its place in that frame,
            // so its trailing edge stays on the new one's whatever their
            // widths.
            control(look, detail: "", isPlaceholder: true)
                .hidden()
                .accessibilityHidden(true)
                .overlay(alignment: .trailing) {
                    ZStack(alignment: .trailing) {
                        Color.clear
                        capsule
                            .id(look)
                            .transition(.opacity)
                    }
                    .frame(width: Self.crossfadeReach, alignment: .trailing)
                    .motion(Motion.kindChange, value: look)
                }
        }
    }

    @ViewBuilder
    private var capsule: some View {
        let detail = state.detail(now: Date(), formatting: formatting, timeZone: timeZone)
        if case .progress(_, let description, _, _) = state.kind {
            // While it runs: the capsule it was, legible, taking no clicks;
            // what runs and git's step are its tooltip.
            control(look, detail: detail)
                .allowsHitTesting(false)
                .overlay {
                    Color.clear
                        .contentShape(Capsule(style: .circular))
                        .tooltip(detail)
                }
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(state.accessibilityTitle(numberFormat))
                .accessibilityValue(description)
        } else {
            control(look, detail: detail)
                .disabled(!state.isEnabled)
                .tooltip(detail)
        }
    }

    /// The plain or split capsule `look` describes. As the placeholder that
    /// sizes the button, it draws no arc.
    @ViewBuilder
    private func control(_ look: Look, detail: String, isPlaceholder: Bool = false) -> some View {
        if look.hasMenu {
            SplitCapsuleButton(look.kind, menuLabel: "Sync Options", action: onPrimary) {
                label(kind: look.kind, detail: detail, drawsArc: !isPlaceholder)
            } menu: {
                menu(detail: detail)
            }
        } else {
            Button(action: onPrimary) {
                label(kind: look.kind, detail: detail, drawsArc: !isPlaceholder)
            }
            .buttonStyle(CapsuleButtonStyle(look.kind))
        }
    }

    /// The chevron's menu: the alternatives under the last fetch, and the
    /// background failure.
    @MenuBuilder
    private func menu(detail: String) -> MenuContent {
        MenuSection(detail) {
            for item in state.menuItems {
                MenuAction(item.title, systemImage: item.systemImage, subtitle: item.description) {
                    onMenuItem(item)
                }
            }
        }
        if let failure = state.backgroundFailure {
            MenuSection {
                MenuAction("\(failure.menuTitle) — Show Details…", action: onShowFailure)
            }
        }
    }

    /// The symbol (with the failure badge drawn into it, so it survives
    /// menu and toolbar labels, which keep only an image and a title), the
    /// title, and its counts in SF Mono ("Push origin ↑2").
    private func label(kind: CapsuleButtonKind, detail: String, drawsArc: Bool) -> some View {
        let symbolColor: NSColor = kind == .prominent ? Palette.buttonText : Palette.text2
        return HStack(spacing: Metrics.ControlHeight.symbolSpacing) {
            symbol(color: symbolColor, drawsArc: drawsArc)
            Text(state.title)
                .lineLimit(1)
            if let counts = state.countsText(numberFormat) {
                // The counts roll to a new value over 0.2 s (a commit adds
                // one to push).
                Text(counts)
                    .font(Typography.aheadCount)
                    .opacity(0.9)
                    .lineLimit(1)
                    .fixedSize()
                    .contentTransition(.numericText())
                    .motion(Motion.kindChange, value: counts)
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(state.label(numberFormat))
        .accessibilityValue(detail)
    }

    /// The symbol; while an operation runs, the arc in its place, which
    /// keeps the symbol's width, or the arc alone for an operation that
    /// isn't one of the button's.
    @ViewBuilder
    private func symbol(color: NSColor, drawsArc: Bool) -> some View {
        // Until git reports how far it has got, the arc turns rather than
        // sitting at zero.
        let arc = ArcProgress(.mini, value: state.progress.flatMap { $0 > 0 ? $0 : nil }, tint: color)
        if let systemImage = state.systemImage {
            if state.isInProgress {
                symbolImage(systemImage, color: color)
                    .hidden()
                    .overlay {
                        if drawsArc {
                            arc
                        }
                    }
            } else {
                symbolImage(systemImage, color: color)
            }
        } else if drawsArc {
            arc
        } else {
            Color.clear
                .frame(width: Metrics.Progress.ArcSize.mini.side, height: Metrics.Progress.ArcSize.mini.side)
        }
    }

    @ViewBuilder
    private func symbolImage(_ systemImage: String, color: NSColor) -> some View {
        if state.backgroundFailure != nil {
            Image(nsImage: BadgedSymbol.image(systemName: systemImage, pointSize: 12, color: color))
        } else {
            Image(systemName: systemImage)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(Color(nsColor: color))
        }
    }
}

/// A symbol with the background failure's warning badge at its top right.
enum BadgedSymbol {
    static func image(systemName: String, pointSize: CGFloat = NSFont.systemFontSize, color: NSColor = .labelColor) -> NSImage {
        let symbolConfiguration = NSImage.SymbolConfiguration(pointSize: pointSize, weight: .semibold)
        let badgeConfiguration = NSImage.SymbolConfiguration(pointSize: pointSize * 0.62, weight: .bold)
            .applying(.init(paletteColors: [Palette.warningMark]))
        let symbol = NSImage(systemSymbolName: systemName, accessibilityDescription: nil)?.withSymbolConfiguration(symbolConfiguration)
        let badge = NSImage(systemSymbolName: "exclamationmark.triangle.fill", accessibilityDescription: "Background fetch failed")?
            .withSymbolConfiguration(badgeConfiguration)
        let size = CGSize(width: (symbol?.size.width ?? pointSize) + 4, height: (symbol?.size.height ?? pointSize) + 2)
        let image = NSImage(size: size, flipped: false) { rect in
            if let symbol {
                // The symbol in the capsule's symbol color, as a template
                // would draw.
                let tinted = NSImage(size: symbol.size, flipped: false) { symbolRect in
                    symbol.draw(in: symbolRect)
                    color.set()
                    symbolRect.fill(using: .sourceAtop)
                    return true
                }
                tinted.draw(in: CGRect(x: 0, y: 0, width: symbol.size.width, height: symbol.size.height))
            }
            if let badge {
                badge.draw(in: CGRect(x: rect.maxX - badge.size.width, y: rect.maxY - badge.size.height, width: badge.size.width, height: badge.size.height))
            }
            return true
        }
        image.accessibilityDescription = "Background fetch failed"
        return image
    }
}

/// "Fetched 2 minutes ago", beside the sync button, while the button's
/// detail is the last fetch.
public struct LastFetchedLabel: View {
    private let lastFetched: Date?
    @Environment(\.dateTimeFormatting) private var formatting
    @Environment(\.timeZone) private var timeZone

    public init(_ state: SyncButtonState) {
        self.init(lastFetched: state.showsLastFetched ? state.lastFetched : nil)
    }

    /// "Fetched" and `lastFetched`; nothing when it's nil.
    init(lastFetched: Date?) {
        self.lastFetched = lastFetched
    }

    public var body: some View {
        if let lastFetched {
            TimelineView(.everyMinute) { context in
                Text("Fetched \(RelativeTime.describe(lastFetched, now: context.date, formatting: formatting, timeZone: timeZone))")
                    .font(Typography.meta)
                    .foregroundStyle(.text3)
                    .lineLimit(1)
                    .fixedSize()
            }
            .accessibilityHidden(true)
        }
    }
}

/// The last fetch and the sync button, side by side, as the toolbar shows
/// them. While the repository's state loads, neither shows, and the group
/// keeps the width it last had, so the search field beside it stays put.
/// While a push, pull, or fetch runs, the button and the last fetch show
/// what they showed before it started, when it's the action the button
/// offered (or none of the button's), and the group doesn't narrow: the
/// button keeps its trailing edge, and the search field its place.
public struct SyncButtonGroup: View {
    private let state: SyncButtonState
    private let scope: AnyHashable?
    private let onPrimary: () -> Void
    private let onMenuItem: (SyncMenuItem) -> Void
    private let onShowFailure: () -> Void
    /// The width the group last had with something to show.
    @State private var shownWidth: CGFloat?
    /// The last state that wasn't progress or loading.
    @State private var settled: Settled?

    /// A state the group showed, and what it belonged to.
    private struct Settled: Equatable {
        let scope: AnyHashable?
        let state: SyncButtonState
    }

    /// - Parameters:
    ///   - scope: What the state belongs to (the repository): what the
    ///     group showed for another doesn't stay while an operation runs.
    public init(
        _ state: SyncButtonState,
        scope: AnyHashable? = nil,
        onPrimary: @escaping () -> Void = {},
        onMenuItem: @escaping (SyncMenuItem) -> Void = { _ in },
        onShowFailure: @escaping () -> Void = {}
    ) {
        self.state = state
        self.scope = scope
        self.onPrimary = onPrimary
        self.onMenuItem = onMenuItem
        self.onShowFailure = onShowFailure
    }

    public var body: some View {
        let settledHere = settled.flatMap { $0.scope == scope ? $0.state : nil }
        let shown = state.keeping(settledHere)
        let isLoading = shown.isLoading
        let isInProgress = shown.isInProgress
        HStack(spacing: 10) {
            LastFetchedLabel(lastFetched: Self.lastFetched(shown, settled: settledHere))
                // Over a wider capsule crossfading out as the button narrows.
                .zIndex(1)
            SyncButtonView(shown, onPrimary: onPrimary, onMenuItem: onMenuItem, onShowFailure: onShowFailure)
                .controlSize(.large)
        }
        .frame(width: isLoading ? shownWidth : nil)
        .frame(minWidth: isInProgress ? shownWidth : nil, alignment: .trailing)
        .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { width in
            if !isLoading {
                shownWidth = width
            }
        }
        .onChange(of: isInProgress || isLoading ? nil : Settled(scope: scope, state: state), initial: true) { _, newSettled in
            if let newSettled {
                settled = newSettled
            }
        }
    }

    /// The last fetch the label shows for `state`: while an operation runs,
    /// what it showed before (the last fetch, if it showed, else none).
    private static func lastFetched(_ state: SyncButtonState, settled: SyncButtonState?) -> Date? {
        if state.isInProgress {
            guard let settled else {
                return state.lastFetched
            }
            return settled.showsLastFetched ? settled.lastFetched : nil
        }
        return state.showsLastFetched ? state.lastFetched : nil
    }
}

/// The toolbar's sync button for the selected repository.
struct SyncButton: View {
    let repository: RepositoryModel
    @Environment(WindowContext.self) private var context
    @State private var isShowingFailure = false

    var body: some View {
        let state = SyncButtonState.make(repository, preferences: context.app.preferences)
        SyncButtonGroup(state, scope: AnyHashable(ObjectIdentifier(repository)), onPrimary: {
            primaryAction(state)
        }, onMenuItem: { item in
            switch item {
            case .fetch: context.actions.perform(.fetch)
            case .forcePush: context.actions.perform(.forcePush)
            }
        }, onShowFailure: {
            isShowingFailure = true
        })
        // Another repository's button shows at once, as navigation between
        // repositories does.
        .motionScope(AnyHashable(ObjectIdentifier(repository)))
        .popoverCard(isPresented: $isShowingFailure, title: repository.lastBackgroundFailure.map { BackgroundFailureSummary($0).menuTitle }) {
            if let failure = repository.lastBackgroundFailure {
                BackgroundFailureDetails(BackgroundFailureSummary(failure)) { index in
                    isShowingFailure = false
                    let recoveries = failure.error.recoveries
                    guard recoveries.indices.contains(index) else {
                        return
                    }
                    Task { await context.presenter.run(recoveries[index]) }
                }
            }
        }
    }

    private func primaryAction(_ state: SyncButtonState) {
        switch state.kind {
        case .progress, .loading, .detachedHead:
            break
        case .publishRepository:
            context.actions.perform(.publishRepository)
        case .publishBranch:
            context.actions.perform(.publishBranch)
        case .fetchUnborn, .fetch:
            context.actions.perform(.fetch)
        case .forcePush:
            context.actions.perform(.forcePush)
        case .pull:
            context.actions.perform(.pull)
        case .push:
            context.actions.perform(.push)
        }
    }
}
