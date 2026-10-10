// Ported from desktop/app/test/helpers/repository-builder-pull-test.ts

import GitKit

/// Creates a test repository with two commits on `master`, and then
/// two commits on `branchName` to be used as the branch for testing pull
/// behaviour
///
/// - Parameter branchName: name to use for new branch
public func createRepository(_ branchName: String) async throws -> Repository {
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
        ],
        commitMessage: "Second!"
    )

    try await makeCommit(repository, secondCommit)

    try await switchTo(repository, branchName)

    let firstCommitToBranch = Tree(
        entries: [
            TreeEntry(path: "CONTRIBUTING.md", contents: ""),
        ],
        commitMessage: "Added a new file"
    )

    try await makeCommit(repository, firstCommitToBranch)

    let secondCommitToBranch = Tree(
        entries: [
            TreeEntry(path: "README.md", contents: "things go here"),
        ],
        commitMessage: "Updated README"
    )

    try await makeCommit(repository, secondCommitToBranch)

    return repository
}
