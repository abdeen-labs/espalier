// Ported from desktop/app/src/lib/stores/sign-in-store.ts
//
// Signing in uses the OAuth device flow: `authenticate()` shows a code to
// enter on the server's verification page and waits for the user.

import EspalierSupport
import Foundation
import GitHubKit
import Observation
import os

private let logger = Log.logger(category: "sign-in")

/// The steps of a sign-in.
public enum SignInStep: String, Sendable, Hashable {
    /// The enterprise server's address and its OAuth app's client ID.
    case endpointEntry
    /// An account is already signed in to the server; a successful sign-in
    /// replaces it.
    case existingAccountWarning
    /// Signing in with a code: ready to ask for one, or waiting for the user
    /// to enter it.
    case authentication
    /// Signed in.
    case success
}

/// How a sign-in ended, for whoever started it.
public enum SignInResult: Sendable, Equatable {
    /// The account that signed in, with its token.
    case success(Account)
    /// The sign-in was cancelled, or replaced by another one.
    case cancelled
}

/// The code the user enters on the server's verification page.
public struct SignInCode: Sendable, Equatable {
    /// The code to enter (`WDJB-MJHT`).
    public let userCode: String
    /// The page to enter it on (`https://github.com/login/device`).
    public let verificationURI: String
    /// When the code expires; ask for a new one after that.
    public let expiresAt: Date

    public init(userCode: String, verificationURI: String, expiresAt: Date) {
        self.userCode = userCode
        self.verificationURI = verificationURI
        self.expiresAt = expiresAt
    }
}

/// Why a sign-in step failed, with the copy to show next to it.
public enum SignInError: Error, Sendable, Equatable, CustomStringConvertible {
    /// The enterprise address isn't a valid URL.
    case invalidEnterpriseAddress
    /// The enterprise address isn't https.
    case unsupportedProtocol
    /// No client ID was given for the enterprise server's OAuth app.
    case missingClientID
    /// The server couldn't be reached.
    case cannotReach(host: String)
    /// The server's certificate isn't trusted (self-signed, a private
    /// certificate authority's): trust it in Keychain Access.
    case untrustedCertificate(host: String)
    /// The server answered, but not as a GitHub Enterprise server does.
    case notGitHubEnterprise(host: String)
    /// The code expired before the user entered it.
    case codeExpired
    /// The user denied the authorization.
    case accessDenied
    /// The server or its OAuth app can't sign in with a device code (device
    /// flow disabled, an unknown client ID, an unsupported grant type, ...).
    case deviceFlow(DeviceFlowError)
    /// The user couldn't be loaded once the code was authorized.
    case userNotLoaded
    /// The token couldn't be stored in the keychain.
    case tokenNotStored(String)
    /// Anything else.
    case other(String)

    /// The message to show.
    public var message: String {
        switch self {
        case .invalidEnterpriseAddress:
            "That doesn't look like a valid address. Enter one like https://example.ghe.com."
        case .unsupportedProtocol:
            "Only https addresses are supported for GitHub Enterprise."
        case .missingClientID:
            DeviceFlowError.missingClientID.message
        case .cannotReach(let host):
            "Couldn't reach \(host)."
        case .untrustedCertificate(let host):
            UntrustedCertificateError(host: host).message
        case .notGitHubEnterprise(let host):
            "The server at \(host) doesn't appear to be GitHub Enterprise. Check the address and try again."
        case .codeExpired:
            "This code has expired."
        case .accessDenied:
            "Authorization was denied."
        case .deviceFlow(let error):
            error.message
        case .userNotLoaded:
            "Couldn't load the account you signed in with."
        case .tokenNotStored(let message), .other(let message):
            message
        }
    }

    public var description: String { message }
}

/// Where a sign-in is (the result callback stays with the model).
///
/// Accounts in states carry no token.
public enum SignInState: Sendable, Equatable {
    case endpointEntry(EndpointEntry)
    case existingAccountWarning(ExistingAccountWarning)
    case authentication(Authentication)
    case success(Success)

    /// The enterprise server to sign in to: its address and the client ID of
    /// an OAuth app registered on it.
    public struct EndpointEntry: Sendable, Equatable {
        /// The address to show, as entered or as known (git's request, the
        /// account being signed in again).
        public var address: String
        /// The client ID to show, as entered or as known.
        public var clientID: String
        public var error: SignInError?
        /// Whether the address is being checked.
        public var loading: Bool
    }

    /// Already signed in to the server: signing in replaces the account once
    /// the new sign-in succeeds.
    public struct ExistingAccountWarning: Sendable, Equatable {
        /// The account signed in to the server now.
        public let existingAccount: Account
        /// The server and OAuth app to sign in with.
        public let configuration: EndpointConfiguration
        public var error: SignInError?
        public var loading: Bool
    }

    /// Signing in with a code.
    public struct Authentication: Sendable, Equatable {
        /// The server and OAuth app to sign in with.
        public let configuration: EndpointConfiguration
        /// Git asked to sign in to a GitHub Enterprise Server the user hasn't
        /// signed in to: confirm the address before continuing.
        public let isUnrecognizedEnterpriseServer: Bool
        /// While waiting for the user: the code to enter.
        public var code: SignInCode?
        public var error: SignInError?
        /// Whether a code is being requested or waited for.
        public var loading: Bool
    }

    /// Signed in.
    public struct Success: Sendable, Equatable {
        /// The account that signed in.
        public let account: Account
    }

    public var kind: SignInStep {
        switch self {
        case .endpointEntry: .endpointEntry
        case .existingAccountWarning: .existingAccountWarning
        case .authentication: .authentication
        case .success: .success
        }
    }

    /// The error to show next to the current step.
    public var error: SignInError? {
        switch self {
        case .endpointEntry(let state): state.error
        case .existingAccountWarning(let state): state.error
        case .authentication(let state): state.error
        case .success: nil
        }
    }

    /// Whether the step is busy: everything but cancelling waits.
    public var loading: Bool {
        switch self {
        case .endpointEntry(let state): state.loading
        case .existingAccountWarning(let state): state.loading
        case .authentication(let state): state.loading
        case .success: false
        }
    }

    /// The API endpoint being signed in to, once known.
    public var endpoint: String? {
        switch self {
        case .endpointEntry: nil
        case .existingAccountWarning(let state): state.configuration.endpoint
        case .authentication(let state): state.configuration.endpoint
        case .success(let state): state.account.endpoint
        }
    }
}

/// Signing in to GitHub.com or a GitHub Enterprise server with the OAuth
/// device flow.
///
/// A sign-in starts with `beginDotComSignIn` or `beginEnterpriseSignIn` (or
/// `beginSignIn(endpoint:)` and `begin(answering:)` for recoveries and git's
/// requests), goes through `setEndpoint` for an enterprise server, and
/// `authenticate()` asks for a code and waits for the user to enter it.
/// `reset()` cancels it. Whoever started it gets a `SignInResult` once.
///
/// An account already signed in to the server is replaced only once the new
/// sign-in succeeds; failing to load the user at the end is an error; and an
/// enterprise server is checked (`GET <api>/meta`) when its address is entered.
@MainActor @Observable
public final class SignInModel {
    /// The sign-in in progress, or nil.
    public private(set) var state: SignInState?

    /// The URL git asked credentials for, when git started this sign-in
    /// ("Git is asking for credentials to access <url>.").
    public private(set) var credentialHelperURL: String?

    @ObservationIgnored weak var accounts: AccountsModel?
    @ObservationIgnored private var resultCallback: (@MainActor (SignInResult) -> Void)?
    /// Bumped by every begin and reset: an asynchronous step applies its
    /// result only to the sign-in it started in.
    @ObservationIgnored private var session = 0
    /// Bumped by every `authenticate()`, so an older code's flow stops.
    @ObservationIgnored private var flowGeneration = 0
    @ObservationIgnored private var flowTask: Task<Void, Never>?

    /// How long checking an enterprise server may take.
    static let enterpriseCheckTimeout: TimeInterval = 15

    init() {}

    // MARK: Starting

    /// Starts signing in to GitHub.com: the existing-account warning if a
    /// GitHub.com account is signed in, else the authentication step.
    public func beginDotComSignIn(_ resultCallback: (@MainActor (SignInResult) -> Void)? = nil) {
        if state != nil {
            reset()
        }
        startSession(resultCallback)
        showDotComSignIn()
    }

    /// Starts signing in to a GitHub Enterprise server, at the endpoint entry
    /// step.
    public func beginEnterpriseSignIn(_ resultCallback: (@MainActor (SignInResult) -> Void)? = nil) {
        if state != nil {
            reset()
        }
        startSession(resultCallback)
        state = .endpointEntry(SignInState.EndpointEntry(address: "", clientID: "", error: nil, loading: false))
    }

    /// Signs in again to `endpoint`, an API endpoint as recoveries (SAML
    /// single sign-on, the workflow scope) and signed-out accounts name it.
    ///
    /// It asks for a code right away: through the existing-account warning,
    /// since signing in again is the point. For an enterprise server whose
    /// OAuth app isn't known (no account used it), it stops at the endpoint
    /// entry with the address filled in. Returns when the sign-in ends or
    /// needs the user.
    public func beginSignIn(endpoint: String, _ resultCallback: (@MainActor (SignInResult) -> Void)? = nil) async {
        if isDotComEndpoint(endpoint) {
            beginDotComSignIn(resultCallback)
            await authenticate()
            return
        }

        beginEnterpriseSignIn(resultCallback)
        // The endpoint entry expects the web address: the API endpoint
        // would make `api.api.<tenant>.ghe.com` for ghe.com.
        let address = getHTMLURL(endpoint)
        guard let clientID = knownClientID(for: endpoint) else {
            showEndpointEntry(address: address, clientID: "")
            return
        }
        await setEndpoint(address, clientID: clientID)
        if let kind = state?.kind, kind == .authentication || kind == .existingAccountWarning {
            await authenticate()
        }
    }

    /// Starts the sign-in git asked for (`Prompt.gitHubSignIn`) and answers
    /// the prompt when it ends: with the new account, or with nothing when
    /// it's cancelled.
    ///
    /// It doesn't ask for a code by itself: the user first sees which server
    /// git wants, with a warning for an Enterprise Server they haven't signed
    /// in to. An enterprise server whose OAuth app isn't known stops at the
    /// endpoint entry, with the address filled in.
    public func begin(answering prompt: PendingPrompt) async {
        guard case .gitHubSignIn(let credentialURL) = prompt.prompt, let prompts = accounts?.environment?.prompts else {
            return
        }
        let id = prompt.id
        await begin(gitCredentialURL: credentialURL) { result in
            switch result {
            case .success(let account):
                prompts.answer(id, with: .credentials(
                    TrampolineAccount(endpoint: account.endpoint, login: account.login, token: account.token)
                ))
            case .cancelled:
                prompts.answer(id, with: .credentials(nil))
            }
        }
    }

    /// Starts the sign-in git asked for at `credentialURL` (the URL of
    /// `Prompt.gitHubSignIn`) and reports how it ends to `resultCallback`,
    /// as `begin(answering:)` does, for a caller that answers git's prompt
    /// itself (the sign-in sheet the prompt host shows).
    ///
    /// The user first sees which server git wants (`credentialHelperURL`);
    /// no code is asked for until `authenticate()`.
    public func begin(gitCredentialURL credentialURL: String, _ resultCallback: @escaping @MainActor (SignInResult) -> Void) async {
        guard let url = try? JSURL(credentialURL) else {
            logger.error("Could not prompt for GitHub sign in: the URL git asked about can't be parsed")
            resultCallback(.cancelled)
            return
        }

        if url.hostname == "github.com" {
            beginDotComSignIn(resultCallback)
            credentialHelperURL = credentialURL
            return
        }

        beginEnterpriseSignIn(resultCallback)
        credentialHelperURL = credentialURL
        let endpoint = getEnterpriseAPIURL(url.origin)
        guard let clientID = knownClientID(for: endpoint) else {
            showEndpointEntry(address: url.origin, clientID: "")
            return
        }
        await setEndpoint(url.origin, clientID: clientID, isEndpointFromGit: true)
    }

    // MARK: Steps

    /// Selects the enterprise server from the endpoint entry or the
    /// existing-account step.
    ///
    /// A github.com address switches to signing in to GitHub.com. Otherwise
    /// the address must be an https URL and the client ID that of an OAuth
    /// app registered on the server; the server is then checked
    /// (`GET <api>/meta`): one that can't be reached or doesn't answer as GitHub
    /// Enterprise stays at this step with an error, and the version it reports
    /// is recorded for its capabilities. Then the existing-account warning when
    /// an account is signed in to the server, else the authentication step,
    /// which asks to confirm a GitHub Enterprise Server address that came from
    /// git.
    ///
    /// - Parameter isEndpointFromGit: The address came from git (also
    ///   assumed when it is the host git asked about).
    public func setEndpoint(_ address: String, clientID: String, isEndpointFromGit: Bool = false) async {
        guard let current = state, current.kind == .endpointEntry || current.kind == .existingAccountWarning else {
            logger.error("Sign in step \(self.state.map { "'\($0.kind.rawValue)'" } ?? "(none)", privacy: .public) not compatible with endpoint entry")
            return
        }
        // The address is being checked already (the UI disables the step
        // meanwhile).
        guard !current.loading else {
            return
        }

        // If the user enters a github.com url in the GitHub Enterprise
        // sign-in flow we'll redirect them to the GitHub.com sign-in flow.
        if address.contains(/^(?:https:\/\/)?(?:api\.)?github\.com($|\/)/) {
            showDotComSignIn()
            return
        }

        let session = self.session
        setLoading(true, in: current, address: address, clientID: clientID)

        let validURL: String
        do {
            validURL = try validateURL(address)
        } catch {
            let signInError: SignInError = (error as? EnterpriseURLValidationError)?.kind == .invalidProtocol
                ? .unsupportedProtocol
                : .invalidEnterpriseAddress
            show(signInError, in: current, address: address, clientID: clientID)
            return
        }

        let trimmedClientID = clientID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedClientID.isEmpty else {
            show(.missingClientID, in: current, address: address, clientID: clientID)
            return
        }

        let endpoint = getEnterpriseAPIURL(validURL)
        if let error = await checkEnterpriseServer(endpoint) {
            guard session == self.session else {
                return
            }
            show(error, in: current, address: address, clientID: clientID)
            return
        }
        guard session == self.session else {
            return
        }

        let configuration = EndpointConfiguration(endpoint: endpoint, clientID: trimmedClientID)
        if let existingAccount = accounts?.accounts.first(where: { $0.endpoint == endpoint }) {
            state = .existingAccountWarning(SignInState.ExistingAccountWarning(
                existingAccount: existingAccount.withToken(""),
                configuration: configuration,
                error: nil,
                loading: false
            ))
        } else {
            let fromGit = isEndpointFromGit || isCredentialHelperHost(validURL)
            state = .authentication(SignInState.Authentication(
                configuration: configuration,
                isUnrecognizedEnterpriseServer: fromGit && isGHES(endpoint),
                code: nil,
                error: nil,
                loading: false
            ))
        }
    }

    /// Asks the server for a code, shows it, and waits for the user to enter
    /// it on the verification page; then loads the user and stores the
    /// account, replacing any account signed in to the same server.
    ///
    /// Runs from the authentication or the existing-account step; calling it
    /// again (after an error, or for a new code) starts over. Returns when
    /// the sign-in succeeds, fails (the error is in the state), or is
    /// cancelled. Polling honors the server's interval and `slow_down`.
    public func authenticate() async {
        let configuration: EndpointConfiguration
        let isUnrecognizedEnterpriseServer: Bool
        switch state {
        case .authentication(let current)?:
            configuration = current.configuration
            isUnrecognizedEnterpriseServer = current.isUnrecognizedEnterpriseServer
        case .existingAccountWarning(let current)?:
            configuration = current.configuration
            isUnrecognizedEnterpriseServer = false
        default:
            logger.error("Sign in step \(self.state.map { "'\($0.kind.rawValue)'" } ?? "(none)", privacy: .public) not compatible with authentication")
            return
        }
        guard let accounts, let environment = accounts.environment else {
            return
        }

        flowTask?.cancel()
        flowGeneration += 1
        let flow = FlowToken(session: session, generation: flowGeneration)
        state = .authentication(SignInState.Authentication(
            configuration: configuration,
            isUnrecognizedEnterpriseServer: isUnrecognizedEnterpriseServer,
            code: nil,
            error: nil,
            loading: true
        ))
        logger.info("Signing in to \(configuration.endpoint, privacy: .public) with a device code")

        let task = Task {
            await self.runDeviceFlow(
                configuration,
                isUnrecognizedEnterpriseServer: isUnrecognizedEnterpriseServer,
                flow: flow,
                environment: environment
            )
        }
        flowTask = task
        await task.value
    }

    /// Opens the page where the user enters the code, if one is shown.
    /// Returns whether it opened.
    @discardableResult
    public func openVerificationPage() -> Bool {
        guard case .authentication(let current)? = state,
              let code = current.code,
              let url = URL(string: code.verificationURI),
              url.scheme?.lowercased() == "https",
              let workspace = accounts?.environment?.workspace
        else {
            return false
        }
        return workspace.open(url)
    }

    /// Cancels the sign-in in progress, if any, and returns to no sign-in;
    /// whoever started it gets `.cancelled`.
    public func reset() {
        let callback = resultCallback
        resultCallback = nil
        session += 1
        flowTask?.cancel()
        flowTask = nil
        credentialHelperURL = nil
        state = nil
        callback?(.cancelled)
    }

    // MARK: The device flow

    private struct FlowToken {
        let session: Int
        let generation: Int
    }

    private func isCurrent(_ flow: FlowToken) -> Bool {
        flow.session == session && flow.generation == flowGeneration && !Task.isCancelled
    }

    private func runDeviceFlow(
        _ configuration: EndpointConfiguration,
        isUnrecognizedEnterpriseServer: Bool,
        flow: FlowToken,
        environment: AppEnvironment
    ) async {
        let scheduler = environment.scheduler
        let deviceFlow = DeviceFlow(
            configuration: configuration,
            runtime: environment.gitHub,
            sleep: { try await scheduler.sleep(for: $0) },
            now: { scheduler.now }
        )

        func showAuthentication(code: SignInCode?, error: SignInError?, loading: Bool) {
            state = .authentication(SignInState.Authentication(
                configuration: configuration,
                isUnrecognizedEnterpriseServer: isUnrecognizedEnterpriseServer,
                code: code,
                error: error,
                loading: loading
            ))
        }

        do {
            let authorization = try await environment.withRuntimes {
                try await deviceFlow.requestDeviceCode()
            }
            guard isCurrent(flow) else {
                return
            }
            showAuthentication(
                code: SignInCode(
                    userCode: authorization.userCode,
                    verificationURI: authorization.verificationURI,
                    expiresAt: authorization.expiresAt
                ),
                error: nil,
                loading: true
            )

            let token = try await environment.withRuntimes {
                try await deviceFlow.pollForAccessToken(authorization)
            }
            guard isCurrent(flow) else {
                return
            }

            let account: Account
            do {
                account = try await environment.withRuntimes {
                    try await deviceFlow.fetchAccount(token: token)
                }
            } catch {
                if error is CancellationError || Task.isCancelled {
                    throw CancellationError()
                }
                logger.error("Signed in to \(configuration.endpoint, privacy: .public) but could not load the user: \(String(describing: error), privacy: .public)")
                throw SignInError.userNotLoaded
            }
            guard isCurrent(flow), let accounts else {
                return
            }

            try await accounts.add(account)
            guard flow.session == session else {
                // Cancelled while the token was being stored: the account
                // stays (the user authorized it), but the sign-in that was
                // cancelled reports nothing more.
                return
            }

            logger.info("Signed in to \(configuration.endpoint, privacy: .public) as \(account.login, privacy: .public)")
            state = .success(SignInState.Success(account: account.withToken("")))
            let callback = resultCallback
            resultCallback = nil
            accounts.signInDidSucceed(account)
            callback?(.success(account))
        } catch {
            guard isCurrent(flow), !(error is CancellationError) else {
                return
            }
            let signInError = Self.signInError(for: error, endpoint: configuration.endpoint)
            logger.info("Signing in to \(configuration.endpoint, privacy: .public) failed: \(signInError.message, privacy: .public)")
            showAuthentication(code: nil, error: signInError, loading: false)
        }
    }

    /// The error to show for a failed device flow step.
    static func signInError(for error: any Error, endpoint: String) -> SignInError {
        switch error {
        case let error as SignInError:
            return error
        case let error as UntrustedCertificateError:
            return .untrustedCertificate(host: error.host)
        case let error as DeviceFlowError:
            switch error {
            case .expiredToken: return .codeExpired
            case .accessDenied: return .accessDenied
            default: return .deviceFlow(error)
            }
        case is OAuthTokenRequestError:
            // Network failures and server errors: GitHubKit doesn't tell
            // them apart, so it never shows a response.
            return .cannotReach(host: displayHost(of: endpoint))
        case let error as OAuthTokenResponseError:
            return .other(error.message)
        default:
            return .other((error as? LocalizedError)?.errorDescription ?? String(describing: error))
        }
    }

    // MARK: The enterprise check

    /// The check of an enterprise server: `GET <api>/meta`, unauthenticated.
    /// Returns the error to show, or nil when the server answers as GitHub
    /// does.
    ///
    /// GitHub marks its API responses with `X-GitHub-Request-Id`, and
    /// Enterprise Server with `X-GitHub-Enterprise-Version`, which is
    /// recorded for the endpoint's capabilities. A proxy may strip the
    /// headers, so `meta`'s own fields count too. A cancelled check returns
    /// nil; the caller has moved on.
    private func checkEnterpriseServer(_ endpoint: String) async -> SignInError? {
        guard let environment = accounts?.environment else {
            return nil
        }
        let host = Self.displayHost(of: endpoint)
        guard let url = URL(string: getAbsoluteUrl(endpoint, "meta")) else {
            return .invalidEnterpriseAddress
        }

        var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: Self.enterpriseCheckTimeout)
        request.httpMethod = "GET"
        request.setValue("application/vnd.github.v3+json, application/json", forHTTPHeaderField: "Accept")
        request.setValue(environment.gitHub.userAgent, forHTTPHeaderField: "User-Agent")
        request.httpShouldHandleCookies = false

        let response: HTTPURLResponse
        let body: Data
        do {
            let (data, urlResponse) = try await environment.gitHub.session.data(for: request)
            guard let httpResponse = urlResponse as? HTTPURLResponse else {
                return .notGitHubEnterprise(host: host)
            }
            response = httpResponse
            body = data
        } catch {
            if Task.isCancelled || error is CancellationError || (error as? URLError)?.code == .cancelled {
                return nil
            }
            logger.info("Checking \(endpoint, privacy: .public) failed: \(String(describing: error), privacy: .public)")
            if UntrustedCertificateError.isUntrustedCertificate(error) {
                return .untrustedCertificate(host: host)
            }
            return .cannotReach(host: host)
        }

        let meta = (try? JSONValue.parse(body)).flatMap { $0.isRecord ? $0 : nil }
        var version = response.value(forHTTPHeaderField: "x-github-enterprise-version")
        if version == nil, case .string(let installed)? = meta?["installed_version"] {
            version = installed
        }
        if let version, !version.isEmpty {
            environment.gitHub.endpointVersions.updateEndpointVersion(endpoint, version)
        }

        let isGitHub = version != nil
            || response.value(forHTTPHeaderField: "x-github-request-id") != nil
            || meta?["verifiable_password_authentication"] != nil
        if !isGitHub {
            logger.info("\(endpoint, privacy: .public) answered \(response.statusCode, privacy: .public) without GitHub's headers")
            return .notGitHubEnterprise(host: host)
        }
        return nil
    }

    // MARK: Helpers

    private func startSession(_ resultCallback: (@MainActor (SignInResult) -> Void)?) {
        session += 1
        self.resultCallback = resultCallback
        credentialHelperURL = nil
    }

    /// The GitHub.com step: the existing-account warning when a GitHub.com
    /// account is signed in, else authentication.
    private func showDotComSignIn() {
        if let existingAccount = accounts?.accounts.first(where: isDotComAccount) {
            state = .existingAccountWarning(SignInState.ExistingAccountWarning(
                existingAccount: existingAccount.withToken(""),
                configuration: .dotCom,
                error: nil,
                loading: false
            ))
        } else {
            state = .authentication(SignInState.Authentication(
                configuration: .dotCom,
                isUnrecognizedEnterpriseServer: false,
                code: nil,
                error: nil,
                loading: false
            ))
        }
    }

    private func showEndpointEntry(address: String, clientID: String) {
        state = .endpointEntry(SignInState.EndpointEntry(address: address, clientID: clientID, error: nil, loading: false))
    }

    private func setLoading(_ loading: Bool, in current: SignInState, address: String, clientID: String) {
        switch current {
        case .endpointEntry:
            state = .endpointEntry(SignInState.EndpointEntry(address: address, clientID: clientID, error: nil, loading: loading))
        case .existingAccountWarning(var warning):
            warning.error = nil
            warning.loading = loading
            state = .existingAccountWarning(warning)
        default:
            break
        }
    }

    /// Shows `error` at the step `setEndpoint` started from, keeping what
    /// the user entered.
    private func show(_ error: SignInError, in current: SignInState, address: String, clientID: String) {
        switch current {
        case .endpointEntry:
            state = .endpointEntry(SignInState.EndpointEntry(address: address, clientID: clientID, error: error, loading: false))
        case .existingAccountWarning(var warning):
            warning.error = error
            warning.loading = false
            state = .existingAccountWarning(warning)
        default:
            break
        }
    }

    /// The client ID of the OAuth app the endpoint's account signs in with,
    /// signed in, signed out, or with a token the keychain won't give.
    private func knownClientID(for endpoint: String) -> String? {
        let candidates = (accounts?.accounts ?? []) + (accounts?.unreadableAccounts ?? []) + (accounts?.invalidatedAccounts ?? [])
        return candidates.first { $0.endpoint == endpoint }?.endpointConfiguration?.clientID
    }

    /// Whether `address` is on the host git asked credentials for.
    private func isCredentialHelperHost(_ address: String) -> Bool {
        guard let credentialHelperURL,
              let requested = try? JSURL(credentialHelperURL),
              let entered = try? JSURL(address)
        else {
            return false
        }
        return requested.host == entered.host
    }

    private func isDotComEndpoint(_ endpoint: String) -> Bool {
        endpoint == getDotComAPIEndpoint() || (try? JSURL(endpoint))?.hostname == "github.com"
    }

    /// The host to name in messages (`github.com`, `ghe.example.com`).
    static func displayHost(of endpoint: String) -> String {
        (try? JSURL(getHTMLURL(endpoint)))?.host ?? endpoint
    }
}
