// History's simple mode: the current branch's first-parent line, one
// commit after another, its unpushed rows marked, with a notice when the
// base has moved on. These check it on real repositories in every edge
// state: a feature branch, the base branch itself, a detached HEAD, an
// unborn branch, no remote, an unpublished branch, a branch with no
// commits of its own, a branch whose base is gone, a shallow clone, a
// branch that merged its base in, and one its base merged. Each says where
// the branch started on the line (the row its color changes to the
// base's), when it did.

@testable import EspalierCore
import EspalierCoreTestSupport
import EspalierSupport
import Foundation
import GitKit
import Testing
import TestSupport

@Suite("Simple history: rows and the base's notice", .offline) @MainActor
struct SimpleHistoryTests {
    private func at(_ daysAgo: Int, hour: Int = 10) -> Int {
        SimpleTime.at(daysAgo: daysAgo, hour: hour)
    }

    @Test("a feature branch: its first-parent line down through the base's history, unpushed rows marked, and the base's new commits")
    func featureBranch() async throws {
        let (local, _) = try await makeRemoteWithMain([("Main 1", at(8)), ("Main 2", at(2, hour: 9))])
        try await runGit(["checkout", "-q", "-b", "feature"], local)
        try await commitAt(at(2, hour: 14), "Feature 1", files: 2, in: local)
        try await commitAt(at(1, hour: 9), "Feature 2", in: local)
        try await runGit(["push", "-q", "-u", "origin", "feature"], local)
        try await commitAt(at(0, hour: 8), "Feature 3", in: local)
        try await commitAt(at(0, hour: 10), "Feature 4", files: 3, in: local)
        try await runGit(["checkout", "-q", "main"], local)
        try await commitAt(at(1, hour: 11), "Main 3", in: local)
        try await commitAt(at(0, hour: 9), "Main 4", in: local)
        try await runGit(["checkout", "-q", "feature"], local)
        try await runGit(["tag", "v1.0", "main~2"], local)

        let fixture = try await makeSimpleFixture(local)
        await fixture.activate()
        let history = fixture.history

        #expect(history.style == .simple)
        #expect(fixture.simpleLines == [
            "Feature 4 (unpushed)",
            "Feature 3 (unpushed)",
            "Feature 2",
            "Feature 1",
            "Main 2",
            "Main 1",
        ])
        #expect(history.simpleBaseStatus?.branch.name == "main")
        #expect(fixture.baseNotice == "main +2")
        #expect(history.simpleOutline.itemIndex(ofRow: 4) == 4)
        // The branch started at Main 2.
        #expect(history.simpleStart?.base.name == "main")
        #expect(history.simpleStart?.row == 4)

        let newest = try fixture.simpleRow("Feature 4")
        #expect(newest.changedFileCount == 3)
        #expect(newest.merge == nil)
        #expect(try fixture.simpleRow("Feature 1").changedFileCount == 2)
        #expect(try fixture.simpleRow("Main 2").tags == ["v1.0"])

        // The rows are the history's: all loaded, HEAD's commit selected.
        #expect(fixture.summaries == ["Feature 4", "Feature 3", "Feature 2", "Feature 1", "Main 2", "Main 1"])
        #expect(history.isComplete)
        #expect(history.totalCommitCount == 6)
        #expect(history.selection.shas == [try await fixture.sha("HEAD")])
        #expect(history.isLoading == false)
    }

    @Test("the base branch itself: its unpushed rows marked, and no notice")
    func baseBranch() async throws {
        let (local, _) = try await makeRemoteWithMain([("Main 1", at(3))])
        try await commitAt(at(1), "Main 2", in: local)
        try await commitAt(at(0), "Main 3", in: local)

        let fixture = try await makeSimpleFixture(local)
        await fixture.activate()

        #expect(fixture.simpleLines == ["Main 3 (unpushed)", "Main 2 (unpushed)", "Main 1"])
        #expect(fixture.baseNotice == nil)
        #expect(fixture.history.simpleStart == nil)
    }

    @Test("a detached HEAD: first parents from HEAD, nothing marked, and no notice")
    func detachedHead() async throws {
        let (local, _) = try await makeRemoteWithMain([("Main 1", at(8)), ("Main 2", at(2, hour: 9))])
        try await runGit(["checkout", "-q", "-b", "feature"], local)
        try await commitAt(at(2, hour: 14), "Feature 1", in: local)
        try await commitAt(at(1), "Feature 2", in: local)
        try await runGit(["checkout", "-q", "main"], local)
        try await commitAt(at(0), "Main 3", in: local)
        try await runGit(["checkout", "-q", "--detach", "feature"], local)

        let fixture = try await makeSimpleFixture(local)
        await fixture.activate()

        #expect(fixture.simpleLines == ["Feature 2", "Feature 1", "Main 2", "Main 1"])
        #expect(fixture.baseNotice == nil)
        #expect(fixture.history.simpleStart == nil)
        #expect(fixture.history.selection.shas == [try await fixture.sha("HEAD")])
    }

    @Test("an unborn branch: no history yet")
    func unbornBranch() async throws {
        let local = try setupEmptyRepository("main")
        let fixture = try await makeSimpleFixture(local)
        await fixture.activate()
        let history = fixture.history

        #expect(history.simpleOutline.items.isEmpty)
        #expect(history.commitSHAs.isEmpty)
        #expect(history.isComplete)
        #expect(history.isLoading == false)
        #expect(history.loadError == nil)
        #expect(history.selection.shas.isEmpty)
        #expect(fixture.baseNotice == nil)

        // The first commit shows.
        try await commitAt(at(0), "First", in: local)
        await fixture.refresh()
        #expect(fixture.simpleLines == ["First"])
    }

    @Test("no remote: nothing is marked unpushed")
    func noRemote() async throws {
        let local = try setupEmptyRepository("main")
        try await commitAt(at(9), "Main 1", in: local)
        try await runGit(["checkout", "-q", "-b", "feature"], local)
        try await commitAt(at(1), "Feature 1", in: local)

        let fixture = try await makeSimpleFixture(local)
        await fixture.activate()

        #expect(fixture.simpleLines == ["Feature 1", "Main 1"])
    }

    @Test("an unpublished branch: the commits no remote has are marked unpushed")
    func unpublishedBranch() async throws {
        let (local, _) = try await makeRemoteWithMain([("Main 1", at(3))])
        try await runGit(["checkout", "-q", "-b", "feature"], local)
        try await commitAt(at(1), "Feature 1", in: local)
        try await commitAt(at(0), "Feature 2", in: local)

        let fixture = try await makeSimpleFixture(local)
        await fixture.activate()

        #expect(fixture.simpleLines == ["Feature 2 (unpushed)", "Feature 1 (unpushed)", "Main 1"])
    }

    @Test("a new branch with no commits of its own: the base's line, nothing marked; a notice once the base moves on")
    func noCommitsOfItsOwn() async throws {
        let (local, _) = try await makeRemoteWithMain([("Main 1", at(3)), ("Main 2", at(2))])
        try await runGit(["checkout", "-q", "-b", "feature"], local)

        let fixture = try await makeSimpleFixture(local)
        await fixture.activate()
        #expect(fixture.simpleLines == ["Main 2", "Main 1"])
        #expect(fixture.baseNotice == nil)
        // It started at its tip.
        #expect(fixture.history.simpleStart?.row == 0)

        try await runGit(["checkout", "-q", "main"], local)
        try await commitAt(at(0), "Main 3", in: local)
        try await runGit(["checkout", "-q", "feature"], local)
        await fixture.refresh()
        #expect(fixture.simpleLines == ["Main 2", "Main 1"])
        #expect(fixture.baseNotice == "main +1")
    }

    @Test("a branch whose base is gone: its line, and no notice")
    func baseGone() async throws {
        let local = try setupEmptyRepository("main")
        try await commitAt(at(9), "Main 1", in: local)
        try await runGit(["checkout", "-q", "-b", "feature"], local)
        try await commitAt(at(1), "Feature 1", in: local)
        try await runGit(["branch", "-q", "-D", "main"], local)

        let fixture = try await makeSimpleFixture(local)
        await fixture.activate()

        #expect(fixture.model.gitState.branches.defaultBranch == nil)
        #expect(fixture.simpleLines == ["Feature 1", "Main 1"])
        #expect(fixture.baseNotice == nil)
        #expect(fixture.history.simpleStart == nil)
    }

    @Test("a shallow clone that cut the branch's line before it met the base: no notice, though the base has commits the branch doesn't")
    func shallowClone() async throws {
        let seed = try setupEmptyRepository("main")
        for number in 1...3 {
            try await commitAt(at(10 - number), "Main \(number)", in: seed)
        }
        try await runGit(["checkout", "-q", "-b", "feature"], seed)
        try await commitAt(at(6, hour: 12), "Feature 1", in: seed)
        try await commitAt(at(6, hour: 13), "Feature 2", in: seed)
        try await runGit(["checkout", "-q", "main"], seed)
        for number in 4...6 {
            try await commitAt(at(10 - number, hour: 14), "Main \(number)", in: seed)
        }
        let remote = try await makeBareRemote(from: seed)
        let local = Repository(path: try createTempDirectory())
        try await runGit(["clone", "-q", "--depth", "2", "--no-single-branch", "file://\(remote.path)", local.path], local)
        try await runGit(["checkout", "-q", "feature"], local)

        let fixture = try await makeSimpleFixture(local)
        await fixture.activate()

        #expect(fixture.model.gitState.branches.defaultBranch?.name == "main")
        #expect(fixture.simpleLines == ["Feature 2", "Feature 1"])
        #expect(fixture.history.isComplete)
        #expect(fixture.history.simpleFrame?.behindCount == 2)
        #expect(fixture.baseNotice == nil)
        #expect(fixture.history.simpleStart == nil)
    }

    @Test("a branch that merged its base in: the merge is one of its rows, and the base has nothing new")
    func mergedBaseIn() async throws {
        let local = try setupEmptyRepository("main")
        try await commitAt(at(9), "Main 1", in: local)
        try await runGit(["checkout", "-q", "-b", "feature"], local)
        try await commitAt(at(5), "Feature 1", in: local)
        try await runGit(["checkout", "-q", "main"], local)
        try await commitAt(at(4), "Main 2", in: local)
        try await runGit(["checkout", "-q", "feature"], local)
        try await mergeAt(at(3), "main", message: "Merge branch 'main' into feature", in: local)
        try await commitAt(at(2), "Feature 2", in: local)

        let fixture = try await makeSimpleFixture(local)
        await fixture.activate()

        #expect(fixture.simpleLines == ["Feature 2", "Merge branch 'main' into feature", "Feature 1", "Main 1"])
        #expect(fixture.baseNotice == nil)
        let merge = try #require(try fixture.simpleRow("Merge branch 'main' into feature").merge)
        #expect(merge == SimpleHistoryMerge(branchName: "main", pullRequestNumber: nil, isExpanded: false))
        // It started at Main 1, below the merge that brought Main 2 in.
        #expect(fixture.history.simpleStart?.row == 3)
    }

    @Test("a branch its base merged: the base has its whole line, which starts at its tip")
    func mergedIntoBase() async throws {
        let local = try setupEmptyRepository("main")
        try await commitAt(at(9), "Main 1", in: local)
        try await runGit(["checkout", "-q", "-b", "feature"], local)
        try await commitAt(at(5), "Feature 1", in: local)
        try await commitAt(at(4), "Feature 2", in: local)
        try await runGit(["checkout", "-q", "main"], local)
        try await commitAt(at(3), "Main 2", in: local)
        try await mergeAt(at(2), "feature", message: "Merge branch 'feature'", in: local)
        try await runGit(["checkout", "-q", "feature"], local)

        let fixture = try await makeSimpleFixture(local)
        await fixture.activate()

        #expect(fixture.simpleLines == ["Feature 2", "Feature 1", "Main 1"])
        // Main has the branch's commits through the merge's second parent,
        // which a first-parent count still excludes.
        #expect(fixture.history.simpleStart?.row == 0)
        #expect(fixture.baseNotice == "main +2")
    }
}
