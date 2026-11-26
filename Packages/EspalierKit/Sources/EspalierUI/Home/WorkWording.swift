// What Home's cards and the shelf's tabs say and draw for a piece of work:
// its headline in words, the mark beside it (a symbol, plain, in a status
// color), and its next step's title. Home and the shelf both read these, so
// a card and a tab say the same thing of the same work.

import AppKit
import EspalierCore
import GitKit

/// The mark of what a piece of work is doing: a symbol and its color.
nonisolated enum WorkMark: Sendable, Hashable {
    case operationStopped, checksFailing, changesRequested, filesChanged, commitsToPush, merged, commitsToPull
    case noPullRequest, changingNow, waitingOnChecks

    /// The mark's symbol; nil for work that's changing now, which draws the
    /// turning arc in its place.
    var systemImage: String? {
        switch self {
        case .operationStopped: "exclamationmark.triangle"
        case .checksFailing: "xmark.circle"
        case .changesRequested: "text.bubble"
        case .filesChanged: PlaceIdentity.changes.systemImage
        case .commitsToPush: "arrow.up"
        case .merged: "arrow.triangle.merge"
        case .commitsToPull: "arrow.down"
        case .noPullRequest: PullRequestGlyph.systemImage
        case .changingNow: nil
        case .waitingOnChecks: "clock"
        }
    }

    var color: NSColor {
        switch self {
        case .operationStopped: Palette.warning
        case .checksFailing: Palette.error
        case .changesRequested: PlaceIdentity.pullRequests.color
        case .filesChanged: PlaceIdentity.changes.color
        case .commitsToPush, .changingNow: Palette.accent
        case .merged: Palette.success
        case .commitsToPull, .noPullRequest: Palette.text2
        case .waitingOnChecks: Palette.text3
        }
    }
}

/// "1 file" or "14 files", in the user's number format.
nonisolated func countedNoun(_ count: Int, _ singular: String, _ plural: String, _ format: NumberFormat) -> String {
    count == 1 ? "1 \(singular)" : "\(formatCount(count, format)) \(plural)"
}

nonisolated extension WorkHeadline {
    var mark: WorkMark {
        switch self {
        case .operationStopped: .operationStopped
        case .checksFailing: .checksFailing
        case .changesRequested: .changesRequested
        case .filesChanged: .filesChanged
        case .commitsToPush: .commitsToPush
        case .merged: .merged
        case .commitsToPull: .commitsToPull
        case .pushedWithoutPullRequest: .noPullRequest
        }
    }

    /// The headline: "Rebase stopped", "14 files changed", "3 commits to
    /// push".
    func title(_ format: NumberFormat) -> String {
        switch self {
        case .operationStopped(.rebase, _): "Rebase stopped"
        case .operationStopped(.merge, _): "Merge stopped"
        case .operationStopped(.cherryPick, _): "Cherry-pick stopped"
        case .operationStopped(.revert, _): "Revert stopped"
        case .checksFailing: "Checks failing"
        case .changesRequested: "Changes requested"
        case .filesChanged(let count): countedNoun(count, "file", "files", format) + " changed"
        case .commitsToPush(let count): countedNoun(count, "commit", "commits", format) + " to push"
        case .merged: "Merged"
        case .commitsToPull(let count): countedNoun(count, "commit", "commits", format) + " to pull"
        case .pushedWithoutPullRequest: "No pull request yet"
        }
    }

    /// What follows the headline in secondary text, apart from a time: "2
    /// files have conflicts", "on #142", "#88 into main". Nil where the
    /// headline says it all.
    func detail(_ format: NumberFormat) -> String? {
        switch self {
        case .operationStopped(_, let conflictedFiles):
            conflictedFiles == 0
                ? nil
                : countedNoun(conflictedFiles, "file has", "files have", format) + " conflicts"
        case .checksFailing(let pullRequest), .changesRequested(let pullRequest):
            "on #\(pullRequest.number)"
        case .merged(let pullRequest):
            "#\(pullRequest.number) into \(pullRequest.baseBranch)"
        case .filesChanged, .commitsToPush, .commitsToPull, .pushedWithoutPullRequest:
            nil
        }
    }
}

nonisolated extension WorkPhase.InProgress {
    var mark: WorkMark {
        switch self {
        case .changingNow: .changingNow
        case .waitingOnChecks: .waitingOnChecks
        }
    }

    /// "Changing now" or "Waiting on checks".
    var title: String {
        switch self {
        case .changingNow: "Changing now"
        case .waitingOnChecks: "Waiting on checks"
        }
    }

    /// "6 files so far", or the pull request's number.
    func detail(_ format: NumberFormat) -> String? {
        switch self {
        case .changingNow(let changedFiles):
            changedFiles == 0 ? nil : countedNoun(changedFiles, "file", "files", format) + " so far"
        case .waitingOnChecks(let pullRequest):
            "#\(pullRequest)"
        }
    }
}

nonisolated extension WorkNextStep {
    /// The button's title. A step that opens a sheet ends in an ellipsis.
    var title: String {
        switch self {
        case .resolve: "Resolve"
        case .viewChecks: "View Checks"
        case .readReview: "Read Review"
        case .review: "Review"
        case .push: "Push"
        case .cleanUp: "Clean Up"
        case .pull: "Pull"
        case .createPullRequest: "Create Pull Request…"
        }
    }
}
