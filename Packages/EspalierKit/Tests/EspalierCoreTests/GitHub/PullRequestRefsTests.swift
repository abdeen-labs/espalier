// Ported from desktop/app/test/unit/pull-request-refs-test.ts
// Plus tests of PullRequestMatching.swift.

@testable import EspalierCore
import EspalierCoreTestSupport
import Foundation
import GitHubKit
import GitKit
import Testing
import TestSupport

private func makeCommit(_ summary: String, _ body: String = "") -> Commit {
    let author = CommitIdentity(name: "A", email: "a@example.com", date: Date(timeIntervalSince1970: 0))
    let digits = String(summary.count, radix: 16)
    return Commit(
        sha: String(repeating: "0", count: 40 - digits.count) + digits,
        shortSha: String(repeating: "0", count: max(0, 7 - digits.count)) + digits,
        summary: summary,
        body: body,
        author: author,
        committer: author,
        parentSHAs: [],
        trailers: [],
        tags: []
    )
}

private func makePullRequest(_ number: Int, _ title: String? = nil) -> PullRequest {
    let owner = Owner(login: "owner", endpoint: "https://example.com", id: 1)
    let repo = GitHubRepository(name: "repo", owner: owner, dbID: 1, isPrivate: false, htmlURL: "https://example.com/owner/repo")
    let ref = PullRequestRef(ref: "feature", sha: "sha", gitHubRepository: repo)
    return PullRequest(
        created: Date(timeIntervalSince1970: 0),
        title: title ?? "PR \(number)",
        pullRequestNumber: number,
        head: ref,
        base: ref,
        author: "someone",
        draft: false,
        body: ""
    )
}

@Suite("extractPullRequestNumbersFromCommits")
struct ExtractPullRequestNumbersTests {
    @Test("extracts the numbers of #NNN and gh-NNN references, once each, in first-seen order", arguments: [
        NamedCase("extracts and de-duplicates refs from summaries and bodies in first-seen order", (
            commits: [
                makeCommit("Merge pull request #123 from a/b"),
                makeCommit("Fix the thing (#456)", "Fixes #789 and addresses #456."),
            ],
            numbers: [123, 456, 789]
        )),
        NamedCase("skips cross-repo owner/repo#NNN references", (
            commits: [makeCommit("Mirror of desktop/desktop#777")],
            numbers: []
        )),
        NamedCase("does not match # preceded by a word character", (
            commits: [makeCommit("color = #ff00aa")],
            numbers: []
        )),
        NamedCase("skips URL-style markers, and numbers followed by a word character; matches markers in any case", (
            commits: [makeCommit("See /pull/12 and #34abc", "GH-56 and (#78), owner#90")],
            numbers: [56, 78]
        )),
        NamedCase("skips #0, reads #007 as 7, and takes only ASCII letters, digits, and _ as word characters, as JavaScript does", (
            commits: [
                makeCommit("Version #0 and (#007)", "after \u{E9}#8, \u{17F}#9, and #10\u{212A}"),
                makeCommit("see \u{212A}-\u{17F}#11 and https://github.com/o/r/i\u{17F}\u{17F}ues/12"),
            ],
            numbers: [7, 8, 9, 10, 11]
        )),
        NamedCase("skips a number too large for an Int", (
            commits: [makeCommit("Fixes #99999999999999999999 and #12")],
            numbers: [12]
        )),
    ])
    func extracts(_ testCase: NamedCase<(commits: [Commit], numbers: [Int])>) {
        #expect(extractPullRequestNumbersFromCommits(testCase.value.commits) == testCase.value.numbers)
    }
}

@Suite("findPullRequestsByNumbers")
struct FindPullRequestsByNumbersTests {
    @Test("matches by number in input order and skips unmatched numbers")
    func inputOrder() {
        let prs = [makePullRequest(2), makePullRequest(1), makePullRequest(3)]
        let matched = findPullRequestsByNumbers([3, 1, 99], prs)
        #expect(matched.map(\.pullRequestNumber) == [3, 1])
    }
}

@Suite("Pull request matching")
struct PullRequestMatchingTests {
    private func pullRequest(head: String, in owner: String, number: Int = 1) -> PullRequest {
        let repository = ModelFixtures.gitHubRepository(owner: owner, name: "hello")
        let base = ModelFixtures.gitHubRepository(owner: "octocat", name: "hello")
        return PullRequest(
            created: Date(timeIntervalSince1970: 0),
            title: "PR",
            pullRequestNumber: number,
            head: PullRequestRef(ref: head, sha: "sha", gitHubRepository: repository),
            base: PullRequestRef(ref: "main", sha: "base", gitHubRepository: base),
            author: owner,
            draft: false,
            body: ""
        )
    }

    @Test("a branch's pull request has its upstream as head, in the repository its remote points at")
    func associated() {
        let branch = ModelFixtures.branch("feature", upstream: "origin/feature")
        let origin = Remote(name: "origin", url: "git@github.com:octocat/hello.git")
        let fork = Remote(name: "origin", url: "https://github.com/hubot/hello.git")
        let prs = [pullRequest(head: "other", in: "octocat", number: 1), pullRequest(head: "feature", in: "octocat", number: 2)]

        #expect(findAssociatedPullRequest(branch, prs, origin)?.pullRequestNumber == 2)
        #expect(findAssociatedPullRequest(branch, prs, fork) == nil)
        #expect(findAssociatedPullRequest(ModelFixtures.branch("feature"), prs, origin) == nil)
        // The upstream's name counts, not the local branch's.
        let renamed = ModelFixtures.branch("my-feature", upstream: "origin/feature")
        #expect(isPullRequestAssociatedWithBranch(renamed, prs[1], origin))
        // A fork's pull request checked out as pr/<number>.
        let prBranch = ModelFixtures.branch("pr/3", upstream: "espalier-hubot/patch")
        let forkRemote = Remote(name: "espalier-hubot", url: "https://github.com/hubot/hello.git")
        #expect(isPullRequestAssociatedWithBranch(prBranch, pullRequest(head: "patch", in: "hubot", number: 3), forkRemote))
    }
}
