// A branch's row in the sidebar's Branches section: a dot in the branch's
// color and its name (the branch you're on as a candy pill, its dot
// haloed: "you are here", or its name semibold, in the theme's way:
// `SidebarThemeStyle.currentBranch`; the default branch's dot is the
// trunk's color, and its tooltip says it's the default), the branch's pull
// request, and how it compares with its upstream ("↑2" and "↓3" in pills
// or as colored text, a dashed circle for not published, or its upstream
// gone), in the same form on every row. Value-driven: `BranchRowContent`
// is built from the models by `BranchesSectionContent`.

import EspalierCore
import GitHubKit
import GitKit
import SwiftUI

/// How a branch compares with its upstream, for the row's trailing text.
nonisolated public enum BranchTracking: Sendable, Equatable {
    /// No upstream (or not known): nothing shows.
    case none
    /// The commits only the branch has, and only its upstream has.
    case aheadBehind(ahead: Int, behind: Int)
    /// A local branch without an upstream.
    case notPublished
    /// The upstream is configured but gone from the remote.
    case upstreamGone

    /// "↑2 ↓3", leaving out zero counts, in `numberFormat`; nil when in
    /// sync or not tracking.
    public func countsText(_ numberFormat: NumberFormat) -> String? {
        guard case .aheadBehind(let ahead, let behind) = self else {
            return nil
        }
        var parts: [String] = []
        if ahead > 0 {
            parts.append("↑\(Self.formatCompactCount(ahead, numberFormat))")
        }
        if behind > 0 {
            parts.append("↓\(Self.formatCompactCount(behind, numberFormat))")
        }
        return parts.isEmpty ? nil : parts.joined(separator: " ")
    }

    /// What VoiceOver and the tooltip say, the counts in `numberFormat`.
    public func description(_ numberFormat: NumberFormat) -> String? {
        switch self {
        case .none:
            return nil
        case .aheadBehind(let ahead, let behind):
            var parts: [String] = []
            if ahead > 0 {
                parts.append("\(formatCount(ahead, numberFormat)) \(ahead == 1 ? "commit" : "commits") ahead")
            }
            if behind > 0 {
                parts.append("\(formatCount(behind, numberFormat)) \(behind == 1 ? "commit" : "commits") behind")
            }
            return parts.isEmpty ? "Up to date with its upstream" : parts.joined(separator: ", ")
        case .notPublished:
            return "Not published"
        case .upstreamGone:
            return "Its upstream branch is gone"
        }
    }

    /// A count in `numberFormat`, shrunk past 999 ("1.2k") as the sync
    /// button's.
    static func formatCompactCount(_ count: Int, _ numberFormat: NumberFormat) -> String {
        formatCompactNumber(Double(count), CompactFormatOptions(numberFormat: numberFormat))
    }
}

/// A branch's pull request, for the row's glyph.
nonisolated public struct BranchPullRequestBadge: Sendable, Equatable {
    public var number: Int
    public var isDraft: Bool
    /// The checks' state, when it's known.
    public var checks: ChecksState?

    public init(number: Int, isDraft: Bool, checks: ChecksState? = nil) {
        self.number = number
        self.isDraft = isDraft
        self.checks = checks
    }

    /// "Pull request #142 · Checks: Successful".
    public var tooltip: String {
        var text = isDraft ? "Draft pull request #\(number)" : "Pull request #\(number)"
        if let checks {
            text += " · Checks: \(checks.title)"
        }
        return text
    }

    /// The glyph's state for a pull request's combined checks, as every
    /// checks glyph shows it.
    public static func checksState(of check: CombinedRefCheck) -> ChecksState {
        CheckGlyphKind(status: check.status, conclusion: check.conclusion).tone
    }
}

/// What a branch row shows.
nonisolated public struct BranchRowContent: Sendable, Equatable, Identifiable {
    /// The branch's full ref, which the row selects (`SidebarPlace.branch`).
    public var ref: String
    /// The branch's name (`origin/feature/login` for a remote branch).
    public var name: String
    /// What the row says: the name's last component inside a folder, the
    /// name without the remote in a remote's group, else the name.
    public var title: String
    public var isCurrent: Bool
    public var isRemote: Bool
    public var tracking: BranchTracking
    public var pullRequest: BranchPullRequestBadge?
    /// The branch's commit, for its color in the graph.
    public var tipSHA: String?
    /// Whether it's the default branch (the trunk's color outside the
    /// graph).
    public var isDefault: Bool

    public init(
        ref: String,
        name: String,
        title: String? = nil,
        isCurrent: Bool = false,
        isRemote: Bool = false,
        tracking: BranchTracking = .none,
        pullRequest: BranchPullRequestBadge? = nil,
        tipSHA: String? = nil,
        isDefault: Bool = false
    ) {
        self.ref = ref
        self.name = name
        self.title = title ?? name
        self.isCurrent = isCurrent
        self.isRemote = isRemote
        self.tracking = tracking
        self.pullRequest = pullRequest
        self.tipSHA = tipSHA
        self.isDefault = isDefault
    }

    /// The dot's color outside the graph: the accent for the current
    /// branch, the trunk's color for the default one, else a palette entry
    /// by name.
    @MainActor
    public var fallbackColor: NSColor {
        TrackPalette.color(forBranch: name, isCurrent: isCurrent, isDefault: isDefault)
    }

    public var id: String {
        ref
    }

    /// The row's tooltip: the name, and that it's the default branch.
    public var tooltip: String {
        Self.tooltip(forBranch: name, isDefault: isDefault)
    }

    /// A branch row's tooltip, in the sidebar and the branch picker:
    /// "main (default branch)", or the name.
    static func tooltip(forBranch name: String, isDefault: Bool) -> String {
        isDefault ? "\(name) (default branch)" : name
    }

    /// The row as VoiceOver reads it: the name, then what the trailing
    /// glyphs say, counts in `numberFormat`.
    public func accessibilityLabel(_ numberFormat: NumberFormat) -> String {
        var parts = [name]
        if isCurrent {
            parts.append("current branch")
        }
        if isDefault {
            parts.append("default branch")
        }
        if let pullRequest {
            parts.append(pullRequest.tooltip)
        }
        if let tracking = tracking.description(numberFormat) {
            parts.append(tracking)
        }
        return parts.joined(separator: ", ")
    }
}

/// What trails a branch row's name: its pull request and how it compares
/// with its upstream.
nonisolated struct BranchRowMarks: Equatable {
    var pullRequest: BranchPullRequestBadge?
    var tracking: BranchTracking

    init(_ content: BranchRowContent) {
        pullRequest = content.pullRequest
        tracking = content.tracking
    }

    /// Whether changing from `old` animates: only a change to what the row
    /// already showed (a commit adding to "↑1", a push clearing it, a pull
    /// request's checks finishing). A comparison or checks loading, as for
    /// a row scrolled into view, and a pull request arriving or leaving
    /// show at once.
    func animates(from old: BranchRowMarks) -> Bool {
        if tracking != old.tracking, tracking == BranchTracking.none || old.tracking == BranchTracking.none {
            return false
        }
        if pullRequest != old.pullRequest {
            guard let pullRequest, let oldPullRequest = old.pullRequest,
                  pullRequest.number == oldPullRequest.number,
                  (pullRequest.checks == nil) == (oldPullRequest.checks == nil) else {
                return false
            }
        }
        return true
    }
}

/// A branch's row: a dot in its branch color, its name (the current one
/// marked in the theme's way, `BranchName`), the pull request glyph, and its comparison with its upstream; its tooltip is its name, and says when
/// it's the default branch. A change to what the row already showed
/// moves over 0.2 s (`BranchRowMarks.animates(from:)`): the counts roll,
/// the glyphs fade in and out, the checks' symbol is replaced, and what's
/// beside them slides.
public struct BranchRow: View {
    private let content: BranchRowContent
    private let dotColor: NSColor?
    /// The marks drawn last, which the next change is compared with.
    @State private var drawnMarks: BranchRowMarks
    @Environment(\.isSidebarRowSelected) private var isSelected
    @Environment(\.numberFormat) private var numberFormat
    @Environment(\.motion) private var motion

    /// - Parameter dotColor: The branch's color in the graph; nil for
    ///   `content.fallbackColor`.
    public init(_ content: BranchRowContent, dotColor: NSColor? = nil) {
        self.content = content
        self.dotColor = dotColor
        _drawnMarks = State(initialValue: BranchRowMarks(content))
    }

    public var body: some View {
        let marks = BranchRowMarks(content)
        let color = dotColor ?? content.fallbackColor
        HStack(spacing: Metrics.insetSmall) {
            BranchDot(color, isCurrent: content.isCurrent)
                .frame(width: Metrics.Sidebar.symbolWidth)
            BranchName(content.title, color: color, isCurrent: content.isCurrent) { isCurrent in
                SidebarRowFont.title(isSelected: isSelected, isEmphasized: isCurrent)
            }
            .foregroundStyle(.sidebarRowText(isSelected: isSelected))
            // The name first; what follows takes the room left.
            .layoutPriority(1)
            HStack(spacing: Metrics.insetSmall) {
                if let pullRequest = content.pullRequest {
                    PullRequestBadgeGlyph(pullRequest)
                }
                BranchTrackingView(content.tracking)
            }
            .frame(maxWidth: .infinity, alignment: .trailing)
            .layoutPriority(0.5)
            .animation(marks.animates(from: drawnMarks) ? motion.animation(Motion.kindChange) : nil, value: marks)
            .onChange(of: marks) { _, marks in
                drawnMarks = marks
            }
        }
        .tooltip(content.tooltip)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(content.accessibilityLabel(numberFormat))
    }
}

/// The trailing comparison, in the theme's way (`SidebarThemeStyle.counts`):
/// "↑2" in a pill of the accent's tint and "↓3" in a neutral pill, or "↑2"
/// in the accent and "↓3" as the sidebar's counts are, in SF Mono; a dashed
/// circle, "Not published" in its tooltip, for a branch that isn't published; a
/// crossed-out cloud, with a tooltip, for a branch whose upstream is gone
/// from its remote. Each takes one form whatever the row's width. Where
/// the row animates a change, the counts roll.
struct BranchTrackingView: View {
    let tracking: BranchTracking
    @Environment(\.isSidebarRowSelected) private var isSelected
    @Environment(\.numberFormat) private var numberFormat
    @Environment(\.motion) private var motion

    init(_ tracking: BranchTracking) {
        self.tracking = tracking
    }

    var body: some View {
        switch tracking {
        case .none:
            EmptyView()
        case .aheadBehind(let ahead, let behind):
            if tracking.countsText(numberFormat) != nil {
                HStack(spacing: Metrics.grid) {
                    if ahead > 0 {
                        AheadCount("↑\(BranchTracking.formatCompactCount(ahead, numberFormat))")
                            .contentTransition(motion.animates ? .numericText() : .identity)
                    }
                    if behind > 0 {
                        BehindCount("↓\(BranchTracking.formatCompactCount(behind, numberFormat))", color: .sidebarRowCount(isSelected: isSelected))
                            .contentTransition(motion.animates ? .numericText() : .identity)
                    }
                }
                .lineLimit(1)
                .fixedSize()
                .tooltip(tracking.description(numberFormat))
            }
        case .notPublished:
            Image(systemName: "circle.dashed")
                .font(Typography.secondary)
                .foregroundStyle(.sidebarRowCount(isSelected: isSelected))
                .tooltip(tracking.description(numberFormat))
                .accessibilityLabel(tracking.description(numberFormat) ?? "")
        case .upstreamGone:
            Image(systemName: "icloud.slash")
                .font(Typography.secondary)
                .foregroundStyle(.sidebarRowCount(isSelected: isSelected))
                .tooltip(tracking.description(numberFormat))
        }
    }
}

/// A pull request's glyph, drafts in a lighter tint, with its checks.
/// Where the row animates a change, the checks' symbol is replaced.
struct PullRequestBadgeGlyph: View {
    let badge: BranchPullRequestBadge
    @Environment(\.motion) private var motion

    init(_ badge: BranchPullRequestBadge) {
        self.badge = badge
    }

    var body: some View {
        HStack(spacing: Metrics.grid) {
            Image(systemName: PullRequestGlyph.systemImage)
                .foregroundStyle(badge.isDraft ? Color.text3 : .text2)
            if let checks = badge.checks {
                ChecksGlyph(checks)
                    .contentTransition(motion.animates ? .symbolEffect(.replace) : .identity)
            }
        }
        .font(Typography.secondary)
        .tooltip(badge.tooltip)
    }
}

/// A branch's dot in the theme's way (`SidebarThemeStyle.currentBranch`):
/// a candy dot, haloed for the current branch, or a plain dot.
struct BranchDot: View {
    private let color: NSColor
    private let isCurrent: Bool

    init(_ color: NSColor, isCurrent: Bool) {
        self.color = color
        self.isCurrent = isCurrent
    }

    var body: some View {
        switch Theme.current.style.sidebar.currentBranch {
        case .pill:
            CandyDot(color, isHere: isCurrent)
        case .semibold:
            Circle()
                .fill(Color(nsColor: color))
                .frame(width: Metrics.Sidebar.dotSize, height: Metrics.Sidebar.dotSize)
                .accessibilityHidden(true)
        }
    }
}

/// A branch's name, the current one marked in the theme's way
/// (`SidebarThemeStyle.currentBranch`): in a candy pill of its color, or in
/// `font(true)`, semibold. Other names are in `font(false)`.
struct BranchName: View {
    private let name: String
    private let color: NSColor
    private let isCurrent: Bool
    private let font: (Bool) -> Font

    init(_ name: String, color: NSColor, isCurrent: Bool, font: @escaping (Bool) -> Font) {
        self.name = name
        self.color = color
        self.isCurrent = isCurrent
        self.font = font
    }

    var body: some View {
        if isCurrent, Theme.current.style.sidebar.currentBranch == .pill {
            // You are here: the name in a pill of its color.
            CandyPill(name, color: color, size: .regular)
        } else {
            Text(name)
                .font(font(isCurrent))
                .lineLimit(1)
                .truncationMode(.middle)
        }
    }
}

/// An ahead count ("↑2") in the theme's way (`SidebarThemeStyle.counts`):
/// in a pill of the accent's tint, or in the accent in SF Mono.
struct AheadCount: View {
    private let text: String

    init(_ text: String) {
        self.text = text
    }

    var body: some View {
        switch Theme.current.style.sidebar.counts {
        case .pills:
            CountPill(text, color: Palette.accent)
        case .text:
            Text(verbatim: text)
                .font(Typography.aheadCount)
                .foregroundStyle(.accent)
        }
    }
}

/// A behind count ("↓3") in the theme's way (`SidebarThemeStyle.counts`):
/// in a neutral pill, or in `color` in SF Mono.
struct BehindCount: View {
    private let text: String
    private let color: Color

    init(_ text: String, color: Color) {
        self.text = text
        self.color = color
    }

    var body: some View {
        switch Theme.current.style.sidebar.counts {
        case .pills:
            CountPill(text)
        case .text:
            Text(verbatim: text)
                .font(Typography.secondaryCount)
                .foregroundStyle(color)
        }
    }
}
