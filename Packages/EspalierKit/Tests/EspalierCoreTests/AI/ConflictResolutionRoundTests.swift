// AI conflict resolution rounds on real conflicts and a mock
// OpenAI-compatible provider: a round, its streamed progress, stopping,
// applying (with the user's choices kept and literal pathspecs),
// delete-vs-modify conflicts, retrying failed and unattempted files,
// failures, "always use AI", and a rebase's next round.

import AIKit
@testable import EspalierCore
import EspalierCoreTestSupport
import EspalierSupport
import Foundation
import GitHubKit
import GitKit
import Testing
import TestSupport

@Suite("Resolving conflicts with AI", .hangGuard(minutes: 5)) @MainActor
struct ConflictResolutionRoundTests {
    /// A repository where merging `feature` into `main` conflicts in
    /// `paths`, with a provider (and consents) for the mock, which resolves
    /// everything it's asked about. The merge isn't started.
    private func fixture(_ paths: [String] = ["a.txt", "b.txt"], defaults: [String: Any] = [:]) async throws -> AIFixture {
        let fixture = try await AIFixture.make(defaults: defaults) { repository in
            try await prepareConflictingBranches(repository, paths: paths)
        }
        try fixture.addProvider()
        fixture.server.answer { conflictResolutionReply(for: $0) }
        return fixture
    }

    private func shownResults(_ fixture: AIFixture) throws -> ConflictResolutionResults {
        guard case .resolved(let results) = fixture.ai.conflictResolution else {
            throw TestSupportError("Expected results, got \(fixture.ai.conflictResolution)")
        }
        return results
    }

    @Test("resolves a merge's conflicts, showing the model's resolutions and summary without writing anything")
    func resolvesMerge() async throws {
        let fixture = try await fixture()
        try await fixture.mergeWithConflicts("feature")
        #expect(fixture.ai.canResolveConflicts)

        try await fixture.ai.resolveConflicts()

        let results = try shownResults(fixture)
        #expect(results.operation == .merge)
        #expect(results.model == ConflictResolutionModelDisplay(modelName: "Model test-model", reasoningEffort: nil))
        #expect(results.resolutions.map(\.path) == ["a.txt", "b.txt"])
        #expect(results.resolution(forPath: "a.txt")?.resolvedContent == "first\nresolved a.txt 0\nlast\n")
        #expect(results.resolution(forPath: "a.txt")?.reasoning == "Combined both sides of a.txt.")
        #expect(results.summary.summaries.map(\.paths) == [["a.txt", "b.txt"]])
        #expect(results.summary.summaries.first?.markdown.contains("### Resolution") == true)
        #expect(results.summary.ourLabel == "main")
        #expect(results.summary.theirLabel == "feature")
        #expect(results.skippedFiles.isEmpty)
        #expect(results.failedFiles.isEmpty)
        #expect(results.notAttemptedFiles.isEmpty)
        #expect(fixture.ai.filesNeedingResolution.isEmpty)
        #expect(fixture.ai.resolutionChoice(forPath: "a.txt") == .model)
        // Nothing is written until the resolutions are applied.
        #expect(fixture.read("a.txt")?.contains("<<<<<<<") == true)

        let request = try #require(fixture.server.requests.first)
        #expect(fixture.server.requests.count == 1)
        #expect(request.isStreaming)
        #expect(request.userPrompt.hasPrefix(#"Merge conflict between "main" (ours) and "feature" (theirs)."#))
        #expect(request.userPrompt.contains("### Theirs (feature) commits:"))
        #expect(request.userPrompt.contains("Change on feature (#12)"))
        #expect(request.userPrompt.contains("### Ours (main) commits:"))
        #expect(request.systemPrompt.contains("You are an expert Git conflict resolver."))
    }

    @Test("sends the pull requests the commits mention: from the cache, else from GitHub with the repository's account", .offline)
    func pullRequestContext() async throws {
        let fixture = try await AIFixture.make(configure: { harness in
            try await harness.store(dotComAccount())
            harness.mockUser("octocat", id: 1)
        }) { repository in
            try await prepareConflictingBranches(repository, paths: ["a.txt"])
            try await commit(["main.txt": "more\n"], "Main work (#34)", in: repository)
        }
        try fixture.addProvider()
        fixture.server.answer { conflictResolutionReply(for: $0) }
        fixture.app.updateRecord(fixture.model.id) { $0.gitHubRepository = gitHubRepoFixture(owner: "octocat", name: "hello") }
        await fixture.settle()
        // Pull request 12 is in the cache of open pull requests.
        fixture.harness.gitHub.on("GET", "/repos/octocat/hello/pulls", respond: .json(encoding: [
            apiPullRequest(12, title: "Feature work", author: "octocat", body: "Adds the feature side."),
        ]))
        await fixture.model.gitHub.refreshPullRequests()
        #expect(fixture.model.gitHub.openPullRequests.map(\.pullRequestNumber) == [12])
        fixture.harness.gitHub.on("GET", "/repos/octocat/hello/pulls/34", respond: .json([
            "number": 34, "title": "Main work", "created_at": "2026-01-01T00:00:00Z", "updated_at": "2026-01-01T00:00:00Z",
            "user": .null, "body": "Changes main.", "state": "closed", "draft": false,
            "head": ["ref": "work", "sha": "abc", "repo": .null],
            "base": ["ref": "main", "sha": "def", "repo": .null],
        ]))
        try await fixture.mergeWithConflicts("feature")

        try await fixture.ai.resolveConflicts()

        let prompt = try #require(fixture.server.requests.first).userPrompt
        #expect(prompt.contains("## Pull Request Context"))
        #expect(prompt.contains("PR #34: Main work"))
        #expect(prompt.contains("Changes main."))
        #expect(prompt.contains("PR #12: Feature work"))
        #expect(prompt.contains("Adds the feature side."))
        #expect(fixture.harness.gitHub.requests("GET", "/repos/octocat/hello/pulls/34").first?.header("Authorization") == "Bearer gho_octocat_token")
        #expect(fixture.harness.gitHub.requests("GET", "/repos/octocat/hello/pulls/12").isEmpty)
        await fixture.app.accounts.idle()
    }

    @Test("streams the model's reasoning while it works; Stop returns to the manual flow")
    func streamsAndStops() async throws {
        let fixture = try await fixture()
        try await fixture.mergeWithConflicts("feature")
        fixture.server.answer { _ in
            .streamThenHang(reasoning: ["Comparing the two versions of each file. ", "Both sides changed the middle line. "])
        }

        let round = Task { @MainActor in
            try await fixture.ai.resolveConflicts()
        }
        await until {
            if case .resolving(let running) = fixture.ai.conflictResolution {
                return running.reasoning.count == 2
            }
            return false
        }
        guard case .resolving(let running) = fixture.ai.conflictResolution else {
            Issue.record("Expected a running round")
            return
        }
        #expect(running.operation == .merge)
        #expect(running.phase == .analyzing)
        #expect(running.files == ["a.txt", "b.txt"])
        #expect(running.filesResolved == 0)
        #expect(running.filesTotal == 2)
        #expect(running.reasoning == ["Comparing the two versions of each file.", "Both sides changed the middle line."])
        #expect(!running.startedAutomatically)
        #expect(!fixture.ai.canResolveConflicts)

        // One round at a time.
        let second = await #expect(throws: OperationError.self) {
            try await fixture.ai.resolveConflicts()
        }
        #expect(second?.reason == .busy(.resolveConflicts))

        fixture.ai.stopResolvingConflicts()
        #expect(fixture.ai.conflictResolution == .idle)
        let result = await round.result
        #expect((result.failure as? OperationError)?.reason == .cancelled(.userCancelled))
        #expect(fixture.read("a.txt")?.contains("<<<<<<<") == true)
    }

    @Test("applying writes the resolutions and stages them; continuing finishes the merge")
    func appliesAndContinues() async throws {
        let fixture = try await fixture()
        try await fixture.mergeWithConflicts("feature")
        try await fixture.ai.resolveConflicts()

        let applied = try await fixture.ai.applyResolutions()

        #expect(applied.written == ["a.txt", "b.txt"])
        #expect(applied.sidesChosen.isEmpty)
        #expect(applied.notWritten.isEmpty)
        #expect(fixture.read("a.txt") == "first\nresolved a.txt 0\nlast\n")
        #expect(fixture.read("b.txt") == "first\nresolved b.txt 0\nlast\n")
        #expect(try await fixture.indexStages("a.txt") == [0])
        #expect(fixture.ai.conflictResolution == .idle)
        #expect(fixture.model.operations.unresolvedFiles.isEmpty)

        let outcome = try await fixture.model.operations.continueOperation()
        #expect(outcome == .merge(.merged(ours: "main", theirs: "feature")))
        await fixture.settle()
        #expect(fixture.model.operations.conflictState == nil)
        #expect(try await runGit(["show", "HEAD:a.txt"], fixture.local) == "first\nresolved a.txt 0\nlast\n")
        #expect(try await fixture.indexStages("b.txt") == [0])
    }

    @Test("diffs each file's choice against the file on disk: the model's resolution or a side")
    func resolutionDiffs() async throws {
        let fixture = try await fixture()
        try await fixture.mergeWithConflicts("feature")
        #expect(try await fixture.ai.resolutionDiff(forPath: "a.txt") == nil)
        try await fixture.ai.resolveConflicts()

        func text(_ diff: ResolutionDiff?) -> String {
            guard case .text(let text)? = diff?.diff else {
                return ""
            }
            return text.text
        }

        let model = try await fixture.ai.resolutionDiff(forPath: "a.txt")
        #expect(text(model).contains("+resolved a.txt 0"))
        #expect(text(model).contains("-<<<<<<< HEAD"))
        #expect(model?.newContents == "first\nresolved a.txt 0\nlast\n")

        fixture.ai.setResolutionChoice(.theirs, forPath: "a.txt")
        let theirs = try await fixture.ai.resolutionDiff(forPath: "a.txt")
        #expect(theirs?.newContents == "first\nfeature side\nlast\n")
        #expect(!text(theirs).contains("+resolved"))
    }

    @Test("applying keeps the sides the user chose, files they resolved, and files changed since")
    func keepsUserWork() async throws {
        let fixture = try await fixture(["a.txt", "b.txt", "c.txt", "d.txt"])
        try await fixture.mergeWithConflicts("feature")
        try await fixture.ai.resolveConflicts()

        fixture.ai.setResolutionChoice(.ours, forPath: "b.txt")
        #expect(fixture.ai.resolutionChoice(forPath: "b.txt") == .ours)
        try fixture.write("c.txt", "first\nresolved by hand\nlast\n")
        let partlyEdited = try #require(fixture.read("d.txt")).replacingOccurrences(of: "first\n", with: "first, edited\n")
        try fixture.write("d.txt", partlyEdited)
        await fixture.refresh()
        // The round's results are still for these conflicts.
        _ = try shownResults(fixture)

        let applied = try await fixture.ai.applyResolutions()

        #expect(applied.written == ["a.txt"])
        #expect(applied.notWritten == [
            .init(path: "b.txt", reason: .userChoseSide),
            .init(path: "c.txt", reason: .alreadyResolved),
            .init(path: "d.txt", reason: .changedSinceResolution),
        ])
        #expect(fixture.read("c.txt") == "first\nresolved by hand\nlast\n")
        #expect(fixture.read("d.txt") == partlyEdited)
        #expect(try await fixture.indexStages("a.txt") == [0])
        #expect(try await fixture.indexStages("d.txt") == [1, 2, 3])
        #expect(fixture.model.operations.unresolvedFiles.map(\.path) == ["d.txt"])
    }

    @Test("a delete-vs-modify conflict gets the model's keep or delete as the operation's choice")
    func deleteConflict() async throws {
        let fixture = try await AIFixture.make { repository in
            try await commit(["gone.txt": "base\n", "a.txt": "first\nshared\nlast\n"], "Initial commit", in: repository)
            try await runGit(["branch", "feature"], repository)
            try await commit(["gone.txt": "changed on main\n", "a.txt": "first\nmain side\nlast\n"], "Change on main", in: repository)
            try await runGit(["checkout", "-q", "feature"], repository)
            try await runGit(["rm", "-q", "gone.txt"], repository)
            try await commit(["a.txt": "first\nfeature side\nlast\n"], "Delete on feature", in: repository)
            try await runGit(["checkout", "-q", "main"], repository)
        }
        try fixture.addProvider()
        fixture.server.answer { conflictResolutionReply(for: $0, actions: ["gone.txt": "keep"]) }
        try await fixture.mergeWithConflicts("feature")

        try await fixture.ai.resolveConflicts()
        let request = try #require(fixture.server.requests.first)
        #expect(request.userPrompt.contains("## File: gone.txt (delete-vs-modify conflict)"))
        #expect(try shownResults(fixture).resolution(forPath: "gone.txt")?.deleteConflictAction == .keep)

        let applied = try await fixture.ai.applyResolutions()

        // Deleted by them; keep is ours, the side that kept it.
        #expect(applied.sidesChosen == ["gone.txt"])
        #expect(applied.written == ["a.txt"])
        #expect(fixture.model.operations.conflictState?.manualResolutions["gone.txt"] == .ours)
        #expect(fixture.ai.resolutionChoice(forPath: "gone.txt") == .ours)

        _ = try await fixture.model.operations.continueOperation()
        await fixture.settle()
        #expect(try await runGit(["show", "HEAD:gone.txt"], fixture.local) == "changed on main\n")
    }

    @Test(
        "stages the resolved paths literally, never other files a pathspec would match",
        arguments: [
            PatternPath("src/[id].ts", decoy: "src/i.ts"),
            PatternPath(":d.ts", decoy: "d.ts"),
            PatternPath(":!e.ts", decoy: "other.ts"),
        ]
    )
    func literalPathspecs(_ path: PatternPath) async throws {
        let fixture = try await AIFixture.make { repository in
            try await commit([path.decoy: "unrelated\n"], "Add an unrelated file", in: repository)
            try await prepareConflictingBranches(repository, paths: [path.name])
        }
        try fixture.addProvider()
        fixture.server.answer { conflictResolutionReply(for: $0) }
        try await fixture.mergeWithConflicts("feature")
        // A change of the user's that `git add -- <name>` would stage.
        try fixture.write(path.decoy, "unrelated, changed\n")
        await fixture.refresh()
        try await fixture.ai.resolveConflicts()

        let applied = try await fixture.ai.applyResolutions()

        #expect(applied.written == [path.name])
        #expect(try await runGit(["diff", "--cached", "--name-only", "-z"], fixture.local) == "\(path.name)\0")
        #expect(try await runGit(["diff", "--name-only", "-z"], fixture.local) == "\(path.decoy)\0")
    }

    @Test("retries the failed and unattempted files together, with the round's context restricted to them")
    func retriesFailedAndUnattemptedFiles() async throws {
        // 101 files: chunks of 15, five at a time. The chunk with file-000
        // fails with an error every request would get, so the last two
        // chunks aren't attempted.
        let paths = (0...100).map { String(format: "file-%03d.txt", $0) }
        let fixture = try await fixture(paths)
        fixture.server.answer { request in
            request.conflictFiles.contains { $0.path == "file-000.txt" } ? authenticationFailure : conflictResolutionReply(for: request)
        }
        try await fixture.mergeWithConflicts("feature")

        try await fixture.ai.resolveConflicts()

        let results = try shownResults(fixture)
        let failed = results.failedFiles.map(\.path)
        #expect(failed == Array(paths[0..<15]))
        #expect(results.failedFiles.first?.message == "Incorrect API key provided.")
        #expect(results.notAttemptedFiles == Array(paths[75...]))
        #expect(results.resolutions.count == 60)
        #expect(fixture.server.requests.count == 5)
        #expect(Set(fixture.ai.filesNeedingResolution) == Set(failed + results.notAttemptedFiles))

        fixture.server.answer { conflictResolutionReply(for: $0) }
        try await fixture.ai.retryFailedFiles()

        let retryRequests = Array(fixture.server.requests.dropFirst(5))
        let retried = retryRequests.flatMap { $0.conflictFiles.map(\.path) }
        #expect(retried.sorted() == (failed + results.notAttemptedFiles).sorted())
        let merged = try shownResults(fixture)
        #expect(merged.resolutions.count == 101)
        #expect(Set(merged.resolutions.map(\.path)) == Set(paths))
        #expect(merged.failedFiles.isEmpty)
        #expect(merged.notAttemptedFiles.isEmpty)
        // The retry's summaries follow the round's, together covering every
        // file.
        #expect(Array(merged.summary.summaries.prefix(results.summary.summaries.count)) == results.summary.summaries)
        #expect(merged.summary.summaries.flatMap(\.paths).sorted() == paths)
        #expect(fixture.ai.filesNeedingResolution.isEmpty)

        let applied = try await fixture.ai.applyResolutions()
        #expect(applied.written.count == 101)
        #expect(fixture.model.operations.unresolvedFiles.isEmpty)
    }

    @Test("a retry that fails again leaves every retried file failed, with the new error")
    func retryFailsAgain() async throws {
        let paths = (0...24).map { String(format: "file-%03d.txt", $0) }
        let fixture = try await fixture(paths)
        // 25 files: chunks of 20 and 5; the second fails (not every
        // request would fail, so nothing is left unattempted).
        fixture.server.answer { request in
            request.conflictFiles.contains { $0.path == "file-024.txt" } ? serverFailure : conflictResolutionReply(for: request)
        }
        try await fixture.mergeWithConflicts("feature")
        try await fixture.ai.resolveConflicts()
        #expect(try shownResults(fixture).failedFiles.map(\.path) == Array(paths[20...]))

        fixture.server.answer { _ in authenticationFailure }
        let error = await #expect(throws: OperationError.self) {
            try await fixture.ai.retryFailedFiles()
        }
        #expect(providerFailureMessage(error) == "Incorrect API key provided.")

        let results = try shownResults(fixture)
        #expect(results.retry == nil)
        #expect(results.resolutions.count == 20)
        #expect(results.failedFiles.map(\.path) == Array(paths[20...]))
        #expect(results.failedFiles.allSatisfy { $0.message == "Incorrect API key provided." })
    }

    @Test("a round that fails shows its error; going back to the manual flow clears it")
    func failedRound() async throws {
        let fixture = try await fixture()
        fixture.server.answer { _ in authenticationFailure }
        try await fixture.mergeWithConflicts("feature")

        let error = await #expect(throws: OperationError.self) {
            try await fixture.ai.resolveConflicts()
        }
        #expect(providerFailureMessage(error) == "Incorrect API key provided.")
        guard case .failed(let failure) = fixture.ai.conflictResolution else {
            Issue.record("Expected the failure, got \(fixture.ai.conflictResolution)")
            return
        }
        #expect(failure.error == error)
        #expect(failure.operation == .merge)

        fixture.ai.dismissConflictResolution()
        #expect(fixture.ai.conflictResolution == .idle)
    }

    @Test("asks for consent and a model first, and sends nothing without them")
    func gates() async throws {
        let fixture = try await AIFixture.make { repository in
            try await prepareConflictingBranches(repository, paths: ["a.txt"])
        }
        try await fixture.mergeWithConflicts("feature")

        let noProvider = await #expect(throws: OperationError.self) {
            try await fixture.ai.resolveConflicts()
        }
        #expect(noProvider?.reason == .ai(.noProvider))

        try fixture.addProvider(models: ["one", "two"], consent: false)
        let ambiguous = await #expect(throws: OperationError.self) {
            try await fixture.ai.resolveConflicts()
        }
        #expect(ambiguous?.reason == .ai(.modelSelectionRequired))

        fixture.app.ai.select(model: fixture.app.ai.availableModels[1].key, for: .conflictResolution)
        let consent = await #expect(throws: OperationError.self) {
            try await fixture.ai.resolveConflicts()
        }
        #expect(consent?.reason == .ai(.consentRequired(provider: "Test AI")))
        #expect(fixture.server.requests.isEmpty)
        #expect(fixture.ai.conflictResolution == .idle)
    }

    @Test("\"Always use AI when conflicts are detected\" starts a round by itself")
    func alwaysUseAI() async throws {
        let fixture = try await fixture(defaults: [PreferenceKey.alwaysUseAIForConflictResolution: true])
        try await fixture.mergeWithConflicts("feature")

        await fixture.ai.roundIdle()

        #expect(fixture.server.requests.count == 1)
        #expect(try shownResults(fixture).resolutions.count == 2)

        // Going back to the manual flow doesn't start another for the same
        // conflicts.
        fixture.ai.dismissConflictResolution()
        await fixture.refresh()
        await fixture.ai.roundIdle()
        #expect(fixture.server.requests.count == 1)
        #expect(fixture.ai.conflictResolution == .idle)
    }

    @Test("\"Always use AI\" counts as off while AI is off, and without consent the manual flow shows")
    func alwaysUseAIGates() async throws {
        let off = try await fixture(defaults: [
            PreferenceKey.alwaysUseAIForConflictResolution: true,
            PreferenceKey.aiFeaturesEnabled: false,
        ])
        try await off.mergeWithConflicts("feature")
        await off.ai.roundIdle()
        #expect(off.server.requests.isEmpty)
        #expect(off.ai.conflictResolution == .idle)
        #expect(!off.ai.canResolveConflicts)

        let noConsent = try await AIFixture.make(defaults: [PreferenceKey.alwaysUseAIForConflictResolution: true]) { repository in
            try await prepareConflictingBranches(repository, paths: ["a.txt"])
        }
        try noConsent.addProvider(consent: false)
        try await noConsent.mergeWithConflicts("feature")
        await noConsent.ai.roundIdle()
        #expect(noConsent.server.requests.isEmpty)
        #expect(noConsent.ai.conflictResolution == .idle)
        #expect(noConsent.ai.canResolveConflicts)
    }

    @Test("results are dropped when their conflicts go away")
    func dropsResultsWhenConflictsEnd() async throws {
        let fixture = try await fixture()
        try await fixture.mergeWithConflicts("feature")
        try await fixture.ai.resolveConflicts()
        _ = try shownResults(fixture)

        try await fixture.model.operations.abortOperation(confirmed: [.abortWithResolvedConflicts])
        await fixture.settle()

        #expect(fixture.model.operations.conflictState == nil)
        #expect(fixture.ai.conflictResolution == .idle)
        let error = await #expect(throws: OperationError.self) {
            try await fixture.ai.applyResolutions()
        }
        #expect(preconditionText(error) != nil)
    }

    @Test("turning AI off drops the results")
    func offSwitchDropsResults() async throws {
        let fixture = try await fixture()
        try await fixture.mergeWithConflicts("feature")
        try await fixture.ai.resolveConflicts()

        fixture.app.preferences.aiFeaturesEnabled = false
        await until { fixture.ai.conflictResolution == .idle }

        #expect(fixture.read("a.txt")?.contains("<<<<<<<") == true)
    }

    @Test("after resolving a rebase's conflicts with AI, its next round starts by itself")
    func rebaseNextRound() async throws {
        let fixture = try await AIFixture.make { repository in
            try await commit(["a.txt": "first\nshared\nlast\n"], "Initial commit", in: repository)
            try await runGit(["branch", "feature"], repository)
            try await commit(["a.txt": "first\nmain side\nlast\n"], "Change on main", in: repository)
            try await runGit(["checkout", "-q", "feature"], repository)
            try await commit(["a.txt": "first\nfeature one\nlast\n"], "First feature change", in: repository)
            try await commit(["a.txt": "first\nfeature two\nlast\n"], "Second feature change", in: repository)
        }
        try fixture.addProvider()
        fixture.server.answer { conflictResolutionReply(for: $0) }
        _ = try await fixture.model.operations.rebase(onto: fixture.branch("main"))
        await fixture.settle()
        #expect(fixture.model.operations.conflictState != nil)

        try await fixture.ai.resolveConflicts()
        let first = try #require(fixture.server.requests.first)
        #expect(first.userPrompt.hasPrefix(#"Merge conflict between "main" (ours) and "feature" (theirs)."#))
        try await fixture.ai.applyResolutions()
        _ = try await fixture.model.operations.continueOperation()
        await fixture.settle()
        #expect(fixture.model.operations.conflictState != nil)

        await fixture.ai.roundIdle()
        #expect(fixture.server.requests.count == 2)
        #expect(try shownResults(fixture).resolutions.map(\.path) == ["a.txt"])

        try await fixture.ai.applyResolutions()
        _ = try await fixture.model.operations.continueOperation()
        await fixture.settle()
        #expect(fixture.model.operations.conflictState == nil)
        #expect(fixture.read("a.txt") == "first\nresolved a.txt 0\nlast\n")
    }
}
