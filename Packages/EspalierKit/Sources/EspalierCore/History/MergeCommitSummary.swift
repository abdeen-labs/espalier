// History's simple mode shows a merge on the first-parent line as one row
// named for what it merged ("Merged #209 jonas/widget-refresh").

import EspalierSupport
import Foundation

/// What a merge commit's summary says it merged: the branch and, for a pull
/// request, its number. Read from the messages git and the hosting services
/// write; a summary written by hand names nothing.
struct MergeCommitSummary: Sendable, Hashable {
    /// The merged branch as the message names it (`jonas/widget-refresh`,
    /// `origin/main`), if it does.
    let branchName: String?
    /// The pull request's number, for a pull request merge.
    let pullRequestNumber: Int?

    /// Nil when `summary` isn't a message git or a hosting service writes
    /// for a merge, or names neither a branch nor a pull request.
    init?(_ summary: String) {
        let summary = JSCompat.trim(summary)
        for format in mergeSummaryFormats {
            guard let match = JSCompat.match(summary, format.pattern) else {
                continue
            }
            let branch = format.branchGroup.flatMap { match[$0] }.flatMap { $0.isEmpty ? nil : $0 }
            let number = format.numberGroup.flatMap { match[$0] }.flatMap(JSCompat.parseInt).flatMap { $0 > 0 ? $0 : nil }
            guard branch != nil || number != nil else {
                return nil
            }
            branchName = branch
            pullRequestNumber = number
            return
        }
        return nil
    }
}

/// A merge message format: its pattern and the groups holding the branch
/// and the pull request number.
private struct MergeSummaryFormat: Sendable {
    let pattern: NSRegularExpression
    let branchGroup: Int?
    let numberGroup: Int?
}

/// One or more characters that aren't whitespace.
private let word = "[^\\s]+"

private let mergeSummaryFormats = [
    // GitHub: "Merge pull request #209 from jonas/widget-refresh".
    MergeSummaryFormat(
        pattern: JSCompat.regex("^Merge pull request #([0-9]+) from (\(word))\\z"),
        branchGroup: 2,
        numberGroup: 1
    ),
    // Bitbucket: "Merged in feature/x (pull request #12)".
    MergeSummaryFormat(
        pattern: JSCompat.regex("^Merged in (\(word)) \\(pull request #([0-9]+)\\)"),
        branchGroup: 1,
        numberGroup: 2
    ),
    // Azure DevOps: "Merged PR 123: Title".
    MergeSummaryFormat(
        pattern: JSCompat.regex("^Merged PR ([0-9]+): "),
        branchGroup: nil,
        numberGroup: 1
    ),
    // git (and GitLab, which quotes the target): "Merge branch 'x'",
    // "Merge branch 'x' into main", "Merge remote-tracking branch
    // 'origin/x'", "Merge branch 'main' of github.com:owner/repo".
    MergeSummaryFormat(
        pattern: JSCompat.regex("^Merge (?:remote-tracking )?branch '([^']+)'(?: of \(word))?(?: into .+)?\\z"),
        branchGroup: 1,
        numberGroup: nil
    ),
]
