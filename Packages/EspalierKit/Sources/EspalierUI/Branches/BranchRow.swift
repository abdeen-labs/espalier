// A branch's row in the sidebar's Branches section: the name (the current
// branch's semibold, the one way it's marked; the default branch's dot is
// the trunk's color, Classic's teal, and its tooltip says it's the
// default), the branch's pull request, and how it compares with its
// upstream ("↑2 ↓3", a dashed circle for not published, or its upstream
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

/// A branch's row: a dot in its branch color, its name (the current one
/// semibold, a selected one medium), the pull request glyph, and its
/// comparison with its upstream; its tooltip is its name, and says when
/// it's the default branch.
public struct BranchRow: View {
    private let content: BranchRowContent
    private let dotColor: NSColor?
    @Environment(\.isSidebarRowSelected) private var isSelected
    @Environment(\.numberFormat) private var numberFormat

    /// - Parameter dotColor: The branch's color in the graph; nil for
    ///   `content.fallbackColor`.
    public init(_ content: BranchRowContent, dotColor: NSColor? = nil) {
        self.content = content
        self.dotColor = dotColor
    }

    public var body: some View {
        HStack(spacing: Metrics.insetSmall) {
            Circle()
                .fill(Color(nsColor: dotColor ?? content.fallbackColor))
                .frame(width: Metrics.Sidebar.dotSize, height: Metrics.Sidebar.dotSize)
                .frame(width: Metrics.Sidebar.symbolWidth)
                .accessibilityHidden(true)
            Text(content.title)
                .font(SidebarRowFont.title(isSelected: isSelected, isEmphasized: content.isCurrent))
                .foregroundStyle(.sidebarRowText(isSelected: isSelected))
                .lineLimit(1)
                .truncationMode(.middle)
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
        }
        .tooltip(content.tooltip)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(content.accessibilityLabel(numberFormat))
    }
}

/// The trailing comparison: "↑2" in the theme's ahead color (Classic's
/// accent) and "↓3" as the sidebar's counts are
/// (`sidebarRowCount(isSelected:)`), in SF Mono; a dashed circle, "Not
/// published" in its tooltip, for a branch that isn't published; a
/// crossed-out cloud, with a tooltip, for a branch whose upstream is gone
/// from its remote. Each takes one form whatever the row's width.
struct BranchTrackingView: View {
    let tracking: BranchTracking
    @Environment(\.isSidebarRowSelected) private var isSelected
    @Environment(\.numberFormat) private var numberFormat

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
                        Text("↑\(BranchTracking.formatCompactCount(ahead, numberFormat))")
                            .font(Typography.aheadCount)
                            .foregroundStyle(.aheadText)
                    }
                    if behind > 0 {
                        Text("↓\(BranchTracking.formatCompactCount(behind, numberFormat))")
                            .font(Typography.secondaryCount)
                            .foregroundStyle(.sidebarRowCount(isSelected: isSelected))
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
struct PullRequestBadgeGlyph: View {
    let badge: BranchPullRequestBadge

    init(_ badge: BranchPullRequestBadge) {
        self.badge = badge
    }

    var body: some View {
        HStack(spacing: Metrics.grid) {
            Image(systemName: PullRequestGlyph.systemImage)
                .foregroundStyle(badge.isDraft ? Color.text3 : .text2)
            if let checks = badge.checks {
                ChecksGlyph(checks)
            }
        }
        .font(Typography.secondary)
        .tooltip(badge.tooltip)
    }
}
