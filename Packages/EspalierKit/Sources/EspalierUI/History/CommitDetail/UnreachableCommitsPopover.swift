// "Commit Reachability", a popover: which selected commits the range's
// diff leaves out (they aren't in the ancestry path of the newest one) and
// which it shows.

import SwiftUI

/// The popover's tabs.
nonisolated enum ReachabilityTab: String, Sendable, Identifiable, CaseIterable {
    case unreachable, reachable

    var id: String {
        rawValue
    }

    var title: String {
        switch self {
        case .unreachable: "Unreachable"
        case .reachable: "Reachable"
        }
    }
}

/// "Commit Reachability": the commits left out of a range's diff, and the
/// ones in it.
struct UnreachableCommitsPopover: View {
    let content: RangeSummaryContent
    @State private var tab: ReachabilityTab

    init(content: RangeSummaryContent, initialTab: ReachabilityTab = .unreachable) {
        self.content = content
        _tab = State(initialValue: initialTab)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: Metrics.insetMedium) {
            Text("Commit Reachability")
                .font(Typography.heading)
            CapsuleSegmentedControl(
                "Commits",
                selection: $tab,
                segments: ReachabilityTab.allCases.map { CapsuleSegment($0.title, value: $0) }
            )
            .fixedSize()
            // Both tabs are laid out, the other one hidden, so the popover
            // keeps the taller one's size whichever shows; they crossfade
            // (0.15 s).
            ZStack(alignment: .topLeading) {
                ForEach(ReachabilityTab.allCases, id: \.self) { candidate in
                    page(candidate)
                        .opacity(candidate == tab ? 1 : 0)
                        .allowsHitTesting(candidate == tab)
                        .accessibilityHidden(candidate != tab)
                }
            }
            .motion(Motion.leave, value: tab)
        }
        .padding(Metrics.insetLarge)
        .frame(width: 360)
    }

    /// A tab's explanation and its commits.
    private func page(_ tab: ReachabilityTab) -> some View {
        VStack(alignment: .leading, spacing: Metrics.insetMedium) {
            Text(message(for: tab))
                .font(Typography.secondary)
                .foregroundStyle(.text2)
                .fixedSize(horizontal: false, vertical: true)
            ScrollView {
                VStack(alignment: .leading, spacing: Metrics.grid) {
                    ForEach(commits(for: tab)) { commit in
                        HStack(spacing: Metrics.insetSmall) {
                            Text(String(commit.sha.prefix(7)))
                                .font(Typography.sha)
                                .foregroundStyle(.text3)
                            Text(RichText.emojified(commit.summary))
                                .foregroundStyle(.text)
                                .lineLimit(1)
                                .truncationMode(.tail)
                        }
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(maxHeight: 220)
        }
    }

    private func commits(for tab: ReachabilityTab) -> [CommitLine] {
        tab == .unreachable ? content.unreachable : content.reachable
    }

    /// A tab's explanation.
    private func message(for tab: ReachabilityTab) -> String {
        let count = commits(for: tab).count
        let noun = count == 1 ? "commit" : "commits"
        let pronoun = count == 1 ? "it's" : "they're"
        switch tab {
        case .unreachable:
            return "You will not see changes from the following \(noun) because \(pronoun) not in the ancestry path of the most recent commit in your selection."
        case .reachable:
            return "You will see changes from the following \(noun) because \(pronoun) in the ancestry path of the most recent commit in your selection."
        }
    }
}
