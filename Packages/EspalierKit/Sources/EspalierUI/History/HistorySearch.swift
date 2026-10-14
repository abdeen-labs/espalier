// The history search's status in the header. The toolbar's search field
// ("Search Commits") dims the loaded commits that don't match; the header
// counts the matches, moves between them, searches older commits, and offers
// to go to a commit when the query looks like a SHA.

import EspalierCore
import GitKit
import SwiftUI

/// What the search's status says.
nonisolated struct HistorySearchStatusContent: Sendable, Equatable {
    /// A run of the status's text: its words, or a count.
    struct Part: Sendable, Equatable {
        var text: String
        var isCount: Bool

        static func words(_ text: String) -> Part {
            Part(text: text, isCount: false)
        }

        static func count(_ count: Int) -> Part {
            Part(text: formatCount(count), isCount: true)
        }
    }

    /// "3 of 17 matches in 2,400 loaded commits", its counts apart.
    var parts: [Part]
    /// Whether there are matches to move between.
    var canMove: Bool
    /// Whether older commits can be loaded and searched.
    var canSearchOlder: Bool
    /// Whether older commits are loading for the search.
    var isSearchingOlder: Bool
    /// The commit the query can name (7 to 64 hexadecimal digits), and its
    /// short form for the button.
    var commitID: String?

    init(parts: [Part], canMove: Bool, canSearchOlder: Bool, isSearchingOlder: Bool, commitID: String?) {
        self.parts = parts
        self.canMove = canMove
        self.canSearchOlder = canSearchOlder
        self.isSearchingOlder = isSearchingOlder
        self.commitID = commitID
    }

    init(search: HistorySearch, loaded: Int, isComplete: Bool, isLoadingMore: Bool) {
        let commits: [Part] = [.count(loaded), .words(loaded == 1 ? " loaded commit" : " loaded commits")]
        let count = search.matchCount
        let matches = count == 1 ? " match in " : " matches in "
        let parts: [Part]
        if count == 0 {
            parts = search.isSearching ? [.words("Searching…")] : [.words("No matches in ")] + commits
        } else if let current = search.currentMatch {
            parts = [.count(current + 1), .words(" of "), .count(count), .words(matches)] + commits
        } else {
            parts = [.count(count), .words(matches)] + commits
        }
        self.init(
            parts: parts,
            canMove: count > 0,
            canSearchOlder: !isComplete,
            isSearchingOlder: isLoadingMore && !isComplete,
            commitID: search.commitID
        )
    }

    @MainActor
    init(_ search: HistorySearch, history: HistoryModel) {
        self.init(search: search, loaded: history.commitSHAs.count, isComplete: history.isComplete, isLoadingMore: history.isLoadingMore)
    }

    /// The status as one string, as VoiceOver reads it.
    var text: String {
        parts.map(\.text).joined()
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

/// The search's status and controls.
struct HistorySearchStatus: View {
    let content: HistorySearchStatusContent
    var actions = HistorySearchActions()

    var body: some View {
        VStack(alignment: .leading, spacing: Metrics.insetSmall) {
            HStack(spacing: Metrics.insetSmall) {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.text3)
                    .accessibilityHidden(true)
                statusText
                    .foregroundStyle(.text2)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .accessibilityLabel(content.text)
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
                    if content.isSearchingOlder {
                        ArcProgress(.small)
                        Text("Searching older commits…")
                            .font(Typography.meta)
                            .foregroundStyle(.text3)
                        Button("Stop", action: actions.stop)
                    } else if content.canSearchOlder {
                        Button("Search Older Commits", action: actions.searchOlder)
                    }
                    if let commitID = content.commitID, let short = content.shortCommitID {
                        Button("Go to Commit \(short)") {
                            actions.goToCommit(commitID)
                        }
                    }
                    Spacer(minLength: 0)
                }
                .buttonStyle(.quiet)
                .controlSize(.small)
            }
        }
    }

    /// The status's words in the meta font, its counts in the code font.
    private var statusText: Text {
        content.parts.reduce(Text(verbatim: "")) { text, part in
            let run = Text(verbatim: part.text).font(part.isCount ? Typography.secondaryCount : Typography.meta)
            return Text("\(text)\(run)")
        }
    }
}
