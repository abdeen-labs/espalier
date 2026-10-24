// Ported from desktop/app/test/unit/copilot-assisted-commit-test.ts, where
// its cases check behavior: the response contract and what a request sends.

@testable import AIKit
import EspalierSupport
import Foundation
import Testing
import TestSupport

private let analysis = AIAssistedCommitAnalysis(snapshotID: "snapshot-1", changes: [
    AIAssistedCommitChange(id: "aaa", kind: "text-hunk", path: "a.txt", diff: "diff --git a/a.txt b/a.txt\n@@ -1 +1 @@\n-old\n+new\n"),
    AIAssistedCommitChange(id: "bbb", kind: "atomic", path: "new.txt", oldPath: "old.txt", diff: "diff --git a/old.txt b/new.txt\n"),
    AIAssistedCommitChange(id: "ccc", kind: "text-hunk", path: "c.txt", diff: "@@ -1 +1 @@\n-x\n+y\n"),
])

private let validPlan = #"{"kind":"plan","snapshotId":"snapshot-1","commits":[{"title":"Change a","description":"Why.","changeIds":["aaa","ccc"]},{"title":"Rename old","changeIds":["bbb"]}]}"#

private let expectedPlan = AIAssistedCommitResponse.plan([
    AIAssistedCommitGroup(title: "Change a", description: "Why.", changeIDs: ["aaa", "ccc"]),
    AIAssistedCommitGroup(title: "Rename old", changeIDs: ["bbb"]),
])

private let tokenPattern = JSCompat.regex("<diff-([0-9a-f]{16})>")

/// A plan for `analysis` with these groups.
private func planJSON(_ groups: String) -> String {
    #"{"kind":"plan","snapshotId":"snapshot-1","commits":\#(groups)}"#
}

@Suite("Assisted commit planning", .hangGuard(minutes: 5))
struct AssistedCommitPlanningTests {
    @Test("reads a plan that owns every change once")
    func readsPlan() throws {
        #expect(try parseAssistedCommitResponse(validPlan, for: analysis) == expectedPlan)
    }

    @Test("reads a plan in one fenced block, and a null description as none")
    func fencedPlan() throws {
        let fenced = "```json\n" + planJSON(#"[{"title":"All","description":null,"changeIds":["aaa","bbb","ccc"]}]"#) + "\n```\n"
        #expect(try parseAssistedCommitResponse(fenced, for: analysis) == .plan([
            AIAssistedCommitGroup(title: "All", description: nil, changeIDs: ["aaa", "bbb", "ccc"]),
        ]))
    }

    @Test("reads uncertain boundaries and refusals")
    func otherOutcomes() throws {
        #expect(
            try parseAssistedCommitResponse(#"{"kind":"uncertain-boundaries","snapshotId":"snapshot-1","title":"Update everything"}"#, for: analysis)
                == .uncertainBoundaries(title: "Update everything", description: nil)
        )
        #expect(
            try parseAssistedCommitResponse(#"{"kind":"unsafe","snapshotId":"snapshot-1","reason":"Secrets in the diff"}"#, for: analysis)
                == .unsafe(reason: "Secrets in the diff")
        )
    }

    @Test("rejects responses that aren't one valid plan", arguments: [
        NamedCase("text around the JSON", "Here's the plan: \(validPlan)"),
        NamedCase("truncated JSON", #"{"kind":"plan","snapshotId":"snapshot-1","commits":[{"title":"A""#),
        NamedCase("two fenced blocks", "```json\n\(validPlan)\n```\n```json\n\(validPlan)\n```"),
        NamedCase("an array", "[\(validPlan)]"),
        NamedCase("an unknown field", #"{"kind":"plan","snapshotId":"snapshot-1","extra":1,"commits":[{"title":"A","changeIds":["aaa","bbb","ccc"]}]}"#),
        NamedCase("a path in a commit", planJSON(#"[{"title":"A","changeIds":["aaa","bbb","ccc"],"paths":["a.txt"]}]"#)),
        NamedCase("another snapshot", #"{"kind":"plan","snapshotId":"snapshot-2","commits":[{"title":"A","changeIds":["aaa","bbb","ccc"]}]}"#),
        NamedCase("an unknown kind", #"{"kind":"patch","snapshotId":"snapshot-1"}"#),
        NamedCase("a change that isn't selected", planJSON(#"[{"title":"A","changeIds":["aaa","bbb","ccc","ddd"]}]"#)),
        NamedCase("a change twice", planJSON(#"[{"title":"A","changeIds":["aaa","bbb"]},{"title":"B","changeIds":["aaa","ccc"]}]"#)),
        NamedCase("a change left out", planJSON(#"[{"title":"A","changeIds":["aaa","bbb"]}]"#)),
        NamedCase("an empty commit", planJSON(#"[{"title":"A","changeIds":["aaa","bbb","ccc"]},{"title":"B","changeIds":[]}]"#)),
        NamedCase("no commits", planJSON("[]")),
        NamedCase("a change ID that isn't text", planJSON(#"[{"title":"A","changeIds":["aaa","bbb","ccc",1]}]"#)),
        NamedCase("a blank title", planJSON(#"[{"title":" ","changeIds":["aaa","bbb","ccc"]}]"#)),
        NamedCase("a title of two lines", planJSON(#"[{"title":"A\nB","changeIds":["aaa","bbb","ccc"]}]"#)),
        NamedCase("a title with a line separator", planJSON(#"[{"title":"A\#u{2028}B","changeIds":["aaa","bbb","ccc"]}]"#)),
        NamedCase("a description that isn't text", planJSON(#"[{"title":"A","description":3,"changeIds":["aaa","bbb","ccc"]}]"#)),
        NamedCase("a refusal without a reason", #"{"kind":"unsafe","snapshotId":"snapshot-1","reason":" "}"#),
        NamedCase("an uncertain outcome without a title", #"{"kind":"uncertain-boundaries","snapshotId":"snapshot-1"}"#),
    ])
    func rejectsInvalidResponses(_ testCase: NamedCase<String>) {
        do {
            _ = try parseAssistedCommitResponse(testCase.value, for: analysis)
            Issue.record("Accepted an invalid response")
        } catch {
            #expect(error.code == .invalidResponse)
        }
    }

    @Test("accepts one commit, and only one, when asked for one")
    func singleCommitMode() throws {
        let one = planJSON(#"[{"title":"All","changeIds":["aaa","bbb","ccc"]}]"#)
        #expect(try parseAssistedCommitResponse(one, for: analysis, mode: .singleCommit) == .plan([
            AIAssistedCommitGroup(title: "All", changeIDs: ["aaa", "bbb", "ccc"]),
        ]))
        do {
            _ = try parseAssistedCommitResponse(validPlan, for: analysis, mode: .singleCommit)
            Issue.record("Accepted a split")
        } catch {
            #expect(error.code == .invalidResponse)
        }
    }

    @Test("sends every change, and only the analysis, in its tagged block", arguments: [AIAssistedCommitPlanningMode.plan, .singleCommit])
    func request(_ mode: AIAssistedCommitPlanningMode) async throws {
        let reply = mode == .plan ? validPlan : planJSON(#"[{"title":"All","changeIds":["aaa","bbb","ccc"]}]"#)
        let provider = ScriptedProvider { _ in .content(reply) }
        let rules = [CommitMessageRule(enforced: .enforced, humanDescription: #"must start with "[DESK-1]""#)]
        let instructions = [RepositoryInstructions(path: ".github/copilot-instructions.md", content: "Use the imperative mood.")]

        _ = try await proposeAssistedCommitPlan(
            analysis,
            mode: mode,
            model: scriptedModel(effort: .medium),
            using: provider,
            commitMessageRules: rules,
            repositoryInstructions: instructions
        )

        let request = try #require(provider.requests.first)
        #expect(provider.requests.count == 1)
        let token = try #require(JSCompat.match(request.userPrompt, tokenPattern)?[1])
        let tags = CommitMessagePromptTags(token: token)
        #expect(
            request.systemPrompt
                == buildRepositoryInstructionsPrompt(instructions, open: tags.repositoryInstructionsOpen, close: tags.repositoryInstructionsClose)
                + buildAssistedCommitSystemPrompt(tags: tags, mode: mode)
        )
        #expect(request.userPrompt == (try buildAssistedCommitUserPrompt(analysis, tags, [#"must start with "[DESK-1]""#])))
        #expect(request.reasoningEffort == .medium)
        #expect(request.timeout == .milliseconds(DefaultAssistedCommitTimeoutMs))

        // The block holds exactly the analysis.
        let start = try #require(request.userPrompt.range(of: "\(tags.diffOpen)\n"))
        let end = try #require(request.userPrompt.range(of: "\n\(tags.diffClose)"))
        let sent = try JSONValue.parse(String(request.userPrompt[start.upperBound..<end.lowerBound]))
        #expect(sent["snapshotId"] == "snapshot-1")
        let changes = try #require(sent["changes"]?.arrayValue)
        #expect(changes.count == analysis.changes.count)
        for (sentChange, change) in zip(changes, analysis.changes) {
            #expect(sentChange["id"]?.stringValue == change.id)
            #expect(sentChange["kind"]?.stringValue == change.kind)
            #expect(sentChange["path"]?.stringValue == change.path)
            #expect(sentChange["oldPath"]?.stringValue == change.oldPath)
            #expect(sentChange["diff"]?.stringValue == change.diff)
        }
    }

    @Test("asks the model nothing for an empty selection or one too large to send")
    func noRequest() async throws {
        let provider = ScriptedProvider { _ in .content(validPlan) }
        let empty = AIAssistedCommitAnalysis(snapshotID: "snapshot-1", changes: [])
        let huge = AIAssistedCommitAnalysis(snapshotID: "snapshot-1", changes: [
            AIAssistedCommitChange(id: "aaa", kind: "text-hunk", path: "a.txt", diff: String(repeating: "+", count: AssistedCommitPromptLimitBytes)),
        ])
        let cases: [(AIAssistedCommitAnalysis, AIAssistedCommitError.Code)] = [(empty, .emptySelection), (huge, .promptTooLarge)]
        for (input, code) in cases {
            let error = await #expect(throws: AIAssistedCommitError.self) {
                _ = try await proposeAssistedCommitPlan(input, model: scriptedModel(), using: provider)
            }
            #expect(error?.code == code)
        }
        #expect(provider.requests.isEmpty)
    }

    @Test("reports a response cut off at the output limit as that, not as an invalid plan")
    func outputLimit() async throws {
        let provider = ScriptedProvider { _ in
            ScriptedTurn(response: AIResponse(content: #"{"kind":"plan","snapshotId":"snapshot-1","commits":["#, stopReason: "max_tokens"))
        }
        let error = await #expect(throws: AIProviderError.self) {
            _ = try await proposeAssistedCommitPlan(analysis, model: scriptedModel(), using: provider)
        }
        #expect(error?.kind == .outputLimitReached)
    }

    @Test("reports an invalid reply as invalid, never as a plan")
    func invalidReply() async throws {
        let provider = ScriptedProvider { _ in .content(planJSON(#"[{"title":"A","changeIds":["aaa"]}]"#)) }
        let error = await #expect(throws: AIAssistedCommitError.self) {
            _ = try await proposeAssistedCommitPlan(analysis, model: scriptedModel(), using: provider)
        }
        #expect(error?.code == .invalidResponse)
    }
}
