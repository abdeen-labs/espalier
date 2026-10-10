import EspalierSupport
import Testing

/// Checks against what JavaScript's `new URL()` gives for the same input.
@Suite("JSURL")
struct JSURLTests {
    @Test("normalizes like WHATWG URLs for special schemes")
    func normalizes() throws {
        let url = try JSURL("HTTPS://Joe:pw@Example.COM:443")
        #expect(url.protocol == "https:")
        #expect(url.username == "Joe")
        #expect(url.password == "pw")
        #expect(url.hostname == "example.com")
        #expect(url.port == "")
        #expect(url.host == "example.com")
        #expect(url.pathname == "/")
        #expect(url.origin == "https://example.com")
        #expect(url.href == "https://Joe:pw@example.com/")
    }

    @Test("keeps a non-default port, the path, query, and fragment")
    func parts() throws {
        let url = try JSURL("http://127.0.0.1:8080/owner/my%20repo.git?x=1#top")
        #expect(url.host == "127.0.0.1:8080")
        #expect(url.origin == "http://127.0.0.1:8080")
        #expect(url.pathname == "/owner/my%20repo.git")
        #expect(url.search == "?x=1")
        #expect(url.hash == "#top")
        #expect(url.href == "http://127.0.0.1:8080/owner/my%20repo.git?x=1#top")
    }

    @Test("keeps brackets around IPv6 hosts")
    func ipv6() throws {
        let url = try JSURL("http://[::1]:9418/repo")
        #expect(url.hostname == "[::1]")
        #expect(url.origin == "http://[::1]:9418")
    }

    @Test("rejects what isn't a URL")
    func invalid() {
        #expect(throws: JSURLError(input: "example.com")) {
            try JSURL("example.com")
        }
        #expect(throws: JSURLError.self) {
            try JSURL("https://exa mple.com/")
        }
    }

    @Test("encodes URI components like encodeURIComponent")
    func encodeURIComponent() {
        #expect(JSURL.encodeURIComponent("me@corp.com") == "me%40corp.com")
        #expect(JSURL.encodeURIComponent("a b/c?d") == "a%20b%2Fc%3Fd")
        #expect(JSURL.encodeURIComponent("-_.!~*'()") == "-_.!~*'()")
        #expect(JSURL.encodeURIComponent("é") == "%C3%A9")
    }
}
