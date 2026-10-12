// Ported from desktop/app/test/unit/copilot-error-test.ts

@testable import AIKit
import Testing

private func parse(_ text: String, status: Int = 402, retryAfter: String? = nil) -> AIProviderError {
    parseProviderErrorResponse(statusCode: status, responseText: text, retryAfter: retryAfter)
}

@Suite("parseProviderErrorResponse")
struct ParseProviderErrorTests {
    @Test("preserves array responses as raw text")
    func arrayResponses() {
        let response = #"[{"message":"Not a top-level error"}]"#
        let error = parse(response)
        #expect(error.message == response)
        #expect(error.code == nil)
    }

    @Test("uses the top-level message when the nested error is an array")
    func nestedArray() {
        let error = parse(#"{"message":"Billing unavailable","error":[{"code":"quota_exceeded","message":"Nested message"}]}"#)
        #expect(error.message == "Billing unavailable")
        #expect(error.code == nil)
    }

    @Test("preserves raw text when an array error has no top-level message")
    func nestedArrayWithoutMessage() {
        let response = #"{"error":[{"code":"quota_exceeded"}]}"#
        let error = parse(response)
        #expect(error.message == response)
        #expect(error.code == nil)
    }

    // The code is kept as the provider sent it.
    @Test("parses quota_exceeded responses")
    func quotaExceeded() {
        let error = parse(
            #"{"error":{"code":"quota_exceeded","message":"You have used all available Copilot premium requests."}}"#,
            retryAfter: "120"
        )
        #expect(error.message == "You have used all available Copilot premium requests.")
        #expect(error.code == "quota_exceeded")
        #expect(error.retryAfter == "120")
        #expect(error.kind == .billing)
    }

    @Test("falls back to the raw response body when the server returns plain text")
    func plainText() {
        let error = parse("You have reached your quota limit.")
        #expect(error.message == "You have reached your quota limit.")
        #expect(error.code == nil)
    }

    // The providers' error formats.

    @Test("reads OpenAI, Anthropic, Azure, and Ollama error bodies")
    func providerFormats() {
        let openAI = parse(
            #"{"error":{"message":"Incorrect API key provided.","type":"invalid_request_error","param":null,"code":"invalid_api_key"}}"#,
            status: 401
        )
        #expect(openAI.kind == .authentication)
        #expect(openAI.message == "Incorrect API key provided.")
        #expect(openAI.code == "invalid_api_key")
        #expect(openAI.statusCode == 401)

        let anthropic = parse(
            #"{"type":"error","error":{"type":"overloaded_error","message":"Overloaded"},"request_id":"req_1"}"#,
            status: 529
        )
        #expect(anthropic.kind == .server)
        #expect(anthropic.message == "Overloaded")
        #expect(anthropic.code == "overloaded_error")

        let azure = parse(#"{"error":{"code":"DeploymentNotFound","message":"The API deployment does not exist."}}"#, status: 404)
        #expect(azure.kind == .notFound)
        #expect(azure.code == "DeploymentNotFound")

        let ollama = parse(#"{"error":"model \"llama9\" not found, try pulling it first"}"#, status: 404)
        #expect(ollama.message == #"model "llama9" not found, try pulling it first"#)
        #expect(ollama.code == nil)
    }

    @Test("classifies status codes")
    func classifiesStatuses() {
        let cases: [(Int, String, AIProviderError.Kind)] = [
            (400, "{}", .badRequest),
            (400, #"{"error":{"message":"prompt is too long: 250000 tokens > 200000 maximum"}}"#, .requestTooLarge),
            (400, #"{"error":{"message":"x","code":"context_length_exceeded"}}"#, .requestTooLarge),
            (401, "", .authentication),
            (402, "", .billing),
            (403, "", .permissionDenied),
            (404, "", .notFound),
            (408, "", .timedOut),
            (413, "", .requestTooLarge),
            (429, "", .rateLimited),
            (429, #"{"error":{"message":"You exceeded your current quota.","code":"insufficient_quota"}}"#, .quotaExceeded),
            (500, "", .server),
            (302, "", .invalidResponse),
        ]
        for (status, body, kind) in cases {
            #expect(parse(body, status: status).kind == kind, "\(status) \(body)")
        }
    }

    @Test("keeps the raw body when its message is blank")
    func blankMessage() {
        #expect(parse(#"{"error":{"message":" "}}"#, status: 500).message == #"{"error":{"message":" "}}"#)
    }
}

@Suite("getAIErrorDisplayInfo")
struct AIErrorDisplayInfoTests {
    // Adapted from "returns a quota-specific title and retry timing for
    // quota_exceeded": a provider's exhausted quota is `insufficient_quota`.
    @Test("returns the provider's message and retry timing for insufficient_quota")
    func quota() {
        let error = parse(
            #"{"error":{"code":"insufficient_quota","message":"You exceeded your current quota."}}"#,
            status: 429,
            retryAfter: "120"
        )

        let displayInfo = getAIErrorDisplayInfo(error)

        #expect(displayInfo.message == "You exceeded your current quota.")
        #expect(displayInfo.retryAfterMessage != nil)
    }

    // Adapted from "treats unknown 402 responses as a generic Copilot
    // billing issue".
    @Test("returns an unknown 402 response's text, without retry timing")
    func billing() {
        let displayInfo = getAIErrorDisplayInfo(parse("You have reached your quota limit."))
        #expect(displayInfo.message == "You have reached your quota limit.")
        #expect(displayInfo.retryAfterMessage == nil)
    }

    @Test("looks through conflict resolution errors, and ignores other errors")
    func anyError() {
        let providerError = parse("", status: 401)
        let wrapped = AIConflictResolutionError(providerError, stage: .streamResponse)
        #expect(getAIErrorDisplayInfo(for: wrapped) != nil)
        #expect(getAIErrorDisplayInfo(for: providerError) != nil)
        #expect(getAIErrorDisplayInfo(for: AIResponseError("No response from the model")) == nil)
        #expect(getAIErrorDisplayInfo(for: AIConflictResolutionError(AIValidationError("bad"), stage: .parseResponse)) == nil)
    }
}
