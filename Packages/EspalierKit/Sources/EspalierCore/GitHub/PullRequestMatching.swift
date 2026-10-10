// Ported from desktop/app/src/lib/helpers/pull-request-matching.ts, lib/pull-request-refs.ts, and lib/markdown-filters/issue-mention-filter.ts

import EspalierSupport
import Foundation
import GitHubKit
import GitKit

/// Find the pull request for this branch.
///
/// - Parameters:
///   - branch: branch in question
///   - pullRequests: list to search
///   - remote: remote for the pull request's head
public func findAssociatedPullRequest(_ branch: Branch, _ pullRequests: [PullRequest], _ remote: Remote) -> PullRequest? {
    guard branch.upstreamWithoutRemote != nil else {
        return nil
    }

    return pullRequests.first { isPullRequestAssociatedWithBranch(branch, $0, remote) }
}

/// Whether `pr`'s head is `branch`'s upstream, in the repository `remote`
/// points at.
public func isPullRequestAssociatedWithBranch(_ branch: Branch, _ pr: PullRequest, _ remote: Remote) -> Bool {
    guard let upstream = branch.upstreamWithoutRemote else {
        return false
    }
    return JSCompat.strictEquals(pr.head.ref, upstream)
        && repositoryMatchesRemote(pr.head.gitHubRepository, remoteURL: remote.url)
}

// MARK: Pull request references

/// A regular expression matching an issue reference:
///
/// 1. An optional owner, or owner/repo, before the marker;
/// 2. an issue marker: gh-, #, /issues/, /pull/, or /discussions/;
/// 3. a number that ends in a word bounding character.
///
/// It's anchored on a non-word "leader" (the start of the text or a character
/// that isn't a word character), so tokens like `abc#123` don't match.
/// JavaScript's `\w`, `\d`, `\b`, and its `i` flag are ASCII; ICU's are
/// Unicode (its case-insensitive `[A-Za-z]` also matches the long s, U+017F,
/// and the Kelvin sign, U+212A), hence the explicit classes, and the
/// marker's letters in both cases.
private let issueReferenceMatcher: NSRegularExpression = {
    let word = "[A-Za-z0-9_]"
    let notWord = "[^A-Za-z0-9_]"
    let ownerOrOwnerRepo = "(?<ownerOrOwnerRepo>\(word)+(?:-\(word)+)*(?:/[.A-Za-z0-9_-]+)?)"
    let marker = "(?<marker>#|[gG][hH]-|/(?:[iI][sS][sS][uU][eE][sS]|[pP][uU][lL][lL]|[dD][iI][sS][cC][uU][sS][sS][iI][oO][nN][sS])/)(?=[0-9])"
    // `\b` after the number: the next character isn't a word character.
    let refNumber = "(?<refNumber>[0-9]+)(?!\(word))"
    let leader = "(?<=^|\(notWord))"
    return JSCompat.regex(leader + ownerOrOwnerRepo + "?" + marker + refNumber)
}()

/// Extract pull request numbers referenced in a list of commits by scanning
/// commit summaries and bodies for issue/PR mentions.
///
/// Catches the common cases:
///   - GitHub merge commits: `Merge pull request #123 from owner/branch`
///   - Squash-merged titles:  `Some title (#456)`
///   - Free-text references:  `Fixes #789` / `Fixes gh-789`
///
/// Reuses `issueReferenceMatcher` but only accepts *bare* same-repo references:
/// we drop cross-repo `owner/repo#N` and URL-style (`/issues/`, `/pull/`)
/// markers because callers resolve these numbers against the *current*
/// repository's pull requests, so another repo's `#1` would be a wrong-repo
/// false match.
///
/// Numbers are returned in first-seen order with duplicates removed.
public func extractPullRequestNumbersFromCommits(_ commits: [Commit]) -> [Int] {
    extractPullRequestNumbers(commits.flatMap { [$0.summary, $0.body] })
}

/// `extractPullRequestNumbersFromCommits` over the texts of commits
/// (summaries and bodies, in order).
func extractPullRequestNumbers(_ fields: [String]) -> [Int] {
    var seen: Set<Int> = []
    var result: [Int] = []

    for field in fields where !field.isEmpty {
        let text = field as NSString
        for match in issueReferenceMatcher.matches(in: field, range: NSRange(location: 0, length: text.length)) {
            // Only bare, same-repo references via `#`/`gh-`; skip cross-repo
            // prefixes and URL-style markers we can't safely resolve here.
            if match.range(withName: "ownerOrOwnerRepo").location != NSNotFound {
                continue
            }
            let markerRange = match.range(withName: "marker")
            guard markerRange.location != NSNotFound else {
                continue
            }
            let marker = text.substring(with: markerRange)
            if marker != "#", JSCompat.toLowerCase(marker) != "gh-" {
                continue
            }

            let numberRange = match.range(withName: "refNumber")
            guard numberRange.location != NSNotFound,
                  let prNumber = JSCompat.parseInt(text.substring(with: numberRange)),
                  prNumber > 0
            else {
                continue
            }
            if seen.insert(prNumber).inserted {
                result.append(prNumber)
            }
        }
    }

    return result
}

/// Find pull requests in a locally-cached list whose numbers appear in the
/// given list. Preserves the order of `numbers` (first-seen wins) and skips
/// numbers without a matching PR — letting callers fall back gracefully.
public func findPullRequestsByNumbers(_ numbers: [Int], _ pullRequests: [PullRequest]) -> [PullRequest] {
    if numbers.isEmpty || pullRequests.isEmpty {
        return []
    }

    var byNumber: [Int: PullRequest] = [:]
    for pr in pullRequests {
        byNumber[pr.pullRequestNumber] = pr
    }

    return numbers.compactMap { byNumber[$0] }
}
