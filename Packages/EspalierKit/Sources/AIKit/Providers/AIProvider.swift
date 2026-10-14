// AIKit makes requests itself, with one client per provider type. Both
// features are a system prompt plus one user message with no tools, so a
// client sends one request and returns one response, streaming it when the
// caller wants the model's live reasoning.

import Foundation

/// The credential sent with each request.
public enum AICredential: Sendable, Hashable {
    /// An API key: `Authorization: Bearer` for OpenAI-compatible providers,
    /// `api-key` for Azure, `x-api-key` for Anthropic.
    case apiKey(String)
    /// A bearer token: `Authorization: Bearer` for every provider type.
    case bearer(String)
    /// No credentials, for local servers.
    case none
}

/// Printing, dumping, or interpolating a credential never shows the secret,
/// so it can't end up in logs or test output.
extension AICredential: CustomStringConvertible, CustomDebugStringConvertible, CustomReflectable {
    public var description: String {
        switch self {
        case .apiKey: "apiKey(<redacted>)"
        case .bearer: "bearer(<redacted>)"
        case .none: "none"
        }
    }

    public var debugDescription: String { description }

    public var customMirror: Mirror {
        Mirror(self, children: [])
    }
}

/// The session AIKit uses unless the app passes another: ephemeral, with no
/// cookies and no cache, so nothing from requests or responses is stored.
public let defaultAIURLSession: URLSession = {
    let configuration = URLSessionConfiguration.ephemeral
    configuration.httpCookieStorage = nil
    configuration.httpShouldSetCookies = false
    configuration.urlCache = nil
    configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
    return URLSession(configuration: configuration)
}()

/// Everything a client needs to reach a provider, plus the provider's name
/// for messages.
public struct AIProviderConfiguration: Sendable, Hashable {
    /// The provider's name from settings, for messages.
    public var name: String
    public var type: BYOKProviderType
    public var baseUrl: String
    /// OpenAI and Azure only; `nil` means Chat Completions.
    public var wireApi: BYOKWireApi?
    /// Azure only; `nil` means the versionless `/openai/v1` routes.
    public var azureApiVersion: String?
    public var credential: AICredential

    public init(
        name: String,
        type: BYOKProviderType,
        baseUrl: String,
        wireApi: BYOKWireApi? = nil,
        azureApiVersion: String? = nil,
        credential: AICredential
    ) {
        self.name = name
        self.type = type
        self.baseUrl = baseUrl
        self.wireApi = wireApi
        self.azureApiVersion = azureApiVersion
        self.credential = credential
    }
}

/// One model turn: a system prompt and one user message.
public struct AIRequest: Sendable, Hashable {
    /// The model ID (for Azure with an API version, the deployment name).
    public var model: String
    public var systemPrompt: String
    public var userPrompt: String
    /// Sent as each API's reasoning parameter when set.
    public var reasoningEffort: ReasoningEffort?
    /// The output token limit. Anthropic requires one; OpenAI-compatible
    /// requests omit it so each server applies the model's own limit.
    public var maxOutputTokens: Int?
    /// How long the whole call may take: every HTTP attempt (retries of
    /// transient failures and fallbacks to another form of the request
    /// included) and streaming the response. When it passes, the request is
    /// cancelled and the call throws `AIProviderError` of kind `timedOut`.
    /// Anything longer than `MaxAIRequestTimeoutSeconds` is clamped to it.
    public var timeout: Duration

    public init(
        model: String,
        systemPrompt: String,
        userPrompt: String,
        reasoningEffort: ReasoningEffort? = nil,
        maxOutputTokens: Int? = nil,
        timeout: Duration
    ) {
        self.model = model
        self.systemPrompt = systemPrompt
        self.userPrompt = userPrompt
        self.reasoningEffort = reasoningEffort
        self.maxOutputTokens = maxOutputTokens
        self.timeout = timeout
    }
}

/// The longest timeout a request uses, in seconds: one year. Longer timeouts
/// (any positive finite `requestTimeoutSeconds` is valid) are clamped to it,
/// so converting them never overflows.
public let MaxAIRequestTimeoutSeconds: Double = 31_536_000

/// `timeout` limited to `MaxAIRequestTimeoutSeconds`, and to zero below.
func clampedRequestTimeout(_ timeout: Duration) -> Duration {
    min(max(timeout, .zero), .seconds(Int64(MaxAIRequestTimeoutSeconds)))
}

/// A complete model response.
public struct AIResponse: Sendable, Hashable {
    /// The assistant's text: the authoritative content.
    public var content: String
    /// The model's visible reasoning (a summary for most hosted models), or
    /// empty.
    public var reasoning: String
    /// The provider's stop or finish reason, when it sent one.
    public var stopReason: String?

    public init(content: String, reasoning: String = "", stopReason: String? = nil) {
        self.content = content
        self.reasoning = reasoning
        self.stopReason = stopReason
    }

    /// Whether the response ended because it reached a limit rather than
    /// because the model finished: the output limit (Anthropic's
    /// `max_tokens`, Chat Completions' `length`, the Responses API's
    /// `max_output_tokens`) or the context window (Anthropic's
    /// `model_context_window_exceeded`).
    public var reachedOutputLimit: Bool {
        switch stopReason {
        case "max_tokens", "length", "max_output_tokens", "model_context_window_exceeded": true
        default: false
        }
    }
}

/// An increment of a streamed response.
public enum AIStreamEvent: Sendable, Hashable {
    /// More of the model's reasoning.
    case reasoning(String)
    /// More of the response text.
    case content(String)
}

/// A client for one provider.
///
/// Both calls honor Swift task cancellation (they throw `CancellationError`
/// and cancel the HTTP request) and the request's timeout. Failures are
/// `AIProviderError`. Like the providers' own SDKs, the clients retry
/// rate limits, server errors, and connection failures twice, before any of
/// the response has been passed on.
public protocol AIProvider: Sendable {
    var configuration: AIProviderConfiguration { get }

    /// Sends the request and waits for the complete response.
    func complete(_ request: AIRequest) async throws -> AIResponse

    /// Sends the request and streams the response, calling `onEvent` with
    /// each reasoning and content increment as it arrives. Returns the
    /// complete response.
    func stream(_ request: AIRequest, onEvent: @escaping @Sendable (AIStreamEvent) -> Void) async throws -> AIResponse
}

/// Creates the client for a provider's type: `OpenAIProvider`,
/// `AzureOpenAIProvider`, or `AnthropicProvider`.
///
/// Throws `AIProviderError` of kind `invalidConfiguration` when the base URL
/// fails `isValidBYOKBaseUrl`, so credentials are never sent over plain http
/// to a remote host, even if a configuration skipped validation.
public func makeAIProvider(
    _ configuration: AIProviderConfiguration,
    session: URLSession = defaultAIURLSession
) throws -> any AIProvider {
    try makeAIProvider(configuration, session: session, retryPolicy: .standard)
}

/// `makeAIProvider(_:session:)` with another retry policy, for tests.
func makeAIProvider(
    _ configuration: AIProviderConfiguration,
    session: URLSession,
    retryPolicy: RetryPolicy
) throws -> any AIProvider {
    guard isValidBYOKBaseUrl(configuration.baseUrl), let baseUrl = parseBaseUrl(configuration.baseUrl) else {
        throw AIProviderError(kind: .invalidConfiguration, message: getFallbackErrorMessage(.invalidConfiguration))
    }
    let http = ProviderHTTPClient(session: session, retryPolicy: retryPolicy)
    switch configuration.type {
    case .openai:
        return OpenAIProvider(configuration: configuration, baseUrl: baseUrl, http: http)
    case .azure:
        return AzureOpenAIProvider(configuration: configuration, baseUrl: baseUrl, http: http)
    case .anthropic:
        return AnthropicProvider(configuration: configuration, baseUrl: baseUrl, http: http)
    }
}
