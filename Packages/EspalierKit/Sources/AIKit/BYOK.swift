// Ported from desktop/app/src/lib/copilot/byok.ts

import Darwin
import EspalierSupport
import Foundation

/// The kind of API a provider speaks. AIKit has a client for each (see
/// `makeAIProvider`).
public enum BYOKProviderType: String, Sendable, Hashable, Codable, CaseIterable {
    /// OpenAI or any OpenAI-compatible server (Ollama, LM Studio, vLLM, ...).
    case openai
    /// Azure OpenAI.
    case azure
    /// Anthropic's Messages API.
    case anthropic
}

/// OpenAI-compatible wire API format.
public enum BYOKWireApi: String, Sendable, Hashable, Codable, CaseIterable {
    /// Chat Completions, `POST {baseUrl}/chat/completions`. The default.
    case completions
    /// Responses, `POST {baseUrl}/responses`.
    case responses
}

/// Authentication mode used by a provider. `none` is allowed for local
/// providers like Ollama.
public enum BYOKAuthKind: String, Sendable, Hashable, Codable, CaseIterable {
    case apiKey
    case bearer
    case none
}

/// A user-declared model offered by a provider. Because the provider's
/// `/models` endpoint isn't probed, the user supplies the metadata.
public struct BYOKModel: Sendable, Hashable, Codable {
    /// Model ID sent to the provider (e.g. `gpt-4o`, `llama3`). For Azure
    /// with an API version, the deployment name.
    public var id: String
    /// Human-readable name shown in the UI.
    public var name: String
    /// The reasoning effort to send when invoking this model. Set for
    /// reasoning models that support an explicit thinking effort (`o3`,
    /// GPT-5 reasoning variants, Claude models with extended thinking,
    /// etc.); leave `nil` for non-reasoning models.
    public var reasoningEffort: ReasoningEffort?

    public init(id: String, name: String, reasoningEffort: ReasoningEffort? = nil) {
        self.id = id
        self.name = name
        self.reasoningEffort = reasoningEffort
    }

    /// Decodes a valid model only. A key that is present must have the right
    /// type: `"reasoningEffort": null` is invalid.
    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        name = try container.decode(String.self, forKey: .name)
        reasoningEffort = try container.decodeExactlyUnlessAbsent(ReasoningEffort.self, forKey: .reasoningEffort)
    }
}

/// Whether a provider's request timeout, in seconds, is usable: a positive
/// finite number. Shared by loading stored providers
/// (`BYOKProvider.init(from:)`) and the provider form
/// (`validateBYOKProviderForm`).
///
/// Very large values are valid; requests clamp them to
/// `MaxAIRequestTimeoutSeconds`.
public func isValidBYOKRequestTimeout(_ seconds: Double) -> Bool {
    seconds.isFinite && seconds > 0
}

/// A user-configured AI provider. Secrets (API key or bearer token) are
/// stored separately in the keychain and never persisted on this value.
public struct BYOKProvider: Sendable, Hashable, Codable, Identifiable {
    /// Stable identifier (UUID) used as the keychain account and selection key.
    public var id: String
    /// Human-readable provider name shown in settings and model pickers.
    public var name: String
    /// Provider type, which selects the client.
    public var type: BYOKProviderType
    /// API endpoint URL.
    public var baseUrl: String
    /// Wire API format (openai and azure only).
    public var wireApi: BYOKWireApi?
    /// Azure-specific API version override. When omitted, Azure requests use
    /// the versionless `/openai/v1` routes.
    public var azureApiVersion: String?
    /// How the provider is authenticated.
    public var authKind: BYOKAuthKind
    /// Optional per-provider request timeout in seconds, used for requests
    /// to this provider. When omitted the default is used
    /// (`DefaultAIRequestTimeoutMs` for commit messages,
    /// `DefaultConflictResolutionTimeoutMs` for conflict resolution).
    public var requestTimeoutSeconds: Double?
    /// Models exposed by this provider.
    public var models: [BYOKModel]

    public init(
        id: String,
        name: String,
        type: BYOKProviderType,
        baseUrl: String,
        wireApi: BYOKWireApi? = nil,
        azureApiVersion: String? = nil,
        authKind: BYOKAuthKind,
        requestTimeoutSeconds: Double? = nil,
        models: [BYOKModel]
    ) {
        self.id = id
        self.name = name
        self.type = type
        self.baseUrl = baseUrl
        self.wireApi = wireApi
        self.azureApiVersion = azureApiVersion
        self.authKind = authKind
        self.requestTimeoutSeconds = requestTimeoutSeconds
        self.models = models
    }

    /// Decodes a valid provider only: the base URL must pass
    /// `isValidBYOKBaseUrl`, every model must be valid, and a request timeout
    /// must be a positive number.
    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        name = try container.decode(String.self, forKey: .name)
        baseUrl = try container.decode(String.self, forKey: .baseUrl)
        guard isValidBYOKBaseUrl(baseUrl) else {
            throw DecodingError.dataCorruptedError(
                forKey: .baseUrl, in: container, debugDescription: "Not an https URL or a local http URL"
            )
        }
        type = try container.decodeExactly(BYOKProviderType.self, forKey: .type)
        authKind = try container.decodeExactly(BYOKAuthKind.self, forKey: .authKind)
        wireApi = try container.decodeExactlyUnlessAbsent(BYOKWireApi.self, forKey: .wireApi)
        azureApiVersion = try container.decodeUnlessAbsent(String.self, forKey: .azureApiVersion)
        models = try container.decode([BYOKModel].self, forKey: .models)
        requestTimeoutSeconds = try container.decodeUnlessAbsent(Double.self, forKey: .requestTimeoutSeconds)
        if let timeout = requestTimeoutSeconds, !isValidBYOKRequestTimeout(timeout) {
            throw DecodingError.dataCorruptedError(
                forKey: .requestTimeoutSeconds, in: container, debugDescription: "Not a positive number"
            )
        }
    }
}

extension KeyedDecodingContainer {
    /// Decodes a key that may be absent. Unlike `decodeIfPresent`, a key that
    /// is present with a `null` value fails.
    func decodeUnlessAbsent<T: Decodable>(_ type: T.Type, forKey key: Key) throws -> T? {
        guard contains(key) else {
            return nil
        }
        return try decode(T.self, forKey: key)
    }

    /// Decodes a string enum whose raw value must match exactly, code unit
    /// for code unit. (A synthesized `Decodable` enum would also take a
    /// canonically equivalent string: `"api\u{212A}ey"`, with a Kelvin sign,
    /// for `apiKey`.)
    func decodeExactly<T: RawRepresentable & CaseIterable>(_ type: T.Type, forKey key: Key) throws -> T
    where T.RawValue == String {
        let raw = try decode(String.self, forKey: key)
        guard let value = T.allCases.first(where: { JSCompat.strictEquals($0.rawValue, raw) }) else {
            throw DecodingError.dataCorruptedError(forKey: key, in: self, debugDescription: "Unknown value")
        }
        return value
    }

    /// `decodeExactly` for a key that may be absent (but not `null`).
    func decodeExactlyUnlessAbsent<T: RawRepresentable & CaseIterable>(_ type: T.Type, forKey key: Key) throws -> T?
    where T.RawValue == String {
        guard contains(key) else {
            return nil
        }
        return try decodeExactly(T.self, forKey: key)
    }
}

// MARK: Storage

/// The providers read from their stored JSON.
public struct StoredBYOKProviders: Sendable, Hashable {
    /// The valid providers, in order.
    public var providers: [BYOKProvider]
    /// The stored entries that aren't valid providers (one written by a
    /// newer version, say), each as JSON. `saveBYOKProviders(_:keeping:)`
    /// writes them back, so an entry isn't lost for good and its secret
    /// isn't left without it.
    public var unloadable: [Data]

    public init(providers: [BYOKProvider], unloadable: [Data] = []) {
        self.providers = providers
        self.unloadable = unloadable
    }
}

/// Reads the providers from their stored JSON: the valid ones, and the
/// entries that fail validation, kept aside. Nothing has been stored, or the
/// stored value is malformed, gives neither.
///
/// The JSON is read the way `JSON.parse` reads it (see `JSONValue.parse`), so
/// a value with a trailing comma is malformed, a repeated key takes its last
/// value, and one provider with an out-of-range number (`1e999`) is set aside
/// on its own instead of failing the whole list, as it would with
/// `JSONDecoder`.
public func loadStoredBYOKProviders(from data: Data?) -> StoredBYOKProviders {
    guard let data, let elements = (try? JSONValue.parse(data))?.arrayValue else {
        return StoredBYOKProviders(providers: [])
    }
    // Each element is checked by `BYOKProvider.init(from:)`. Re-serializing
    // writes an infinity as `null`, which that check rejects.
    let decoder = JSONDecoder()
    var stored = StoredBYOKProviders(providers: [])
    for element in elements {
        let json = element.serialized()
        if let provider = try? decoder.decode(BYOKProvider.self, from: json) {
            stored.providers.append(provider)
        } else {
            stored.unloadable.append(json)
        }
    }
    return stored
}

/// The valid providers in their stored JSON (`loadStoredBYOKProviders`).
public func loadBYOKProviders(from data: Data?) -> [BYOKProvider] {
    loadStoredBYOKProviders(from: data).providers
}

/// Encodes the given list of providers for storage, followed by the stored
/// entries that didn't load (`StoredBYOKProviders.unloadable`), unchanged.
///
/// A request timeout that isn't a positive finite number (NaN, an infinity,
/// zero, or a negative number, which only code can set; the settings form
/// rejects them) is left out, so the provider loads back with the default
/// timeout.
///
/// - Returns: The JSON to store, or `nil` when there's nothing to store,
///   meaning the stored value should be removed.
/// - Throws: When the providers can't be encoded. A failure never returns
///   `nil`, so it can't be mistaken for "remove every provider".
public func saveBYOKProviders(_ providers: [BYOKProvider], keeping unloadable: [Data] = []) throws -> Data? {
    guard !providers.isEmpty || !unloadable.isEmpty else {
        return nil
    }
    let storable = providers.map { provider in
        var provider = provider
        if let timeout = provider.requestTimeoutSeconds, !isValidBYOKRequestTimeout(timeout) {
            provider.requestTimeoutSeconds = nil
        }
        return provider
    }
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
    var data = try encoder.encode(storable)
    guard !unloadable.isEmpty else {
        return data
    }
    // The encoder writes a compact array: `[`, the elements separated by
    // commas, `]`.
    data.removeLast()
    for entry in unloadable {
        if data.count > 1 {
            data.append(UInt8(ascii: ","))
        }
        data.append(entry)
    }
    data.append(UInt8(ascii: "]"))
    return data
}

// MARK: Secrets

/// The keychain service for provider secrets. The account is the provider ID.
public let BYOKSecretService = "Espalier - AI provider"

/// Returns the API key or bearer token stored in the keychain for the given
/// provider, or `nil` if none has been stored.
public func getBYOKSecret(_ providerId: String, store: any SecretStore = KeychainSecretStore()) async throws -> String? {
    try store.secret(service: BYOKSecretService, account: providerId)
}

/// Stores the given secret in the keychain for the given provider.
public func setBYOKSecret(
    _ providerId: String,
    _ secret: String,
    store: any SecretStore = KeychainSecretStore()
) async throws {
    try store.setSecret(secret, service: BYOKSecretService, account: providerId)
}

/// Removes any secret stored in the keychain for the given provider. Returns
/// whether one existed.
@discardableResult
public func deleteBYOKSecret(_ providerId: String, store: any SecretStore = KeychainSecretStore()) async throws -> Bool {
    try store.deleteSecret(service: BYOKSecretService, account: providerId)
}

// MARK: Model keys

/// A provider and model pair persisted in per-feature model selections.
public struct AIModelKey: Sendable, Hashable {
    public var providerId: String
    public var modelId: String

    public init(providerId: String, modelId: String) {
        self.providerId = providerId
        self.modelId = modelId
    }
}

private let ByokKeyPrefix = "byok:"

/// Encodes a model key to the string form persisted in model selections:
/// `byok:<providerId>:<modelId>`.
public func encodeModelKey(_ key: AIModelKey) -> String {
    "\(ByokKeyPrefix)\(key.providerId):\(key.modelId)"
}

/// Parses a persisted model selection. Returns `nil` for anything that isn't
/// a well-formed `byok:` key, including `copilot:` keys and bare model IDs,
/// so the feature has no selection rather than throwing.
///
/// The provider ID ends at the first colon; model IDs may contain colons
/// (`llama3:latest`).
public func parseModelKey(_ value: String) -> AIModelKey? {
    guard JSCompat.startsWith(value, ByokKeyPrefix) else {
        return nil
    }
    let rest = Array(value.unicodeScalars.dropFirst(ByokKeyPrefix.unicodeScalars.count))
    guard let separator = rest.firstIndex(of: ":"), separator > 0, separator < rest.count - 1 else {
        return nil
    }
    return AIModelKey(
        providerId: String(String.UnicodeScalarView(rest[..<separator])),
        modelId: String(String.UnicodeScalarView(rest[(separator + 1)...]))
    )
}

/// Returns true if saving a provider with the given new auth kind requires
/// the user to enter a fresh secret. The previously stored secret can be
/// relied on only when editing an existing provider that already used the
/// same auth kind; switching auth kinds (or adding a new provider) requires a
/// new credential because the keychain entry is missing or shaped wrong for
/// the new kind.
public func requiresNewBYOKSecret(_ newAuthKind: BYOKAuthKind, _ existingProvider: BYOKProvider?) -> Bool {
    if newAuthKind == .none {
        return false
    }
    guard let existingProvider else {
        return true
    }
    return existingProvider.authKind != newAuthKind
}

// MARK: Base URLs

/// Returns true if the given base URL points at the local machine: the host
/// is `localhost`, an IPv4 address in the 127/8 loopback block (RFC 1122
/// section 3.2.1.3), or the IPv6 loopback address in any notation. Used for the
/// "Local" badge and to allow plain http.
///
/// The host is read with Foundation's `URLComponents`, the parser
/// `URLSession` uses for the actual requests, so the host checked here is
/// always the host a request reaches. The WHATWG URL parser disagrees on some
/// inputs: for `http://localhost\@evil.com/` it reports `localhost` while
/// Foundation (and so the request) uses `evil.com`. Shorthand IPv4 forms that
/// WHATWG rewrites (`127.1`) are not treated as local.
public func isLocalBaseUrl(_ baseUrl: String) -> Bool {
    guard let components = parseBaseUrl(baseUrl), let host = components.percentEncodedHost else {
        return false
    }
    return isLoopbackHost(host)
}

/// Returns true if the given string parses as an absolute `http://` or
/// `https://` URL with a host. Used as the single source of truth for base
/// URL validation, in settings and when loading stored providers.
///
/// `http://` is only accepted when the host is on the local machine (see
/// `isLocalBaseUrl`); sending an API key to an arbitrary remote host over
/// plaintext HTTP would leak the credential to anyone on the network path.
public func isValidBYOKBaseUrl(_ value: String) -> Bool {
    guard let components = parseBaseUrl(value),
          let scheme = components.scheme?.lowercased(),
          let host = components.percentEncodedHost, !host.isEmpty
    else {
        return false
    }
    if let port = components.port, !(0...65535).contains(port) {
        return false
    }
    switch scheme {
    case "https":
        return true
    case "http":
        return isLoopbackHost(host)
    default:
        return false
    }
}

/// Parses a base URL the way requests use it. Like the WHATWG URL parser,
/// leading and trailing C0 controls and spaces are ignored and tabs and
/// newlines are removed; the rest is up to `URLComponents`.
func parseBaseUrl(_ value: String) -> URLComponents? {
    let isC0OrSpace: (Unicode.Scalar) -> Bool = { $0.value <= 0x20 }
    var scalars = Substring(value).unicodeScalars
    while let first = scalars.first, isC0OrSpace(first) {
        scalars.removeFirst()
    }
    while let last = scalars.last, isC0OrSpace(last) {
        scalars.removeLast()
    }
    let cleaned = String(String.UnicodeScalarView(scalars.filter { $0 != "\t" && $0 != "\n" && $0 != "\r" }))
    guard let components = URLComponents(string: cleaned), components.scheme != nil else {
        return nil
    }
    return components
}

/// Whether a URL host (as `URLComponents.percentEncodedHost` reports it)
/// names the local machine.
private func isLoopbackHost(_ host: String) -> Bool {
    if host.lowercased() == "localhost" {
        return true
    }

    // IPv6 hosts keep their brackets. Any notation of ::1 is loopback. The
    // WHATWG parser rejects zone IDs (`%25lo0`), so they aren't local here
    // either (inet_pton would ignore them).
    if host.hasPrefix("["), host.hasSuffix("]") {
        let address = String(host.dropFirst().dropLast())
        guard !address.contains("%") else {
            return false
        }
        var parsed = in6_addr()
        guard inet_pton(AF_INET6, address, &parsed) == 1 else {
            return false
        }
        let bytes = withUnsafeBytes(of: &parsed) { Array($0) }
        return bytes.dropLast().allSatisfy { $0 == 0 } && bytes.last == 1
    }

    // Any 127.0.0.0/8 address is loopback.
    return isIPv4(host) && host.hasPrefix("127.")
}

/// Node's `net.isIPv4`: four dot-separated decimal octets from 0 to 255,
/// without leading zeros.
private func isIPv4(_ string: String) -> Bool {
    let octets = string.split(separator: ".", omittingEmptySubsequences: false)
    guard octets.count == 4 else {
        return false
    }
    return octets.allSatisfy { octet in
        guard (1...3).contains(octet.count),
              octet.unicodeScalars.allSatisfy(JS.isASCIIDigit),
              octet.count == 1 || octet.first != "0",
              let value = Int(octet)
        else {
            return false
        }
        return value <= 255
    }
}
