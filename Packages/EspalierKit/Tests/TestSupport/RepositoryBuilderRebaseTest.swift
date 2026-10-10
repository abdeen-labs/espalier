// Ported from desktop/app/test/helpers/repository-builder-rebase-test.ts

import GitKit

/// Creates a test repository to be used as the branch for testing rebase
/// behaviour with:
///  - two commits on `master`,
///  - one commit on `firstBranchName`, which is based on `master`
///  - one commit on `secondBranchName`, which is also based on `master`
public func createRebaseTestRepository(
    _ firstBranchName: String,
    _ secondBranchName: String
) async throws -> Repository {
    let repository = try setupEmptyRepository()

    // make two commits on `master` to setup the README

    let firstCommit = Tree(
        entries: [
            TreeEntry(path: "README.md", contents: "# HELLO WORLD! \n"),
        ],
        commitMessage: "First!"
    )

    try await makeCommit(repository, firstCommit)

    let secondCommit = Tree(
        entries: [
            TreeEntry(path: "THING.md", contents: "# HELLO WORLD! \nTHINGS GO HERE\n"),
            TreeEntry(path: "OTHER.md", contents: "# HELLO WORLD! \nTHINGS GO HERE\n"),
            TreeEntry(path: "THIRD.md", contents: "nothing goes here"),
        ],
        commitMessage: "Second!"
    )

    try await makeCommit(repository, secondCommit)

    try await createBranch(repository, firstBranchName, "HEAD")
    try await createBranch(repository, secondBranchName, "HEAD")

    try await switchTo(repository, firstBranchName)

    let baseBranchCommit = Tree(
        entries: [
            TreeEntry(path: "THING.md", contents: "# HELLO WORLD! \nTHINGS GO HERE\nBASE BRANCH UNDERWAY\n"),
            TreeEntry(path: "OTHER.md", contents: "# HELLO WORLD! \nTHINGS GO HERE\nALSO BASE BRANCH UNDERWAY\n"),
        ],
        commitMessage: "Base Branch!"
    )

    try await makeCommit(repository, baseBranchCommit)

    try await switchTo(repository, secondBranchName)

    let featureBranchCommit = Tree(
        entries: [
            TreeEntry(path: "THING.md", contents: "# HELLO WORLD! \nTHINGS GO HERE\nFEATURE BRANCH UNDERWAY\n"),
            TreeEntry(path: "OTHER.md", contents: "# HELLO WORLD! \nTHINGS GO HERE\nALSO FEATURE BRANCH UNDERWAY\n"),
        ],
        commitMessage: "Feature Branch!"
    )

    try await makeCommit(repository, featureBranchCommit)

    // put the repository back on the default branch

    try await switchTo(repository, "master")

    return repository
}
