import EspalierSupport
import Foundation

/// A client for Azure OpenAI, the `azure` provider type. The request and
/// response formats are OpenAI's; the URLs and the API key header differ.
///
/// The base URL is the resource, for example
/// `https://<resource>.openai.azure.com/` (a trailing `/openai` or
/// `/openai/v1` is tolerated).
///
/// - With an `azureApiVersion`, requests use the versioned routes:
///   `POST {base}/openai/deployments/{model}/chat/completions?api-version=V`,
///   or `POST {base}/openai/responses?api-version=V` with the deployment as
///   the body's `model`.
/// - Without one, the versionless GA routes: `POST {base}/openai/v1/chat/completions`
///   or `POST {base}/openai/v1/responses`.
///
/// An API key goes in the `api-key` header, a bearer token (for example from
/// Microsoft Entra ID) in `Authorization: Bearer`.
public struct AzureOpenAIProvider: AIProvider {
    public let configuration: AIProviderConfiguration
    private let client: OpenAIFamilyClient

    init(configuration: AIProviderConfiguration, baseUrl: URLComponents, http: ProviderHTTPClient) {
        self.configuration = configuration
        let headers: [String: String] =
            switch configuration.credential {
            case .apiKey(let secret): ["api-key": secret]
            case .bearer(let secret): ["Authorization": "Bearer \(secret)"]
            case .none: [:]
            }
        // Trimmed of JavaScript whitespace (a pasted value can end in a
        // newline). Blank means no version.
        let apiVersion = configuration.azureApiVersion.flatMap { version -> String? in
            let trimmed = JSCompat.trim(version)
            return trimmed.isEmpty ? nil : trimmed
        }
        client = OpenAIFamilyClient(
            configuration: configuration,
            http: http,
            makeURL: { wireApi, model in
                try Self.endpoint(baseUrl: baseUrl, wireApi: wireApi, model: model, apiVersion: apiVersion)
            },
            headers: headers,
            splitsThinkTags: false
        )
    }

    static func endpoint(baseUrl: URLComponents, wireApi: BYOKWireApi, model: String, apiVersion: String?) throws -> URL {
        var root = baseUrl.appendingPath("")
        var path = root.trimmedPath
        for suffix in ["/openai/v1", "/openai"] where path.hasSuffix(suffix) {
            path.removeLast(suffix.count)
            break
        }
        root.percentEncodedPath = path

        guard let apiVersion else {
            return try root.appendingPath(wireApi == .responses ? "/openai/v1/responses" : "/openai/v1/chat/completions")
                .requireURL()
        }

        var components: URLComponents
        switch wireApi {
        case .completions:
            var segment = CharacterSet.urlPathAllowed
            segment.remove("/")
            let deployment = model.addingPercentEncoding(withAllowedCharacters: segment) ?? model
            components = root.appendingPath("/openai/deployments/\(deployment)/chat/completions")
        case .responses:
            components = root.appendingPath("/openai/responses")
        }
        var queryItems = (components.queryItems ?? []).filter { $0.name != "api-version" }
        queryItems.append(URLQueryItem(name: "api-version", value: apiVersion))
        components.queryItems = queryItems
        return try components.requireURL()
    }

    public func complete(_ request: AIRequest) async throws -> AIResponse {
        try await client.complete(request)
    }

    public func stream(
        _ request: AIRequest,
        onEvent: @escaping @Sendable (AIStreamEvent) -> Void
    ) async throws -> AIResponse {
        try await client.stream(request, onEvent: onEvent)
    }
}
