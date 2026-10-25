// The history search's status in the header. The toolbar's search field
// ("Search Commits") dims the loaded commits that don't match; the header
// counts the matches, moves between them, searches older commits, and offers
// to go to a commit when the query looks like a SHA.

import EspalierCore
import GitKit
import SwiftUI

/// What the search's status says.
nonisolated struct HistorySearchStatusContent: Sendable, Equatable {
    /// "3 of 17 matches in 2,400 loaded commits".
    var text: String
    /// Whether there are matches to move between.
    var canMove: Bool
    /// Whether older commits can be loaded and searched.
    var canSearchOlder: Bool
    /// Whether older commits are loading for the search.
    var isSearchingOlder: Bool
    /// The commit the query can name (7 to 64 hexadecimal digits), and its
    /// short form for the button.
    var commitID: String?

    init(text: String, canMove: Bool, canSearchOlder: Bool, isSearchingOlder: Bool, commitID: String?) {
        self.text = text
        self.canMove = canMove
        self.canSearchOlder = canSearchOlder
        self.isSearchingOlder = isSearchingOlder
        self.commitID = commitID
    }

    /// The status of `search`, its counts in `numberFormat`.
    init(search: HistorySearch, loaded: Int, isComplete: Bool, isLoadingMore: Bool, numberFormat: NumberFormat) {
        let commits = "\(formatCount(loaded, numberFormat)) \(loaded == 1 ? "loaded commit" : "loaded commits")"
        let count = search.matchCount
        let matches = "\(formatCount(count, numberFormat)) \(count == 1 ? "match" : "matches") in \(commits)"
        let text: String
        if count == 0 {
            text = search.isSearching ? "Searching…" : "No matches in \(commits)"
        } else if let current = search.currentMatch {
            text = "\(formatCount(current + 1, numberFormat)) of \(matches)"
        } else {
            text = matches
        }
        self.init(
            text: text,
            canMove: count > 0,
            canSearchOlder: !isComplete,
            isSearchingOlder: isLoadingMore && !isComplete,
            commitID: search.commitID
        )
    }

    /// The status of the history's search: the loaded commits counted
    /// are the list's and, in the simple style, those its merges brought
    /// in that were searched.
    @MainActor
    init(_ search: HistorySearch, history: HistoryModel, numberFormat: NumberFormat) {
        self.init(
            search: search,
            loaded: history.commitSHAs.count + search.mergedCommitCount,
            isComplete: history.isComplete,
            isLoadingMore: history.isLoadingMore,
            numberFormat: numberFormat
        )
    }

    /// The commit's short SHA for "Go to Commit a1b2c3d".
    var shortCommitID: String? {
        commitID.map(shortenSHA)
    }
}

/// What the search's controls do.
struct HistorySearchActions {
    var previous: () -> Void = {}
    var next: () -> Void = {}
    var searchOlder: () -> Void = {}
    var stop: () -> Void = {}
    var goToCommit: (String) -> Void = { _ in }
}

/// The search's status and controls. Searching older commits starting and
/// ending crossfade over 0.15 s.
struct HistorySearchStatus: View {
    let content: HistorySearchStatusContent
    var actions = HistorySearchActions()
    @Environment(\.motion) private var motion

    var body: some View {
        VStack(alignment: .leading, spacing: Metrics.insetSmall) {
            HStack(spacing: Metrics.insetSmall) {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.text3)
                    .accessibilityHidden(true)
                Text(content.text)
                    .font(Typography.meta)
                    // The digits keep their width as the counts change.
                    .monospacedDigit()
                    .foregroundStyle(.text2)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .accessibilityAddTraits(.updatesFrequently)
                Spacer(minLength: Metrics.grid)
                HStack(spacing: Metrics.grid) {
                    Button(action: actions.previous) {
                        Image(systemName: "chevron.up")
                            .font(.system(size: 10, weight: .semibold))
                            .foregroundStyle(.text2)
                    }
                    .tooltip("Previous Match (⇧⌘G)")
                    .accessibilityLabel("Previous Match")
                    Button(action: actions.next) {
                        Image(systemName: "chevron.down")
                            .font(.system(size: 10, weight: .semibold))
                            .foregroundStyle(.text2)
                    }
                    .tooltip("Next Match (⌘G)")
                    .accessibilityLabel("Next Match")
                }
                .buttonStyle(.quiet)
                .controlSize(.small)
                .fixedSize()
                .disabled(!content.canMove)
            }
            if content.canSearchOlder || content.commitID != nil {
                HStack(spacing: Metrics.insetSmall) {
                    Group {
                        if content.isSearchingOlder {
                            ArcProgress(.small)
                            Text("Searching older commits…")
                                .font(Typography.meta)
                                .foregroundStyle(.text3)
                            Button("Stop", action: actions.stop)
                        } else if content.canSearchOlder {
                            Button("Search Older Commits", action: actions.searchOlder)
                        }
                    }
                    .transition(motion.animates ? .opacity : .identity)
                    if let commitID = content.commitID, let short = content.shortCommitID {
                        Button("Go to Commit \(short)") {
                            actions.goToCommit(commitID)
                        }
                    }
                    Spacer(minLength: 0)
                }
                .buttonStyle(.quiet)
                .controlSize(.small)
                .motion(Motion.leave, value: content.isSearchingOlder)
            }
        }
    }
}
