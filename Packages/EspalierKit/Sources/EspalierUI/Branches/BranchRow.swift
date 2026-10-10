// A branch's row in the sidebar's Branches section: the name, the branch's
// pull request, and how it compares with its upstream ("↑2 ↓3", or not
// published). Value-driven: `BranchRowContent` is built from the models by
// `BranchesSectionContent` and snapshotted on its own.

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

    /// "↑2 ↓3", leaving out zero counts; nil when in sync or not tracking.
    public var countsText: String? {
        guard case .aheadBehind(let ahead, let behind) = self else {
            return nil
        }
        var parts: [String] = []
        if ahead > 0 {
            parts.append("↑\(Self.formatCount(ahead))")
        }
        if behind > 0 {
            parts.append("↓\(Self.formatCount(behind))")
        }
        return parts.isEmpty ? nil : parts.joined(separator: " ")
    }

    /// What VoiceOver and the tooltip say.
    public var description: String? {
        switch self {
        case .none:
            return nil
        case .aheadBehind(let ahead, let behind):
            var parts: [String] = []
            if ahead > 0 {
                parts.append("\(ahead) \(ahead == 1 ? "commit" : "commits") ahead")
            }
            if behind > 0 {
                parts.append("\(behind) \(behind == 1 ? "commit" : "commits") behind")
            }
            return parts.isEmpty ? "Up to date with its upstream" : parts.joined(separator: ", ")
        case .notPublished:
            return "Not published"
        case .upstreamGone:
            return "Its upstream branch is gone"
        }
    }

    /// Counts past 999 shrink ("1.2k"), as the sync button's.
    static func formatCount(_ count: Int) -> String {
        guard count >= 1_000 else {
            return "\(count)"
        }
        let thousands = Double(count) / 1_000
        return thousands >= 10 ? "\(Int(thousands))k" : String(format: "%.1fk", thousands)
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

    /// The glyph's state for a pull request's combined checks: pending
    /// until they conclude; failed when they failed, timed out, or need an
    /// action; neutral when cancelled, skipped, stale, or neutral.
    public static func checksState(of check: CombinedRefCheck) -> ChecksState {
        guard let conclusion = check.conclusion, check.status == .completed else {
            return .pending
        }
        switch conclusion {
        case .success: return .success
        case .failure, .timedOut, .actionRequired: return .failure
        default: return .neutral
        }
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
    /// Whether it's the default branch (the trunk's teal outside the graph).
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
    /// branch, teal for the default one, else a palette entry by name.
    @MainActor
    public var fallbackColor: NSColor {
        TrackPalette.color(forBranch: name, isCurrent: isCurrent, isDefault: isDefault)
    }

    public var id: String {
        ref
    }

    /// The row's symbol: the current branch's check, else a branch.
    public var systemImage: String {
        isCurrent ? "checkmark.circle.fill" : "arrow.trianglehead.branch"
    }

    /// The row as VoiceOver reads it: the name, then what the trailing
    /// glyphs say.
    public var accessibilityLabel: String {
        var parts = [name]
        if isCurrent {
            parts.append("current branch")
        }
        if let pullRequest {
            parts.append(pullRequest.tooltip)
        }
        if let tracking = tracking.description {
            parts.append(tracking)
        }
        return parts.joined(separator: ", ")
    }
}

/// A branch's row: a dot in its track color, its name (the current one
/// semibold, a selected one medium), the pull request glyph, and its
/// comparison with its upstream.
public struct BranchRow: View {
    private let content: BranchRowContent
    private let dotColor: NSColor?
    @Environment(\.isSidebarRowSelected) private var isSelected

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
                .frame(width: 16)
                .accessibilityHidden(true)
            Text(content.title)
                .font(SidebarRowFont.title(isSelected: isSelected, isEmphasized: content.isCurrent))
                .foregroundStyle(.text)
                .lineLimit(1)
                .truncationMode(.middle)
                // The name first; what follows takes the room left.
                .layoutPriority(1)
            Spacer(minLength: Metrics.grid)
            if let pullRequest = content.pullRequest {
                PullRequestBadgeGlyph(pullRequest)
            }
            BranchTrackingView(content.tracking)
                // After the name, before the spacer: "Not published" gets the
                // room the name leaves. At the spacer's priority it would be
                // offered half of it and fall back to the glyph even in wide
                // rows.
                .layoutPriority(0.5)
        }
        .help(content.name)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(content.accessibilityLabel)
    }
}

/// The trailing comparison: "↑2" in the accent and "↓3" in tertiary text,
/// in SF Mono; a dashed circle and "Not published" for a branch that isn't
/// published; the dashed circle alone, with a tooltip, for a branch whose
/// upstream is gone.
struct BranchTrackingView: View {
    let tracking: BranchTracking

    init(_ tracking: BranchTracking) {
        self.tracking = tracking
    }

    var body: some View {
        switch tracking {
        case .none:
            EmptyView()
        case .aheadBehind(let ahead, let behind):
            if tracking.countsText != nil {
                HStack(spacing: 4) {
                    if ahead > 0 {
                        Text("↑\(BranchTracking.formatCount(ahead))")
                            .font(Typography.aheadCount)
                            .foregroundStyle(Color.accentColor)
                    }
                    if behind > 0 {
                        Text("↓\(BranchTracking.formatCount(behind))")
                            .font(Typography.secondaryCount)
                            .foregroundStyle(.text3)
                    }
                }
                .lineLimit(1)
                .fixedSize()
                .help(tracking.description ?? "")
            }
        case .notPublished:
            // The words give way to the name in a narrow row.
            ViewThatFits(in: .horizontal) {
                HStack(spacing: Metrics.grid) {
                    Image(systemName: "circle.dashed")
                    Text(tracking.description ?? "")
                }
                .fixedSize()
                Image(systemName: "circle.dashed")
                    .help(tracking.description ?? "")
            }
            .font(Typography.secondary)
            .foregroundStyle(.text3)
            .lineLimit(1)
        case .upstreamGone:
            Image(systemName: "circle.dashed")
                .font(Typography.secondary)
                .foregroundStyle(.text3)
                .help(tracking.description ?? "")
        }
    }
}

/// A pull request's glyph, drafts in a secondary tint, with its checks.
struct PullRequestBadgeGlyph: View {
    let badge: BranchPullRequestBadge

    init(_ badge: BranchPullRequestBadge) {
        self.badge = badge
    }

    var body: some View {
        HStack(spacing: 2) {
            Image(systemName: "arrow.trianglehead.pull")
                .foregroundStyle(Color(espalier: badge.isDraft ? Palette.text3 : Palette.text2))
                .imageScale(.small)
            if let checks = badge.checks {
                ChecksGlyph(checks)
                    .imageScale(.small)
            }
        }
        .font(Typography.secondary)
        .help(badge.tooltip)
    }
}
