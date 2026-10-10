// Ported from desktop/app/test/helpers/repository-builder-long-rebase-test.ts

import GitKit

/// Creates a test repository to be used as the branch for testing rebase
/// behaviour with:
///  - two commits on `master`,
///  - three commit on `firstBranchName`, which is based on `master`
///  - ten commits on `secondBranchName`, which is also based on `master`
public func createLongRebaseTestRepository(
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

    let firstBaseBranchCommit = Tree(
        entries: [
            TreeEntry(path: "THING.md", contents: "# HELLO WORLD! \nTHINGS GO HERE\nBASE BRANCH UNDERWAY\n"),
            TreeEntry(path: "OTHER.md", contents: "# HELLO WORLD! \nTHINGS GO HERE\nALSO BASE BRANCH UNDERWAY\n"),
        ],
        commitMessage: "Base Branch First Commit!"
    )
    try await makeCommit(repository, firstBaseBranchCommit)

    let secondBaseBranchCommit = Tree(
        entries: [
            TreeEntry(path: "THING.md", contents: "# HELLO WORLD! \nTHINGS GO HERE\nMAKING BRANCH CHANGES\n"),
            TreeEntry(path: "OTHER.md", contents: "# HELLO WORLD! \nTHINGS GO HERE\nMORE BASE BRANCH CHANGES HAPPENING\n"),
        ],
        commitMessage: "Base Branch Second Commit!"
    )
    try await makeCommit(repository, secondBaseBranchCommit)

    let thirdBaseBranchCommit = Tree(
        entries: [
            TreeEntry(path: "THING.md", contents: "# HELLO WORLD! \nWORDS IN HERE\nMAKING BRANCH CHANGES\n"),
            TreeEntry(path: "OTHER.md", contents: "# HELLO WORLD! \nALSO WORDS GO IN HERE\nMORE BASE BRANCH CHANGES HAPPENING\n"),
        ],
        commitMessage: "Base Branch Third Commit!"
    )
    try await makeCommit(repository, thirdBaseBranchCommit)

    try await switchTo(repository, secondBranchName)

    let firstFeatureBranchCommit = Tree(
        entries: [
            TreeEntry(path: "THING.md", contents: "# HELLO WORLD! \nTHINGS GO HERE\nFEATURE BRANCH UNDERWAY\n"),
            TreeEntry(path: "OTHER.md", contents: "# HELLO WORLD! \nTHINGS GO HERE\nALSO FEATURE BRANCH UNDERWAY\n"),
        ],
        commitMessage: "Feature Branch First Commit!"
    )
    try await makeCommit(repository, firstFeatureBranchCommit)

    let secondFeatureBranchCommit = Tree(
        entries: [
            TreeEntry(path: "THING.md", contents: "# HELLO WORLD! \nTHINGS GO HERE\nALSO FEATURE BRANCH CHANGES\n"),
            TreeEntry(path: "OTHER.md", contents: "# HELLO WORLD! \nTHINGS GO HERE\nYES FEATURE BRANCH HERE TOO\n"),
        ],
        commitMessage: "Feature Branch Second Commit!"
    )
    try await makeCommit(repository, secondFeatureBranchCommit)

    let thirdFeatureBranchCommit = Tree(
        entries: [
            TreeEntry(path: "THING.md", contents: "# HELLO WORLD! \nCHAAAAANGE HERE\nALSO FEATURE BRANCH CHANGES\n"),
            TreeEntry(path: "OTHER.md", contents: "# HELLO WORLD! \nCHAAAAANGE GO HERE\nYES FEATURE BRANCH HERE TOO\n"),
        ],
        commitMessage: "Feature Branch Third Commit!"
    )
    try await makeCommit(repository, thirdFeatureBranchCommit)

    let fourthFeatureBranchCommit = Tree(
        entries: [
            TreeEntry(path: "THING.md", contents: "# HELLO WORLD! \nCHANGES GO HERE\nALSO FEATURE BRANCH CHANGES\n"),
            TreeEntry(path: "OTHER.md", contents: "# HELLO WORLD! \nCHANGE ALSO GO HERE TOO\nYES FEATURE BRANCH HERE TOO\n"),
        ],
        commitMessage: "Feature Branch Fourth Commit!"
    )
    try await makeCommit(repository, fourthFeatureBranchCommit)

    let fifthFeatureBranchCommit = Tree(
        entries: [
            TreeEntry(path: "THING.md", contents: "# SO LONG AND THANKS FOR THE FISH! \nTHINGS GO HERE\nALSO FEATURE BRANCH CHANGES\n"),
            TreeEntry(path: "OTHER.md", contents: "# IS IT FRIDAY YET? \nTHINGS GO HERE\nYES FEATURE BRANCH HERE TOO\n"),
        ],
        commitMessage: "Feature Branch Fifth Commit!"
    )
    try await makeCommit(repository, fifthFeatureBranchCommit)

    let sixthFeatureBranchCommit = Tree(
        entries: [
            TreeEntry(path: "THING.md", contents: "# HELLO WORLD! \nWORDS WORDS WORDS\nALSO FEATURE BRANCH CHANGES\n"),
            TreeEntry(path: "OTHER.md", contents: "# HELLO WORLD! WORDS WORDS WORDS\nYES FEATURE BRANCH HERE TOO\n"),
        ],
        commitMessage: "Feature Branch Sixth Commit!"
    )
    try await makeCommit(repository, sixthFeatureBranchCommit)

    let seventhFeatureBranchCommit = Tree(
        entries: [
            TreeEntry(path: "THING.md", contents: "# HELLO WORLD! \nTHINGS GO HERE\nWORDS WORDS WORDS\n"),
            TreeEntry(path: "OTHER.md", contents: "# HELLO WORLD! \nTHINGS GO HERE\nWORDS WORDS WORDS\n"),
        ],
        // The seventh commit repeats the third's summary.
        commitMessage: "Feature Branch Third Commit!"
    )
    try await makeCommit(repository, seventhFeatureBranchCommit)

    let eighthFeatureBranchCommit = Tree(
        entries: [
            TreeEntry(path: "THING.md", contents: "# WORDS WORDS WORDS! \nTHINGS GO HERE\nALSO FEATURE BRANCH CHANGES\n"),
            TreeEntry(path: "OTHER.md", contents: "# WORDS WORDS WORDS! \nTHINGS GO HERE\nYES FEATURE BRANCH HERE TOO\n"),
        ],
        commitMessage: "Feature Branch Eighth Commit!"
    )
    try await makeCommit(repository, eighthFeatureBranchCommit)

    let ninthFeatureBranchCommit = Tree(
        entries: [
            TreeEntry(path: "THING.md", contents: "# HELLO WORLD! \nTHINGS GO HERE\nARE WE THERE YET?\n"),
            TreeEntry(path: "OTHER.md", contents: "# HELLO WORLD! \nTHINGS GO HERE\nARE WE THERE YET?\n"),
        ],
        commitMessage: "Feature Branch Ninth Commit!"
    )
    try await makeCommit(repository, ninthFeatureBranchCommit)

    let tenthFeatureBranchCommit = Tree(
        entries: [
            TreeEntry(path: "THING.md", contents: "# HELLO WORLD! \nDOOT DOOT DOOT\nALSO FEATURE BRANCH CHANGES\n"),
            TreeEntry(path: "OTHER.md", contents: "# DOOT DOOT DOOT! \nTHINGS GO HERE\nYES FEATURE BRANCH HERE TOO\n"),
        ],
        commitMessage: "Feature Branch Tenth Commit!"
    )
    try await makeCommit(repository, tenthFeatureBranchCommit)

    // put the repository back on the default branch

    try await switchTo(repository, "master")

    return repository
}
