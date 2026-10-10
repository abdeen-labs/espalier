// Ported from desktop/app/test/unit/git-store-test.ts
// The discard, discard renamed, undo first commit, and HEAD-file cases,
// driven through the models (LoadBranchesTests.swift has the loadBranches
// cases).

@testable import EspalierCore
import EspalierCoreTestSupport
import EspalierSupport
import Foundation
import GitKit
import Testing
import TestSupport

@Suite("GitStore (changes)", .offline) @MainActor
struct GitStoreChangesTests {
    private let everything: Set<ConfirmationKind> = [.discardChanges, .discardAllChanges]

    @Test("can discard changes from a repository")
    func discardChanges() async throws {
        let repo = try setupEmptyRepository()

        let readmeFile = "README.md"
        let readmeFilePath = POSIXPath.join(repo.path, readmeFile)
        try Data("SOME WORDS GO HERE\n".utf8).write(to: URL(filePath: readmeFilePath))

        let licenseFile = "LICENSE.md"
        let licenseFilePath = POSIXPath.join(repo.path, licenseFile)
        try Data("SOME WORDS GO HERE\n".utf8).write(to: URL(filePath: licenseFilePath))

        // commit the readme file but leave the license
        try await runGit(["add", readmeFile], repo)
        try await runGit(["commit", "-m", "added readme file"], repo)

        try Data("WRITING SOME NEW WORDS\n".utf8).write(to: URL(filePath: readmeFilePath))
        // setup requires knowing about the current tip
        let fixture = try await ChangesFixture.make(repo)

        var status = try await getStatusOrThrow(repo)
        var files = status.workingDirectory.files

        #expect(files.count == 2)
        #expect(files[0].path == "README.md")
        #expect(files[0].status.kind == .modified)

        // discard the LICENSE.md file
        try await fixture.changes.discard([files[1]], confirmed: everything)

        status = try await getStatusOrThrow(repo)
        files = status.workingDirectory.files

        #expect(files.count == 1)
        #expect(fixture.harness.trash.trashedPaths == [licenseFilePath])
        await fixture.settle()
    }

    @Test("can discard a renamed file")
    func discardRenamed() async throws {
        let repo = try setupEmptyRepository()

        let file = "README.md"
        let renamedFile = "NEW-README.md"
        let filePath = POSIXPath.join(repo.path, file)

        try Data("SOME WORDS GO HERE\n".utf8).write(to: URL(filePath: filePath))

        // commit the file, and then rename it
        try await runGit(["add", file], repo)
        try await runGit(["commit", "-m", "added file"], repo)
        try await runGit(["mv", file, renamedFile], repo)

        let statusBeforeDiscard = try await getStatusOrThrow(repo)
        let filesToDiscard = statusBeforeDiscard.workingDirectory.files
        let fixture = try await ChangesFixture.make(repo)

        // discard the renamed file
        try await fixture.changes.discard(filesToDiscard, confirmed: everything)

        let status = try await getStatusOrThrow(repo)
        let files = status.workingDirectory.files

        #expect(files.count == 0)
        #expect(fixture.read(file) == "SOME WORDS GO HERE\n")
        #expect(!fixture.exists(renamedFile))
        await fixture.settle()
    }

    // MARK: undo first commit

    private let commitMessage = "added file"

    private func setupRepo() async throws -> (repository: Repository, firstCommit: Commit) {
        let repository = try setupEmptyRepository()

        let file = "README.md"
        let filePath = POSIXPath.join(repository.path, file)

        try Data("SOME WORDS GO HERE\n".utf8).write(to: URL(filePath: filePath))

        try await runGit(["add", file], repository)
        try await runGit(["commit", "-m", commitMessage], repository)

        let firstCommit = try #require(try await getCommit(repository, "master"))
        #expect(firstCommit.parentSHAs.count == 0)

        return (repository, firstCommit)
    }

    @Test("reports the repository is unborn")
    func undoFirstCommitUnborn() async throws {
        let (repository, firstCommit) = try await setupRepo()
        let fixture = try await ChangesFixture.make(repository)
        #expect(fixture.model.gitState.tip.isValidBranch)

        try await fixture.commit.undo(firstCommit)

        let after = try await getStatusOrThrow(repository)
        #expect(after.currentTip == nil)
        await fixture.settle()
    }

    @Test("pre-fills the commit message")
    func undoFirstCommitMessage() async throws {
        let (repository, firstCommit) = try await setupRepo()
        let fixture = try await ChangesFixture.make(repository)

        try await fixture.commit.undo(firstCommit)

        #expect(fixture.commit.draft.summary == commitMessage)
        await fixture.settle()
    }

    @Test("clears the undo commit dialog")
    func undoFirstCommitClearsLocalCommits() async throws {
        let (repository, firstCommit) = try await setupRepo()
        let fixture = try await ChangesFixture.make(repository)

        #expect(fixture.model.gitState.localCommitSHAs.count == 1)
        #expect(fixture.commit.undoableCommitSHA == firstCommit.sha)

        try await fixture.commit.undo(firstCommit)
        await fixture.refresh(.full)

        guard case .unborn = fixture.model.gitState.tip else {
            Issue.record("Expected an unborn tip, got \(fixture.model.gitState.tip)")
            return
        }
        #expect(fixture.model.gitState.localCommitSHAs.count == 0)
        #expect(fixture.commit.undoableCommitSHA == nil)
    }

    @Test("has no staged files")
    func undoFirstCommitNoStagedFiles() async throws {
        let (repository, firstCommit) = try await setupRepo()
        let fixture = try await ChangesFixture.make(repository)

        #expect(fixture.model.gitState.localCommitSHAs.count == 1)

        try await fixture.commit.undo(firstCommit)

        // compare the index state to some other tree-ish
        // 4b825dc642cb6eb9a060e54bf8d69288fbee4904 is the magic empty tree
        // if nothing is staged, this should return no entries
        let result = try await runGit(
            ["diff-index", "--name-status", "-z", "4b825dc642cb6eb9a060e54bf8d69288fbee4904"],
            repository
        )
        #expect(result.isEmpty)
        #expect(fixture.paths == ["README.md"])
        #expect(try fixture.file("README.md").status.kind == .untracked)
        await fixture.settle()
    }

    // MARK: repository with HEAD file

    @Test("can discard modified change cleanly")
    func discardWithHEADFile() async throws {
        let path = try setupFixtureRepository("repository-with-HEAD-file")
        let repo = Repository(path: path)
        let fixture = try await ChangesFixture.make(repo)

        let file = "README.md"
        let filePath = POSIXPath.join(repo.path, file)

        try Data("SOME WORDS GO HERE\n".utf8).write(to: URL(filePath: filePath))

        var status = try await getStatusOrThrow(repo)
        var files = status.workingDirectory.files
        #expect(files.count == 1)

        try await fixture.changes.discard([files[0]], confirmed: everything)

        status = try await getStatusOrThrow(repo)
        files = status.workingDirectory.files
        #expect(files.count == 0)
        await fixture.settle()
    }
}
