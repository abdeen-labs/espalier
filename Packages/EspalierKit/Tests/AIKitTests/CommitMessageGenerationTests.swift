@testable import AIKit
import EspalierSupport
import Foundation
import Testing
import TestSupport

private let diff = "diff --git a/a.txt b/a.txt\n--- a/a.txt\n+++ b/a.txt\n@@ -1 +1 @@\n-old\n+new"

private func model(_ server: MockServer, type: BYOKProviderType = .openai, timeout: Duration? = nil) -> AIModelRequest {
    AIModelRequest(
        modelId: type == .anthropic ? "claude-opus-5-5" : "gpt-4o-mini",
        provider: configuration(server, type, path: type == .openai ? "/v1" : ""),
        reasoningEffort: .low,
        timeout: timeout
    )
}

private func chatCompletion(_ content: String) -> MockResponse {
    let escaped = String(decoding: JSONValue.string(content).serialized(), as: UTF8.self)
    return .json(#"{"choices":[{"message":{"role":"assistant","content":\#(escaped)},"finish_reason":"stop"}]}"#)
}

private let tokenPattern = JSCompat.regex("<diff-([0-9a-f]{16})>")

@Suite("Commit message generation", .hangGuard(minutes: 5))
struct CommitMessageGenerationTests {
    @Test("sends desktop's prompts with the repository's rules and instructions, and parses the reply")
    func endToEnd() async throws {
        let server = MockServer()
        server.enqueue(chatCompletion(#"{"title":"Update a.txt","description":"Replace old with new."}"#))
        let rules = [
            CommitMessageRule(enforced: .enforced, humanDescription: #"must start with "[DESK-1]""#),
            CommitMessageRule(enforced: .notEnforced, humanDescription: "not for this user"),
        ]
        let instructions = [RepositoryInstructions(path: ".github/copilot-instructions.md", content: "Use the imperative mood.")]

        let message = try await generateCommitMessage(
            diff: diff,
            model: model(server),
            commitMessageRules: rules,
            repositoryInstructions: instructions,
            session: server.session
        )

        #expect(message == AICommitMessage(title: "Update a.txt", description: "Replace old with new."))

        let body = try #require(server.requests.first).json
        guard case .array(let messages)? = body["messages"],
              let systemPrompt = messages.first?["content"]?.stringValue,
              let userPrompt = messages.last?["content"]?.stringValue
        else {
            Issue.record("Unexpected request body \(body)")
            return
        }
        let token = try #require(JSCompat.match(userPrompt, tokenPattern)?[1])
        let tags = CommitMessagePromptTags(token: token)
        #expect(
            systemPrompt
                == buildRepositoryInstructionsPrompt(instructions, open: tags.repositoryInstructionsOpen, close: tags.repositoryInstructionsClose)
                + buildCommitMessageSystemPrompt(hasRules: true, tags: tags)
        )
        #expect(systemPrompt.hasPrefix("This repository provides custom instructions for AI tools."))
        #expect(systemPrompt.contains("\(tags.repositoryInstructionsOpen)\nSource: .github/copilot-instructions.md\n\nUse the imperative mood.\n\(tags.repositoryInstructionsClose)"))
        #expect(userPrompt == buildCommitMessageUserPrompt(diff, tags, [#"must start with "[DESK-1]""#]))
        #expect(body["model"] == "gpt-4o-mini")
        #expect(body["reasoning_effort"] == "low")
        #expect(body["stream"] == nil)
    }

    @Test("ignores blank instruction files")
    func blankInstructions() async throws {
        let provider = ScriptedProvider { _ in .content(#"{"title":"T"}"#) }
        _ = try await generateCommitMessage(
            diff: diff,
            model: scriptedModel(),
            using: provider,
            repositoryInstructions: [RepositoryInstructions(path: "a.md", content: " \n")]
        )
        #expect(provider.requests.first?.systemPrompt == CommitMessageSystemPrompt)
    }

    @Test("truncates long instruction files")
    func longInstructions() {
        let long = String(repeating: "x", count: MaxRepositoryInstructionsLength + 10)
        let prompt = buildRepositoryInstructionsPrompt([RepositoryInstructions(path: "a.md", content: long)], open: "<o>", close: "</o>")
        #expect(prompt.contains(String(repeating: "x", count: MaxRepositoryInstructionsLength) + "\n\u{2026}(truncated)\n</o>"))
        #expect(!prompt.contains(long))
    }

    @Test("fails on an empty reply and on unusable JSON")
    func unusableReplies() async throws {
        let empty = ScriptedProvider { _ in ScriptedTurn(response: AIResponse(content: "")) }
        await #expect(throws: AIResponseError.self) {
            _ = try await generateCommitMessage(diff: diff, model: scriptedModel(), using: empty)
        }

        let prose = ScriptedProvider { _ in .content("Update a.txt") }
        await #expect(throws: AIResponseError.self) {
            _ = try await generateCommitMessage(diff: diff, model: scriptedModel(), using: prose)
        }
    }

    @Test("reports a reply cut off at the output limit as that, not as invalid JSON", arguments: ["length", "max_tokens", "max_output_tokens"])
    func cutOff(stopReason: String) async throws {
        for content in [#"{"title":"Update a.txt","descr"#, ""] {
            let provider = ScriptedProvider { _ in ScriptedTurn(response: AIResponse(content: content, stopReason: stopReason)) }
            let error = await providerError {
                _ = try await generateCommitMessage(diff: diff, model: scriptedModel(), using: provider)
            }
            #expect(error?.kind == .outputLimitReached)
            #expect(provider.requests.count == 1)
        }

        // A complete message is used, however the response ended.
        let complete = ScriptedProvider { _ in ScriptedTurn(response: AIResponse(content: #"{"title":"T"}"#, stopReason: stopReason)) }
        #expect(try await generateCommitMessage(diff: diff, model: scriptedModel(), using: complete).title == "T")
    }

    @Test("sends at most MaxCommitMessageDiffSize of a long diff, with every file in view")
    func longDiff() async throws {
        let big = (0..<20_000).map { "+generated line \($0)" }.joined(separator: "\n")
        let longDiff = [
            ":100644 100644 1111111 2222222 M\tpackage-lock.json",
            ":100644 100644 3333333 4444444 M\tsrc/app.ts",
            "",
            "diff --git a/package-lock.json b/package-lock.json\n--- a/package-lock.json\n+++ b/package-lock.json\n@@ -1 +1,20000 @@\n\(big)",
            "diff --git a/src/app.ts b/src/app.ts\n--- a/src/app.ts\n+++ b/src/app.ts\n@@ -1 +1 @@\n-old\n+new",
        ].joined(separator: "\n") + "\n"
        let provider = ScriptedProvider { _ in .content(#"{"title":"T"}"#) }

        _ = try await generateCommitMessage(diff: longDiff, model: scriptedModel(), using: provider)

        let prompt = try #require(provider.requests.first?.userPrompt)
        #expect(prompt.utf8.count < MaxCommitMessageDiffSize + 200)
        // The file list and the small file whole, the large one cut short.
        #expect(prompt.contains(":100644 100644 1111111 2222222 M\tpackage-lock.json\n:100644 100644 3333333 4444444 M\tsrc/app.ts\n"))
        #expect(prompt.contains("diff --git a/src/app.ts b/src/app.ts\n--- a/src/app.ts\n+++ b/src/app.ts\n@@ -1 +1 @@\n-old\n+new\n"))
        #expect(prompt.contains("diff --git a/package-lock.json b/package-lock.json\n--- a/package-lock.json\n+++ b/package-lock.json\n@@ -1 +1,20000 @@\n+generated line 0\n"))
        #expect(prompt.range(of: #"\n\[[0-9]+ more lines left out\]\ndiff --git a/src/app.ts"#, options: .regularExpression) != nil)

        // A diff within the limit is sent as it is.
        #expect(limitDiffForCommitMessage(diff) == diff)
    }

    @Test("sends the first files of a diff with too many to show each, and counts the rest")
    func manyFiles() {
        let files = (0..<1_000).map { "diff --git a/f\($0) b/f\($0)\n--- a/f\($0)\n+++ b/f\($0)\n@@ -1 +1 @@\n-old \($0)\n+new \($0)" }
        let limited = limitDiffForCommitMessage(files.joined(separator: "\n"), limit: 10_240)

        // As many files as fit, whole.
        let sent = limited.components(separatedBy: "diff --git ").count - 1
        #expect(sent > 100)
        #expect(limited == files.prefix(sent).joined(separator: "\n") + "\n[The diffs of \(1_000 - sent) more files are left out]")
        #expect(limited.utf8.count <= 10_240 + 100)
    }

    @Test("surfaces provider errors (401, 429)", arguments: [401, 429])
    func providerErrors(status: Int) async throws {
        let server = MockServer()
        // A 429 would otherwise be retried after the 9 seconds it asks for.
        server.enqueue(
            .json(#"{"error":{"message":"Nope"}}"#, status: status, headers: ["Retry-After": "9", "x-should-retry": "false"])
        )

        let error = await providerError {
            _ = try await generateCommitMessage(diff: diff, model: model(server), session: server.session)
        }

        #expect(error?.statusCode == status)
        #expect(error?.message == "Nope")
    }

    @Test("times out after the request timeout")
    func timesOut() async throws {
        let server = MockServer()
        server.enqueue(.hang)

        let error = await providerError {
            _ = try await generateCommitMessage(diff: diff, model: model(server, timeout: .milliseconds(200)), session: server.session)
        }

        #expect(error?.kind == .timedOut)
        await server.waitForStops(1)
        #expect(server.stoppedCount == 1)
    }

    @Test("reports cancellation as CommitMessageGenerationCancelledError")
    func cancellation() async throws {
        let server = MockServer()
        server.enqueue(.hang)

        let task = Task {
            try await generateCommitMessage(diff: diff, model: model(server), session: server.session)
        }
        await server.waitForRequests(1)
        task.cancel()

        await #expect(throws: CommitMessageGenerationCancelledError()) {
            _ = try await task.value
        }
        await server.waitForStops(1)
        #expect(server.stoppedCount == 1)

        let cancelledBeforeStart = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return try await generateCommitMessage(diff: diff, model: scriptedModel(), using: ScriptedProvider { _ in .content("{}") })
        }
        await #expect(throws: CommitMessageGenerationCancelledError()) {
            _ = try await cancelledBeforeStart.value
        }
    }
}
