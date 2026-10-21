// These drive `CommitModel.commit` against real git.

@testable import EspalierCore
import EspalierCoreTestSupport
import EspalierSupport
import Foundation
import GitKit
import Testing
import TestSupport

@Suite("Commit", .offline, .hangGuard(minutes: 5)) @MainActor
struct CommitOperationTests {
    /// A selected repository with one commit on `main` and a remote.
    private func makeRepository(
        responder: PromptCenter.Responder? = PromptResponder.failing(),
        git: GitRuntime? = nil
    ) async throws -> (AppHarness, AppModel, RepositoryModel, Repository) {
        let (local, _) = try await setupRepositoryWithRemote()
        let harness = try AppHarness(responder: responder, git: git)
        let app = await harness.loadedApp()
        let repository = try await harness.addAndSelect(local, to: app)
        return (harness, app, repository, local)
    }

    private func commitCount(_ local: Repository) async throws -> Int {
        Int(JSCompat.trim(try await runGit(["rev-list", "--count", "HEAD"], local))) ?? -1
    }

    /// The tip's message, exactly as stored.
    private func lastMessage(_ local: Repository) async throws -> String {
        let commit = try await runGit(["cat-file", "commit", "HEAD"], local)
        guard let headerEnd = commit.range(of: "\n\n") else {
            return ""
        }
        return String(commit[headerEnd.upperBound...])
    }

    @Test("commits the included files, then clears the summary and description but keeps co-authors")
    func commitsIncludedFiles() async throws {
        let (harness, app, repository, local) = try await makeRepository()
        try harness.write("a.txt", "a\n", in: local)
        try harness.write("b.txt", "b\n", in: local)
        await repository.refresh(.status, reason: .user)
        let b = try #require(repository.changes.workingDirectory.files.first { $0.path == "b.txt" })
        repository.changes.setIncluded([b.id], false)

        let mona = Author.known(KnownAuthor(name: "Mona", email: "mona@example.com", username: "mona"))
        repository.commit.draft = CommitDraft(summary: "Add a", description: "The first file.", coAuthors: [mona], showCoAuthoredBy: true, generatedByAI: true)
        let result = try await repository.commit.commit()

        #expect(result.amended == false)
        #expect(result.sha.count == 40)
        #expect(repository.gitState.tip.branch?.tip.sha == result.sha)
        #expect(try await lastMessage(local) == "Add a\n\nThe first file.\n")
        #expect(repository.changes.workingDirectory.files.map(\.path) == ["b.txt"])
        #expect(repository.commit.draft == CommitDraft(coAuthors: [mona], showCoAuthoredBy: true))
        #expect(repository.refreshScheduler.lastPassOptions?.contains(.clearPartialSelections) == true)
        await app.idle()
    }

    @Test("a single included file fills in the summary")
    func placeholderSummary() async throws {
        let (harness, app, repository, local) = try await makeRepository()

        try harness.write("new.txt", "new\n", in: local)
        await repository.refresh(.status, reason: .user)
        _ = try await repository.commit.commit()
        #expect(try await lastMessage(local) == "Create new.txt\n")

        try harness.write("README.md", "# Changed\n", in: local)
        await repository.refresh(.status, reason: .user)
        _ = try await repository.commit.commit()
        #expect(try await lastMessage(local) == "Update README.md\n")

        try FileManager.default.removeItem(atPath: local.path + "/new.txt")
        await repository.refresh(.status, reason: .user)
        _ = try await repository.commit.commit()
        #expect(try await lastMessage(local) == "Delete new.txt\n")
        await app.idle()
    }

    @Test("refuses when there's nothing to commit")
    func nothingToCommit() async throws {
        let (harness, app, repository, local) = try await makeRepository()

        repository.commit.draft.summary = "Nothing"
        let nothing = await #expect(throws: OperationError.self) { try await repository.commit.commit() }
        #expect(preconditionText(nothing) != nil)

        try harness.write("a.txt", "a\n", in: local)
        try harness.write("b.txt", "b\n", in: local)
        await repository.refresh(.status, reason: .user)
        repository.commit.draft.summary = ""
        let noSummary = await #expect(throws: OperationError.self) { try await repository.commit.commit() }
        #expect(preconditionText(noSummary) != nil)

        repository.commit.draft.summary = "Something"
        repository.changes.setIncludeAll(false)
        let noFiles = await #expect(throws: OperationError.self) { try await repository.commit.commit() }
        #expect(preconditionText(noFiles) != nil)
        #expect(try await commitCount(local) == 1)

        // Allowing an empty commit commits nothing, once.
        repository.commit.options.allowEmpty = true
        _ = try await repository.commit.commit()
        #expect(try await commitCount(local) == 2)
        #expect(repository.commit.options.allowEmpty == false)
        #expect(repository.changes.workingDirectory.files.count == 2)
        await app.idle()
    }

    @Test("asks before committing with co-authors who weren't found")
    func unknownCoAuthors() async throws {
        let (harness, app, repository, local) = try await makeRepository()
        try harness.write("a.txt", "a\n", in: local)
        await repository.refresh(.status, reason: .user)
        repository.commit.draft = CommitDraft(
            summary: "Add a",
            coAuthors: [.unknown(UnknownAuthor(username: "ghost", state: .error))],
            showCoAuthoredBy: true
        )
        let error = await #expect(throws: OperationError.self) { try await repository.commit.commit() }
        guard case .confirmationRequired(let confirmation)? = error?.reason else {
            Issue.record("Unexpected error \(String(describing: error))")
            return
        }
        #expect(confirmation.kind == .commitWithUnknownCoAuthors)
        #expect(confirmation.details == .authors(["ghost"]))
        #expect(try await commitCount(local) == 1)

        _ = try await repository.commit.commit(confirmed: [.commitWithUnknownCoAuthors])
        #expect(try await lastMessage(local) == "Add a\n")
        await app.idle()
    }

    @Test("adds co-author trailers in GitHub repositories")
    func coAuthorTrailers() async throws {
        let (harness, app, repository, local) = try await makeRepository()
        app.updateRecord(repository.id) { $0.gitHubRepository = ModelFixtures.gitHubRepository() }
        try harness.write("a.txt", "a\n", in: local)
        await repository.refresh(.status, reason: .user)
        repository.commit.draft = CommitDraft(
            summary: "Pair on a",
            coAuthors: [.known(KnownAuthor(name: "Mona", email: "mona@example.com", username: "mona"))],
            showCoAuthoredBy: true
        )
        _ = try await repository.commit.commit()
        #expect(try await lastMessage(local) == "Pair on a\n\nCo-Authored-By: Mona <mona@example.com>\n")
        await app.idle()
    }

    @Test("co-authors kept in the draft while the field is hidden are never committed or checked, and come back when it shows")
    func hiddenCoAuthors() async throws {
        let (harness, app, repository, local) = try await makeRepository()
        app.updateRecord(repository.id) { $0.gitHubRepository = ModelFixtures.gitHubRepository() }
        let mona = Author.known(KnownAuthor(name: "Mona", email: "mona@example.com", username: "mona"))
        let ghost = Author.unknown(UnknownAuthor(username: "ghost", state: .error))
        repository.commit.draft = CommitDraft(coAuthors: [mona, ghost], showCoAuthoredBy: true)

        // Hiding the field keeps them in the draft.
        repository.commit.draft.showCoAuthoredBy = false
        repository.commit.draft.summary = "Solo on a"
        try harness.write("a.txt", "a\n", in: local)
        await repository.refresh(.status, reason: .user)
        // No trailer, and no question about the unknown one.
        _ = try await repository.commit.commit()
        #expect(try await lastMessage(local) == "Solo on a\n")
        #expect(repository.commit.draft == CommitDraft(coAuthors: [mona, ghost], showCoAuthoredBy: false))

        // Showing the field again brings them back, and they count again.
        repository.commit.draft.showCoAuthoredBy = true
        repository.commit.draft.summary = "Pair on b"
        try harness.write("b.txt", "b\n", in: local)
        await repository.refresh(.status, reason: .user)
        let error = await #expect(throws: OperationError.self) { try await repository.commit.commit() }
        #expect(error?.reason == .confirmationRequired(.commitWithUnknownCoAuthors(["ghost"])))
        _ = try await repository.commit.commit(confirmed: [.commitWithUnknownCoAuthors])
        #expect(try await lastMessage(local) == "Pair on b\n\nCo-Authored-By: Mona <mona@example.com>\n")
        await app.idle()
    }

    @Test("signs off and skips hooks when asked")
    func options() async throws {
        let (harness, app, repository, local) = try await makeRepository()
        try writeScript(local.path + "/.git/hooks/pre-commit", "#!/bin/sh\nexit 1\n")
        try harness.write("a.txt", "a\n", in: local)
        await repository.refresh(.status, reason: .user)
        repository.commit.draft.summary = "Signed"
        repository.commit.options = CommitOptions(skipHooks: true, signOff: true)
        _ = try await repository.commit.commit()
        #expect(try await lastMessage(local) == "Signed\n\nSigned-off-by: Joe Bloggs <joe.bloggs@somewhere.com>\n")
        // Only allow-empty resets after a commit.
        #expect(repository.commit.options == CommitOptions(skipHooks: true, signOff: true))
        await app.idle()
    }

    @Test("a failure keeps the message and still refreshes")
    func failure() async throws {
        let (harness, app, repository, local) = try await makeRepository()
        try writeScript(local.path + "/.git/hooks/pre-commit", "#!/bin/sh\necho 'lint failed' >&2\nexit 1\n")
        try harness.write("a.txt", "a\n", in: local)
        await repository.refresh(.status, reason: .user)
        repository.commit.draft.summary = "Add a"
        let passes = repository.refreshScheduler.passCount

        let error = await #expect(throws: OperationError.self) { try await repository.commit.commit() }
        #expect(error?.gitContext == .commit)
        #expect(error?.message.contains("lint failed") == true)
        #expect(repository.commit.draft.summary == "Add a")
        await repository.idle()
        #expect(repository.refreshScheduler.passCount == passes + 1)
        #expect(repository.refreshScheduler.lastPassReasons == [.operation(.commit)])
        #expect(try await commitCount(local) == 1)
        await app.idle()
    }

    @Test("amending replaces the tip and records the branch as rewritten")
    func amend() async throws {
        let (harness, app, repository, local) = try await makeRepository()
        let tip = try #require(try await getCommit(local, "HEAD"))
        try harness.write("a.txt", "a\n", in: local)
        await repository.refresh(.status, reason: .user)
        repository.commit.setAmending(tip)
        repository.commit.draft.summary = "Initial commit, amended"

        let result = try await repository.commit.commit()
        #expect(result.amended)
        #expect(result.sha != tip.sha)
        #expect(repository.commit.amending == nil)
        #expect(try await commitCount(local) == 1)
        #expect(try await lastMessage(local) == "Initial commit, amended\n")
        // Recorded with the remote branch's tip: the commit amended.
        #expect(repository.operations.rewrittenBranches == ["main": tip.sha])
        await app.idle()
    }

    @Test("amend mode ends when the tip moves away from the commit being amended")
    func amendModeEnds() async throws {
        let (harness, app, repository, local) = try await makeRepository()
        let tip = try #require(try await getCommit(local, "HEAD"))
        repository.commit.setAmending(tip)
        try harness.write("a.txt", "a\n", in: local)
        try await runGit(["add", "a.txt"], local)
        try await runGit(["commit", "-m", "Made outside"], local)
        await repository.refresh(.status, reason: .user)
        #expect(repository.commit.amending == nil)
        await app.idle()
    }

    @Test("a commit while another local operation runs is busy")
    func busy() async throws {
        let (harness, app, repository, local) = try await makeRepository()
        try harness.write("a.txt", "a\n", in: local)
        await repository.refresh(.status, reason: .user)
        repository.commit.draft.summary = "Add a"

        let gate = AsyncGate()
        let other = Task {
            try await repository.perform(OperationDescriptor(kind: .commit)) { _ in
                await gate.wait()
            }
        }
        try await gate.waitUntilWaiting()
        let error = await #expect(throws: OperationError.self) { try await repository.commit.commit() }
        #expect(error?.reason == .busy(.commit))
        gate.open()
        try await other.value
        await app.idle()
    }

    @Test("Abort in a failing hook's prompt cancels the commit; Ignore lets it land")
    func hookFailurePrompt() async throws {
        try await withIsolatedGitConfig { _ in
            let server = TrampolineServer()
            let hookDefaults = try TemporaryDefaults()
            defer { hookDefaults.remove() }
            var runtime = GitRuntime.current
            runtime.hooks = HooksEnvironment(server: server, helperPath: askpassHelperPath, prompter: nil, defaults: hookDefaults.defaults)
            runtime.processEnvironment["SHELL"] = try makeLoginShell()

            let observations = HookObservations()
            let answers = [HookFailureResolution.abort, .ignore]
            let responder: PromptCenter.Responder = { prompt in
                observations.hooksAtPrompt.append(observations.repository?.localOperation?.hook)
                let answer = answers[min(observations.hooksAtPrompt.count - 1, answers.count - 1)]
                return .hookFailure(answer)
            }
            let (harness, app, repository, local) = try await makeRepository(responder: responder, git: runtime)
            observations.repository = repository
            try writeScript(local.path + "/.git/hooks/pre-commit", "#!/bin/sh\necho 'lint failed' >&2\nexit 1\n")
            try harness.write("a.txt", "a\n", in: local)
            await repository.refresh(.status, reason: .user)
            repository.commit.draft.summary = "Add a"

            let aborted = await #expect(throws: OperationError.self) { try await repository.commit.commit() }
            #expect(aborted?.reason == .cancelled(.hookAborted("pre-commit")))
            #expect(try await commitCount(local) == 1)
            #expect(repository.commit.draft.summary == "Add a")

            _ = try await repository.commit.commit()
            #expect(try await commitCount(local) == 2)

            #expect(harness.prompts.history.count == 2)
            for prompt in harness.prompts.history {
                guard case .hookFailed(let name, let output) = prompt else {
                    Issue.record("Unexpected prompt \(prompt)")
                    continue
                }
                #expect(name == "pre-commit")
                #expect(output.contains("lint failed"))
            }
            #expect(observations.hooksAtPrompt == [
                HookActivity(name: "pre-commit", status: .running),
                HookActivity(name: "pre-commit", status: .running),
            ])
            await app.idle()
            await server.stop()
        }
    }

    /// A stand-in for the user's login shell.
    private func makeLoginShell() throws -> String {
        let shell = POSIXPath.join(try createTempDirectory(), "shell")
        try writeScript(shell, """
            #!/bin/sh
            export PATH='/usr/bin:/bin'
            eval "$2"
            """)
        return shell
    }
}

@MainActor
private final class HookObservations {
    weak var repository: RepositoryModel?
    var hooksAtPrompt: [HookActivity?] = []
}
