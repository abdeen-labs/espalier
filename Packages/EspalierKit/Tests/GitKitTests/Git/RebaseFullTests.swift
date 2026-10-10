// Ported from desktop/app/test/unit/git/rebase-full-test.ts

import GitKit
import Testing
import TestSupport

private func findBranch(_ repo: Repository, _ name: String) async throws -> Branch {
    let branches = try await getBranches(repo)
    guard let branch = branches.first(where: { $0.name == name }) else {
        throw TestSupportError("Branch \(name) not found")
    }
    return branch
}

@Suite("git/rebase")
struct RebaseFullTests {
    @Suite("getRebaseInternalState")
    struct GetRebaseInternalState {
        @Test("returns null when no rebase is in progress")
        func nullWithoutRebase() async throws {
            let repo = try setupEmptyRepository()
            try await makeCommit(repo, Tree(
                entries: [TreeEntry(path: "file.txt", contents: "initial")],
                commitMessage: "initial commit"
            ))

            let state = await getRebaseInternalState(repo)
            #expect(state == nil)
        }
    }

    @Suite("rebase")
    struct Rebase {
        @Test("rebases with a leading hyphen in a branch name", arguments: [
            NamedCase("rebases with a leading hyphen in the base branch name", (baseName: "-base", targetName: "feature")),
            NamedCase("rebases with a leading hyphen in the target branch name", (baseName: "master", targetName: "-feature")),
        ])
        func leadingHyphen(_ testCase: NamedCase<(baseName: String, targetName: String)>) async throws {
            let (baseName, targetName) = testCase.value
            let repo = try setupEmptyRepository(baseName)
            try await makeCommit(repo, Tree(
                entries: [TreeEntry(path: "initial.txt", contents: "initial")],
                commitMessage: "initial commit"
            ))

            let targetRef = "refs/heads/\(targetName)"
            // Imported refs can have names that git branch does not create.
            try await git(["update-ref", targetRef, "HEAD"], repo.path, "create target")
            try await makeCommit(repo, Tree(
                entries: [TreeEntry(path: "base.txt", contents: "base")],
                commitMessage: "base commit"
            ))

            try await git(["checkout", "--detach", targetRef], repo.path, "checkout target")
            try await git(["symbolic-ref", "HEAD", targetRef], repo.path, "attach target")
            try await makeCommit(repo, Tree(
                entries: [TreeEntry(path: "feature.txt", contents: "feature")],
                commitMessage: "feature commit"
            ))

            let baseBranch = try await findBranch(repo, baseName)
            let targetBranch = try await findBranch(repo, targetName)
            let result = try await rebase(repo, baseBranch, targetBranch)

            #expect(result == .completedWithoutError)
            let status = try await getStatusOrThrow(repo)
            #expect(status.currentBranch == targetName)

            let commits = try await getCommits(repo, "HEAD", limit: 10)
            #expect(commits.map(\.summary) == ["feature commit", "base commit", "initial commit"])
            #expect(commits[1].sha == baseBranch.tip.sha)
            #expect(commits[0].sha != targetBranch.tip.sha)
            #expect(try await findBranch(repo, targetName).tip.sha == commits[0].sha)
            #expect(try await findBranch(repo, baseName).tip.sha == baseBranch.tip.sha)
        }
    }
}
