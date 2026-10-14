// Ported from desktop/app/test/unit/copilot-error-test.ts

@testable import AIKit
import Testing
import TestSupport

private func parse(_ text: String, status: Int = 402, retryAfter: String? = nil) -> AIProviderError {
    parseProviderErrorResponse(statusCode: status, responseText: text, retryAfter: retryAfter)
}

@Suite("parseProviderErrorResponse")
struct ParseProviderErrorTests {
    @Test("describes the failure when the body has no message to show", arguments: [
        NamedCase("an array", (body: #"[{"message":"Not a top-level error"}]"#, status: 402)),
        NamedCase("an array error without a top-level message", (body: #"{"error":[{"code":"quota_exceeded"}]}"#, status: 402)),
        NamedCase("a blank message", (body: #"{"error":{"message":" "}}"#, status: 500)),
        NamedCase("a gateway's HTML page", (body: "<html>\n<head><title>502 Bad Gateway</title></head>\n<body>nginx</body>\n</html>", status: 502)),
        NamedCase("an HTML page with a doctype", (body: "  <!DOCTYPE html><html><body>Not Found</body></html>", status: 404)),
    ])
    func noMessage(_ testCase: NamedCase<(body: String, status: Int)>) {
        let error = parse(testCase.value.body, status: testCase.value.status)
        #expect(error.message == getFallbackErrorMessage(error.kind))
        #expect(error.code == nil)
    }

    @Test("uses the top-level message when the nested error is an array")
    func nestedArray() {
        let error = parse(#"{"message":"Billing unavailable","error":[{"code":"quota_exceeded","message":"Nested message"}]}"#)
        #expect(error.message == "Billing unavailable")
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
            (400, #"{"type":"error","error":{"type":"invalid_request_error","message":"input length and `max_tokens` exceed context limit: 188240 + 64000 > 200000, decrease input length or `max_tokens` and try again"}}"#, .requestTooLarge),
            (401, "", .authentication),
            (402, "", .billing),
            (403, "", .permissionDenied),
            (404, "", .notFound),
            (408, "", .timedOut),
            (413, "", .requestTooLarge),
            (429, "", .rateLimited),
            (429, #"{"error":{"message":"You exceeded your current quota.","code":"insufficient_quota"}}"#, .quotaExceeded),
            (429, #"{"error":{"message":"Rate limit reached for gpt-4o on tokens per min (TPM): Limit 30000, Used 29000, Requested 2000.","type":"tokens","code":"rate_limit_exceeded"}}"#, .rateLimited),
            (429, #"{"error":{"message":"Request too large for gpt-4o on tokens per min (TPM): Limit 30000, Requested 50000. The input or output tokens must be reduced in order to run successfully.","type":"tokens","code":"rate_limit_exceeded"}}"#, .requestTooLarge),
            (500, "", .server),
            (302, "", .invalidResponse),
        ]
        for (status, body, kind) in cases {
            #expect(parse(body, status: status).kind == kind, "\(status) \(body)")
        }
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
