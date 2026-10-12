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
            try parseAICommitMessage(#"{"title":"T","description":null}"#)
        }
    }
}
