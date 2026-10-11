// The header of a range of commits: "Showing changes from 3 commits", and
// when the range leaves commits out of its diff, a warning whose link shows
// them (UnreachableCommitsPopover.swift).

import EspalierCore
import GitKit
import SwiftUI

/// A commit in the reachability lists.
nonisolated struct CommitLine: Sendable, Equatable, Identifiable {
    var sha: String
    var summary: String

    var id: String {
        sha
    }
}

/// What a range's header shows.
nonisolated struct RangeSummaryContent: Sendable, Equatable {
    /// The commits whose changes the diff shows.
    var reachable: [CommitLine]
    /// The selected commits it leaves out.
    var unreachable: [CommitLine]

    /// "Showing changes from 3 commits".
    var title: String {
        let count = reachable.count
        return "Showing changes from \(formatCount(count)) \(count == 1 ? "commit" : "commits")"
    }

    /// "2 unreachable commits", the link.
    var unreachableTitle: String? {
        let count = unreachable.count
        guard count > 0 else {
            return nil
        }
        return "\(formatCount(count)) unreachable \(count == 1 ? "commit" : "commits")"
    }
}

extension RangeSummaryContent {
    /// The range selected in `history`.
    @MainActor
    init(selection: CommitSelection, history: HistoryModel) {
        func lines(_ shas: [String]) -> [CommitLine] {
            shas.map { sha in
                let summary = RichText.emojified(history.commit(sha)?.summary ?? "")
                return CommitLine(sha: sha, summary: summary.isEmpty ? CommitRowContent.emptySummary : summary)
            }
        }
        // Newest first, as the list shows them.
        let order = { (sha: String) in history.row(of: sha) ?? Int.max }
        self.init(
            reachable: lines(selection.shasInDiff.sorted { order($0) < order($1) }),
            unreachable: lines(selection.unreachableSHAs.sorted { order($0) < order($1) })
        )
    }
}

/// A range's header.
struct RangeSummary: View {
    let content: RangeSummaryContent
    @State private var showsReachability: ReachabilityTab?

    var body: some View {
        VStack(alignment: .leading, spacing: Metrics.CommitDetail.titleSpacing) {
            Text(content.title)
                .font(Typography.commitSummary)
                .foregroundStyle(.text)
            if let link = content.unreachableTitle {
                HStack(spacing: Metrics.grid) {
                    Image(systemName: "info.circle")
                        .foregroundStyle(.text3)
                    Button(link) {
                        showsReachability = .unreachable
                    }
                    .buttonStyle(.textLink)
                    Text("not included.")
                        .foregroundStyle(.text3)
                }
                .font(Typography.secondary)
                .popoverCard(item: $showsReachability, title: "Commit Reachability") { tab in
                    UnreachableCommitsPopover(content: content, initialTab: tab)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}
