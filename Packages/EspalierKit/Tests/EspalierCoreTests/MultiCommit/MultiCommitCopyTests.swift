// Ported in part from desktop/app/test/unit/ui/banner-surfaces-test.tsx
// Whether undoing a cherry-pick is announced, and the commit counts the
// banners show.

@testable import EspalierCore
import EspalierCoreTestSupport
import GitKit
import Testing

@Suite("Multi-commit banners")
struct MultiCommitCopyTests {
    @Test("undoing a cherry-pick is announced, unless it deletes the branch the cherry-pick created")
    func cherryPickUndone() {
        let one = MultiCommitUndo(kind: .cherryPick, undoSha: "a", branchName: "main", resultTip: "b", commitCount: 1, createdBranch: nil)
        #expect(one.undoneMessage != nil)
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
