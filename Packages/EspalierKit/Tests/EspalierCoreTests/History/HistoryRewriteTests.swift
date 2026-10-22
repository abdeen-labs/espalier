// The commit a squash or reorder starts after, and the merge commits it
// refuses in the range, are found on the current branch's first-parent
// line: the history shows other branches too, so its indexes won't do.

@testable import EspalierCore
import EspalierCoreTestSupport
import EspalierSupport
import GitKit
import Testing
import TestSupport

@Suite("History rewrite checks", .offline) @MainActor
struct HistoryRewriteTests {
    /// `main`: A (root), B, M (merging `side`'s S1 into B), C, D (HEAD);
    /// `feature` from C with F1.
    private func makeRepository() async throws -> (HistoryFixture, [String: String]) {
        var shas: [String: String] = [:]
        let fixture = try await makeHistoryFixture { repository in
            shas["A"] = try await commitWithGit(repository, "a.txt", "a\n", message: "A")
            shas["B"] = try await commitWithGit(repository, "b.txt", "b\n", message: "B")
            try await runGit(["checkout", "-q", "-b", "side", shas["A"]!], repository)
            shas["S1"] = try await commitWithGit(repository, "s.txt", "s\n", message: "S1")
            try await runGit(["checkout", "-q", "main"], repository)
            try await runGit(["merge", "-q", "--no-ff", "-m", "M", "side"], repository)
            shas["M"] = JSCompat.trim(try await runGit(["rev-parse", "HEAD"], repository))
            shas["C"] = try await commitWithGit(repository, "c.txt", "c\n", message: "C")
            try await runGit(["checkout", "-q", "-b", "feature"], repository)
            shas["F1"] = try await commitWithGit(repository, "f.txt", "f\n", message: "F1")
            try await runGit(["checkout", "-q", "main"], repository)
            shas["D"] = try await commitWithGit(repository, "d.txt", "d\n", message: "D")
        }
        await fixture.activate()
        return (fixture, shas)
    }

    @Test("commits on the current branch's line give their order and the commit before the oldest")
    func onTheLine() async throws {
        let (fixture, shas) = try await makeRepository()
        let rewrite = try #require(fixture.history.currentBranchRewrite(moving: [shas["C"]!, shas["D"]!], relativeTo: nil))
        #expect(rewrite.commits.map(\.summary) == ["D", "C"])
        #expect(rewrite.lastRetainedCommitRef == "\(shas["C"]!)^")
        #expect(rewrite.positions[shas["D"]!] == 0)

        // Squashing D into C reaches no further than C.
        let squash = try #require(fixture.history.currentBranchRewrite(moving: [shas["D"]!], relativeTo: shas["C"]!))
        #expect(squash.lastRetainedCommitRef == "\(shas["C"]!)^")
    }

    @Test("a merge commit in the range, a commit on another branch, or a detached HEAD refuse it")
    func refusals() async throws {
        let (fixture, shas) = try await makeRepository()
        // C, just above the merge M, can be rewritten: B can't.
        #expect(fixture.history.currentBranchRewrite(moving: [shas["C"]!], relativeTo: nil) != nil)
        // B is below the merge M: replaying from B^ would replay M.
        #expect(fixture.history.currentBranchRewrite(moving: [shas["B"]!], relativeTo: nil) == nil)
        // F1 is on `feature`, not `main`.
        #expect(fixture.history.currentBranchRewrite(moving: [shas["F1"]!], relativeTo: nil) == nil)
        #expect(fixture.history.currentBranchRewrite(moving: [shas["D"]!], relativeTo: shas["C"]!) != nil)
        #expect(fixture.history.currentBranchRewrite(moving: [shas["D"]!], relativeTo: shas["F1"]!) == nil)
        #expect(fixture.history.currentBranchRewrite(moving: [], relativeTo: nil) == nil)

        // D can be rewritten until HEAD is detached.
        #expect(fixture.history.currentBranchRewrite(moving: [shas["D"]!], relativeTo: nil) != nil)
        try await fixture.git(["checkout", "-q", "--detach", "HEAD"])
        await fixture.refresh()
        #expect(fixture.history.currentBranchRewrite(moving: [shas["D"]!], relativeTo: nil) == nil)
    }

    @Test("a merge commit is the reason when the commits are in the branch's history: below a merge, merged in, or the merge itself")
    func mergeReason() async throws {
        let (fixture, shas) = try await makeRepository()
        let history = fixture.history
        let m = shas["M"]!
        // B is below M on the line.
        #expect(history.checkCurrentBranchRewrite(moving: [shas["B"]!], relativeTo: nil).mergeInTheWay?.sha == m)
        // Squashing C into B, or moving D below B, replays M.
        #expect(history.checkCurrentBranchRewrite(moving: [shas["C"]!], relativeTo: shas["B"]!).mergeInTheWay?.sha == m)
        #expect(history.checkCurrentBranchRewrite(moving: [shas["D"]!], relativeTo: shas["B"]!).mergeInTheWay?.sha == m)
        // S1 came in with M, off the first-parent line.
        #expect(history.checkCurrentBranchRewrite(moving: [shas["S1"]!], relativeTo: nil).mergeInTheWay?.sha == m)
        // The merge itself.
        #expect(history.checkCurrentBranchRewrite(moving: [m], relativeTo: nil).mergeInTheWay?.sha == m)
        // Above the merge it's allowed.
        #expect(history.checkCurrentBranchRewrite(moving: [shas["D"]!], relativeTo: shas["C"]!).rewrite != nil)
    }

    @Test("below two merges, the reason is the older one, nearest the commits")
    func nearestMerge() async throws {
        // `main`: A (root), B, "Merge one" (of `one`'s commit from A), C,
        // "Merge two" (of `two`'s commit from A), D (HEAD).
        var shas: [String: String] = [:]
        let fixture = try await makeHistoryFixture { repository in
            shas["A"] = try await commitWithGit(repository, "a.txt", "a\n", message: "A")
            try await runGit(["checkout", "-q", "-b", "one"], repository)
            try await commitWithGit(repository, "one.txt", "one\n", message: "One")
            try await runGit(["checkout", "-q", "-b", "two", shas["A"]!], repository)
            try await commitWithGit(repository, "two.txt", "two\n", message: "Two")
            try await runGit(["checkout", "-q", "main"], repository)
            try await commitWithGit(repository, "b.txt", "b\n", message: "B")
            try await runGit(["merge", "-q", "--no-ff", "-m", "Merge one", "one"], repository)
            shas["Merge one"] = JSCompat.trim(try await runGit(["rev-parse", "HEAD"], repository))
            shas["C"] = try await commitWithGit(repository, "c.txt", "c\n", message: "C")
            try await runGit(["merge", "-q", "--no-ff", "-m", "Merge two", "two"], repository)
            shas["Merge two"] = JSCompat.trim(try await runGit(["rev-parse", "HEAD"], repository))
            shas["D"] = try await commitWithGit(repository, "d.txt", "d\n", message: "D")
        }
        await fixture.activate()
        let history = fixture.history
        // A is below both merges; C only below "Merge two".
        #expect(history.checkCurrentBranchRewrite(moving: [shas["A"]!], relativeTo: nil).mergeInTheWay?.sha == shas["Merge one"])
        #expect(history.checkCurrentBranchRewrite(moving: [shas["C"]!], relativeTo: nil).mergeInTheWay?.sha == shas["Merge two"])
        #expect(history.checkCurrentBranchRewrite(moving: [shas["D"]!], relativeTo: nil).rewrite != nil)
    }

    @Test("another branch's commits, or any with a detached HEAD, can't be rewritten, with nothing to explain")
    func unavailable() async throws {
        let (fixture, shas) = try await makeRepository()
        let history = fixture.history
        // F1 is on `feature`, which `main` hasn't merged, though M is above it.
        #expect(history.checkCurrentBranchRewrite(moving: [shas["F1"]!], relativeTo: nil) == .unavailable)
        #expect(history.checkCurrentBranchRewrite(moving: [shas["D"]!], relativeTo: shas["F1"]!) == .unavailable)
        #expect(history.checkCurrentBranchRewrite(moving: [shas["B"]!, shas["F1"]!], relativeTo: nil) == .unavailable)
        #expect(history.checkCurrentBranchRewrite(moving: [], relativeTo: nil) == .unavailable)
        #expect(history.checkCurrentBranchRewrite(moving: ["0000000000000000000000000000000000000000"], relativeTo: nil) == .unavailable)

        try await fixture.git(["checkout", "-q", "--detach", "HEAD"])
        await fixture.refresh()
        #expect(history.checkCurrentBranchRewrite(moving: [shas["B"]!], relativeTo: nil) == .unavailable)
    }

    @Test("a branch's root commit rewrites from the root")
    func root() async throws {
        let fixture = try await makeHistoryFixture { repository in
            try await commitWithGit(repository, "a.txt", "a\n", message: "A")
            try await commitWithGit(repository, "b.txt", "b\n", message: "B")
        }
        await fixture.activate()
        let a = try await fixture.sha("HEAD~1")
        let rewrite = try #require(fixture.history.currentBranchRewrite(moving: [a], relativeTo: nil))
        #expect(rewrite.lastRetainedCommitRef == nil)
    }

    @Test("moving commits to where they are changes nothing (desktop's drop rules)")
    func noOpReorders() async throws {
        let (fixture, shas) = try await makeRepository()
        let history = fixture.history
        let c = shas["C"]!, d = shas["D"]!
        // C right below D is where it is; D at the top is where it is.
        #expect(try #require(history.currentBranchRewrite(moving: [c], relativeTo: d)).isNoOpReorder(below: d))
        #expect(try #require(history.currentBranchRewrite(moving: [d], relativeTo: nil)).isNoOpReorder(below: nil))
        // D below C moves it; C at the top moves it.
        #expect(try #require(history.currentBranchRewrite(moving: [d], relativeTo: c)).isNoOpReorder(below: c) == false)
        #expect(try #require(history.currentBranchRewrite(moving: [c], relativeTo: nil)).isNoOpReorder(below: nil) == false)
        // Within the moved commits: nothing to do.
        #expect(try #require(history.currentBranchRewrite(moving: [c, d], relativeTo: c)).isNoOpReorder(below: c))
    }
}
