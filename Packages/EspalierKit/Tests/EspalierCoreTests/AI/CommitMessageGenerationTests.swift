// Generating a commit message into the draft against a mock
// OpenAI-compatible provider: consent before the first request, the diff of
// the included files only (made with a temporary index), the override
// confirmation, cancellation, the AI off switch, model choice, rules and
// instructions, amending, and failures.

import AIKit
@testable import EspalierCore
import EspalierCoreTestSupport
import EspalierSupport
import Foundation
import GitHubKit
import GitKit
import Testing
import TestSupport

@Suite("Generating commit messages", .hangGuard(minutes: 5)) @MainActor
struct CommitMessageGenerationTests {
    /// A repository with one commit and two changed files, `included.txt`
    /// (included in the commit) and `excluded.txt` (excluded).
    private func fixture(defaults: [String: Any] = [:]) async throws -> AIFixture {
        let fixture = try await AIFixture.make(defaults: defaults) { repository in
            try await commit(["included.txt": "one\n", "excluded.txt": "one\n"], "Initial commit", in: repository)
        }
        try fixture.write("included.txt", "one\ntwo included\n")
        try fixture.write("excluded.txt", "one\ntwo excluded\n")
        await fixture.refresh()
        let excluded = try #require(fixture.model.changes.workingDirectory.files.first { $0.path == "excluded.txt" })
        fixture.model.changes.setIncluded([excluded.id], false)
        return fixture
    }

    @Test("asks for consent before the first request to a provider, and sends nothing until then")
    func consentFirst() async throws {
        let fixture = try await fixture()
        let provider = try fixture.addProvider(consent: false)
        fixture.server.answer { _ in .commitMessage(title: "Add a line", description: "") }

        let error = await #expect(throws: OperationError.self) {
            try await fixture.ai.generateCommitMessage()
        }
        #expect(error?.reason == .ai(.consentRequired(provider: "Test AI")))
        #expect(fixture.server.requests.isEmpty)
        #expect(fixture.ai.commitMessageGeneration == .idle)

        // The disclosure says where it would be sent.
        let disclosure = try #require(fixture.app.ai.disclosure(for: .commitMessageGeneration))
        #expect(disclosure.providerName == "Test AI")
        #expect(disclosure.host == fixture.server.host)

        fixture.app.ai.recordConsent(disclosure.consentIdentifier)
        try await fixture.ai.generateCommitMessage()
        #expect(fixture.server.requests.count == 1)
        #expect(fixture.model.commit.draft.summary == "Add a line")
        _ = provider
    }

    @Test("generates into the draft from the diff of the included files only, leaving the index alone")
    func generatesIntoDraft() async throws {
        let fixture = try await fixture()
        try fixture.addProvider()
        fixture.server.answer { _ in .commitMessage(title: "Add a second line", description: "The file needed one more line.") }
        let author = Author.known(KnownAuthor(name: "Hubot", email: "hubot@example.com", username: "hubot"))
        fixture.model.commit.draft.coAuthors = [author]

        try await fixture.ai.generateCommitMessage()

        let draft = fixture.model.commit.draft
        #expect(draft.summary == "Add a second line")
        #expect(draft.description == "The file needed one more line.")
        #expect(draft.generatedByAI)
        #expect(draft.coAuthors == [author])
        #expect(fixture.ai.commitMessageGeneration == .idle)

        let request = try #require(fixture.server.requests.first)
        #expect(request.url.path == "/v1/chat/completions")
        #expect(request.headers["authorization"] == "Bearer sk-test-key")
        #expect(request.model == "test-model")
        #expect(request.userPrompt.contains("+two included"))
        #expect(request.userPrompt.contains("included.txt"))
        #expect(!request.userPrompt.contains("excluded"))
        #expect(request.systemPrompt.contains("concisely summarize code changes"))

        // The temporary index left the repository's own alone: nothing is
        // staged.
        #expect(try await runGit(["diff", "--cached", "--name-only"], fixture.local).isEmpty)
    }

    @Test("asks before overriding a typed message, unless the confirmation is off")
    func overrideConfirmation() async throws {
        let fixture = try await fixture()
        try fixture.addProvider()
        fixture.server.answer { _ in .commitMessage(title: "Generated", description: "") }
        fixture.model.commit.draft.summary = "Typed by hand"

        let error = await #expect(throws: OperationError.self) {
            try await fixture.ai.generateCommitMessage()
        }
        guard case .confirmationRequired(let confirmation)? = error?.reason else {
            Issue.record("Expected the override confirmation, got \(String(describing: error))")
            return
        }
        #expect(confirmation.kind == .overwriteCommitMessage)
        #expect(fixture.server.requests.isEmpty)
        #expect(fixture.model.commit.draft.summary == "Typed by hand")

        try await fixture.ai.generateCommitMessage(confirmed: [.overwriteCommitMessage])
        #expect(fixture.model.commit.draft.summary == "Generated")

        // A description alone counts too; with the confirmation off, it
        // isn't asked.
        fixture.model.commit.draft.description = "More"
        fixture.app.preferences.confirmCommitMessageOverride = false
        try await fixture.ai.generateCommitMessage()
        #expect(fixture.server.requests.count == 2)
    }

    @Test("cancelling stops the request and leaves the draft as it was")
    func cancels() async throws {
        let fixture = try await fixture()
        try fixture.addProvider()
        fixture.server.answer { _ in .hang }
        fixture.model.commit.draft.description = "Kept"
        fixture.app.preferences.confirmCommitMessageOverride = false

        let generation = Task { @MainActor in
            try await fixture.ai.generateCommitMessage()
        }
        await fixture.server.waitForRequests(1)
        #expect(fixture.ai.commitMessageGeneration == .generating)

        // Only one at a time.
        let second = await #expect(throws: OperationError.self) {
            try await fixture.ai.generateCommitMessage()
        }
        #expect(second?.reason == .busy(.generateCommitMessage))

        fixture.ai.cancelGeneration()
        #expect(fixture.ai.commitMessageGeneration == .idle)
        let result = await generation.result
        #expect((result.failure as? OperationError)?.reason == .cancelled(.userCancelled))
        #expect(fixture.model.commit.draft.summary.isEmpty)
        #expect(fixture.model.commit.draft.description == "Kept")
        #expect(!fixture.model.commit.draft.generatedByAI)

        // The next one works.
        fixture.server.answer { _ in .commitMessage(title: "After cancelling", description: "") }
        try await fixture.ai.generateCommitMessage()
        #expect(fixture.model.commit.draft.summary == "After cancelling")
    }

    @Test("cancelling the calling task cancels the generation")
    func cancelsWithCaller() async throws {
        let fixture = try await fixture()
        try fixture.addProvider()
        fixture.server.answer { _ in .hang }

        let generation = Task { @MainActor in
            try await fixture.ai.generateCommitMessage()
        }
        await fixture.server.waitForRequests(1)
        generation.cancel()

        let result = await generation.result
        #expect((result.failure as? OperationError)?.reason == .cancelled(.userCancelled))
        #expect(fixture.ai.commitMessageGeneration == .idle)
    }

    @Test("a message for changes committed while it was generated is dropped")
    func dropsStaleMessage() async throws {
        let fixture = try await fixture()
        // The answer waits on a commit and a refresh, which took more than
        // the default 60 seconds on CI's busy runner; a passing test never
        // waits for the longer timeout.
        try fixture.addProvider(requestTimeoutSeconds: 300)
        fixture.server.answer { _ in .deferred(.commitMessage(title: "Too late", description: "")) }

        let generation = Task { @MainActor in
            try await fixture.ai.generateCommitMessage()
        }
        await fixture.server.waitForRequests(1)
        // The changes are committed elsewhere meanwhile.
        try await runGit(["commit", "-qam", "Committed in Terminal"], fixture.local)
        await fixture.refresh()
        fixture.server.releaseDeferred()

        try await generation.value
        #expect(fixture.model.commit.draft.summary.isEmpty)
        #expect(!fixture.model.commit.draft.generatedByAI)
        #expect(fixture.ai.commitMessageGeneration == .idle)
    }

    @Test("with AI off, nothing is offered and no request is made; turning it off stops a generation")
    func offSwitch() async throws {
        let fixture = try await fixture()
        try fixture.addProvider()
        fixture.server.answer { _ in .hang }
        fixture.app.preferences.aiFeaturesEnabled = false

        let error = await #expect(throws: OperationError.self) {
            try await fixture.ai.generateCommitMessage()
        }
        #expect(error?.reason == .ai(.disabled))
        #expect(fixture.server.requests.isEmpty)

        fixture.app.preferences.aiFeaturesEnabled = true
        let generation = Task { @MainActor in
            try await fixture.ai.generateCommitMessage()
        }
        await fixture.server.waitForRequests(1)
        fixture.app.preferences.aiFeaturesEnabled = false

        let result = await generation.result
        #expect((result.failure as? OperationError)?.reason == .cancelled(.userCancelled))
        #expect(fixture.ai.commitMessageGeneration == .idle)
    }

    @Test("without a provider, or with several models and none chosen, says what's missing")
    func missingModel() async throws {
        let fixture = try await fixture()
        fixture.server.answer { _ in .commitMessage(title: "Chosen", description: "") }

        let none = await #expect(throws: OperationError.self) {
            try await fixture.ai.generateCommitMessage()
        }
        #expect(none?.reason == .ai(.noProvider))
        #expect(opensAISettings(none))

        let provider = try fixture.addProvider(models: ["small", "large"])
        let ambiguous = await #expect(throws: OperationError.self) {
            try await fixture.ai.generateCommitMessage()
        }
        #expect(ambiguous?.reason == .ai(.modelSelectionRequired))
        #expect(fixture.server.requests.isEmpty)

        fixture.app.ai.select(model: encodeModelKey(AIModelKey(providerId: provider.id, modelId: "large")), for: .commitMessageGeneration)
        try await fixture.ai.generateCommitMessage()
        #expect(fixture.server.requests.first?.model == "large")
    }

    @Test("needs included files or a commit to amend")
    func needsFiles() async throws {
        let fixture = try await fixture()
        try fixture.addProvider()
        fixture.model.changes.setIncludeAll(false)
        #expect(!fixture.ai.hasChangesToDescribe)

        let error = await #expect(throws: OperationError.self) {
            try await fixture.ai.generateCommitMessage()
        }
        #expect(preconditionText(error) != nil)
    }

    @Test("says so, without asking the model, when the changes have no diff")
    func emptyDiff() async throws {
        let fixture = try await AIFixture.make { repository in
            try await commit(["base.txt": "base\n"], "Initial commit", in: repository)
            try await runGit(["commit", "--allow-empty", "-m", "Empty commit"], repository)
        }
        try fixture.addProvider()
        try await fixture.model.commit.startAmending()
        await fixture.settle()

        let error = await #expect(throws: OperationError.self) {
            try await fixture.ai.generateCommitMessage(confirmed: [.overwriteCommitMessage])
        }

        #expect(preconditionText(error) != nil)
        #expect(fixture.ai.commitMessageGeneration == .failed(try #require(error)))
        #expect(fixture.server.requests.isEmpty)
    }

    @Test("sends the repository's commit message rules and its instructions for AI tools")
    func rulesAndInstructions() async throws {
        let fixture = try await AIFixture.make { repository in
            try await commit([".github/copilot-instructions.md": "Start every title with an emoji.\n"], "Add instructions", in: repository)
        }
        try fixture.write("change.txt", "new\n")
        await fixture.refresh()
        try fixture.addProvider()
        fixture.server.answer { _ in .commitMessage(title: "Add change", description: "") }
        var rules = RepoRulesInfo()
        rules.commitMessagePatterns.push(RepoRulesMetadataRule(
            enforced: .enforced,
            matcher: { _ in true },
            humanDescription: "must start with \"feat:\"",
            rulesetId: 1
        ))
        rules.commitMessagePatterns.push(RepoRulesMetadataRule(
            enforced: .notEnforced,
            matcher: { _ in true },
            humanDescription: "must be short",
            rulesetId: 2
        ))
        fixture.model.gitHub.repoRules = rules

        try await fixture.ai.generateCommitMessage()

        let request = try #require(fixture.server.requests.first)
        #expect(request.systemPrompt.contains("Start every title with an emoji."))
        #expect(request.systemPrompt.contains("Source: .github/copilot-instructions.md"))
        #expect(request.userPrompt.contains("- must start with \"feat:\""))
        #expect(!request.userPrompt.contains("must be short"))
    }

    @Test("instructions that link outside the repository aren't sent")
    func instructionsOutsideRepository() async throws {
        let outside = POSIXPath.join(try createTempDirectory(), "secret.md")
        try Data("Do not send me.\n".utf8).write(to: URL(filePath: outside))
        let fixture = try await AIFixture.make { repository in
            try FileManager.default.createDirectory(atPath: POSIXPath.join(repository.path, ".github"), withIntermediateDirectories: true)
            try FileManager.default.createSymbolicLink(
                atPath: POSIXPath.join(repository.path, ".github/copilot-instructions.md"),
                withDestinationPath: outside
            )
            try await commit(["file.txt": "one\n"], "Initial commit", in: repository)
        }
        try fixture.write("file.txt", "two\n")
        await fixture.refresh()
        try fixture.addProvider()
        fixture.server.answer { _ in .commitMessage(title: "Change", description: "") }

        try await fixture.ai.generateCommitMessage()

        let request = try #require(fixture.server.requests.first)
        #expect(!request.systemPrompt.contains("Do not send me."))
        #expect(!request.userPrompt.contains("Do not send me."))
    }

    @Test("when amending, describes the amended commit's changes with the included ones")
    func amending() async throws {
        let fixture = try await AIFixture.make { repository in
            try await commit(["base.txt": "base\n"], "Initial commit", in: repository)
            try await commit(["amended.txt": "in the amended commit\n"], "Second commit", in: repository)
        }
        try fixture.addProvider()
        fixture.server.answer { _ in .commitMessage(title: "Amended", description: "") }
        try await fixture.model.commit.startAmending()
        await fixture.settle()
        #expect(fixture.model.commit.amending != nil)
        #expect(fixture.ai.hasChangesToDescribe)

        // Amending loaded the commit's message into the draft.
        try await fixture.ai.generateCommitMessage(confirmed: [.overwriteCommitMessage])

        let request = try #require(fixture.server.requests.first)
        #expect(request.userPrompt.contains("+in the amended commit"))
        #expect(!request.userPrompt.contains("+base"))
        #expect(fixture.model.commit.draft.summary == "Amended")
    }

    @Test("amending the first commit describes it against the empty tree")
    func amendingFirstCommit() async throws {
        let fixture = try await AIFixture.make { repository in
            try await commit(["first.txt": "the very first line\n"], "Initial commit", in: repository)
        }
        try fixture.addProvider()
        fixture.server.answer { _ in .commitMessage(title: "Start the project", description: "") }
        try await fixture.model.commit.startAmending()
        await fixture.settle()

        try await fixture.ai.generateCommitMessage(confirmed: [.overwriteCommitMessage])

        let request = try #require(fixture.server.requests.first)
        #expect(request.userPrompt.contains("+the very first line"))
        #expect(fixture.model.commit.draft.summary == "Start the project")
    }

    @Test("a provider's failure is kept for the composer")
    func providerFailure() async throws {
        let fixture = try await fixture()
        try fixture.addProvider()
        fixture.server.answer { _ in authenticationFailure }

        let error = await #expect(throws: OperationError.self) {
            try await fixture.ai.generateCommitMessage()
        }
        #expect(providerFailureMessage(error) == "Incorrect API key provided.")
        // The key is fixed in Settings ▸ AI.
        #expect(opensAISettings(error))
        #expect(fixture.ai.commitMessageGeneration == .failed(try #require(error)))
        #expect(fixture.model.commit.draft.summary.isEmpty)

        fixture.ai.dismissGenerationFailure()
        #expect(fixture.ai.commitMessageGeneration == .idle)
    }

    @Test("a reply that isn't a commit message fails with the model's error")
    func invalidReply() async throws {
        let fixture = try await fixture()
        try fixture.addProvider()
        fixture.server.answer { _ in .content("Sure! Here is a commit message: Add a line") }

        let error = await #expect(throws: OperationError.self) {
            try await fixture.ai.generateCommitMessage()
        }
        if case .ai(.provider(title: .none, message: _))? = error?.reason {} else {
            Issue.record("Unexpected reason \(String(describing: error?.reason))")
        }
        // Trying again may help; Settings won't.
        #expect(error?.recoveries.isEmpty == true)
    }

    @Test("a missing API key makes the model unavailable and offers Settings")
    func missingKey() async throws {
        let fixture = try await fixture()
        let provider = try fixture.addProvider()
        try fixture.harness.secrets.deleteSecret(service: BYOKSecretService, account: provider.id)

        let error = await #expect(throws: OperationError.self) {
            try await fixture.ai.generateCommitMessage()
        }
        if case .ai(.modelUnavailable)? = error?.reason {} else {
            Issue.record("Unexpected reason \(String(describing: error?.reason))")
        }
        #expect(opensAISettings(error))
        #expect(fixture.server.requests.isEmpty)
    }
}
