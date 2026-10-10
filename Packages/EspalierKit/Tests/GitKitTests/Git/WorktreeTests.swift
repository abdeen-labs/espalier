// Ported from desktop/app/test/unit/git/worktree-test.ts

import EspalierSupport
import Foundation
import GitKit
import Testing
import TestSupport

private func porcelain(_ blocks: [[String]]) -> String {
    blocks.map { $0.joined(separator: "\0") }.joined(separator: "\0\0") + "\0"
}

private let mainBlock = [
    "worktree /path/to/repo",
    "HEAD abc1234abc1234abc1234abc1234abc1234abc123",
    "branch refs/heads/main",
]

private func stdout(_ result: Dugite.Result) -> String {
    String(decoding: result.stdout, as: UTF8.self)
}

@Suite("git/worktree")
struct WorktreeTests {
    @Suite("parseWorktreePorcelainOutput")
    struct ParseWorktreePorcelainOutput {
        @Test("returns empty array for empty output")
        func empty() {
            #expect(parseWorktreePorcelainOutput("").isEmpty)
            #expect(parseWorktreePorcelainOutput("  \n  ").isEmpty)
        }

        @Test("parses a single main worktree")
        func singleMain() {
            let output = mainBlock.joined(separator: "\0") + "\0"

            let entries = parseWorktreePorcelainOutput(output)
            #expect(entries.count == 1)
            #expect(entries[0] == WorktreeEntry(
                path: POSIXPath.normalize("/path/to/repo"),
                head: "abc1234abc1234abc1234abc1234abc1234abc123",
                branch: "refs/heads/main",
                isDetached: false,
                type: .main,
                isLocked: false,
                isPrunable: false
            ))
        }

        @Test("parses multiple worktrees")
        func multiple() {
            let output = porcelain([
                mainBlock,
                [
                    "worktree /path/to/linked",
                    "HEAD def5678def5678def5678def5678def5678def567",
                    "branch refs/heads/feature",
                ],
            ])

            let entries = parseWorktreePorcelainOutput(output)
            #expect(entries.count == 2)

            #expect(entries[0].type == .main)
            #expect(entries[0].path == POSIXPath.normalize("/path/to/repo"))

            #expect(entries[1].type == .linked)
            #expect(entries[1].path == POSIXPath.normalize("/path/to/linked"))
            #expect(entries[1].branch == "refs/heads/feature")
        }

        @Test("parses detached HEAD worktree")
        func detached() {
            let output = porcelain([
                mainBlock,
                [
                    "worktree /path/to/detached",
                    "HEAD def5678def5678def5678def5678def5678def567",
                    "detached",
                ],
            ])

            let entries = parseWorktreePorcelainOutput(output)
            #expect(entries.count == 2)

            #expect(entries[1].isDetached)
            #expect(entries[1].branch == nil)
        }

        @Test("parses a locked worktree", arguments: [
            NamedCase("parses locked worktree", "locked"),
            NamedCase("parses locked worktree with reason", "locked reason why it is locked"),
        ])
        func locked(_ testCase: NamedCase<String>) {
            let output = porcelain([
                mainBlock,
                [
                    "worktree /path/to/locked-wt",
                    "HEAD def5678def5678def5678def5678def5678def567",
                    "branch refs/heads/locked-branch",
                    testCase.value,
                ],
            ])

            let entries = parseWorktreePorcelainOutput(output)
            #expect(entries[1].isLocked)
        }

        @Test("parses prunable worktree")
        func prunable() {
            let output = porcelain([
                mainBlock,
                [
                    "worktree /path/to/prunable-wt",
                    "HEAD def5678def5678def5678def5678def5678def567",
                    "branch refs/heads/stale",
                    "prunable gitdir file points to non-existent location",
                ],
            ])

            let entries = parseWorktreePorcelainOutput(output)
            #expect(entries[1].isPrunable)
        }

        @Test("parses paths with separators", arguments: [
            NamedCase("parses paths with spaces", (main: "/path/to/my repo", linked: "/path/to/my other worktree")),
            NamedCase("parses paths with newlines", (main: "/path/to/my\nrepo", linked: "/path/to/my\nother\nworktree")),
        ])
        func pathsWithSeparators(_ testCase: NamedCase<(main: String, linked: String)>) {
            let (main, linked) = testCase.value
            let output = porcelain([
                [
                    "worktree \(main)",
                    "HEAD abc1234abc1234abc1234abc1234abc1234abc123",
                    "branch refs/heads/main",
                ],
                [
                    "worktree \(linked)",
                    "HEAD def5678def5678def5678def5678def5678def567",
                    "branch refs/heads/feature",
                ],
            ])

            let entries = parseWorktreePorcelainOutput(output)
            #expect(entries[0].path == POSIXPath.normalize(main))
            #expect(entries[1].path == POSIXPath.normalize(linked))
        }

        @Test("parses worktree with locked and prunable flags combined")
        func lockedAndPrunable() {
            let output = porcelain([
                mainBlock,
                [
                    "worktree /path/to/bad-wt",
                    "HEAD def5678def5678def5678def5678def5678def567",
                    "detached",
                    "locked",
                    "prunable",
                ],
            ])

            let entries = parseWorktreePorcelainOutput(output)
            #expect(entries[1].isDetached)
            #expect(entries[1].isLocked)
            #expect(entries[1].isPrunable)
            #expect(entries[1].branch == nil)
        }
    }

    @Suite("listWorktrees")
    struct ListWorktrees {
        /// Helper to extract checked-out branch refs from worktree entries
        private func checkedOutBranches(_ worktrees: [WorktreeEntry]) -> Set<String> {
            Set(worktrees.compactMap(\.branch))
        }

        @Test("returns only main worktree branch when there are no linked worktrees")
        func onlyMain() async throws {
            let repo = try setupEmptyRepository("main")
            try await makeCommit(repo, Tree(entries: [TreeEntry(path: "README", contents: "hello")]))

            let branches = checkedOutBranches(try await listWorktrees(repo))
            #expect(branches == ["refs/heads/main"])
        }

        @Test("handles multiple linked worktrees")
        func multipleLinked() async throws {
            let repo = try setupEmptyRepository("main")
            try await makeCommit(repo, Tree(entries: [TreeEntry(path: "README", contents: "hello")]))
            _ = try await Dugite.exec(["branch", "feature-a"], repo.path)
            _ = try await Dugite.exec(["branch", "feature-b"], repo.path)
            _ = try await Dugite.exec(["worktree", "add", repo.path + "-wt-a", "feature-a"], repo.path)
            _ = try await Dugite.exec(["worktree", "add", repo.path + "-wt-b", "feature-b"], repo.path)

            let branches = checkedOutBranches(try await listWorktrees(repo))
            #expect(branches.contains("refs/heads/feature-a"))
            #expect(branches.contains("refs/heads/feature-b"))
            #expect(branches.contains("refs/heads/main"))
            #expect(branches.count == 3)
        }

        @Test("handles detached HEAD worktrees")
        func detachedLinked() async throws {
            let repo = try setupEmptyRepository("main")
            try await makeCommit(repo, Tree(entries: [TreeEntry(path: "README", contents: "hello")]))

            let sha = JSCompat.trim(stdout(try await Dugite.exec(["rev-parse", "HEAD"], repo.path)))
            _ = try await Dugite.exec(["worktree", "add", "--detach", repo.path + "-wt-detached", sha], repo.path)

            let branches = checkedOutBranches(try await listWorktrees(repo))
            #expect(branches == ["refs/heads/main"])
        }

        @Test("lists worktrees from a git dir after a linked worktree directory is removed")
        func fromGitDir() async throws {
            let repo = try setupEmptyRepository("main")
            try await makeCommit(repo, Tree(entries: [TreeEntry(path: "README", contents: "hello")]))
            _ = try await Dugite.exec(["branch", "feature-a"], repo.path)

            let worktreePath = repo.path + "-wt-a"
            _ = try await Dugite.exec(["worktree", "add", worktreePath, "feature-a"], repo.path)

            let gitDirOutput = JSCompat.trim(stdout(try await Dugite.exec(["rev-parse", "--git-dir"], worktreePath)))
            let gitDir = POSIXPath.resolve(worktreePath, gitDirOutput)

            try FileManager.default.removeItem(atPath: worktreePath)

            let worktrees = try await listWorktreesFromGitDir(gitDir)
            let mainWorktree = worktrees.first { $0.type == .main }
            // Temporary directories are already real paths.
            let repoPath = repo.path
            let resolvedWorktreePath = repoPath + "-wt-a"

            #expect(mainWorktree?.path == repoPath)
            #expect(worktrees.contains { $0.path == resolvedWorktreePath && $0.isPrunable })
        }
    }

    @Suite("resolveMainWorktreePath")
    struct ResolveMainWorktreePath {
        /// Sets up a repository with a single linked worktree and returns the
        /// realpath'd main worktree path, the linked worktree path and the linked
        /// worktree's admin git dir.
        private func setupWorktree() async throws -> (repo: Repository, mainPath: String, worktreePath: String, gitDir: String) {
            let repo = try setupEmptyRepository("main")
            try await makeCommit(repo, Tree(entries: [TreeEntry(path: "README", contents: "hello")]))
            _ = try await Dugite.exec(["branch", "feature-a"], repo.path)

            let worktreePath = repo.path + "-wt-a"
            _ = try await Dugite.exec(["worktree", "add", worktreePath, "feature-a"], repo.path)

            let gitDirOutput = JSCompat.trim(stdout(try await Dugite.exec(["rev-parse", "--git-dir"], worktreePath)))

            return (repo, repo.path, worktreePath, POSIXPath.resolve(worktreePath, gitDirOutput))
        }

        @Test("resolves from the persisted path once the worktree metadata is gone")
        func persistedPath() async throws {
            let (repo, mainPath, worktreePath, gitDir) = try await setupWorktree()

            // Espalier switched onto the worktree, recording the main worktree
            // it came from.
            let selected = Repository(path: worktreePath, gitDir: gitDir)

            // `git worktree remove` deletes the working directory *and* the admin
            // metadata under <main>/.git/worktrees/<name>.
            _ = try await Dugite.exec(["worktree", "remove", "--force", worktreePath], repo.path)

            #expect(try await resolveMainWorktreePath(selected, mainWorktreePath: mainPath) == mainPath)
        }

        @Test("falls back to the git dir when no path was persisted")
        func gitDirFallback() async throws {
            let (_, mainPath, worktreePath, gitDir) = try await setupWorktree()

            // A repository record with a git dir but no main worktree path.
            let selected = Repository(path: worktreePath, gitDir: gitDir)

            // A plain delete leaves the admin metadata intact, so the worktree set
            // is still discoverable through it.
            try FileManager.default.removeItem(atPath: worktreePath)

            #expect(try await resolveMainWorktreePath(selected, mainWorktreePath: nil) == mainPath)
        }

        @Test("returns null when the repository is already the main worktree")
        func alreadyMain() async throws {
            let (repo, mainPath, _, _) = try await setupWorktree()

            let selected = Repository(path: mainPath, gitDir: POSIXPath.join(repo.path, ".git"))

            #expect(try await resolveMainWorktreePath(selected, mainWorktreePath: mainPath) == nil)
        }

        @Test("falls back to the git dir when the persisted path is stale")
        func stalePersistedPath() async throws {
            let (_, mainPath, worktreePath, gitDir) = try await setupWorktree()

            // A persisted path can outlive the location it names — a repository moved
            // outside Espalier, say. It shouldn't stop us resolving the main worktree
            // by the means that still work.
            let selected = Repository(path: worktreePath, gitDir: gitDir)

            #expect(
                try await resolveMainWorktreePath(
                    selected,
                    mainWorktreePath: POSIXPath.join(mainPath, "no", "longer", "here")
                ) == mainPath
            )
        }

        @Test("returns null when neither a persisted path nor a git dir is available")
        func nothingAvailable() async throws {
            let (_, _, worktreePath, _) = try await setupWorktree()

            let selected = Repository(path: worktreePath)

            #expect(try await resolveMainWorktreePath(selected, mainWorktreePath: nil) == nil)
        }
    }

    // MARK: - Espalier

    @Suite("worktree management")
    struct Management {
        @Test("adds, moves, and removes a linked worktree")
        func addMoveRemove() async throws {
            let repo = try setupEmptyRepository("main")
            try await makeCommit(repo, Tree(entries: [TreeEntry(path: "README", contents: "hello")]))

            let worktreePath = repo.path + "-wt-new"
            try await addWorktree(repo, worktreePath, AddWorktreeOptions(createBranch: "new-branch"))
            var worktrees = try await listWorktrees(repo)
            #expect(worktrees.contains { $0.path == worktreePath && $0.branch == "refs/heads/new-branch" })

            let movedPath = repo.path + "-wt-moved"
            try await moveWorktree(repo, worktreePath, movedPath)
            worktrees = try await listWorktrees(repo)
            #expect(worktrees.map(\.path).contains(movedPath))
            #expect(!worktrees.map(\.path).contains(worktreePath))

            try await removeWorktree(repo.path, movedPath)
            worktrees = try await listWorktrees(repo.path)
            #expect(worktrees.map(\.path) == [repo.path])
        }

        @Test("adds a worktree for a commit-ish, and removes a dirty one only by force")
        func commitishAndForce() async throws {
            let repo = try setupEmptyRepository("main")
            try await makeCommit(repo, Tree(entries: [TreeEntry(path: "README", contents: "hello")]))
            let sha = JSCompat.trim(stdout(try await Dugite.exec(["rev-parse", "HEAD"], repo.path)))

            let worktreePath = repo.path + "-wt-detached"
            try await addWorktree(repo, worktreePath, AddWorktreeOptions(commitish: sha))
            let worktree = try #require(try await listWorktrees(repo).first { $0.path == worktreePath })
            #expect(worktree.isDetached)
            #expect(worktree.head == sha)

            try Data("dirty".utf8).write(to: URL(filePath: POSIXPath.join(worktreePath, "README")))
            await #expect(throws: GitError.self) {
                try await removeWorktree(repo.path, worktreePath)
            }
            try await removeWorktree(repo.path, worktreePath, true)
            #expect(!FileManager.default.fileExists(atPath: worktreePath))
        }
    }
}
