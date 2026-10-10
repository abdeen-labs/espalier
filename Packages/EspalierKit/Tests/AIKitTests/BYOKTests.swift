// Ported from desktop/app/test/unit/copilot-byok-test.ts

@testable import AIKit
import EspalierSupport
import Foundation
import Testing

private let sampleProvider = BYOKProvider(
    id: "p1",
    name: "OpenAI",
    type: .openai,
    baseUrl: "https://api.openai.com/v1",
    wireApi: .completions,
    authKind: .apiKey,
    models: [BYOKModel(id: "gpt-4o", name: "GPT-4o", reasoningEffort: .medium)]
)

/// The provider as its stored JSON object.
private let sampleProviderJSON = """
    {"id":"p1","name":"OpenAI","type":"openai","baseUrl":"https://api.openai.com/v1","wireApi":"completions",\
    "authKind":"apiKey","models":[{"id":"gpt-4o","name":"GPT-4o","reasoningEffort":"medium"}]}
    """

private func load(_ json: String) -> [BYOKProvider] {
    loadBYOKProviders(from: Data(json.utf8))
}

@Suite("byok storage")
struct BYOKStorageTests {
    @Test("round-trips providers through localStorage")
    func roundTrips() throws {
        let saved = try saveBYOKProviders([sampleProvider])
        #expect(loadBYOKProviders(from: saved) == [sampleProvider])
    }

    @Test("returns an empty list when no providers have been stored")
    func emptyWhenNothingStored() {
        #expect(loadBYOKProviders(from: nil) == [])
    }

    @Test("removes the storage entry when saving an empty list")
    func removesWhenEmpty() throws {
        #expect(try saveBYOKProviders([sampleProvider]) != nil)
        #expect(try saveBYOKProviders([]) == nil)
    }

    @Test("filters out entries that fail validation")
    func filtersInvalidEntries() {
        // The second entry is missing baseUrl and models.
        #expect(load(#"[\#(sampleProviderJSON), {"id":"x","name":"Bad","type":"openai"}]"#) == [sampleProvider])
    }

    // What the app reads back from the stored format.

    @Test("rejects present-but-null optional fields and non-positive timeouts, as desktop does")
    func rejectsNullsAndBadTimeouts() {
        let base = #""id":"p","name":"N","type":"openai","baseUrl":"https://h""#
        let valid = #"\#(base),"authKind":"none","models":[]"#
        #expect(load("[{\(valid)}]").count == 1)
        #expect(load(#"[{\#(valid),"wireApi":null}]"#).isEmpty)
        #expect(load(#"[{\#(valid),"wireApi":"chat"}]"#).isEmpty)
        #expect(load(#"[{\#(valid),"azureApiVersion":5}]"#).isEmpty)
        #expect(load(#"[{\#(valid),"requestTimeoutSeconds":0}]"#).isEmpty)
        #expect(load(#"[{\#(valid),"requestTimeoutSeconds":-1}]"#).isEmpty)
        #expect(load(#"[{\#(valid),"requestTimeoutSeconds":"30"}]"#).isEmpty)
        #expect(load(#"[{\#(valid),"requestTimeoutSeconds":30}]"#).first?.requestTimeoutSeconds == 30)
        #expect(load(#"[{\#(base),"authKind":"none","models":[{"id":"m","name":"M","reasoningEffort":"max"}]}]"#).isEmpty)
        #expect(load(#"[{\#(base),"authKind":"none","models":[{"id":"m","name":"M","reasoningEffort":null}]}]"#).isEmpty)
        #expect(load(#"[{\#(base),"authKind":"none","models":[{"id":"m","name":"M","reasoningEffort":"xhigh"}]}]"#).count == 1)
        #expect(load(#"[{\#(base),"authKind":"oauth","models":[]}]"#).isEmpty)
        #expect(load(#"{"providers":[]}"#).isEmpty)
    }

    @Test("omits absent optional fields when saving")
    func omitsAbsentFields() throws {
        let provider = BYOKProvider(
            id: "p", name: "N", type: .anthropic, baseUrl: "https://api.anthropic.com", authKind: .none,
            models: [BYOKModel(id: "m", name: "M")]
        )
        let json = try JSONValue.parse(try #require(try saveBYOKProviders([provider])))
        #expect(
            json == [
                [
                    "id": "p", "name": "N", "type": "anthropic", "baseUrl": "https://api.anthropic.com",
                    "authKind": "none", "models": [["id": "m", "name": "M"]],
                ],
            ]
        )
    }

    // Written as `null`, an invalid timeout would make the loader drop the
    // provider. And a failed encoding must not look like an empty list, which
    // means "remove every stored provider".
    @Test("saves an invalid timeout as no timeout instead of losing the provider")
    func invalidTimeoutsOnSave() throws {
        for timeout in [Double.nan, .infinity, -.infinity, 0, -5] {
            var provider = sampleProvider
            provider.requestTimeoutSeconds = timeout
            let saved = try #require(try saveBYOKProviders([provider]), "\(timeout)")
            var expected = provider
            expected.requestTimeoutSeconds = nil
            #expect(loadBYOKProviders(from: saved) == [expected], "\(timeout)")
        }
        var long = sampleProvider
        long.requestTimeoutSeconds = 1e300
        #expect(loadBYOKProviders(from: try saveBYOKProviders([long])) == [long])
    }

    @Test("reads the stored JSON the way JSON.parse does")
    func strictJSON() {
        let second = sampleProviderJSON.replacingOccurrences(of: #""id":"p1""#, with: #""id":"p2""#)
        // A trailing comma or a byte order mark makes the whole value
        // malformed.
        #expect(load("[\(sampleProviderJSON),]").isEmpty)
        #expect(load("\u{FEFF}[\(sampleProviderJSON)]").isEmpty)
        // A repeated key takes its last value.
        #expect(load(#"[{"id":"x",\#(sampleProviderJSON.dropFirst())]"#).map(\.id) == ["p1"])
        // A timeout too large for a double is infinity, so that provider is
        // invalid; the rest still load.
        let infinite = second.replacingOccurrences(of: #""authKind":"apiKey""#, with: #""authKind":"apiKey","requestTimeoutSeconds":1e999"#)
        #expect(load("[\(sampleProviderJSON),\(infinite)]").map(\.id) == ["p1"])
        // Unknown fields don't matter, whatever they hold.
        let extra = second.replacingOccurrences(of: #""authKind":"apiKey""#, with: #""authKind":"apiKey","extra":[1e999,"\ud800"]"#)
        #expect(load("[\(sampleProviderJSON),\(extra)]").map(\.id) == ["p1", "p2"])
        // Enum values are compared by code units: a Kelvin sign is not a K.
        let kelvin = sampleProviderJSON.replacingOccurrences(of: #""apiKey""#, with: #""apiKey""#)
        #expect(load("[\(kelvin)]").isEmpty)
    }
}

@Suite("byok secrets")
struct BYOKSecretTests {
    @Test("stores secrets under the AI provider service with the provider ID as the account")
    func storesSecrets() async throws {
        let store = InMemorySecretStore()
        #expect(try await getBYOKSecret("p1", store: store) == nil)
        try await setBYOKSecret("p1", "sk-test", store: store)
        #expect(try store.secret(service: "Espalier - AI provider", account: "p1") == "sk-test")
        #expect(try await getBYOKSecret("p1", store: store) == "sk-test")
        #expect(try await deleteBYOKSecret("p1", store: store))
        #expect(try await !deleteBYOKSecret("p1", store: store))
        #expect(try await getBYOKSecret("p1", store: store) == nil)
    }
}

@Suite("encode/parseModelKey")
struct ModelKeyTests {

    @Test("round-trips byok keys")
    func roundTripsByokKeys() {
        let key = AIModelKey(providerId: "abc", modelId: "llama3")
        #expect(encodeModelKey(key) == "byok:abc:llama3")
        #expect(parseModelKey(encodeModelKey(key)) == key)
    }

    // Adapted from "treats legacy bare strings as copilot model IDs": bare
    // model IDs and `copilot:` keys select nothing.
    @Test("treats legacy bare strings and copilot keys as no selection")
    func legacyKeysSelectNothing() {
        #expect(parseModelKey("claude-sonnet") == nil)
        #expect(parseModelKey("copilot:gpt-5-mini") == nil)
    }

    @Test("handles model IDs that contain colons")
    func modelIdsWithColons() {
        let key = AIModelKey(providerId: "p", modelId: "llama3:latest")
        #expect(parseModelKey(encodeModelKey(key)) == key)
    }

    // Adapted from "falls back to an empty copilot model on a malformed BYOK key".
    @Test("falls back to no selection on a malformed BYOK key")
    func malformedKeys() {
        #expect(parseModelKey("byok:") == nil)
        #expect(parseModelKey("byok:onlyone") == nil)
        #expect(parseModelKey("byok::model") == nil)
        #expect(parseModelKey("byok:provider:") == nil)
    }
}

@Suite("isValidBYOKBaseUrl")
struct ValidBaseUrlTests {
    @Test("accepts https URLs")
    func acceptsHttps() {
        #expect(isValidBYOKBaseUrl("https://api.openai.com/v1"))
    }

    @Test("accepts http URLs that point at the local machine")
    func acceptsLocalHttp() {
        #expect(isValidBYOKBaseUrl("http://localhost:11434/v1"))
        #expect(isValidBYOKBaseUrl("http://127.0.0.1:11434/"))
        #expect(isValidBYOKBaseUrl("http://[::1]:11434/"))
    }

    @Test("rejects http URLs that point at non-loopback hosts")
    func rejectsRemoteHttp() {
        #expect(!isValidBYOKBaseUrl("http://api.openai.com/v1"))
        #expect(!isValidBYOKBaseUrl("http://192.168.1.5/"))
        #expect(!isValidBYOKBaseUrl("http://0.0.0.0:11434/"))
    }

    @Test("rejects ftp:// and other non-http schemes")
    func rejectsOtherSchemes() {
        #expect(!isValidBYOKBaseUrl("ftp://example.com/"))
        #expect(!isValidBYOKBaseUrl("data:text/plain,hi"))
    }

    @Test("rejects strings that are not absolute URLs")
    func rejectsRelative() {
        #expect(!isValidBYOKBaseUrl(""))
        #expect(!isValidBYOKBaseUrl("not a url"))
        #expect(!isValidBYOKBaseUrl("/api/v1"))
    }

    @Test("validates the host requests actually go to")
    func validatesRequestHost() {
        // WHATWG reads the host as localhost; Foundation, and so the
        // request, goes to evil.com.
        #expect(!isValidBYOKBaseUrl("http://localhost\\@evil.com/"))
        #expect(!isValidBYOKBaseUrl("http://localhost.evil.com/"))
        #expect(isValidBYOKBaseUrl("http://user:pw@localhost/"))
    }

    @Test("ignores case, surrounding spaces, and tabs or newlines, as the WHATWG parser does")
    func normalizesLikeWHATWG() {
        #expect(isValidBYOKBaseUrl("HTTPS://API.OPENAI.COM/v1"))
        #expect(isValidBYOKBaseUrl("HTTP://LOCALHOST:11434/v1"))
        #expect(isValidBYOKBaseUrl("  https://api.openai.com/v1\n"))
        #expect(isValidBYOKBaseUrl("https://api.open\tai.com/v1"))
    }

    @Test("rejects empty hosts and ports out of range")
    func rejectsEmptyHostsAndBadPorts() {
        #expect(!isValidBYOKBaseUrl("https://"))
        #expect(!isValidBYOKBaseUrl("https:///v1"))
        #expect(!isValidBYOKBaseUrl("https://example.com:99999/"))
    }
}

@Suite("loadBYOKProviders URL validation")
struct LoadURLValidationTests {
    @Test("rejects providers whose stored baseUrl is not http(s)")
    func rejectsNonHttpBaseUrls() {
        func provider(_ id: String, _ baseUrl: String) -> String {
            sampleProviderJSON.replacingOccurrences(of: #""id":"p1""#, with: #""id":"\#(id)""#)
                .replacingOccurrences(of: "https://api.openai.com/v1", with: baseUrl)
        }
        let loaded = load(
            "[\(sampleProviderJSON), \(provider("p2", "file:///etc/passwd")), "
                + "\(provider("p3", "javascript:alert(1)")), \(provider("p4", "not-a-url"))]"
        )
        #expect(loaded.map(\.id) == ["p1"])
    }
}

@Suite("isLocalBaseUrl")
struct LocalBaseUrlTests {
    @Test("matches the rest of the 127/8 loopback block")
    func matchesLoopbackBlock() {
        #expect(isLocalBaseUrl("http://127.0.0.2/"))
        #expect(isLocalBaseUrl("http://127.1.2.3/"))
    }

    @Test("does not match malformed 127/8 addresses")
    func doesNotMatchMalformed() {
        #expect(!isLocalBaseUrl("http://127.999.0.1/"))
    }

    @Test("matches every notation of the IPv6 loopback address and nothing else")
    func ipv6Notations() {
        #expect(isLocalBaseUrl("http://[0:0:0:0:0:0:0:1]/"))
        #expect(isLocalBaseUrl("http://[0000::0001]:8080/"))
        #expect(!isLocalBaseUrl("http://[::2]/"))
        #expect(!isLocalBaseUrl("http://[::]/"))
        #expect(!isLocalBaseUrl("http://[::ffff:127.0.0.1]/"))
        #expect(!isLocalBaseUrl("http://[::1%25lo0]/"))
    }

    @Test("needs strict dotted-decimal IPv4 and the exact name localhost")
    func strictHosts() {
        #expect(isLocalBaseUrl("http://LocalHost/"))
        #expect(isLocalBaseUrl("http://127.255.255.255/"))
        #expect(!isLocalBaseUrl("http://127.0.0.256/"))
        #expect(!isLocalBaseUrl("http://127.0.0.01/"))
        #expect(!isLocalBaseUrl("http://127.1/"))
        #expect(!isLocalBaseUrl("http://127.0.0.1.evil.com/"))
        #expect(!isLocalBaseUrl("http://localhost./"))
        #expect(!isLocalBaseUrl("http://sub.localhost/"))
        #expect(!isLocalBaseUrl("http://128.0.0.1/"))
    }
}

@Suite("requiresNewBYOKSecret")
struct RequiresNewSecretTests {
    private var apiKeyProvider: BYOKProvider {
        var provider = sampleProvider
        provider.authKind = .apiKey
        return provider
    }

    private var bearerProvider: BYOKProvider {
        var provider = sampleProvider
        provider.authKind = .bearer
        return provider
    }

    @Test("never requires a secret when the new auth kind is none")
    func neverForNone() {
        #expect(!requiresNewBYOKSecret(.none, nil))
        #expect(!requiresNewBYOKSecret(.none, apiKeyProvider))
    }

    @Test("requires a secret for new (non-none) providers")
    func requiredForNewProviders() {
        #expect(requiresNewBYOKSecret(.apiKey, nil))
        #expect(requiresNewBYOKSecret(.bearer, nil))
    }

    @Test("does not require a new secret when editing with the same auth kind")
    func notRequiredForSameKind() {
        #expect(!requiresNewBYOKSecret(.apiKey, apiKeyProvider))
        #expect(!requiresNewBYOKSecret(.bearer, bearerProvider))
    }

    @Test("requires a new secret when switching between apiKey and bearer")
    func requiredWhenSwitching() {
        #expect(requiresNewBYOKSecret(.bearer, apiKeyProvider))
        #expect(requiresNewBYOKSecret(.apiKey, bearerProvider))
    }
}
