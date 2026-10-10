// Ported from desktop/app/test/unit/oauth-token-test.ts
//
// The token request tests run against the device flow's token request
// (`DeviceFlow.requestAccessToken`), with the device code grant.

import Foundation
@testable import GitHubKit
import TestSupport
import Testing

private let issuedAt: Double = 1_700_000_000_000
private let tokenResponse: [String: JSONValue] = [
    "access_token": "new-access-token",
    "refresh_token": "new-refresh-token",
    "expires_in": 28800,
    "refresh_token_expires_in": 15_897_600,
    "token_type": "bearer",
    "scope": "repo,user,workflow",
]

/// `tokenResponse` with `key` replaced, or removed when `value` is nil.
private func tokenResponse(_ key: String, _ value: JSONValue?) -> JSONValue {
    var response = tokenResponse
    response[key] = value
    return .object(response)
}

/// The `rejects invalid ${field} (${String(value)})` tests, named as the
/// template literal names them: every kind of invalid `expires_in`, and one
/// `refresh_token_expires_in`, which the same validation reads.
private let invalidLifetimeCases: [NamedCase<(field: String, value: JSONValue)>] = {
    let values: [(value: JSONValue, string: String)] = [
        (.null, "null"),
        ("3600", "3600"),
        (-1, "-1"),
        (1.5, "1.5"),
        (.number(9_007_199_254_740_991), "9007199254740991"),
    ]
    let cases = values.map { (field: "expires_in", value: $0) } + [(field: "refresh_token_expires_in", value: values[1])]
    return cases.map { NamedCase("rejects invalid \($0.field) (\($0.value.string))", (field: $0.field, value: $0.value.value)) }
}()

@Suite("parseOAuthToken")
struct ParseOAuthTokenTests {
    @Test("parses rotating credentials and absolute expiration times")
    func parsesRotatingCredentials() throws {
        #expect(try parseOAuthToken(.object(tokenResponse), issuedAt: issuedAt) == OAuthToken(
            accessToken: "new-access-token",
            refreshToken: "new-refresh-token",
            expiresAt: 1_700_000_000_000 + 28_800_000,
            refreshTokenExpiresAt: 1_700_000_000_000 + 15_897_600_000
        ))
    }

    @Test("accepts legacy credentials without inventing metadata")
    func acceptsLegacyCredentials() throws {
        #expect(try parseOAuthToken(["access_token": "legacy-token"], issuedAt: issuedAt) == OAuthToken(accessToken: "legacy-token"))
    }

    @Test("keeps missing lifetimes unknown even when a refresh token exists")
    func keepsMissingLifetimesUnknown() throws {
        #expect(
            try parseOAuthToken(["access_token": "access", "refresh_token": "refresh"], issuedAt: issuedAt)
                == OAuthToken(accessToken: "access", refreshToken: "refresh")
        )
    }

    @Test("accepts zero lifetimes as already expired")
    func acceptsZeroLifetimes() throws {
        var response = tokenResponse
        response["expires_in"] = 0
        response["refresh_token_expires_in"] = 0
        let token = try parseOAuthToken(.object(response), issuedAt: issuedAt)
        #expect(token.expiresAt == 1_700_000_000_000)
        #expect(token.refreshTokenExpiresAt == 1_700_000_000_000)
    }

    @Test("rejects malformed credentials without exposing their contents", arguments: [
        nil,
        "secret-response",
        [:],
        ["access_token": 123],
        ["access_token": ""],
        ["access_token": "token\nsecret"],
        tokenResponse("refresh_token", ""),
        tokenResponse("error", "secret-error"),
        tokenResponse("token_type", "unknown"),
        tokenResponse("scope", []),
        ["access_token": "access", "refresh_token_expires_in": 60],
    ] as [JSONValue?])
    func rejectsMalformedCredentials(value: JSONValue?) {
        #expect {
            try parseOAuthToken(value, issuedAt: issuedAt)
        } throws: { error in
            error as? OAuthTokenResponseError == OAuthTokenResponseError()
                && String(describing: error) == "The OAuth token response is invalid."
        }
    }

    @Test("rejects invalid lifetimes", arguments: invalidLifetimeCases)
    func rejectsInvalidLifetime(_ testCase: NamedCase<(field: String, value: JSONValue)>) {
        let (field, value) = testCase.value
        #expect(throws: OAuthTokenResponseError.self) {
            try parseOAuthToken(tokenResponse(field, value), issuedAt: issuedAt)
        }
    }

    @Test("rejects invalid issuance timestamps and overflowing expiration times")
    func rejectsInvalidIssuanceTimestamps() {
        for timestamp in [-1, 1.5] {
            #expect(throws: OAuthTokenResponseError.self) {
                try parseOAuthToken(.object(tokenResponse), issuedAt: timestamp)
            }
        }
        #expect(throws: OAuthTokenResponseError.self) {
            try parseOAuthToken(.object(tokenResponse), issuedAt: 9_007_199_254_740_991)
        }
    }
}

@Suite("OAuth token requests", .offline)
struct OAuthTokenRequestTests {
    private let mock = MockGitHub()
    private let path = "/login/oauth/access_token"

    private let authorization = DeviceAuthorization(
        deviceCode: "device-code",
        userCode: "WDJB-MJHT",
        verificationURI: "https://github.com/login/device",
        expiresAt: Date(timeIntervalSince1970: 1_800_000_000),
        interval: 5
    )

    private func flow(
        _ configuration: EndpointConfiguration = .dotCom,
        timeout: Duration = .seconds(30)
    ) -> DeviceFlow {
        DeviceFlow(
            configuration: configuration,
            runtime: mock.runtime,
            requestTimeout: timeout,
            now: { Date(timeIntervalSince1970: issuedAt / 1000) }
        )
    }

    private func expectFailure(
        _ expected: OAuthTokenRequestError,
        _ configuration: EndpointConfiguration = .dotCom,
        timeout: Duration = .seconds(30),
        sourceLocation: SourceLocation = #_sourceLocation
    ) async {
        await #expect(sourceLocation: sourceLocation) {
            _ = try await flow(configuration, timeout: timeout).requestAccessToken(authorization)
        } throws: { error in
            error as? OAuthTokenRequestError == expected && !String(describing: error).contains("secret")
        }
    }

    @Test("exchanges a code at the HTML endpoint", arguments: ["https://github.com", "https://enterprise.example/"].map {
        NamedCase("exchanges a code at the HTML endpoint \($0)", $0)
    })
    func exchangesCodeAtHTMLEndpoint(_ testCase: NamedCase<String>) async throws {
        let endpoint = testCase.value
        let configuration = endpoint == "https://github.com"
            ? EndpointConfiguration.dotCom
            : try EndpointConfiguration.enterprise(address: endpoint, clientID: "enterprise-client-id")
        mock.on("POST", path, respond: .json(.object(tokenResponse)))

        let result = try await flow(configuration).requestAccessToken(authorization)

        #expect(result == .token(try parseOAuthToken(.object(tokenResponse), issuedAt: issuedAt)))

        let requests = mock.requests
        #expect(requests.count == 1)
        let request = try #require(requests.first)
        #expect(request.url.absoluteString == "\(endpoint.replacing(/\/$/, with: ""))/login/oauth/access_token")
        #expect(request.method == "POST")
        #expect(request.header("Accept") == "application/json")
        #expect(request.header("Content-Type") == "application/x-www-form-urlencoded")
        #expect(request.header("User-Agent") == mock.runtime.userAgent)
        #expect(request.header("Authorization") == nil)
        #expect(request.form == [
            "client_id": configuration.clientID,
            "device_code": "device-code",
            "grant_type": "urn:ietf:params:oauth:grant-type:device_code",
        ])
    }

    @Test("rejects other OAuth errors even with HTTP 200 and valid token fields")
    func rejectsOtherOAuthErrors() async {
        var response = tokenResponse
        response["error"] = "secret-error"
        response["error_description"] = "secret-description"
        mock.on("POST", path, respond: .json(.object(response)))

        await expectFailure(.failed)
    }

    @Test("rejects non-success HTTP statuses without trusting token fields")
    func rejectsNonSuccessStatuses() async {
        mock.on("POST", path, respond: .json(.object(tokenResponse), status: 500))

        await expectFailure(.failed)
    }

    @Test("treats non-JSON error responses as request failures")
    func treatsNonJSONAsFailure() async {
        mock.on("POST", path, respond: .text("<html>secret-gateway-response</html>", status: 502))

        await expectFailure(.failed)
        #expect(mock.requests.count == 1)
    }

    // An authorization_pending trusted from a server error would keep the
    // device flow polling.
    @Test("does not trust OAuth errors in server errors")
    func doesNotTrustErrorsInServerErrors() async {
        mock.on("POST", path, respond: .json(
            ["error": "authorization_pending", "error_description": "secret-error-description"],
            status: 503
        ))

        await expectFailure(.failed)
        #expect(mock.requests.count == 1)
    }

    @Test("sanitizes malformed JSON responses")
    func sanitizesMalformedJSON() async {
        mock.on("POST", path, respond: .text("secret-response-body"))

        await #expect {
            _ = try await flow().requestAccessToken(authorization)
        } throws: { error in
            error as? OAuthTokenResponseError == OAuthTokenResponseError()
                && String(describing: error) == "The OAuth token response is invalid."
        }
    }

    @Test("sanitizes network failures without retrying")
    func sanitizesNetworkFailures() async {
        mock.on("POST", path, respond: .networkError(.cannotConnectToHost))

        await expectFailure(.failed)
        #expect(mock.requests.count == 1)
    }

    @Test("bounds even a fetch that ignores cancellation")
    func boundsHangingRequests() async {
        mock.on("POST", path, respond: .hang)

        await expectFailure(.timedOut, timeout: .milliseconds(200))
        #expect(mock.requests.count == 1)
    }

    @Test("keeps the deadline active while reading the response body")
    func keepsDeadlineWhileReadingBody() async {
        mock.on("POST", path, respond: .partial(status: 200, headers: [:], body: Data(#"{"access_token":"#.utf8)))

        await expectFailure(.timedOut, timeout: .milliseconds(200))
    }

    @Test("refuses redirects")
    func refusesRedirects() async {
        mock.on("POST", path, respond: .status(302, headers: ["Location": "https://example.com/login/oauth/access_token"]))

        await expectFailure(.failed)
        #expect(mock.requests.count == 1)
    }
}
