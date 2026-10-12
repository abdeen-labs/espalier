// Requests to a server whose certificate isn't trusted fail with
// `UntrustedCertificateError`.

import Foundation
@testable import GitHubKit
import TestSupport
import Testing

@Suite("Untrusted certificates", .offline)
struct UntrustedCertificateTests {
    let mock = MockGitHub()

    @Test("an API request to a server with an untrusted certificate fails with the server's host")
    func apiRequest() async throws {
        mock.on("GET", "/repos/octocat/hello/pulls/1", respond: .networkError(.serverCertificateHasUnknownRoot))
        let api = API(endpoint: getDotComAPIEndpoint(), token: "token", runtime: mock.runtime)

        let error = await #expect(throws: UntrustedCertificateError.self) {
            try await api.fetchPullRequest(owner: "octocat", name: "hello", prNumber: "1")
        }
        #expect(error?.host == "api.github.com")
    }

    @Test("other network failures stay what they were")
    func otherFailures() async throws {
        mock.on("GET", "/repos/octocat/hello/pulls/1", respond: .networkError(.secureConnectionFailed))
        let api = API(endpoint: getDotComAPIEndpoint(), token: "token", runtime: mock.runtime)

        let error = await #expect(throws: URLError.self) {
            try await api.fetchPullRequest(owner: "octocat", name: "hello", prNumber: "1")
        }
        #expect(error?.code == .secureConnectionFailed)
        #expect(!UntrustedCertificateError.isUntrustedCertificate(URLError(.cannotConnectToHost)))
    }

    @Test("signing in to a server with an untrusted certificate says so instead of a generic failure")
    func deviceFlow() async throws {
        mock.on("POST", "/login/device/code", respond: .networkError(.serverCertificateUntrusted))
        let flow = DeviceFlow(runtime: mock.runtime)

        await #expect(throws: UntrustedCertificateError(host: "github.com")) {
            try await flow.requestDeviceCode()
        }
    }
}
