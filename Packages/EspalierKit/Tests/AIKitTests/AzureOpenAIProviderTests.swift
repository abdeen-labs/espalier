@testable import AIKit
import Foundation
import Testing

private let chatCompletion = #"{"choices":[{"message":{"content":"Hello"},"finish_reason":"stop"}]}"#
private let responsesBody = #"{"status":"completed","output":[{"type":"message","content":[{"type":"output_text","text":"Hello"}]}]}"#

@Suite("Azure OpenAI provider")
struct AzureOpenAIProviderTests {
    @Test("uses the deployment route and api-version, with the api-key header for an API key")
    func versionedDeployment() async throws {
        let server = MockServer()
        server.enqueue(.json(chatCompletion))
        let provider = try makeProvider(
            configuration(server, .azure, path: "/", credential: .apiKey("azure-key"), azureApiVersion: "2024-10-21"),
            server
        )

        let response = try await provider.complete(testRequest(model: "my-deployment", effort: .low))

        #expect(response.content == "Hello")
        let request = try #require(server.requests.first)
        #expect(request.url.absoluteString == server.url("/openai/deployments/my-deployment/chat/completions?api-version=2024-10-21"))
        #expect(request.header("api-key") == "azure-key")
        #expect(request.header("Authorization") == nil)
        #expect(
            try request.json == [
                "model": "my-deployment",
                "messages": [
                    ["role": "system", "content": "System prompt"],
                    ["role": "user", "content": "User prompt"],
                ],
                "reasoning_effort": "low",
            ]
        )
    }

    @Test("uses the versionless v1 route without an API version, with a bearer token")
    func versionlessRoute() async throws {
        let server = MockServer()
        server.enqueue(.json(chatCompletion))
        let provider = try makeProvider(configuration(server, .azure, credential: .bearer("entra-token")), server)

        _ = try await provider.complete(testRequest(model: "gpt-4o"))

        let request = try #require(server.requests.first)
        #expect(request.url.absoluteString == server.url("/openai/v1/chat/completions"))
        #expect(request.header("Authorization") == "Bearer entra-token")
        #expect(request.header("api-key") == nil)
    }

    @Test("uses the Responses routes with and without an API version")
    func responsesRoutes() async throws {
        let server = MockServer()
        server.enqueue(.json(responsesBody), .json(responsesBody))

        let versioned = try makeProvider(
            configuration(server, .azure, wireApi: .responses, azureApiVersion: "2025-04-01-preview"),
            server
        )
        _ = try await versioned.complete(testRequest(model: "gpt-5"))
        let versionless = try makeProvider(configuration(server, .azure, wireApi: .responses), server)
        _ = try await versionless.complete(testRequest(model: "gpt-5"))

        #expect(server.requests[0].url.absoluteString == server.url("/openai/responses?api-version=2025-04-01-preview"))
        #expect(try server.requests[0].json["model"] == "gpt-5")
        #expect(server.requests[1].url.absoluteString == server.url("/openai/v1/responses"))
    }

    @Test("tolerates /openai and /openai/v1 base URLs, keeps other query items, and escapes deployment names")
    func baseUrlForms() throws {
        let base = try #require(URLComponents(string: "https://res.openai.azure.com/openai/v1/"))
        #expect(
            try AzureOpenAIProvider.endpoint(baseUrl: base, wireApi: .completions, model: "m", apiVersion: nil).absoluteString
                == "https://res.openai.azure.com/openai/v1/chat/completions"
        )
        let withOpenAI = try #require(URLComponents(string: "https://res.openai.azure.com/openai"))
        #expect(
            try AzureOpenAIProvider.endpoint(baseUrl: withOpenAI, wireApi: .responses, model: "m", apiVersion: nil).absoluteString
                == "https://res.openai.azure.com/openai/v1/responses"
        )
        let project = try #require(URLComponents(string: "https://host/api/projects/agents?team=1&api-version=old"))
        #expect(
            try AzureOpenAIProvider.endpoint(baseUrl: project, wireApi: .completions, model: "my deployment/x", apiVersion: "2024-10-21")
                .absoluteString
                == "https://host/api/projects/agents/openai/deployments/my%20deployment%2Fx/chat/completions?team=1&api-version=2024-10-21"
        )
    }

    @Test("trims the API version of JavaScript whitespace, line breaks included")
    func trimsApiVersion() async throws {
        let server = MockServer()
        server.enqueue(.json(#"{"choices":[{"message":{"content":"x"}}]}"#), .json(#"{"choices":[{"message":{"content":"x"}}]}"#))

        for version in ["2024-10-21\n", "\u{A0}2024-10-21\u{2028}"] {
            let provider = try makeProvider(configuration(server, .azure, azureApiVersion: version), server)
            _ = try await provider.complete(testRequest(model: "deployment"))
        }

        for request in server.requests {
            #expect(request.url.absoluteString == server.url("/openai/deployments/deployment/chat/completions?api-version=2024-10-21"))
        }
    }

    @Test("sends no credentials with auth none, and leaves think tags in the content")
    func noCredentials() async throws {
        let server = MockServer()
        server.enqueue(.json(#"{"choices":[{"message":{"content":"<think>x</think>y"}}]}"#))
        let provider = try makeProvider(configuration(server, .azure, credential: .none, azureApiVersion: " "), server)

        let response = try await provider.complete(testRequest())

        #expect(response.content == "<think>x</think>y")
        let request = try #require(server.requests.first)
        #expect(request.header("api-key") == nil)
        #expect(request.header("Authorization") == nil)
        // A blank API version means the versionless route.
        #expect(request.url.absoluteString == server.url("/openai/v1/chat/completions"))
    }
}
