// OAuth device flow sign-in (RFC 8628), which needs no client secret.
//
// https://docs.github.com/en/apps/oauth-apps/building-oauth-apps/authorizing-oauth-apps#device-flow

import EspalierSupport
import Foundation
import os

private let log = Log.logger(category: "github-device-flow")

/// The server an account signs in to and the OAuth app it signs in with.
///
/// Espalier's OAuth app (`OAuthConfig.dotComClientID`) exists only on
/// github.com, so a GitHub Enterprise server (Enterprise Server or ghe.com)
/// needs an OAuth app registered on that server, with device flow enabled,
/// and its client ID here.
public struct EndpointConfiguration: Codable, Sendable, Hashable {
    /// The API endpoint, e.g. `https://api.github.com` or
    /// `https://github.example.com/api/v3`.
    public let endpoint: String

    /// The client ID of the OAuth app registered on the server.
    public let clientID: String

    public init(endpoint: String, clientID: String) {
        self.endpoint = endpoint
        self.clientID = clientID
    }

    /// GitHub.com, with Espalier's OAuth app.
    public static let dotCom = EndpointConfiguration(
        endpoint: getDotComAPIEndpoint(),
        clientID: OAuthConfig.dotComClientID
    )

    /// A GitHub Enterprise server at `address` (as the user typed it; see
    /// `validateURL`), with the client ID of an OAuth app registered on it.
    ///
    /// A github.com address means GitHub.com, which signs in with Espalier's
    /// own OAuth app.
    public static func enterprise(address: String, clientID: String) throws -> EndpointConfiguration {
        if isDotComAddress(address) {
            return .dotCom
        }

        let validURL = try validateURL(address)
        let clientID = clientID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !clientID.isEmpty else {
            throw DeviceFlowError.missingClientID
        }
        return EndpointConfiguration(endpoint: getEnterpriseAPIURL(validURL), clientID: clientID)
    }
}

/// Whether an address typed for an Enterprise server is GitHub.com's:
/// `github.com` or `api.github.com`, in any case, optionally after
/// `https://` and before a path.
public func isDotComAddress(_ address: String) -> Bool {
    address.trimmingCharacters(in: .whitespacesAndNewlines)
        .contains(/^(?:https:\/\/)?(?:api\.)?github\.com($|\/)/.ignoresCase())
}

extension Account {
    /// The server and OAuth app to sign in with again, for example after the
    /// token expired or GitHub rejected it: the app the account signed in
    /// with, or Espalier's app for a GitHub.com account that has none.
    public var endpointConfiguration: EndpointConfiguration? {
        if let clientID {
            return EndpointConfiguration(endpoint: endpoint, clientID: clientID)
        }
        return isDotComAccount(self) ? .dotCom : nil
    }
}

/// What the user needs to authorize this device: a code to enter at a URL.
public struct DeviceAuthorization: Sendable, Hashable {
    /// Identifies this sign-in to the server. Never shown to the user.
    public let deviceCode: String

    /// The code the user enters on the verification page.
    public let userCode: String

    /// The page where the user enters the code, e.g.
    /// `https://github.com/login/device`.
    public let verificationURI: String

    /// When the codes expire.
    public let expiresAt: Date

    /// The minimum number of seconds between token requests.
    public let interval: Int

    public init(deviceCode: String, userCode: String, verificationURI: String, expiresAt: Date, interval: Int) {
        self.deviceCode = deviceCode
        self.userCode = userCode
        self.verificationURI = verificationURI
        self.expiresAt = expiresAt
        self.interval = interval
    }
}

/// Why device flow sign-in failed. Network and response problems are
/// `OAuthTokenRequestError` and `OAuthTokenResponseError`.
public enum DeviceFlowError: Error, LocalizedError, CustomStringConvertible, Sendable, Equatable {
    /// The codes expired before the user authorized the device.
    case expiredToken
    /// The user denied the authorization request.
    case accessDenied
    /// The server doesn't accept the device code grant type.
    case unsupportedGrantType
    /// The client ID isn't an OAuth app on this server.
    case incorrectClientCredentials
    /// The server doesn't recognize the device code.
    case incorrectDeviceCode
    /// The OAuth app doesn't have device flow enabled.
    case deviceFlowDisabled
    /// No client ID was given for an enterprise server.
    case missingClientID
    /// The device authorization response can't be used.
    case invalidResponse

    /// The device flow error code GitHub returns for this error.
    public init?(errorCode: String) {
        switch errorCode {
        case "expired_token": self = .expiredToken
        case "access_denied": self = .accessDenied
        case "unsupported_grant_type": self = .unsupportedGrantType
        case "incorrect_client_credentials": self = .incorrectClientCredentials
        case "incorrect_device_code": self = .incorrectDeviceCode
        case "device_flow_disabled": self = .deviceFlowDisabled
        default: return nil
        }
    }

    public var message: String {
        switch self {
        case .expiredToken:
            "The sign-in code has expired. Try signing in again."
        case .accessDenied:
            "The authorization request was denied. Try signing in again."
        case .unsupportedGrantType:
            "This server doesn't support signing in with a device code."
        case .incorrectClientCredentials:
            "The OAuth app client ID isn't valid on this server. Check the client ID and try again."
        case .incorrectDeviceCode:
            "The sign-in code isn't valid. Try signing in again."
        case .deviceFlowDisabled:
            "Device flow isn't enabled for this OAuth app. Enable it in the app's settings on the server and try again."
        case .missingClientID:
            "Enter the client ID of an OAuth app registered on this server."
        case .invalidResponse:
            "The device authorization response is invalid."
        }
    }

    public var errorDescription: String? { message }
    public var description: String { message }
}

/// The answer to one token request while waiting for the user.
public enum DeviceTokenPollResult: Sendable, Equatable {
    /// The user authorized the device.
    case token(OAuthToken)
    /// The user hasn't finished yet; ask again after the interval.
    case authorizationPending
    /// Requests are too frequent; wait longer. Carries the server's new
    /// interval in seconds, if it sent one.
    case slowDown(interval: Int?)
}

/// Signs in to a GitHub server with the OAuth device flow.
///
/// 1. `requestDeviceCode()` returns a user code and a verification URL. Show
///    the code and open the URL.
/// 2. `pollForAccessToken(_:)` waits until the user enters the code and
///    approves, honoring the server's interval and `slow_down` responses.
///    Cancel the calling task to stop waiting.
/// 3. `fetchAccount(token:)` loads the user and builds the `Account`.
///
/// `signIn(presentAuthorization:)` runs all three.
public struct DeviceFlow: Sendable {
    /// The interval RFC 8628 prescribes when the server sends none.
    public static let defaultInterval = 5

    /// The seconds added to the interval after each `slow_down` response.
    public static let slowDownIncrement = 5

    public let configuration: EndpointConfiguration
    public let scopes: [String]

    private let runtime: GitHubRuntime
    private let requestTimeout: Duration
    private let sleep: @Sendable (Duration) async throws -> Void
    private let now: @Sendable () -> Date

    /// - Parameters:
    ///   - configuration: The server and OAuth app to sign in with.
    ///   - scopes: The OAuth scopes to request.
    ///   - runtime: The session and user agent for requests.
    ///   - requestTimeout: The deadline for each request.
    ///   - sleep: Waits between token requests. Tests pass a virtual clock.
    ///   - now: The current time.
    public init(
        configuration: EndpointConfiguration = .dotCom,
        scopes: [String] = OAuthConfig.scopes,
        runtime: GitHubRuntime = .current,
        requestTimeout: Duration = .seconds(30),
        sleep: @escaping @Sendable (Duration) async throws -> Void = { try await Task.sleep(for: $0) },
        now: @escaping @Sendable () -> Date = Date.init
    ) {
        self.configuration = configuration
        self.scopes = scopes
        self.runtime = runtime
        self.requestTimeout = requestTimeout
        self.sleep = sleep
        self.now = now
    }

    /// The server's web host, where the OAuth endpoints live.
    public var htmlEndpoint: String {
        getHTMLURL(configuration.endpoint)
    }

    /// Asks the server for a device code and a user code.
    public func requestDeviceCode() async throws -> DeviceAuthorization {
        let requestedAt = now()
        let parameters: KeyValuePairs = [
            "client_id": configuration.clientID,
            "scope": scopes.joined(separator: " "),
        ]
        let endpoint = htmlEndpoint
        let runtime = runtime

        do {
            return try await withDeadline(requestTimeout) {
                let response = try await postOAuthForm(endpoint, "login/device/code", parameters, runtime: runtime)

                let value: JSONValue
                do {
                    value = try JSONValue.parse(response.body)
                } catch {
                    if !response.ok {
                        throw OAuthTokenRequestError.failed
                    }
                    throw DeviceFlowError.invalidResponse
                }

                if response.status >= 500 {
                    throw OAuthTokenRequestError.failed
                }
                if value.isRecord, let error = value["error"] {
                    if case .string(let code) = error, let deviceFlowError = DeviceFlowError(errorCode: code) {
                        throw deviceFlowError
                    }
                    throw OAuthTokenRequestError.failed
                }
                if !response.ok {
                    throw OAuthTokenRequestError.failed
                }

                return try parseDeviceAuthorization(value, requestedAt: requestedAt)
            }
        } catch {
            let sanitized = sanitizedOAuthError(error)
            log.warning("requestDeviceCode: failed with endpoint \(configuration.endpoint, privacy: .public): \(String(describing: sanitized), privacy: .public)")
            throw sanitized
        }
    }

    /// Asks once whether the user has authorized the device.
    public func requestAccessToken(_ authorization: DeviceAuthorization) async throws -> DeviceTokenPollResult {
        let response = try await requestOAuthToken(
            htmlEndpoint,
            [
                "client_id": configuration.clientID,
                "device_code": authorization.deviceCode,
                "grant_type": "urn:ietf:params:oauth:grant-type:device_code",
            ],
            timeout: requestTimeout,
            runtime: runtime,
            now: now
        )

        switch response {
        case .token(let token):
            return .token(token)
        case .error(code: "authorization_pending", _):
            return .authorizationPending
        case .error(code: "slow_down", let body):
            let interval = body["interval"]?.numberValue.flatMap { isSafeInteger($0) && $0 > 0 ? Int($0) : nil }
            return .slowDown(interval: interval)
        case .error(let code, _):
            throw DeviceFlowError(errorCode: code) ?? OAuthTokenRequestError.failed
        }
    }

    /// Waits for the user to authorize the device and returns the token.
    ///
    /// Waits `interval` seconds before each request, adds five seconds after
    /// each `slow_down`, and fails with `DeviceFlowError.expiredToken` once the
    /// codes expire. Cancelling the calling task stops waiting and throws
    /// `CancellationError`.
    public func pollForAccessToken(_ authorization: DeviceAuthorization) async throws -> OAuthToken {
        var interval = authorization.interval > 0 ? authorization.interval : Self.defaultInterval

        while true {
            do {
                try await sleep(.seconds(interval))
            } catch {
                throw CancellationError()
            }
            try Task.checkCancellation()

            if now() >= authorization.expiresAt {
                throw DeviceFlowError.expiredToken
            }

            switch try await requestAccessToken(authorization) {
            case .token(let token):
                return token
            case .authorizationPending:
                continue
            case .slowDown(let serverInterval):
                interval = max(interval + Self.slowDownIncrement, serverInterval ?? 0)
            }
        }
    }

    /// Loads the user the token belongs to and builds the account, with this
    /// flow's client ID and the token's expiry.
    public func fetchAccount(token: OAuthToken) async throws -> Account {
        let account = try await fetchUser(endpoint: configuration.endpoint, token: token.accessToken, runtime: runtime)
        return account
            .withToken(token.accessToken, expiresAt: token.expirationDate)
            .withClientID(configuration.clientID)
    }

    /// Runs the whole flow: requests the codes, hands them to
    /// `presentAuthorization` (which shows the user code and opens the
    /// verification page), waits for the user, and returns the account.
    public func signIn(
        presentAuthorization: @Sendable (DeviceAuthorization) async throws -> Void
    ) async throws -> Account {
        let authorization = try await requestDeviceCode()
        try await presentAuthorization(authorization)
        let token = try await pollForAccessToken(authorization)
        return try await fetchAccount(token: token)
    }
}

/// Validates the response to a device code request.
func parseDeviceAuthorization(_ value: JSONValue, requestedAt: Date) throws -> DeviceAuthorization {
    guard isToken(value["device_code"]),
          case .string(let deviceCode)? = value["device_code"],
          case .string(let userCode)? = value["user_code"], !userCode.isEmpty,
          case .string(let verificationURI)? = value["verification_uri"], !verificationURI.isEmpty,
          case .number(let expiresIn)? = value["expires_in"], isSafeInteger(expiresIn), expiresIn > 0
    else {
        throw DeviceFlowError.invalidResponse
    }

    var interval = DeviceFlow.defaultInterval
    if let intervalValue = value["interval"] {
        guard case .number(let seconds) = intervalValue, isSafeInteger(seconds), seconds >= 0 else {
            throw DeviceFlowError.invalidResponse
        }
        interval = Int(seconds)
    }

    return DeviceAuthorization(
        deviceCode: deviceCode,
        userCode: userCode,
        verificationURI: verificationURI,
        expiresAt: requestedAt.addingTimeInterval(expiresIn),
        interval: interval
    )
}
