// Ported from desktop/app/test/unit/git/environment-test.ts

import GitKit
import Testing
import TestSupport

@Suite("git/environment")
struct EnvironmentTests {
    struct SuchError: Error {}

    static let httpProxyUrl = "http://proxy:8888/"
    static let httpsProxyUrl = "https://proxy:8888/"

    static let nullResolver: @Sendable (String) async throws -> String? = { _ in nil }
    static let throwingResolver: @Sendable (String) async throws -> String? = { _ in throw SuchError() }
    static let defaultResolver: @Sendable (String) async throws -> String? = { url in
        if url.hasPrefix("http://") {
            return httpProxyUrl
        } else if url.hasPrefix("https://") {
            return httpsProxyUrl
        } else {
            return nil
        }
    }

    @Suite("envForProxy")
    struct EnvForProxy {
        @Test("sets the correct environment variable based on protocol")
        func setsVariableByProtocol() async {
            #expect(await envForProxy("https://github.com/", env: [:], resolve: defaultResolver) == ["https_proxy": httpsProxyUrl])
            #expect(await envForProxy("http://github.com/", env: [:], resolve: defaultResolver) == ["http_proxy": httpProxyUrl])
        }

        @Test("sets no variables without a proxy for the URL", arguments: [
            NamedCase("fails gracefully if resolver throws", (url: "https://github.com/", resolve: throwingResolver)),
            NamedCase("it doesn't set any variables if resolver returns undefined", (url: "https://github.com/", resolve: nullResolver)),
            NamedCase("ignores unknown protocols", (url: "ftp://github.com/", resolve: defaultResolver)),
        ])
        func noVariables(_ testCase: NamedCase<(url: String, resolve: @Sendable (String) async throws -> String?)>) async {
            let (url, resolve) = testCase.value
            #expect(await envForProxy(url, env: [:], resolve: resolve) == nil)
        }

        @Test("does not override existing environment variables")
        func doesNotOverrideExisting() async {
            #expect(await envForProxy("https://github.com/", env: ["https_proxy": "foo"], resolve: defaultResolver) == nil)
            #expect(await envForProxy("https://github.com/", env: ["HTTPS_PROXY": "foo"], resolve: defaultResolver) == nil)
            #expect(await envForProxy("http://github.com/", env: ["http_proxy": "foo"], resolve: defaultResolver) == nil)
            #expect(await envForProxy("https://github.com/", env: ["ALL_PROXY": "foo"], resolve: defaultResolver) == nil)
            #expect(await envForProxy("https://github.com/", env: ["all_proxy": "foo"], resolve: defaultResolver) == nil)
        }
    }
}
