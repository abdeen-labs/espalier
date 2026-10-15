// Amending, undoing, and resetting (GitStoreChangesTests.swift has the
// first-commit cases): messages and co-authors restored, confirmations,
// the rewrite recorded for a force push, and the commits these may and may
// not touch.

@testable import EspalierCore
import EspalierCoreTestSupport
import EspalierSupport
import Foundation
import GitKit
import Testing
import TestSupport

@Suite("Amend, undo, and reset", .offline) @MainActor
struct AmendUndoResetTests {
    /// A selected repository whose `main` was pushed to `origin`, then got
    /// `count` local commits (local1.txt, local2.txt, ...).
    private func makeFixture(localCommits count: Int) async throws -> (ChangesFixture, [Commit]) {
        let (local, _) = try await setupRepositoryWithRemote()
        var commits: [Commit] = []
        for index in 1...max(count, 1) where count > 0 {
            try Data("local \(index)\n".utf8).write(to: URL(filePath: POSIXPath.join(local.path, "local\(index).txt")))
            try await runGit(["add", "local\(index).txt"], local)
            try await runGit(["commit", "-m", "Local \(index)", "-m", "Body \(index)."], local)
            commits.append(try await getTipOrError(local))
        }
        return (try await ChangesFixture.make(local), commits)
    }

    // MARK: Amending

    @Test("amending loads the tip's message, and the next commit replaces the tip and records the rewrite")
    func amend() async throws {
        let (fixture, commits) = try await makeFixture(localCommits: 1)
        let tip = commits[0]

        try await fixture.commit.startAmending()
        #expect(fixture.commit.amending == tip)
        // The body as git prints it (`%b`), trailing newline included.
        #expect(fixture.commit.draft == CommitDraft(summary: "Local 1", description: "Body 1.\n"))
        #expect(!fixture.commit.hasUnfinishedDraft)

        fixture.commit.draft.summary = "Local one"
        #expect(fixture.commit.hasUnfinishedDraft)
        let result = try await fixture.commit.commit()
        await fixture.settle()
        #expect(result.amended)
        #expect(try await fixture.lastMessage() == "Local one\n\nBody 1.\n")
        #expect(try await fixture.commitCount() == 2)
        #expect(fixture.commit.amending == nil)
        let upstream = JSCompat.trim(try await fixture.git(["rev-parse", "main@{upstream}"]))
        #expect(fixture.model.operations.rewrittenBranches == ["main": upstream])
    }

    @Test("amending a pushed commit asks first, unless the preference is off or HEAD is detached")
    func amendPushed() async throws {
        let (fixture, _) = try await makeFixture(localCommits: 0)

        let error = await #expect(throws: OperationError.self) { try await fixture.commit.startAmending() }
        let asked = try #require(confirmation(of: error))
        #expect(asked.kind == .rewritePublishedCommits)
        #expect(fixture.commit.amending == nil)

        try await fixture.commit.startAmending(confirmed: [.rewritePublishedCommits])
        #expect(fixture.commit.amending?.summary == "Initial commit")
        fixture.commit.stopAmending()

        fixture.app.preferences.confirmForcePush = false
        try await fixture.commit.startAmending()
        #expect(fixture.commit.amending != nil)
        fixture.commit.stopAmending()

        fixture.app.preferences.confirmForcePush = true
        try await fixture.git(["checkout", "-q", "--detach"])
        await fixture.refresh(.full)
        try await fixture.commit.startAmending()
        #expect(fixture.commit.amending != nil)
        await fixture.settle()
    }

    @Test("amending works on a detached HEAD: the commit replaces HEAD and no branch moves")
    func amendDetached() async throws {
        let (fixture, commits) = try await makeFixture(localCommits: 2)
        try await fixture.git(["checkout", "-q", "--detach", "HEAD~1"])
        await fixture.refresh(.full)
        let detached = commits[0]
        #expect(fixture.model.gitState.tip == .detached(currentSha: detached.sha))
        #expect(fixture.commit.canStartAmending)

        try await fixture.commit.startAmending()
        #expect(fixture.commit.amending == detached)
        #expect(fixture.commit.draft == CommitDraft(summary: "Local 1", description: "Body 1.\n"))
        fixture.commit.draft.summary = "Local one, detached"
        try fixture.write("local1.txt", "amended while detached\n")
        await fixture.refresh()

        let result = try await fixture.commit.commit()
        await fixture.settle()
        #expect(result.amended)
        #expect(fixture.model.gitState.tip == .detached(currentSha: result.sha))
        #expect(try await fixture.lastMessage() == "Local one, detached\n\nBody 1.\n")
        // The amended commit has the detached commit's parent, and main is
        // where it was.
        #expect(JSCompat.trim(try await fixture.git(["rev-parse", "HEAD^"])) == JSCompat.trim(try await fixture.git(["rev-parse", "\(detached.sha)^"])))
        #expect(JSCompat.trim(try await fixture.git(["rev-parse", "main"])) == commits[1].sha)
        #expect(JSCompat.trim(try await fixture.git(["show", "HEAD:local1.txt"])) == "amended while detached")
        #expect(fixture.commit.amending == nil)
        // No branch was rewritten, so nothing needs a force push.
        #expect(fixture.model.operations.rewrittenBranches.isEmpty)
    }

    @Test("amending can't start without a commit or while a rebase is in progress")
    func amendUnavailable() async throws {
        let empty = try await ChangesFixture.make(try setupEmptyRepository())
        #expect(!empty.commit.canStartAmending)
        await empty.settle()

        let (fixture, _) = try await makeFixture(localCommits: 1)
        #expect(fixture.commit.canStartAmending)
        try await fixture.git(["checkout", "-q", "-b", "other", "HEAD~1"])
        try fixture.write("local1.txt", "other\n")
        try await fixture.git(["add", "local1.txt"])
        try await fixture.git(["commit", "-q", "-m", "Other"])
        #expect(try await runGitAllowingFailure(["rebase", "main"], fixture.local) != 0)
        await fixture.refresh(.full)
        #expect(fixture.model.gitState.tip.sha != nil)
        guard case .rebase? = fixture.model.gitState.inProgress else {
            Issue.record("No rebase in progress")
            return
        }
        #expect(!fixture.commit.canStartAmending)
        try await fixture.git(["rebase", "--abort"])
        await fixture.refresh(.full)
        #expect(fixture.commit.canStartAmending)
        await fixture.settle()
    }

    @Test("amending sets an unfinished message aside, and it comes back when amending stops or commits")
    func amendSetsDraftAside() async throws {
        let (fixture, _) = try await makeFixture(localCommits: 1)
        fixture.commit.draft = CommitDraft(summary: "Half a thought", description: "More later.")

        try await fixture.commit.startAmending()
        #expect(fixture.commit.draft.summary == "Local 1")
        #expect(fixture.commit.hasUnfinishedDraft)
        fixture.commit.stopAmending()
        #expect(fixture.commit.draft == CommitDraft(summary: "Half a thought", description: "More later."))

        try await fixture.commit.startAmending()
        fixture.commit.draft.summary = "Local 1, amended"
        try fixture.write("local1.txt", "amended\n")
        await fixture.refresh()
        _ = try await fixture.commit.commit()
        await fixture.settle()
        #expect(try await fixture.lastMessage() == "Local 1, amended\n\nBody 1.\n")
        #expect(fixture.commit.draft == CommitDraft(summary: "Half a thought", description: "More later."))
        #expect(fixture.commit.amending == nil)
    }

    @Test("in GitHub repositories, co-author trailers move into the co-authors, reusing known usernames")
    func coAuthorsRestored() async throws {
        let (local, _) = try await setupRepositoryWithRemote()
        try Data("pair\n".utf8).write(to: URL(filePath: POSIXPath.join(local.path, "pair.txt")))
        try await runGit(["add", "pair.txt"], local)
        let message = "Pair up\n\nWorked on together.\n\nCo-Authored-By: Mona Lisa <mona@example.com>\nCo-authored-by: Hubot <hubot@example.com>\n"
        try await runGit(["commit", "-F", "-"], local, stdin: message)
        let fixture = try await ChangesFixture.make(local)
        fixture.app.updateRecord(fixture.model.id) { $0.gitHubRepository = ModelFixtures.gitHubRepository() }

        let mona = KnownAuthor(name: "Mona Lisa", email: "mona@example.com", username: "mona")
        fixture.commit.draft.coAuthors = [.known(mona)]
        try await fixture.commit.startAmending()
        #expect(fixture.commit.draft.summary == "Pair up")
        #expect(fixture.commit.draft.description == "Worked on together.")
        #expect(fixture.commit.draft.coAuthors == [
            .known(mona),
            .known(KnownAuthor(name: "Hubot", email: "hubot@example.com", username: nil)),
        ])
        #expect(fixture.commit.draft.showCoAuthoredBy)

        // Amending writes them back as trailers.
        _ = try await fixture.commit.commit()
        await fixture.settle()
        #expect(try await fixture.lastMessage() == "Pair up\n\nWorked on together.\n\nCo-Authored-By: Mona Lisa <mona@example.com>\nCo-Authored-By: Hubot <hubot@example.com>\n")
    }

    @Test("outside GitHub repositories the whole message comes back, trailers included")
    func coAuthorsNotRestoredOutsideGitHub() async throws {
        let (local, _) = try await setupRepositoryWithRemote()
        try Data("pair\n".utf8).write(to: URL(filePath: POSIXPath.join(local.path, "pair.txt")))
        try await runGit(["add", "pair.txt"], local)
        try await runGit(["commit", "-F", "-"], local, stdin: "Pair up\n\nCo-Authored-By: Mona Lisa <mona@example.com>\n")
        let fixture = try await ChangesFixture.make(local)
        let tip = try await getTipOrError(local)

        try await fixture.commit.undo(tip)
        #expect(fixture.commit.draft.summary == "Pair up")
        #expect(fixture.commit.draft.description == "Co-Authored-By: Mona Lisa <mona@example.com>\n")
        #expect(fixture.commit.draft.coAuthors.isEmpty)
        await fixture.settle()
    }

    @Test("a co-author trailer that isn't Name <email> stays in the message, and one without a space isn't doubled, through amend and Undo Commit")
    func coAuthorTrailersKept() async throws {
        let (local, _) = try await setupRepositoryWithRemote()
        try Data("pair\n".utf8).write(to: URL(filePath: POSIXPath.join(local.path, "pair.txt")))
        try await runGit(["add", "pair.txt"], local)
        let message = "Pair up\n\nWorked on together.\n\nCo-authored-by: bob@example.com\nCo-authored-by:Hubot <hubot@example.com>\n"
        try await runGit(["commit", "-F", "-"], local, stdin: message)
        let fixture = try await ChangesFixture.make(local)
        fixture.app.updateRecord(fixture.model.id) { $0.gitHubRepository = ModelFixtures.gitHubRepository() }
        let hubot = Author.known(KnownAuthor(name: "Hubot", email: "hubot@example.com", username: nil))
        let description = "Worked on together.\n\nCo-authored-by: bob@example.com"
        let committed = "Pair up\n\nWorked on together.\n\nCo-authored-by: bob@example.com\nCo-Authored-By: Hubot <hubot@example.com>\n"

        try await fixture.commit.startAmending()
        #expect(fixture.commit.draft.description == description)
        #expect(fixture.commit.draft.coAuthors == [hubot])
        _ = try await fixture.commit.commit()
        await fixture.settle()
        #expect(try await fixture.lastMessage() == committed)

        try await fixture.commit.undo(try await getTipOrError(local))
        await fixture.settle()
        #expect(fixture.commit.draft.summary == "Pair up")
        #expect(fixture.commit.draft.description == description)
        #expect(fixture.commit.draft.coAuthors == [hubot])
        _ = try await fixture.commit.commit()
        await fixture.settle()
        #expect(try await fixture.lastMessage() == committed)
    }

    // MARK: Undoing

    @Test("undoing keeps the commit's changes and restores its message")
    func undo() async throws {
        let (fixture, commits) = try await makeFixture(localCommits: 2)
        #expect(fixture.commit.undoableCommitSHA == commits[1].sha)

        try await fixture.commit.undo(commits[1])
        #expect(try await fixture.head() == commits[0].sha)
        #expect(fixture.paths == ["local2.txt"])
        #expect(fixture.read("local2.txt") == "local 2\n")
        #expect(fixture.commit.draft.summary == "Local 2")
        #expect(fixture.commit.draft.description == "Body 2.\n")
        // The restored message is unfinished work: undoing removed the commit.
        #expect(fixture.commit.hasUnfinishedDraft)
        await fixture.settle()
    }

    @Test("undoing asks first with changes per the preference, and always for a merge commit")
    func undoConfirmations() async throws {
        let (fixture, commits) = try await makeFixture(localCommits: 1)
        try fixture.write("README.md", "# Changed\n")
        await fixture.refresh()

        let error = await #expect(throws: OperationError.self) { try await fixture.commit.undo(commits[0]) }
        let asked = try #require(confirmation(of: error))
        #expect(asked.kind == .undoCommitWithChanges)
        #expect(try await fixture.head() == commits[0].sha)

        fixture.app.preferences.confirmUndoCommit = false
        try await fixture.commit.undo(commits[0])
        #expect(fixture.paths == ["local1.txt", "README.md"])
        await fixture.settle()

        // A merge commit, with a clean tree and the preference off.
        try await fixture.git(["stash", "push", "-u", "-q"])
        try await fixture.git(["checkout", "-q", "-b", "feature"])
        try fixture.write("feature.txt", "feature\n")
        try await fixture.git(["add", "feature.txt"])
        try await fixture.git(["commit", "-qm", "Feature"])
        try await fixture.git(["checkout", "-q", "main"])
        try fixture.write("main.txt", "main\n")
        try await fixture.git(["add", "main.txt"])
        try await fixture.git(["commit", "-qm", "Main"])
        try await fixture.git(["merge", "-q", "--no-ff", "--no-edit", "feature"])
        await fixture.refresh(.full)
        let merge = try await getTipOrError(fixture.local)
        #expect(merge.isMergeCommit)

        let mergeError = await #expect(throws: OperationError.self) { try await fixture.commit.undo(merge) }
        let mergeAsked = try #require(confirmation(of: mergeError))
        #expect(mergeAsked.details == .commit(sha: merge.sha, isMergeCommit: true))

        try await fixture.commit.undo(merge, confirmed: [.undoCommitWithChanges])
        #expect(try await fixture.head() == merge.parentSHAs[0])
        #expect(fixture.paths == ["feature.txt"])
        await fixture.settle()
    }

    @Test("undoing refuses a commit that isn't the tip, one that was pushed, and a first commit on a detached HEAD")
    func undoRefusals() async throws {
        let (fixture, commits) = try await makeFixture(localCommits: 2)

        let notTip = await #expect(throws: OperationError.self) { try await fixture.commit.undo(commits[0]) }
        #expect(preconditionText(notTip) != nil)

        try await fixture.git(["push", "-q", "origin", "main"])
        await fixture.refresh(.full)
        #expect(fixture.commit.undoableCommitSHA == nil)
        let pushed = await #expect(throws: OperationError.self) { try await fixture.commit.undo(commits[1]) }
        #expect(preconditionText(pushed) != nil)
        #expect(try await fixture.head() == commits[1].sha)

        let repository = try setupEmptyRepository()
        try Data("first\n".utf8).write(to: URL(filePath: POSIXPath.join(repository.path, "first.txt")))
        try await runGit(["add", "first.txt"], repository)
        try await runGit(["commit", "-m", "First"], repository)
        try await runGit(["checkout", "-q", "--detach"], repository)
        let detached = try await ChangesFixture.make(repository)
        let first = try await getTipOrError(repository)
        let error = await #expect(throws: OperationError.self) { try await detached.commit.undo(first) }
        #expect(preconditionText(error) != nil)
        #expect(try await detached.head() == first.sha)
        await fixture.settle()
        await detached.settle()
    }

    @Test("undoing refuses while a merge waits on conflicts, and a tagged commit isn't offered")
    func undoDuringConflicts() async throws {
        let fixture = try await ChangesFixture.make(try await setupConflictedRepo())
        let tip = try await getTipOrError(fixture.local)
        #expect(fixture.commit.undoableCommitSHA == nil)
        let error = await #expect(throws: OperationError.self) {
            try await fixture.commit.undo(tip, confirmed: [.undoCommitWithChanges])
        }
        #expect(preconditionText(error) != nil)
        #expect(try await fixture.gitStatus().mergeHeadFound)

        let (tagged, commits) = try await makeFixture(localCommits: 1)
        #expect(tagged.commit.undoableCommitSHA == commits[0].sha)
        try await tagged.git(["tag", "v1"])
        await tagged.refresh(.full)
        #expect(tagged.commit.undoableCommitSHA == nil)
        await fixture.settle()
        await tagged.settle()
    }

    @Test("undoing while amending stops amending first")
    func undoWhileAmending() async throws {
        let (fixture, commits) = try await makeFixture(localCommits: 1)
        fixture.commit.draft.summary = "Mine"
        try await fixture.commit.startAmending()
        try await fixture.commit.undo(commits[0])
        #expect(fixture.commit.amending == nil)
        #expect(fixture.commit.draft.summary == "Local 1")
        await fixture.settle()
    }

    // MARK: Resetting

    @Test("resetting keeps the changes of the commits it takes off the branch")
    func reset() async throws {
        let (fixture, commits) = try await makeFixture(localCommits: 2)
        let pushedTip = try #require(commits[0].parentSHAs.first)
        let pushed = try #require(try await getCommit(fixture.local, pushedTip))

        try await fixture.commit.reset(to: pushed)
        #expect(try await fixture.head() == pushed.sha)
        #expect(fixture.paths == ["local1.txt", "local2.txt"])
        #expect(fixture.read("local1.txt") == "local 1\n")
        // No message comes back for a reset.
        #expect(fixture.commit.draft == CommitDraft())
        await fixture.settle()
    }

    @Test("resetting asks first with changes, and refuses HEAD, other branches' commits, and pushed commits")
    func resetRefusals() async throws {
        // Initial and Pushed on origin; Local 1 and Local 2 only here.
        let (local, _) = try await setupRepositoryWithRemote()
        try Data("pushed\n".utf8).write(to: URL(filePath: POSIXPath.join(local.path, "pushed.txt")))
        try await runGit(["add", "pushed.txt"], local)
        try await runGit(["commit", "-m", "Pushed"], local)
        try await runGit(["push", "-q", "origin", "main"], local)
        let pushed = try await getTipOrError(local)
        var localCommits: [Commit] = []
        for index in 1...2 {
            try Data("local \(index)\n".utf8).write(to: URL(filePath: POSIXPath.join(local.path, "local\(index).txt")))
            try await runGit(["add", "local\(index).txt"], local)
            try await runGit(["commit", "-m", "Local \(index)"], local)
            localCommits.append(try await getTipOrError(local))
        }
        let initial = try #require(try await getCommit(local, "HEAD~3"))
        #expect(initial.summary == "Initial commit")
        let fixture = try await ChangesFixture.make(local)

        let atHead = await #expect(throws: OperationError.self) { try await fixture.commit.reset(to: localCommits[1]) }
        #expect(preconditionText(atHead) != nil)

        try fixture.write("README.md", "# Changed\n")
        await fixture.refresh()
        let dirty = await #expect(throws: OperationError.self) { try await fixture.commit.reset(to: localCommits[0]) }
        let asked = try #require(confirmation(of: dirty))
        #expect(asked.kind == .resetWithChanges)

        // A commit on another branch.
        try await fixture.git(["stash", "push", "-q"])
        try await fixture.git(["checkout", "-q", "-b", "other", initial.sha])
        try fixture.write("other.txt", "other\n")
        try await fixture.git(["add", "other.txt"])
        try await fixture.git(["commit", "-qm", "Other"])
        let other = try await getTipOrError(fixture.local)
        try await fixture.git(["checkout", "-q", "main"])
        await fixture.refresh(.full)
        let elsewhere = await #expect(throws: OperationError.self) {
            try await fixture.commit.reset(to: other, confirmed: [.resetWithChanges])
        }
        #expect(preconditionText(elsewhere) != nil)

        // Below the pushed commit: it would come off the branch.
        let belowPushed = await #expect(throws: OperationError.self) {
            try await fixture.commit.reset(to: initial, confirmed: [.resetWithChanges])
        }
        #expect(preconditionText(belowPushed) != nil)
        #expect(try await fixture.head() == localCommits[1].sha)

        // Up to the first pushed commit, included, only local commits come off.
        try await fixture.commit.reset(to: pushed, confirmed: [.resetWithChanges])
        #expect(try await fixture.head() == pushed.sha)
        #expect(fixture.paths == ["local1.txt", "local2.txt"])
        await fixture.settle()
    }
}

/// Runs git with standard input in `repository`, requiring success.
@discardableResult
private func runGit(_ args: [String], _ repository: Repository, stdin: String) async throws -> String {
    let result = try await git(args, repository.path, "test", options: GitExecutionOptions(stdin: stdin))
    return result.stdout
}
