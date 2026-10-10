// In History's simple mode a merge on the first-parent line is one row,
// named for what it merged, that expands to the commits it brought in.

@testable import EspalierCore
import EspalierCoreTestSupport
import EspalierSupport
import Foundation
import GitKit
import Testing
import TestSupport

@Suite("Simple history: merges", .offline) @MainActor
struct SimpleHistoryMergeTests {
    private func at(_ daysAgo: Int, hour: Int = 10) -> Int {
        SimpleTime.at(daysAgo: daysAgo, hour: hour)
    }

    /// main: Main 1, a pull request merge of two commits, a merge of
    /// fix/x, and a merge with a message written by hand.
    private func makeMerges() async throws -> Repository {
        let local = try setupEmptyRepository("main")
        try await commitAt(at(9), "Main 1", in: local)
        try await runGit(["checkout", "-q", "-b", "jonas/widget-refresh"], local)
        try await commitAt(at(8), "Widget 1", in: local)
        try await commitAt(at(7), "Widget 2", files: 2, in: local)
        try await runGit(["checkout", "-q", "main"], local)
        try await commitAt(at(6), "Main 2", in: local)
        try await mergeAt(at(5), "jonas/widget-refresh", message: "Merge pull request #209 from jonas/widget-refresh", in: local)
        try await runGit(["checkout", "-q", "-b", "fix/x"], local)
        try await commitAt(at(4), "Fix 1", in: local)
        try await runGit(["checkout", "-q", "main"], local)
        try await mergeAt(at(3), "fix/x", message: "Merge branch 'fix/x'", in: local)
        try await runGit(["checkout", "-q", "-b", "y"], local)
        try await commitAt(at(2), "Y 1", in: local)
        try await runGit(["checkout", "-q", "main"], local)
        try await mergeAt(at(1), "y", message: "Bring in y", in: local)
        return local
    }

    @Test("a merge is one row naming the merged branch and pull request, with the files it brought in")
    func mergeRows() async throws {
        let fixture = try await makeSimpleFixture(try await makeMerges())
        await fixture.activate()

        #expect(fixture.simpleLines == [
            "Bring in y",
            "Merge branch 'fix/x'",
            "Merge pull request #209 from jonas/widget-refresh",
            "Main 2",
            "Main 1",
        ])
        let pullRequest = try fixture.simpleRow("Merge pull request #209 from jonas/widget-refresh")
        #expect(pullRequest.merge == SimpleHistoryMerge(branchName: "jonas/widget-refresh", pullRequestNumber: 209, isExpanded: false))
        #expect(pullRequest.changedFileCount == 3)
        #expect(try fixture.simpleRow("Merge branch 'fix/x'").merge?.branchName == "fix/x")
        let byHand = try #require(try fixture.simpleRow("Bring in y").merge)
        #expect(byHand.branchName == nil && byHand.pullRequestNumber == nil)
        #expect(try fixture.simpleRow("Main 2").merge == nil)
    }

    @Test("a merge expands to the commits it brought in, loaded once, and collapses")
    func expandAndCollapse() async throws {
        let fixture = try await makeSimpleFixture(try await makeMerges())
        await fixture.activate()
        let history = fixture.history
        let row = try #require(history.commitSHAs.firstIndex { history.commit($0)?.summary.hasPrefix("Merge pull request") == true })

        history.setMergeExpanded(true, row: row)
        #expect(history.mergedCommits(ofRow: row)?.state == .loading)
        #expect(fixture.simpleLines[2...4] == ["Merge pull request #209 from jonas/widget-refresh", "  (loading)", "Main 2"])
        await history.idle()

        #expect(history.mergedCommits(ofRow: row) == SimpleMergedCommits(state: .loaded, count: 2, hasMore: false))
        #expect(fixture.simpleLines == [
            "Bring in y",
            "Merge branch 'fix/x'",
            "Merge pull request #209 from jonas/widget-refresh",
            "  Widget 2",
            "  Widget 1",
            "Main 2",
            "Main 1",
        ])
        #expect(history.simpleOutline.itemIndex(ofRow: row + 1) == 5)
        #expect(history.simpleRow(atRow: row)?.merge?.isExpanded == true)
        let widget2 = try #require(history.simpleMergedRow(mergeRow: row, index: 0))
        #expect(widget2.changedFileCount == 2)
        #expect(widget2.isUnpushed == false)
        #expect(widget2.merge == nil)

        // A merged commit is a commit of the history: it can be selected.
        #expect(history.commit(widget2.commit.sha) == widget2.commit)
        history.select(shas: [widget2.commit.sha], contiguous: true)
        await history.idle()
        #expect(history.selection.changeset.value?.files.count == 2)

        history.setMergeExpanded(false, row: row)
        #expect(history.mergedCommits(ofRow: row) == nil)
        #expect(fixture.simpleLines.contains("  Widget 2") == false)

        // Expanding again shows what was loaded, at once.
        history.setMergeExpanded(true, row: row)
        #expect(history.mergedCommits(ofRow: row)?.state == .loaded)
        #expect(fixture.simpleLines.contains("  Widget 1"))

        // The expansion survives a reload with a new commit on top.
        try await commitAt(at(0), "Main 3", in: fixture.local)
        await fixture.refresh()
        #expect(history.simpleRow(atRow: row + 1)?.merge?.isExpanded == true)
        #expect(fixture.simpleLines.contains("  Widget 1"))
        // The selected merged commit stays selected.
        #expect(history.selection.shas == [widget2.commit.sha])
    }

    @Test("a merge's commits stopped loading when the repository was deselected load when History shows again")
    func resumedExpansion() async throws {
        let fixture = try await makeSimpleFixture(try await makeMerges())
        await fixture.activate()
        let history = fixture.history
        history.setMergeExpanded(true, row: 1)
        history.repositoryDidBecomeInactive()
        await history.idle()
        #expect(history.mergedCommits(ofRow: 1)?.state == .loading)
        #expect(history.mergedCommits(ofRow: 1)?.count == 0)

        await fixture.activate()
        #expect(history.mergedCommits(ofRow: 1) == SimpleMergedCommits(state: .loaded, count: 1, hasMore: false))
        #expect(history.simpleMergedRow(mergeRow: 1, index: 0)?.commit.summary == "Fix 1")
    }

    @Test("a merge's commits are unpushed when the upstream doesn't have them")
    func unpushedMergedCommits() async throws {
        let (local, _) = try await makeRemoteWithMain([("Main 1", at(5))])
        try await runGit(["checkout", "-q", "-b", "w"], local)
        try await commitAt(at(4), "W 1", in: local)
        // The upstream gets W 1 (but not the merge's first parent's line).
        try await runGit(["push", "-q", "origin", "w:main"], local)
        try await commitAt(at(3), "W 2", in: local)
        try await runGit(["checkout", "-q", "main"], local)
        try await mergeAt(at(2), "w", message: "Merge branch 'w'", in: local)

        let fixture = try await makeSimpleFixture(local)
        await fixture.activate()
        let history = fixture.history
        #expect(fixture.simpleLines == ["Merge branch 'w' (unpushed)", "Main 1"])
        history.setMergeExpanded(true, row: 0)
        await history.idle()

        #expect(fixture.simpleLines == ["Merge branch 'w' (unpushed)", "  W 2 (unpushed)", "  W 1", "Main 1"])

        // Pushed, none of them is.
        try await runGit(["push", "-q", "origin", "main"], local)
        await fixture.refresh()
        #expect(fixture.simpleLines == ["Merge branch 'w'", "  W 2", "  W 1", "Main 1"])
        #expect(history.mergedCommits(ofRow: 0)?.state == .loaded)
    }

    @Test("a merge that brought in more commits than an expansion shows says so")
    func largeMerge() async throws {
        let local = try setupEmptyRepository("main")
        try await commitAt(at(9), "Main 1", in: local)
        let base = JSCompat.trim(try await runGit(["rev-parse", "HEAD"], local))
        try await importLinearHistory(
            local,
            branch: "big",
            count: HistoryModel.mergedCommitsLimit + 5,
            prefix: "Big",
            parent: base,
            startTime: at(9, hour: 12)
        )
        try await commitAt(at(8), "Main 2", in: local)
        try await mergeAt(at(7), "big", message: "Merge branch 'big'", in: local)

        let fixture = try await makeSimpleFixture(local)
        await fixture.activate()
        let history = fixture.history
        history.setMergeExpanded(true, row: 0)
        await history.idle()

        #expect(history.mergedCommits(ofRow: 0) == SimpleMergedCommits(
            state: .loaded,
            count: HistoryModel.mergedCommitsLimit,
            hasMore: true
        ))
        let lines = fixture.simpleLines
        #expect(lines.count == HistoryModel.mergedCommitsLimit + 4)
        #expect(lines[HistoryModel.mergedCommitsLimit + 1] == "  (loaded)")
        #expect(history.simpleMergedRow(mergeRow: 0, index: 0)?.commit.summary == "Big \(HistoryModel.mergedCommitsLimit + 5)")
    }
}

@Suite("Merge commit summaries")
struct MergeCommitSummaryTests {
    @Test("reads the branch and pull request from the messages git and hosting services write", arguments: [
        NamedCase("a GitHub pull request", ("Merge pull request #209 from jonas/widget-refresh", "jonas/widget-refresh", 209)),
        NamedCase("git's merge of a branch", ("Merge branch 'feature'", "feature", nil)),
        NamedCase("git's merge of a branch into another", ("Merge branch 'feature' into main", "feature", nil)),
        NamedCase("GitLab's, which quotes the target", ("Merge branch 'feature' into 'main'", "feature", nil)),
        NamedCase("git's merge of a remote-tracking branch", ("Merge remote-tracking branch 'origin/main'", "origin/main", nil)),
        NamedCase("git pull's merge", ("Merge branch 'main' of github.com:owner/repo", "main", nil)),
        NamedCase("git pull's merge into another branch", ("Merge branch 'main' of https://github.com/owner/repo into feature", "main", nil)),
        NamedCase("a Bitbucket pull request", ("Merged in feature/x (pull request #12)", "feature/x", 12)),
        NamedCase("an Azure DevOps pull request, which names no branch", ("Merged PR 123: Add the widget", nil, 123)),
        NamedCase("a pull request numbered 0 isn't one", ("Merge pull request #0 from owner/branch", "owner/branch", nil)),
    ] as [NamedCase<(summary: String, branch: String?, number: Int?)>])
    func recognized(_ testCase: NamedCase<(summary: String, branch: String?, number: Int?)>) throws {
        let (summary, branch, number) = testCase.value
        let parsed = try #require(MergeCommitSummary(summary))
        #expect(parsed.branchName == branch)
        #expect(parsed.pullRequestNumber == number)
    }

    @Test("names nothing for other messages", arguments: [
        "Bring in y",
        "Merge branches 'a' and 'b'",
        "Merge tag 'v1.0'",
        "Merge pull request #209 from jonas/widget-refresh and more",
        "Merge branch ''",
    ])
    func unrecognized(summary: String) {
        #expect(MergeCommitSummary(summary) == nil)
    }
}
