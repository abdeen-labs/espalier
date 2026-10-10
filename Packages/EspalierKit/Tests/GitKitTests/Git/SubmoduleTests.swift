// Ported from desktop/app/test/unit/git/submodule-test.ts

import EspalierSupport
import Foundation
import GitKit
import Synchronization
import Testing
import TestSupport

private func featureBranch(_ submoduleRepository: Repository) async throws -> Branch {
    let branches = try await getBranches(submoduleRepository, "refs/remotes/origin/feature-branch")

    guard let branch = branches.first else {
        throw TestSupportError("Could not find branch: feature-branch")
    }
    return branch
}

@Suite("git/submodule")
struct SubmoduleTests {
    @Suite("listSubmodules")
    struct ListSubmodules {
        @Test("returns the submodule entry")
        func entry() async throws {
            let testRepoPath = try setupFixtureRepository("submodule-basic-setup")
            let repository = Repository(path: testRepoPath)
            let result = try await listSubmodules(repository)
            #expect(result.count == 1)
            #expect(result[0].sha == "c59617b65080863c4ca72c1f191fa1b423b92223")
            #expect(result[0].path == "foo/submodule")
            #expect(result[0].describe == "first-tag~2")
        }

        @Test("returns the expected tag")
        func expectedTag() async throws {
            let testRepoPath = try setupFixtureRepository("submodule-basic-setup")
            let repository = Repository(path: testRepoPath)

            let submodulePath = POSIXPath.join(testRepoPath, "foo", "submodule")
            let submoduleRepository = Repository(path: submodulePath)

            try await checkoutBranch(submoduleRepository, try await featureBranch(submoduleRepository), nil)

            let result = try await listSubmodules(repository)
            #expect(result.count == 1)
            #expect(result[0].sha == "14425bb2a4ee361af7f789a81b971f8466ae521d")
            #expect(result[0].path == "foo/submodule")
            #expect(result[0].describe == "heads/feature-branch")
        }

        @Test("lists a submodule whose folder is gone, without a describe (desktop skipped it)")
        func missingFolder() async throws {
            let testRepoPath = try setupFixtureRepository("submodule-basic-setup")
            let repository = Repository(path: testRepoPath)
            try FileManager.default.removeItem(atPath: POSIXPath.join(testRepoPath, "foo", "submodule"))

            let result = try await listSubmodules(repository)
            #expect(result == [SubmoduleEntry(sha: "c59617b65080863c4ca72c1f191fa1b423b92223", path: "foo/submodule", describe: "")])
        }
    }

    @Suite("resetSubmodulePaths")
    struct ResetSubmodulePaths {
        @Test("update submodule to original commit")
        func updatesToOriginalCommit() async throws {
            let testRepoPath = try setupFixtureRepository("submodule-basic-setup")
            let repository = Repository(path: testRepoPath)

            let submodulePath = POSIXPath.join(testRepoPath, "foo", "submodule")
            let submoduleRepository = Repository(path: submodulePath)

            try await checkoutBranch(submoduleRepository, try await featureBranch(submoduleRepository), nil)

            var result = try await listSubmodules(repository)
            #expect(result[0].describe == "heads/feature-branch")

            try await resetSubmodulePaths(repository, ["foo/submodule"])

            result = try await listSubmodules(repository)
            #expect(result[0].describe == "first-tag~2")
        }

        @Test("eliminate submodule dirty state")
        func eliminatesDirtyState() async throws {
            let testRepoPath = try setupFixtureRepository("submodule-basic-setup")
            let repository = Repository(path: testRepoPath)

            let submodulePath = POSIXPath.join(testRepoPath, "foo", "submodule")

            let filePath = POSIXPath.join(submodulePath, "README.md")
            try Data("changed".utf8).write(to: URL(filePath: filePath))

            try await resetSubmodulePaths(repository, ["foo/submodule"])

            let result = try String(contentsOfFile: filePath, encoding: .utf8)
            #expect(result == "# submodule-test-case")
        }
    }

    // MARK: - Espalier

    @Suite("listSubmodules without submodules")
    struct NoSubmodules {
        @Test("returns nothing for a repository without submodules")
        func noSubmodules() async throws {
            let repository = try setupEmptyRepository()
            try await makeCommit(repository, Tree(entries: [TreeEntry(path: "README.md", contents: "hi")]))
            #expect(try await listSubmodules(repository).isEmpty)
        }

        @Test("looks for modules in a linked worktree's common directory")
        func linkedWorktree() async throws {
            let submodule = try await setupTwoCommitRepo()
            let repository = try await setupTwoCommitRepo()
            _ = try await Dugite.exec(
                ["-c", "protocol.file.allow=always", "submodule", "add", submodule.path, "test-submodule"],
                repository.path
            )
            _ = try await Dugite.exec(["commit", "-m", "Add submodule"], repository.path)

            let worktreePath = try createTempDirectory() + "/linked"
            _ = try await Dugite.exec(["worktree", "add", "--detach", worktreePath], repository.path)
            _ = try await Dugite.exec(
                ["-c", "protocol.file.allow=always", "submodule", "update", "--init"],
                worktreePath
            )
            // Without .gitmodules in the working tree (git reads the index's
            // copy) and with `.git` a file, only the common directory's
            // modules show that there are submodules.
            try FileManager.default.removeItem(atPath: POSIXPath.join(worktreePath, ".gitmodules"))
            let gitDir = JSCompat.trim(String(
                decoding: try await Dugite.exec(["rev-parse", "--absolute-git-dir"], worktreePath).stdout,
                as: UTF8.self
            ))
            let linked = Repository(path: worktreePath, gitDir: gitDir)

            let result = try await listSubmodules(linked)
            #expect(result.map(\.path) == ["test-submodule"])

            // Without the git directory, the common directory can't be found.
            #expect(try await listSubmodules(Repository(path: worktreePath)).isEmpty)
        }
    }

    @Suite("updateSubmodulesAfterOperation")
    struct UpdateSubmodules {
        @Test("initializes submodules and reports progress")
        func initializes() async throws {
            let repository = try await setupRepositoryWithUninitializedSubmodule()
            _ = try await Dugite.exec(["checkout", "branch-with-submodule"], repository.path)

            let progress = Mutex<[CheckoutProgress]>([])
            try await updateSubmodulesAfterOperation(
                repository,
                nil,
                { event in progress.withLock { $0.append(event) } },
                CheckoutProgress.self,
                "Checking out branch branch-with-submodule",
                "branch-with-submodule",
                true
            )

            let events = progress.withLock { $0 }
            #expect(events.first == CheckoutProgress(
                value: 0,
                title: "Checking out branch branch-with-submodule",
                description: "Updating submodules",
                target: "branch-with-submodule"
            ))
            #expect(events.last == CheckoutProgress(
                value: 1,
                title: "Checking out branch branch-with-submodule",
                description: "Submodules updated",
                target: "branch-with-submodule"
            ))
            #expect(events.dropFirst().dropLast().allSatisfy {
                $0.description.hasPrefix("Updating submodules: ") && $0.value > 0 && $0.value < 1
            })
            #expect(FileManager.default.fileExists(
                atPath: POSIXPath.join(repository.path, "test-submodule", "good-file")
            ))
        }

        @Test("refuses local submodules unless allowed")
        func fileProtocol() async throws {
            let repository = try await setupRepositoryWithUninitializedSubmodule()
            _ = try await Dugite.exec(["checkout", "branch-with-submodule"], repository.path)

            await #expect(throws: GitError.self) {
                try await updateSubmodulesAfterOperation(
                    repository, nil, nil, CheckoutProgress.self, "Checking out", "branch-with-submodule", false
                )
            }
        }
    }
}
