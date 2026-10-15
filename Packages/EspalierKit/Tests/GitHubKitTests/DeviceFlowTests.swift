// OAuth device flow sign-in.

import Foundation
@testable import GitHubKit
import Synchronization
import TestSupport
import Testing

private let deviceCodePath = "/login/device/code"
private let tokenPath = "/login/oauth/access_token"

private let deviceCodeResponse: JSONValue = [
    "device_code": "3584d83530557fdd1f46af8289938c8ef79f9dc5",
    "user_code": "WDJB-MJHT",
    "verification_uri": "https://github.com/login/device",
    "expires_in": 900,
    "interval": 5,
]

private let pending: MockGitHub.Response = .json(["error": "authorization_pending"])

private func oauthError(_ code: String, interval: Int? = nil) -> MockGitHub.Response {
    var body: [String: JSONValue] = ["error": .string(code), "error_description": "description"]
    if let interval {
        body["interval"] = .number(Double(interval))
    }
    return .json(.object(body))
}

private let token: MockGitHub.Response = .json([
    "access_token": "gho_16C7e42F292c6912E7710c838347Ae178B4a",
    "token_type": "bearer",
    "scope": "repo,user,workflow",
])

@Suite("DeviceFlow", .offline)
struct DeviceFlowTests {
    let mock = MockGitHub()
    let clock = TestClock()

    func flow(_ configuration: EndpointConfiguration = .dotCom) -> DeviceFlow {
        DeviceFlow(
            configuration: configuration,
            runtime: mock.runtime,
            sleep: clock.sleep,
            now: clock.now
        )
    }

    func mockUser(login: String = "octocat") {
        mock.on("GET", "/user", respond: .json(encoding: createMockAPIFullIdentity(id: 1, login: login)))
        mock.on("GET", "/user/emails", respond: .json(encoding: [createMockAPIEmail("\(login)@example.com")]))
    }

    @Suite("requesting a device code")
    struct RequestingADeviceCode {
        let mock = MockGitHub()
        let clock = TestClock()

        @Test("asks GitHub.com with Espalier's client ID and desktop's scopes")
        func requestsDeviceCode() async throws {
            mock.on("POST", deviceCodePath, respond: .json(deviceCodeResponse))
            let flow = DeviceFlow(runtime: mock.runtime, sleep: clock.sleep, now: clock.now)

            let authorization = try await flow.requestDeviceCode()

            #expect(authorization == DeviceAuthorization(
                deviceCode: "3584d83530557fdd1f46af8289938c8ef79f9dc5",
                userCode: "WDJB-MJHT",
                verificationURI: "https://github.com/login/device",
                expiresAt: clock.now().addingTimeInterval(900),
                interval: 5
            ))

            let request = try #require(mock.requests.first)
            #expect(request.url.absoluteString == "https://github.com/login/device/code")
            #expect(request.method == "POST")
            #expect(request.header("Accept") == "application/json")
            #expect(request.header("Content-Type") == "application/x-www-form-urlencoded")
            #expect(request.header("Authorization") == nil)
            #expect(request.form == ["client_id": OAuthConfig.dotComClientID, "scope": "repo user workflow"])
        }

        @Test("asks an enterprise server with its own client ID")
        func requestsEnterpriseDeviceCode() async throws {
            mock.on("POST", deviceCodePath, respond: .json(deviceCodeResponse))
            let configuration = try EndpointConfiguration.enterprise(address: "github.example.com", clientID: " Ov23liEnterprise ")
            let flow = DeviceFlow(configuration: configuration, runtime: mock.runtime, sleep: clock.sleep, now: clock.now)

            _ = try await flow.requestDeviceCode()

            #expect(configuration.endpoint == "https://github.example.com/api/v3")
            let request = try #require(mock.requests.first)
            #expect(request.url.absoluteString == "https://github.example.com/login/device/code")
            #expect(request.form["client_id"] == "Ov23liEnterprise")
        }

        @Test("signs in on the enterprise's host and port", arguments: [
            NamedCase("uses the api. subdomain for ghe.com", (address: "https://octocorp.ghe.com", endpoint: "https://api.octocorp.ghe.com/", deviceCodeURL: "https://octocorp.ghe.com/login/device/code")),
            NamedCase("keeps an Enterprise Server's port", (address: "https://github.example.com:8443", endpoint: "https://github.example.com:8443/api/v3", deviceCodeURL: "https://github.example.com:8443/login/device/code")),
        ])
        func requestsDeviceCodeOnEnterpriseHost(_ testCase: NamedCase<(address: String, endpoint: String, deviceCodeURL: String)>) async throws {
            mock.on("POST", deviceCodePath, respond: .json(deviceCodeResponse))
            let configuration = try EndpointConfiguration.enterprise(address: testCase.value.address, clientID: "client")
            let flow = DeviceFlow(configuration: configuration, runtime: mock.runtime, sleep: clock.sleep, now: clock.now)

            _ = try await flow.requestDeviceCode()

            #expect(configuration.endpoint == testCase.value.endpoint)
            #expect(mock.requests.first?.url.absoluteString == testCase.value.deviceCodeURL)
        }

        @Test("requires a client ID for enterprise servers")
        func requiresEnterpriseClientID() {
            #expect(throws: DeviceFlowError.missingClientID) {
                try EndpointConfiguration.enterprise(address: "github.example.com", clientID: "  ")
            }
        }

        @Test("treats a github.com address as GitHub.com")
        func treatsDotComAddressAsDotCom() throws {
            #expect(try EndpointConfiguration.enterprise(address: "https://github.com", clientID: "other") == .dotCom)
            #expect(try EndpointConfiguration.enterprise(address: "api.github.com/", clientID: "") == .dotCom)
            #expect(try EndpointConfiguration.enterprise(address: "GitHub.com", clientID: "") == .dotCom)
            #expect(try EndpointConfiguration.enterprise(address: " HTTPS://GITHUB.COM ", clientID: "") == .dotCom)
            #expect(try EndpointConfiguration.enterprise(address: "github.company.com", clientID: "c").endpoint == "https://github.company.com/api/v3")
        }

        @Test("rejects enterprise addresses desktop rejects")
        func rejectsInvalidAddresses() {
            #expect(throws: EnterpriseURLValidationError(kind: .invalidProtocol, message: "Invalid protocol")) {
                try EndpointConfiguration.enterprise(address: "http://github.example.com", clientID: "c")
            }
        }

        @Test("remembers where to sign in again")
        func remembersEndpointConfiguration() {
            func account(_ endpoint: String, clientID: String?) -> Account {
                Account(login: "a", endpoint: endpoint, token: "", emails: [], avatarURL: "", id: 1, name: "", clientID: clientID)
            }

            #expect(
                account("https://ghe.io/api/v3", clientID: "client").endpointConfiguration
                    == EndpointConfiguration(endpoint: "https://ghe.io/api/v3", clientID: "client")
            )
            #expect(account("https://api.github.com", clientID: nil).endpointConfiguration == .dotCom)
            #expect(account("https://ghe.io/api/v3", clientID: nil).endpointConfiguration == nil)
        }

        @Test("defaults the interval to five seconds")
        func defaultsInterval() async throws {
            var response = deviceCodeResponse
            if case .object(var fields) = response {
                fields.removeValue(forKey: "interval")
                response = .object(fields)
            }
            mock.on("POST", deviceCodePath, respond: .json(response))
            let flow = DeviceFlow(runtime: mock.runtime, sleep: clock.sleep, now: clock.now)

            #expect(try await flow.requestDeviceCode().interval == 5)
        }

        @Test("reports device flow errors")
        func reportsErrors() async {
            mock.on("POST", deviceCodePath, respond: oauthError("device_flow_disabled"))
            let flow = DeviceFlow(runtime: mock.runtime, sleep: clock.sleep, now: clock.now)

            await #expect(throws: DeviceFlowError.deviceFlowDisabled) {
                try await flow.requestDeviceCode()
            }
        }

        @Test("rejects malformed responses", arguments: [
            ["user_code": "WDJB-MJHT", "verification_uri": "https://github.com/login/device", "expires_in": 900],
            ["device_code": "code", "user_code": "WDJB-MJHT", "verification_uri": "https://github.com/login/device", "expires_in": -1],
            ["device_code": "code", "user_code": "WDJB-MJHT", "verification_uri": "https://github.com/login/device", "expires_in": 900, "interval": "5"],
            "secret",
        ] as [JSONValue])
        func rejectsMalformedResponses(response: JSONValue) async {
            mock.on("POST", deviceCodePath, respond: .json(response))
            let flow = DeviceFlow(runtime: mock.runtime, sleep: clock.sleep, now: clock.now)

            await #expect(throws: DeviceFlowError.invalidResponse) {
                try await flow.requestDeviceCode()
            }
        }

        @Test("treats server errors and network failures as request failures")
        func treatsFailuresAsRequestFailures() async {
            mock.on("POST", deviceCodePath, sequence: [
                .text("<html>secret</html>", status: 502),
                .networkError(.networkConnectionLost),
            ])
            let flow = DeviceFlow(runtime: mock.runtime, sleep: clock.sleep, now: clock.now)

            await #expect(throws: OAuthTokenRequestError.failed) {
                try await flow.requestDeviceCode()
            }
            await #expect(throws: OAuthTokenRequestError.failed) {
                try await flow.requestDeviceCode()
            }
        }
    }

    @Test("signs in after authorization_pending")
    func signsInAfterPending() async throws {
        mock.on("POST", deviceCodePath, respond: .json(deviceCodeResponse))
        mock.on("POST", tokenPath, sequence: [pending, pending, token])
        mockUser()
        let presented = Mutex<[DeviceAuthorization]>([])

        let account = try await flow().signIn { authorization in
            presented.withLock { $0.append(authorization) }
        }

        #expect(presented.withLock { $0.map(\.userCode) } == ["WDJB-MJHT"])
        #expect(clock.sleeps == [5, 5, 5])
        #expect(mock.requests("POST", tokenPath).count == 3)
        #expect(account.login == "octocat")
        #expect(account.endpoint == "https://api.github.com")
        #expect(account.token == "gho_16C7e42F292c6912E7710c838347Ae178B4a")
        #expect(account.clientID == OAuthConfig.dotComClientID)
        #expect(account.tokenExpiresAt == nil)
        #expect(account.emails == [createMockAPIEmail("octocat@example.com")])

        let userRequest = try #require(mock.requests("GET", "/user").first)
        #expect(userRequest.url.absoluteString == "https://api.github.com/user")
        #expect(userRequest.header("Authorization") == "Bearer gho_16C7e42F292c6912E7710c838347Ae178B4a")
        for request in mock.requests("POST", tokenPath) {
            #expect(request.form["device_code"] == "3584d83530557fdd1f46af8289938c8ef79f9dc5")
        }
    }

    @Test("adds five seconds to the interval on slow_down")
    func backsOffOnSlowDown() async throws {
        mock.on("POST", tokenPath, sequence: [pending, oauthError("slow_down"), pending, token])
        let authorization = DeviceAuthorization(
            deviceCode: "device",
            userCode: "CODE",
            verificationURI: "https://github.com/login/device",
            expiresAt: clock.now().addingTimeInterval(900),
            interval: 5
        )

        let result = try await flow().pollForAccessToken(authorization)

        #expect(result.accessToken == "gho_16C7e42F292c6912E7710c838347Ae178B4a")
        #expect(clock.sleeps == [5, 5, 10, 10])
    }

    @Test("honors a longer interval sent with slow_down")
    func honorsServerInterval() async throws {
        mock.on("POST", tokenPath, sequence: [oauthError("slow_down", interval: 20), oauthError("slow_down", interval: 5), token])
        let authorization = DeviceAuthorization(
            deviceCode: "device",
            userCode: "CODE",
            verificationURI: "https://github.com/login/device",
            expiresAt: clock.now().addingTimeInterval(900),
            interval: 5
        )

        _ = try await flow().pollForAccessToken(authorization)

        #expect(clock.sleeps == [5, 20, 25])
    }

    @Test("fails when GitHub reports the code expired")
    func failsOnExpiredToken() async {
        mock.on("POST", deviceCodePath, respond: .json(deviceCodeResponse))
        mock.on("POST", tokenPath, sequence: [pending, oauthError("expired_token")])

        await #expect(throws: DeviceFlowError.expiredToken) {
            try await flow().signIn { _ in }
        }
        #expect(mock.requests("GET", "/user").isEmpty)
    }

    @Test("stops polling once the code expires")
    func stopsPollingAfterExpiry() async {
        mock.on("POST", deviceCodePath, respond: .json(deviceCodeResponse))
        mock.on("POST", tokenPath, respond: pending)

        await #expect(throws: DeviceFlowError.expiredToken) {
            try await flow().signIn { _ in }
        }
        // 900 seconds at five-second intervals: polls at 5, 10, ... 895.
        #expect(mock.requests("POST", tokenPath).count == 179)
    }

    @Test("fails clearly on device flow errors", arguments: [
        NamedCase("fails when the user denies access", (code: "access_denied", expected: DeviceFlowError.accessDenied)),
        NamedCase("incorrect_device_code", (code: "incorrect_device_code", expected: DeviceFlowError.incorrectDeviceCode)),
    ])
    func failsOnDeviceFlowErrors(_ testCase: NamedCase<(code: String, expected: DeviceFlowError)>) async {
        let (code, expected) = testCase.value
        mock.on("POST", deviceCodePath, respond: .json(deviceCodeResponse))
        mock.on("POST", tokenPath, sequence: [pending, oauthError(code)])

        await #expect(throws: expected) {
            try await flow().signIn { _ in }
        }
        #expect(!expected.message.isEmpty)
    }

    @Test("fails on unknown OAuth errors without exposing them")
    func failsOnUnknownErrors() async {
        mock.on("POST", tokenPath, respond: oauthError("secret_error"))
        let authorization = DeviceAuthorization(
            deviceCode: "device",
            userCode: "CODE",
            verificationURI: "https://github.com/login/device",
            expiresAt: clock.now().addingTimeInterval(900),
            interval: 5
        )

        await #expect(throws: OAuthTokenRequestError.failed) {
            try await flow().pollForAccessToken(authorization)
        }
    }

    @Test("stops polling when cancelled while waiting")
    func cancelsWhileWaiting() async throws {
        mock.on("POST", tokenPath, respond: pending)
        let started = AsyncStream<Void>.makeStream()
        let flow = DeviceFlow(
            runtime: mock.runtime,
            sleep: { duration in
                started.continuation.yield()
                try await Task.sleep(for: .seconds(3600))
            },
            now: clock.now
        )
        let authorization = DeviceAuthorization(
            deviceCode: "device",
            userCode: "CODE",
            verificationURI: "https://github.com/login/device",
            expiresAt: clock.now().addingTimeInterval(900),
            interval: 5
        )

        let polling = Task { try await flow.pollForAccessToken(authorization) }
        var iterator = started.stream.makeAsyncIterator()
        _ = await iterator.next()
        polling.cancel()

        await #expect(throws: CancellationError.self) {
            try await polling.value
        }
        #expect(mock.requests.isEmpty)
    }

    @Test("stops polling when cancelled during a request")
    func cancelsDuringRequest() async throws {
        let requested = AsyncStream<Void>.makeStream()
        mock.on("POST", tokenPath) { _ in
            requested.continuation.yield()
            return .hang
        }
        let authorization = DeviceAuthorization(
            deviceCode: "device",
            userCode: "CODE",
            verificationURI: "https://github.com/login/device",
            expiresAt: clock.now().addingTimeInterval(900),
            interval: 5
        )
        let flow = flow()

        let polling = Task { try await flow.pollForAccessToken(authorization) }
        var iterator = requested.stream.makeAsyncIterator()
        _ = await iterator.next()
        polling.cancel()

        await #expect(throws: CancellationError.self) {
            try await polling.value
        }
        #expect(mock.requests.count == 1)
    }

    @Test("fails when the user can't be loaded after authorization")
    func surfacesFetchUserFailures() async {
        mock.on("POST", deviceCodePath, respond: .json(deviceCodeResponse))
        mock.on("POST", tokenPath, respond: token)
        mock.on("GET", "/user", respond: .json(["message": "Server Error"], status: 500))
        mock.on("GET", "/user/emails", respond: .json([]))

        await #expect {
            _ = try await flow().signIn { _ in }
        } throws: { error in
            (error as? APIError)?.responseStatus == 500
        }
    }

    @Test("records an expiring token's expiry on the account")
    func recordsTokenExpiry() async throws {
        mock.on("POST", deviceCodePath, respond: .json(deviceCodeResponse))
        mock.on("POST", tokenPath, respond: .json([
            "access_token": "ghu_expiring",
            "expires_in": 28800,
            "refresh_token": "ghr_refresh",
            "refresh_token_expires_in": 15_897_600,
            "token_type": "bearer",
            "scope": "",
        ]))
        mockUser()

        let account = try await flow().signIn { _ in }

        // Polled once, after the five-second interval.
        let issuedAt = clock.now()
        #expect(account.token == "ghu_expiring")
        #expect(account.tokenExpiresAt == issuedAt.addingTimeInterval(28800))
        #expect(!account.isTokenExpired(at: issuedAt))
        #expect(account.isTokenExpired(at: issuedAt.addingTimeInterval(28800)))
    }

    @Test("signs in to an enterprise server's API with its client ID")
    func signsInToEnterprise() async throws {
        let configuration = try EndpointConfiguration.enterprise(address: "https://github.example.com", clientID: "Ov23liEnterprise")
        mock.on("POST", deviceCodePath, respond: .json(deviceCodeResponse))
        mock.on("POST", tokenPath, respond: token)
        mock.on("GET", "/api/v3/user", respond: .json(encoding: createMockAPIFullIdentity(id: 7, login: "monalisa")))
        mock.on("GET", "/api/v3/user/emails", respond: .json(encoding: [createMockAPIEmail()]))

        let account = try await flow(configuration).signIn { _ in }

        #expect(account.endpoint == "https://github.example.com/api/v3")
        #expect(account.clientID == "Ov23liEnterprise")
        #expect(account.login == "monalisa")
        #expect(mock.requests("POST", tokenPath).first?.url.host() == "github.example.com")
        #expect(mock.requests("POST", tokenPath).first?.form["client_id"] == "Ov23liEnterprise")
    }
}
