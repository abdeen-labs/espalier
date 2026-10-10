// Ported from desktop/app/test/unit/git/checkout-test.ts
//
// The tip comes from `loadTip` (TestSupport).

import EspalierSupport
import Foundation
import GitKit
import Synchronization
import Testing
import TestSupport

/// Collects progress events from any thread.
private final class ProgressLog: Sendable {
    private let events = Mutex<[CheckoutProgress]>([])

    var all: [CheckoutProgress] {
        events.withLock { $0 }
    }

    var callback: @Sendable (CheckoutProgress) -> Void {
        { [self] event in events.withLock { $0.append(event) } }
    }
}

private func write(_ repository: Repository, _ name: String, _ contents: String) throws {
    try Data(contents.utf8).write(to: URL(filePath: POSIXPath.join(repository.path, name)))
}

private func read(_ repository: Repository, _ name: String) throws -> String {
    try String(contentsOfFile: POSIXPath.join(repository.path, name), encoding: .utf8)
}

private func validBranch(_ repository: Repository) async throws -> Branch? {
    guard case .valid(let branch) = try await loadTip(repository) else {
        return nil
    }
    return branch
}

@Suite("git/checkout")
struct CheckoutTests {
    @Test("throws when invalid characters are used for branch name")
    func invalidCharacters() async throws {
        let repository = try setupEmptyRepository()

        let branch = Branch(
            name: "..",
            upstream: nil,
            tip: BranchTip(sha: ""),
            type: .local,
            ref: ""
        )

        let error = await #expect(throws: GitError.self) {
            try await checkoutBranch(repository, branch, nil)
        }
        #expect(error?.message.contains("fatal: invalid reference: ..\n") == true)
    }

    @Test("can checkout a valid branch name in an existing repository")
    func validBranchName() async throws {
        let path = try setupFixtureRepository("repo-with-many-refs")
        let repository = Repository(path: path)

        let branches = try await getBranches(repository, "refs/heads/commit-with-long-description")

        guard let branch = branches.first else {
            throw TestSupportError("Could not find branch: commit-with-long-description")
        }

        try await checkoutBranch(repository, branch, nil)

        let tip = try await loadTip(repository)

        #expect(tip.kind == .valid)

        let validBranch = try #require(try await validBranch(repository))
        #expect(validBranch.name == "commit-with-long-description")
    }

    @Test("can checkout a branch when it exists on multiple remotes")
    func multipleRemotes() async throws {
        let path = try setupFixtureRepository("checkout-test-cases")
        let repository = Repository(path: path)

        let expectedBranch = "first"
        let firstRemote = "first-remote"
        let secondRemote = "second-remote"

        let branches = try await getBranches(repository)
        let firstBranch = "\(firstRemote)/\(expectedBranch)"
        guard let firstRemoteBranch = branches.first(where: { $0.name == firstBranch }) else {
            throw TestSupportError("Could not find branch: '\(firstBranch)'")
        }

        let secondBranch = "\(secondRemote)/\(expectedBranch)"
        guard branches.contains(where: { $0.name == secondBranch }) else {
            throw TestSupportError("Could not find branch: '\(secondBranch)'")
        }

        try await checkoutBranch(repository, firstRemoteBranch, nil)

        let tip = try await loadTip(repository)

        #expect(tip.kind == .valid)

        let validBranch = try #require(try await validBranch(repository))
        #expect(validBranch.name == expectedBranch)
        #expect(validBranch.type == .local)
        #expect(validBranch.upstreamRemoteName == "first-remote")
    }

    @Test("will fail when an existing branch matches the remote branch")
    func existingBranchMatchesRemoteBranch() async throws {
        let path = try setupFixtureRepository("checkout-test-cases")
        let repository = Repository(path: path)

        let expectedBranch = "first"
        let firstRemote = "first-remote"

        let branches = try await getBranches(repository)
        let firstBranch = "\(firstRemote)/\(expectedBranch)"
        guard let remoteBranch = branches.first(where: { $0.name == firstBranch }) else {
            throw TestSupportError("Could not find branch: '\(firstBranch)'")
        }

        try await createBranch(repository, expectedBranch, nil)

        let error = await #expect(throws: GitError.self) {
            try await checkoutBranch(repository, remoteBranch, nil)
        }
        #expect(error?.message.contains("A branch with that name already exists.") == true)
    }

    @Suite("with submodules")
    struct WithSubmodules {
        @Test("updates a changed submodule reference")
        func updatesChangedSubmoduleReference() async throws {
            let path = try setupFixtureRepository("test-submodule-checkouts")
            let repository = Repository(path: path)

            // put the repository into a known good state
            _ = try await Dugite.exec(["checkout", "master", "-f", "--recurse-submodules"], path)

            let branches = try await getBranches(repository)
            guard let devBranch = branches.first(where: { $0.name == "dev" }) else {
                throw TestSupportError("Could not find branch: 'dev'")
            }

            try await checkoutBranch(repository, devBranch, nil)

            let status = try await getStatusOrThrow(repository)
            #expect(status.workingDirectory.files.count == 0)
        }

        @Test("initializes an uninitialized submodule when checking out a branch")
        func initializesUninitializedSubmodule() async throws {
            let repository = try await setupRepositoryWithUninitializedSubmodule()

            let branches = try await getBranches(repository)
            guard let branchWithSubmodule = branches.first(where: { $0.name != "master" }) else {
                throw TestSupportError("Could not find branch other than 'master'")
            }

            try await checkoutBranch(repository, branchWithSubmodule, nil, nil, allowFileProtocol: true)

            // Verify we're on the correct branch
            let statusOutput = try await Dugite.exec(["status"], repository.path)
            #expect(String(decoding: statusOutput.stdout, as: UTF8.self).contains("On branch \(branchWithSubmodule.name)"))

            // Verify the submodule is initialized and has the correct commits
            let submodulePath = POSIXPath.join(repository.path, "test-submodule")
            let submoduleGitPath = POSIXPath.join(submodulePath, ".git")

            // Check that submodule .git exists (either as file or directory)
            let submoduleGitExists = await pathExists(submoduleGitPath)
            #expect(submoduleGitExists == true, "Submodule .git should exist after checkout")

            // Verify submodule has two commits
            let submoduleLog = try await Dugite.exec(["log", "--oneline"], submodulePath)
            #expect(JSCompat.split(JSCompat.trim(String(decoding: submoduleLog.stdout, as: UTF8.self)), "\n").count == 2)
        }
    }

    // MARK: - Espalier

    @Suite("checkoutBranch")
    struct CheckoutBranch {
        @Test("refuses to overwrite local changes, and keeps them")
        func localChangesOverwritten() async throws {
            let repository = try setupEmptyRepository()
            try write(repository, "a", "1")
            try write(repository, "b", "2")
            try await git(["add", "a", "b"], repository.path, "add")
            try await git(["commit", "-m", "initial"], repository.path, "commit")
            try await createBranch(repository, "feature-branch", nil)
            try write(repository, "a", "3")
            try write(repository, "b", "4")
            try await git(["commit", "-am", "second"], repository.path, "commit")
            try write(repository, "a", "local change")

            let feature = try await getBranchOrError(repository, "feature-branch")
            let error = await #expect(throws: GitError.self) {
                try await checkoutBranch(repository, feature, nil)
            }

            #expect(error?.result.gitError == .localChangesOverwritten)
            #expect(error?.message == "Switching branches would overwrite changes in your working directory. Commit or stash them first.")
            #expect(parseFilesToBeOverwritten(error?.result.stderr ?? "") == ["a"])
            #expect(try read(repository, "a") == "local change")
            #expect(try await validBranch(repository)?.name == "master")
        }

        @Test("carries local changes that don't conflict to the other branch")
        func carriesLocalChanges() async throws {
            let repository = try await setupTwoCommitRepo()
            try await createBranch(repository, "other", nil)
            try write(repository, "good-file", "changed here")
            try write(repository, "untracked", "new")

            try await checkoutBranch(repository, try await getBranchOrError(repository, "other"), nil)

            #expect(try await validBranch(repository)?.name == "other")
            #expect(try read(repository, "good-file") == "changed here")
            #expect(try read(repository, "untracked") == "new")
        }

        @Test("checks out a branch named like a file, and never the file")
        func branchNamedLikeAFile() async throws {
            let repository = try await setupTwoCommitRepo()
            try write(repository, "good-file", "local change")

            // Not a branch: without `--`, git would check out the file and
            // throw the local change away.
            let notABranch = Branch(name: "good-file", upstream: nil, tip: BranchTip(sha: ""), type: .local, ref: "refs/heads/good-file")
            await #expect(throws: GitError.self) {
                try await checkoutBranch(repository, notABranch, nil)
            }
            #expect(try read(repository, "good-file") == "local change")
            #expect(try await validBranch(repository)?.name == "master")

            // A branch with a file's name.
            try await createBranch(repository, "great-file", nil)
            try await checkoutBranch(repository, try await getBranchOrError(repository, "great-file"), nil)
            #expect(try await validBranch(repository)?.name == "great-file")
            #expect(try read(repository, "good-file") == "local change")
        }

        @Test("reports progress from the start to the submodule update")
        func progress() async throws {
            let repository = try await setupTwoCommitRepo()
            try await createBranch(repository, "other", "HEAD~1", noTrack: false)
            let log = ProgressLog()

            try await checkoutBranch(repository, try await getBranchOrError(repository, "other"), nil, log.callback)

            let events = log.all
            let title = "Checking out branch other"
            #expect(events.first == CheckoutProgress(value: 0, title: title, description: "Switching to Branch", target: "other"))
            #expect(events.last == CheckoutProgress(value: 1, title: title, description: "Submodules updated", target: "other"))
            #expect(events.contains(CheckoutProgress(value: 0.9, title: title, description: "Updating submodules", target: "other")))
            #expect(events.allSatisfy { $0.title == title && $0.target == "other" && (0...1).contains($0.value) })
            #expect(zip(events, events.dropFirst()).allSatisfy { $0.value <= $1.value })
        }

        @Test("refuses to switch branches during a conflicted merge")
        func duringMerge() async throws {
            let repository = try await setupConflictedRepo()
            let conflicted = try read(repository, "foo")

            let error = await #expect(throws: GitError.self) {
                try await checkoutBranch(repository, try await getBranchOrError(repository, "master"), nil)
            }

            #expect(error?.message.contains("you need to resolve your current index first") == true)
            #expect(try await validBranch(repository)?.name == "other-branch")
            #expect(await pathExists(POSIXPath.join(repository.path, ".git", "MERGE_HEAD")))
            #expect(try read(repository, "foo") == conflicted)
        }

        @Test("checks out a branch with a non-ASCII name")
        func nonASCIIName() async throws {
            let repository = try await setupTwoCommitRepo()
            let name = "f\u{EB}ature-\u{1F331}"
            try await createBranch(repository, name, "HEAD~1", noTrack: false)

            try await checkoutBranch(repository, try await getBranchOrError(repository, name), nil)

            let branch = try #require(try await validBranch(repository))
            #expect(Array(branch.name.utf8) == Array(name.utf8))
            #expect(try read(repository, "good-file") == "wishes it was great")
        }
    }

    @Suite("checkoutCommit")
    struct CheckoutCommit {
        @Test("detaches HEAD at the commit and reports progress")
        func detaches() async throws {
            let repository = try await setupTwoCommitRepo()
            let first = try await getRefOrError(repository, "HEAD~1")
            let log = ProgressLog()

            try await checkoutCommit(repository, CommitOneLine(sha: first.sha, summary: first.summary), nil, log.callback)

            #expect(try await loadTip(repository) == .detached(currentSha: first.sha))
            #expect(try read(repository, "good-file") == "wishes it was great")

            let events = log.all
            let target = shortenSHA(first.sha)
            #expect(events.first == CheckoutProgress(value: 0, title: "Checking out commit", description: "Checking out commit", target: target))
            #expect(events.last == CheckoutProgress(value: 1, title: "Checking out commit", description: "Submodules updated", target: target))
        }

        @Test("refuses to overwrite local changes")
        func localChanges() async throws {
            let repository = try await setupTwoCommitRepo()
            let first = try await getRefOrError(repository, "HEAD~1")
            try write(repository, "good-file", "local change")

            let error = await #expect(throws: GitError.self) {
                try await checkoutCommit(repository, CommitOneLine(sha: first.sha, summary: first.summary), nil)
            }
            #expect(error?.result.gitError == .localChangesOverwritten)
            #expect(try read(repository, "good-file") == "local change")
            #expect(try await validBranch(repository)?.name == "master")
        }
    }

    @Suite("checkoutPaths")
    struct CheckoutPaths {
        @Test("restores the given paths from HEAD and leaves the others alone")
        func restoresPaths() async throws {
            let repository = try await setupTwoCommitRepo()
            try FileManager.default.removeItem(atPath: POSIXPath.join(repository.path, "good-file"))
            try write(repository, "great-file", "local change")

            try await checkoutPaths(repository, ["good-file"])

            #expect(try read(repository, "good-file") == "is great")
            #expect(try read(repository, "great-file") == "local change")
            let status = try await getStatusOrThrow(repository)
            #expect(status.workingDirectory.files.map(\.path) == ["great-file"])
        }
    }
}
