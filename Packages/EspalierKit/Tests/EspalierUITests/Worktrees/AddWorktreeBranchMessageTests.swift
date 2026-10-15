// Add Worktree says when nothing of the branch's name is valid, whether
// it's typed or, with nothing typed, the worktree's name, and when the
// local branch it makes can't be kept beside the local branches: one of
// them in another case, or one that is another's folder.

@testable import EspalierCore
import GitKit
import Testing
import TestSupport
@testable import EspalierUI

@Suite("Add Worktree's branch name")
struct AddWorktreeBranchMessageTests {
    /// The repository's local and remote branches, the worktree's name, the
    /// branch name typed, and whether the message is an error.
    typealias Case = (local: [String], remote: [String], name: String, branchName: String, isError: Bool)

    private static func branches(_ testCase: Case) -> [Branch] {
        testCase.local.map {
            Branch(name: $0, upstream: nil, tip: BranchTip(sha: String(repeating: "1", count: 40)), type: .local, ref: "refs/heads/\($0)")
        } + testCase.remote.map {
            Branch(name: $0, upstream: nil, tip: BranchTip(sha: String(repeating: "2", count: 40)), type: .remote, ref: "refs/remotes/\($0)")
        }
    }

    @Test("an invalid or clashing branch name is an error", arguments: [
        NamedCase("an invalid name typed", (local: [], remote: [], name: "espalier-login", branchName: "HEAD", isError: true)),
        NamedCase("an invalid worktree name", (local: [], remote: [], name: "HEAD", branchName: "", isError: true)),
        NamedCase("a valid worktree name", (local: [], remote: [], name: "espalier-login", branchName: "", isError: false)),
        NamedCase("a valid name typed for the worktree's", (local: [], remote: [], name: "HEAD", branchName: "login", isError: false)),
        NamedCase("a new branch inside a branch", (local: ["main", "feature"], remote: [], name: "wt", branchName: "feature/x", isError: true)),
        NamedCase("a new branch around a branch", (local: ["main", "feature/x"], remote: [], name: "wt", branchName: "feature", isError: true)),
        NamedCase("the worktree's name, a branch in another case", (local: ["main", "login"], remote: [], name: "Login", branchName: "", isError: true)),
        NamedCase("a remote branch inside a local branch", (local: ["main", "feature"], remote: ["origin/feature/x"], name: "wt", branchName: "feature/x", isError: true)),
        NamedCase("only starting like a branch", (local: ["main", "feature"], remote: [], name: "wt", branchName: "feature-x/y", isError: false)),
        NamedCase("an existing branch", (local: ["main", "feature"], remote: [], name: "wt", branchName: "feature", isError: false)),
    ] as [NamedCase<Case>])
    func branchName(_ testCase: NamedCase<Case>) {
        let value = testCase.value
        let branches = Self.branches(value)
        // As `WorktreesModel.branchResolution(for:path:)` resolves it.
        let resolution = WorktreesModel.effectiveBranchName(value.branchName, path: value.name)
            .map { WorktreesModel.resolveBranch($0, in: branches) }
        let message = AddWorktreeContent.branchMessage(
            name: value.name,
            branchName: value.branchName,
            resolution: resolution,
            branches: branches
        )
        #expect((message?.isError ?? false) == value.isError)
    }
}
