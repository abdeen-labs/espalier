// Ported from desktop/app/test/helpers/repository-builder-cherry-pick-test.ts

import GitKit

/// Creates a test repository to be used for testing cherry pick behaviour with:
///  - one commit on default branch,
///  - one commit on `featureBranchName` to cherry pick
///  - creates `targetBranchName` off of default branch
public func createCherryPickTestRepository(
    _ featureBranchName: String,
    _ targetBranchName: String
) async throws -> Repository {
    let repository = try setupEmptyRepositoryDefaultMain()

    let firstCommit = Tree(
        entries: [
            TreeEntry(path: "README.md", contents: "# HELLO WORLD! \n"),
        ],
        commitMessage: "First!"
    )
    try await makeCommit(repository, firstCommit)

    try await createBranch(repository, featureBranchName, "HEAD")
    try await createBranch(repository, targetBranchName, "HEAD")

    try await switchTo(repository, featureBranchName)
    let featureBranchCommit = Tree(
        entries: [
            TreeEntry(path: "THING.md", contents: "# HELLO WORLD! \nTHINGS GO HERE\n"),
        ],
        commitMessage: "Cherry-picked Feature!"
    )
    try await makeCommit(repository, featureBranchCommit)

    try await switchTo(repository, targetBranchName)
    return repository
}
