// These drive `PullRequestPreviewModel` against real git: the commits and
// the changes from the merge base, mergeability, the empty states, and an
// open pull request's changes when its head is in the repository.

@testable import EspalierCore
import EspalierCoreTestSupport
import EspalierSupport
import Foundation
import GitHubKit
import GitKit
import Testing
import TestSupport

@Suite("Pull request preview", .offline) @MainActor
struct PullRequestPreviewTests {
    /// `main` (Base, then M1 changing main.txt) and `feature` from Base
    /// (F1, F2), checked out.
    private func makeRepository() async throws -> (HistoryFixture, [String: String]) {
        var shas: [String: String] = [:]
        let fixture = try await makeHistoryFixture { repository in
            shas["Base"] = try await commitWithGit(repository, "shared.txt", "one\ntwo\n", message: "Base")
            try await runGit(["checkout", "-q", "-b", "feature"], repository)
            shas["F1"] = try await commitWithGit(repository, "feature.txt", "f1\n", message: "F1")
            shas["F2"] = try await commitWithGit(repository, "shared.txt", "one\ntwo  \n", message: "F2")
            try await runGit(["checkout", "-q", "main"], repository)
            shas["M1"] = try await commitWithGit(repository, "main.txt", "m1\n", message: "M1")
            try await runGit(["checkout", "-q", "feature"], repository)
        }
        return (fixture, shas)
    }

    @Test("previews the current branch into the default branch, from the merge base")
    func previewIntoDefaultBranch() async throws {
        let (fixture, shas) = try await makeRepository()
        let preview = fixture.history.pullRequestPreview
        await fixture.history.previewPullRequest()
        await fixture.settle()

        #expect(preview.status == .loaded)
        #expect(preview.baseBranch?.name == "main")
        #expect(preview.headBranch?.name == "feature")
        #expect(preview.commitSHAs == [shas["F2"]!, shas["F1"]!])
        #expect(preview.hasMergeBase)
        #expect(preview.summary == "Merge 2 commits into main from feature.")
        // Only the branch's changes: main's M1 isn't in them.
        let selection = preview.selection
        #expect(selection.shas == preview.commitSHAs)
        #expect(selection.shasInDiff == preview.commitSHAs)
        #expect(selection.changeset.value?.files.map(\.path) == ["feature.txt", "shared.txt"])
        #expect(selection.changeset.value?.files.first?.commitish == shas["F2"])
        #expect(selection.file?.path == "feature.txt")
        guard case .text(let diff)? = selection.diff.value else {
            Issue.record("Expected a text diff, got \(String(describing: selection.diff))")
            return
        }
        #expect(diff.text.contains("+f1"))
        #expect(preview.mergeStatus == .clean)
        #expect(preview.mergeStatusMessage?.title == "Able to merge.")
        #expect(preview.mergeStatusMessage?.message == "These branches can be automatically merged.")
        #expect(preview.emptyMessage == nil)
        // Nothing is pushed.
        #expect(preview.nonLocalCommitSHA == nil)

        // Another file's diff, with whitespace hidden.
        let shared = try #require(selection.changeset.value?.files.last)
        preview.setHideWhitespaceInDiff(true)
        preview.selectFile(shared)
        await fixture.settle()
        #expect(fixture.app.preferences.hideWhitespaceInPullRequestDiff)
        #expect(fixture.app.preferences.hideWhitespaceInHistoryDiff == false)
        guard case .text(let hidden)? = preview.selection.diff.value else {
            Issue.record("Expected a text diff")
            return
        }
        #expect(hidden.hunks.isEmpty)
    }

    @Test("a conflicting pull request can't merge automatically")
    func conflicts() async throws {
        let (fixture, _) = try await makeRepository()
        try await fixture.git(["checkout", "-q", "main"])
        try await fixture.commit("shared.txt", "one\nmain\n", message: "M2")
        try await fixture.git(["checkout", "-q", "feature"])
        await fixture.refresh()
        let preview = fixture.history.pullRequestPreview
        await fixture.history.previewPullRequest(base: try fixture.branch("main"))
        await fixture.settle()

        #expect(preview.mergeStatus == .conflicts(conflictedFiles: 1))
        #expect(preview.mergeStatusMessage?.title == "Can't automatically merge.")
        #expect(preview.mergeStatusMessage?.message == "You can still create the pull request.")
    }

    @Test("another base branch previews again")
    func changeBaseBranch() async throws {
        let (fixture, shas) = try await makeRepository()
        let preview = fixture.history.pullRequestPreview
        try await fixture.git(["branch", "older", shas["Base"]!])
        await fixture.refresh()
        await fixture.history.previewPullRequest()
        await fixture.settle()

        await preview.setBaseBranch(try fixture.branch("older"))
        await fixture.settle()
        #expect(preview.baseBranch?.name == "older")
        #expect(preview.commitSHAs == [shas["F2"]!, shas["F1"]!])
        #expect(preview.summary == "Merge 2 commits into older from feature.")
    }

    @Test("no changes: the base is up to date with the branch")
    func noChanges() async throws {
        let (fixture, _) = try await makeRepository()
        try await fixture.git(["checkout", "-q", "-b", "same", "main"])
        await fixture.refresh()
        let preview = fixture.history.pullRequestPreview
        await fixture.history.previewPullRequest()
        await fixture.settle()

        #expect(preview.status == .loaded)
        #expect(preview.commitSHAs.isEmpty)
        #expect(preview.selection.changeset.value?.files.isEmpty == true)
        #expect(preview.mergeStatus == nil)
        #expect(preview.emptyMessage?.title == "There are no changes.")
        #expect(preview.emptyMessage?.message == "main is up to date with all commits from same.")
    }

    @Test("unrelated histories have no merge base")
    func unrelatedHistories() async throws {
        let (fixture, _) = try await makeRepository()
        try await fixture.git(["checkout", "-q", "--orphan", "unrelated"])
        try await fixture.git(["rm", "-q", "-r", "--cached", "."])
        try await fixture.commit("other.txt", "other\n", message: "Unrelated")
        await fixture.refresh()
        let preview = fixture.history.pullRequestPreview
        await fixture.history.previewPullRequest()
        await fixture.settle()

        #expect(preview.hasMergeBase == false)
        #expect(preview.commitSHAs.isEmpty)
        #expect(preview.mergeStatus == .invalid)
        #expect(preview.mergeStatusMessage?.title == "Error checking merge status.")
        #expect(preview.emptyMessage?.message == "main and unrelated are entirely different commit histories.")
    }

    @Test("without a default branch there's nothing to compare against")
    func noBaseBranch() async throws {
        let fixture = try await makeHistoryFixture { repository in
            try await runGit(["checkout", "-q", "-b", "work"], repository)
            try await commitWithGit(repository, "a.txt", "a\n", message: "A")
        }
        let preview = fixture.history.pullRequestPreview
        await fixture.history.previewPullRequest()

        #expect(preview.status == .noBaseBranch)
        #expect(preview.baseBranch == nil)
        #expect(preview.emptyMessage?.title == "Could not find a default branch to compare against.")
        #expect(preview.emptyMessage?.message == "Select a base branch above.")

        preview.close()
        #expect(preview.status == .idle)
        #expect(preview.headBranch == nil)
    }

    @Test("base branch candidates are the default remote's")
    func baseBranchCandidates() async throws {
        let (local, _) = try await setupRepositoryWithRemote()
        try await runGit(["push", "-q", "origin", "main:other"], local)
        try await runGit(["fetch", "-q", "origin"], local)
        try await runGit(["branch", "local-only"], local)
        let harness = try AppHarness()
        let app = await harness.loadedApp()
        let model = try await harness.addAndSelect(local, to: app)

        let names = model.history.pullRequestPreview.baseBranchCandidates.map(\.name)
        #expect(names.contains("main"))
        #expect(names.contains("origin/other"))
        #expect(!names.contains("local-only"))
    }

    // MARK: Open pull requests

    private func pullRequest(head: String, base: String, headRef: String = "feature") -> PullRequest {
        let repository = ModelFixtures.gitHubRepository(owner: "octocat", name: "app")
        return PullRequest(
            created: Date(timeIntervalSince1970: 1_700_000_000),
            title: "Add a feature",
            pullRequestNumber: 7,
            head: PullRequestRef(ref: headRef, sha: head, gitHubRepository: repository),
            base: PullRequestRef(ref: "main", sha: base, gitHubRepository: repository),
            author: "octocat",
            draft: false,
            body: ""
        )
    }

    @Test("an open pull request's changes, from the base repository's remote-tracking branch")
    func openPullRequestChanges() async throws {
        let (local, _) = try await setupRepositoryWithRemote()
        let base = JSCompat.trim(try await runGit(["rev-parse", "HEAD"], local))
        try await runGit(["checkout", "-q", "-b", "feature"], local)
        try await commitWithGit(local, "feature.txt", "f1\n", message: "F1")
        try await runGit(["checkout", "-q", "main"], local)
        try await commitWithGit(local, "main.txt", "m1\n", message: "M1")
        try await runGit(["push", "-q", "origin", "main"], local)
        try await runGit(["checkout", "-q", "feature"], local)
        try await runGit(["merge", "-q", "--no-ff", "-m", "Merge main", "main"], local)
        let head = try await commitWithGit(local, "feature.txt", "f2\n", message: "F2")
        try await runGit(["checkout", "-q", "main"], local)
        // The base repository's remote (no network is used).
        try await runGit(["remote", "set-url", "origin", "https://github.com/octocat/app.git"], local)
        let harness = try AppHarness()
        let app = await harness.loadedApp()
        let model = try await harness.addAndSelect(local, to: app)
        let changes = model.history.pullRequestChanges

        // GitHub's base commit is older than origin/main, which has M1.
        await changes.showChanges(of: pullRequest(head: head, base: base))
        await model.history.idle()
        #expect(changes.status == .loaded)
        #expect(changes.commits.map(\.summary) == ["F2", "Merge main", "F1"])
        #expect(changes.selection.changeset.value?.files.map(\.path) == ["feature.txt"])
        #expect(changes.selection.diff.value != nil)
        #expect(changes.mergeStatus == .clean)
        #expect(changes.pullRequest?.pullRequestNumber == 7)
        // The preview of the current branch is a separate model.
        #expect(model.history.pullRequestPreview.status == .idle)
    }

    @Test("a pull request whose head isn't in the repository has no changes to show")
    func changesNotAvailable() async throws {
        let (fixture, shas) = try await makeRepository()
        let changes = fixture.history.pullRequestChanges
        await changes.showChanges(of: pullRequest(head: String(repeating: "1", count: 40), base: shas["Base"]!))
        await fixture.settle()
        #expect(changes.status == .changesNotAvailable)
        #expect(changes.commits.isEmpty)

        // Without a remote for the base repository, GitHub's base commit is
        // used.
        await changes.showChanges(of: pullRequest(head: shas["F2"]!, base: shas["Base"]!))
        await fixture.settle()
        #expect(changes.status == .loaded)
        #expect(changes.commitSHAs == [shas["F2"]!, shas["F1"]!])
    }
}
