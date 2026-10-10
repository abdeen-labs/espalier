// Ported from desktop/app/test/helpers/repositories.ts
//
// `setupFixtureRepository` is in Fixtures.swift.

import EspalierSupport
import Foundation
import GitKit

/// Initializes a new, empty, git repository at in a temporary location.
///
/// - Returns: the new local repository
public func setupEmptyRepository(_ defaultBranchName: String = "master") throws -> Repository {
    let repoPath = try createTempDirectory()
    let fileManager = FileManager.default

    for directory in [".git", ".git/objects", ".git/refs", ".git/refs/tags", ".git/refs/heads", ".git/info"] {
        try fileManager.createDirectory(atPath: POSIXPath.join(repoPath, directory), withIntermediateDirectories: false)
    }

    let headRef = "ref: refs/heads/\(defaultBranchName)\n"

    // `ignorecase` is false here, whatever the volume.
    let config = """
        [core]
        repositoryformatversion = 0
        filemode = true
        bare = false
        logallrefupdates = true
        ignorecase = false
        precomposeunicode = true

        """

    try Data(headRef.utf8).write(to: URL(filePath: POSIXPath.join(repoPath, ".git/HEAD")))
    try Data(config.utf8).write(to: URL(filePath: POSIXPath.join(repoPath, ".git/config")))
    try Data(DefaultGitDescription.utf8).write(to: URL(filePath: POSIXPath.join(repoPath, ".git/description")))

    return Repository(path: repoPath)
}

/// Initializes a new, empty, git repository at in a temporary location with
/// default branch of main.
///
/// - Returns: the new local repository
public func setupEmptyRepositoryDefaultMain() throws -> Repository {
    try setupEmptyRepository("main")
}

/// Initialize a new, empty folder that is incorrectly associated with a Git
/// repository. This should only be used to test error handling of the Git
/// interactions.
public func setupEmptyDirectory() throws -> Repository {
    let repoPath = try createTempDirectory()
    return Repository(path: repoPath)
}

/// Setup a repository and create a merge conflict
///
/// The current branch will be 'other-branch' and the merged branch will be
/// 'master' in your test harness.
///
/// The conflicted file will be 'foo'.
///
/// - Returns: the new local repository
public func setupConflictedRepo() async throws -> Repository {
    let repo = try setupEmptyRepository()

    let firstCommit = Tree(entries: [TreeEntry(path: "foo", contents: "")])

    try await makeCommit(repo, firstCommit)

    // create this branch starting from the first commit, but don't checkout it
    // because we want to create a divergent history
    _ = try await Dugite.exec(["branch", "other-branch"], repo.path)

    let secondCommit = Tree(entries: [TreeEntry(path: "foo", contents: "b1")])

    try await makeCommit(repo, secondCommit)

    try await switchTo(repo, "other-branch")

    let thirdCommit = Tree(entries: [TreeEntry(path: "foo", contents: "b2")])
    try await makeCommit(repo, thirdCommit)

    _ = try await Dugite.exec(["merge", "master"], repo.path)

    return repo
}

/// Setup a repository and create a merge conflict
///
/// The current branch will be 'other-branch' and the merged branch will be
/// 'master' in your test harness.
///
/// The conflicted file will be 'foo'. There will also be uncommitted changes
/// unrelated to the merge in 'perlin'.
///
/// - Returns: the new local repository
public func setupConflictedRepoWithUnrelatedCommittedChange() async throws -> Repository {
    let repo = try setupEmptyRepository()

    let firstCommit = Tree(entries: [
        TreeEntry(path: "foo", contents: ""),
        TreeEntry(path: "perlin", contents: "perlin"),
    ])

    try await makeCommit(repo, firstCommit)

    // create this branch starting from the first commit, but don't checkout it
    // because we want to create a divergent history
    _ = try await Dugite.exec(["branch", "other-branch"], repo.path)

    let secondCommit = Tree(entries: [TreeEntry(path: "foo", contents: "b1")])

    try await makeCommit(repo, secondCommit)

    try await switchTo(repo, "other-branch")

    let thirdCommit = Tree(entries: [TreeEntry(path: "foo", contents: "b2")])
    try await makeCommit(repo, thirdCommit)

    try Data("noise".utf8).write(to: URL(filePath: POSIXPath.join(repo.path, "perlin")))

    _ = try await Dugite.exec(["merge", "master"], repo.path)

    return repo
}

/// Setup a repository and create a merge conflict with multiple files
///
/// The current branch will be 'other-branch' and the merged branch will be
/// 'master' in your test harness.
///
/// The conflicted files will be 'foo', 'bar', and 'baz'.
///
/// - Returns: the new local repository
public func setupConflictedRepoWithMultipleFiles() async throws -> Repository {
    let repo = try setupEmptyRepository()

    let firstCommit = Tree(entries: [
        TreeEntry(path: "foo", contents: "b0"),
        TreeEntry(path: "bar", contents: "b0"),
    ])

    try await makeCommit(repo, firstCommit)

    // create this branch starting from the first commit, but don't checkout it
    // because we want to create a divergent history
    _ = try await Dugite.exec(["branch", "other-branch"], repo.path)

    let secondCommit = Tree(entries: [
        TreeEntry(path: "foo", contents: "b1"),
        TreeEntry(path: "bar", contents: nil),
        TreeEntry(path: "baz", contents: "b1"),
        TreeEntry(path: "cat", contents: "b1"),
    ])

    try await makeCommit(repo, secondCommit)

    try await switchTo(repo, "other-branch")

    let thirdCommit = Tree(entries: [
        TreeEntry(path: "foo", contents: "b2"),
        TreeEntry(path: "bar", contents: "b2"),
        TreeEntry(path: "baz", contents: "b2"),
        TreeEntry(path: "cat", contents: "b2"),
    ])

    try await makeCommit(repo, thirdCommit)

    try Data("touch".utf8).write(to: URL(filePath: POSIXPath.join(repo.path, "dog")))

    _ = try await Dugite.exec(["merge", "master"], repo.path)

    return repo
}

/// Setup a repo with a single commit
///
/// files are `great-file` and `good-file`, which are both added in the one commit
public func setupTwoCommitRepo() async throws -> Repository {
    let repo = try setupEmptyRepository()

    let firstCommit = Tree(entries: [
        TreeEntry(path: "good-file", contents: "wishes it was great"),
        TreeEntry(path: "great-file", contents: "wishes it was good"),
    ])
    let secondCommit = Tree(entries: [
        TreeEntry(path: "good-file", contents: "is great"),
        TreeEntry(path: "great-file", contents: "is good"),
    ])

    try await makeCommit(repo, firstCommit)
    try await makeCommit(repo, secondCommit)
    return repo
}

/// Sets up a local fork of the provided repository
/// and configures the origin remote to point to the
/// local "upstream" repository.
public func setupLocalForkOfRepository(_ upstream: Repository) async throws -> Repository {
    let path = try createTempDirectory()
    try await git(["clone", "--local", upstream.path, path], path, "clone")
    return Repository(path: path)
}

/// Setup a repository with an uninitialized submodule in a branch
///
/// The repository will have:
/// - Two commits on the main branch
/// - A branch named 'branch-with-submodule' with a submodule added
/// - The submodule is uninitialized (its .git/modules entry is removed)
///
/// This simulates a scenario where a submodule exists in a branch but
/// hasn't been initialized yet when checking out that branch.
///
/// - Returns: the new local repository
public func setupRepositoryWithUninitializedSubmodule() async throws -> Repository {
    let repo = try await setupTwoCommitRepo()

    // Create a submodule repository
    let submoduleRepo = try await setupTwoCommitRepo()

    // Create a new branch and add the submodule
    _ = try await Dugite.exec(["checkout", "-b", "branch-with-submodule"], repo.path)

    _ = try await Dugite.exec(
        [
            "-c",
            "protocol.file.allow=always",
            "submodule",
            "add",
            submoduleRepo.path,
            "test-submodule",
        ],
        repo.path
    )
    _ = try await Dugite.exec(["commit", "-m", "Add submodule"], repo.path)

    // Go back to main branch
    _ = try await Dugite.exec(["checkout", "master"], repo.path)

    // Remove the .git/modules directory for the submodule to make it uninitialized
    let fileManager = FileManager.default
    let modulesPath = POSIXPath.join(repo.path, ".git", "modules", "test-submodule")
    try? fileManager.removeItem(atPath: modulesPath)
    try? fileManager.removeItem(atPath: POSIXPath.join(repo.path, "test-submodule"))

    return repo
}
