// Ported in part from desktop/app/test/unit/ui/banner-surfaces-test.tsx
// The cherry-pick undone banner's strings. The branch up-to-date case, and
// the other banners' copy, are checked where real operations produce them:
// the merge, rebase, cherry-pick, squash and reorder, and revert tests.

@testable import EspalierCore
import EspalierCoreTestSupport
import GitKit
import Testing

@Suite("Multi-commit banner copy")
struct MultiCommitCopyTests {
    @Test("renders cherry-pick undone messages with singular and plural commit copy")
    func cherryPickUndone() {
        let one = MultiCommitUndo(kind: .cherryPick, undoSha: "a", branchName: "main", resultTip: "b", commitCount: 1, createdBranch: nil)
        #expect(one.undoneMessage == "Cherry-pick undone. Removed the 1 copied commit from main.")
        let three = MultiCommitUndo(kind: .cherryPick, undoSha: "a", branchName: "release", resultTip: "b", commitCount: 3, createdBranch: nil)
        #expect(three.undoneMessage == "Cherry-pick undone. Removed the 3 copied commits from release.")
        // Undoing a cherry-pick to a new branch deletes it: no message.
        let created = MultiCommitUndo(kind: .cherryPick, undoSha: "a", branchName: "copies", resultTip: "b", commitCount: 1, createdBranch: "copies")
        #expect(created.undoneMessage == nil)
    }

    @Test("counts the commits of each kind for the banners")
    func counts() {
        let commit = makeTestCommit(sha: "a", summary: "A")
        let main = ModelFixtures.branch("main")
        func count(_ detail: MultiCommitOperationDetail) -> Int {
            MultiCommitOperation(kind: .squash, detail: detail, phase: .conflicted, targetBranch: main, origin: .espalier).commitCount
        }
        #expect(count(.squash(commits: [commit, commit], currentTip: "x", lastRetainedCommitRef: nil, targetCommit: commit, commitContext: CommitContext(summary: "s", description: nil))) == 3)
        #expect(count(.reorder(commits: [commit], currentTip: "x", lastRetainedCommitRef: nil, beforeCommit: nil)) == 1)
        #expect(count(.cherryPick(sourceBranch: nil, branchCreated: false, commits: [CommitOneLine(sha: "a", summary: "A")])) == 1)
    }
}
