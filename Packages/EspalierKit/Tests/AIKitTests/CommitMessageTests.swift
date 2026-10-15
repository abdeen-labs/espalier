// Ported from desktop/app/test/unit/copilot-commit-message-test.ts

@testable import AIKit
import Testing

@Suite("parseAICommitMessage")
struct CommitMessageTests {
    @Test("parses object payloads")
    func parsesObjects() throws {
        #expect(
            try parseAICommitMessage(#"{"title":"Fix token renewal","description":"Preserve credentials"}"#)
                == AICommitMessage(title: "Fix token renewal", description: "Preserve credentials")
        )
    }

    @Test("rejects arrays, null, and primitives as non-object payloads")
    func rejectsNonObjects() {
        for content in ["[]", "null", "42"] {
            #expect(throws: AIResponseError.self, "\(content)") {
                try parseAICommitMessage(content)
            }
        }
    }

    // The rest of the parser's contract.

    @Test("unwraps code fences and defaults a missing description")
    func unwrapsFences() throws {
        #expect(
            try parseAICommitMessage("```json\n{\"title\":\"T\"}\n```")
                == AICommitMessage(title: "T", description: "")
        )
        #expect(
            try parseAICommitMessage("Here you go:\n```\n{\"title\":\"T\",\"description\":\"D\"}\n```\nThanks")
                == AICommitMessage(title: "T", description: "D")
        )
        #expect(try parseAICommitMessage("  {\"title\":\"T\"}\n").title == "T")
    }

    @Test("rejects invalid JSON, blank titles, and non-string descriptions")
    func rejectsInvalidPayloads() {
        #expect(throws: AIResponseError.self) {
            try parseAICommitMessage("Fix the bug")
        }
        #expect(throws: AIResponseError.self) {
            try parseAICommitMessage(#"{"title":"  ","description":"D"}"#)
        }
        #expect(throws: AIResponseError.self) {
            try parseAICommitMessage(#"{"title":1}"#)
        }
        #expect(throws: AIResponseError.self) {
            try parseAICommitMessage(#"{"title":"T","description":2}"#)
        }
    }

    @Test("takes a null description as none, and trims the title")
    func nullDescription() throws {
        #expect(
            try parseAICommitMessage(#"{"title":" Fix token renewal\n","description":null}"#)
                == AICommitMessage(title: "Fix token renewal", description: "")
        )
    }

    @Test("finds the JSON as the conflict parser does: past a broken first block, or with fences inside it")
    func sharedExtraction() throws {
        // The first block isn't JSON; the response as a whole is.
        #expect(try parseAICommitMessage(#"{"title":"Add a ```fenced``` example"}"#).title == "Add a ```fenced``` example")
        // The description has a code block of its own.
        let fenced = "```json\n{\"title\":\"T\",\"description\":\"Run:\\n```\\nmake\\n```\"}\n```"
        #expect(try parseAICommitMessage(fenced) == AICommitMessage(title: "T", description: "Run:\n```\nmake\n```"))
    }
}
