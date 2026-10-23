// Signing in with the OAuth device flow through the model: codes, polling
// on the app's scheduler, Enterprise servers, cancellation, errors,
// replacing an account, git's sign-in request, and signing in again.
//
// Flows that run to the end use an `ImmediateScheduler`, whose sleeps return
// at once, so polling needs no driving; flows the test stops while they wait
// for the user use the harness's `ManualScheduler`.

@testable import EspalierCore
import EspalierCoreTestSupport
import EspalierSupport
import Foundation
import GitHubKit
import Synchronization
import Testing
import TestSupport

/// A secret store whose writes fail.
private final class FailingSecretStore: SecretStore {
    struct WriteFailed: Error, CustomStringConvertible {
        var description: String { "The keychain is locked." }
    }

    func secret(service: String, account: String) throws -> String? {
        nil
    }

    func setSecret(_ secret: String, service: String, account: String) throws {
        throw WriteFailed()
    }

    func deleteSecret(service: String, account: String) throws -> Bool {
        throw WriteFailed()
    }
}

@Suite("Device flow sign-in", .offline, .hangGuard(minutes: 5)) @MainActor
struct DeviceFlowSignInTests {
    /// A loaded app on the harness's environment with an immediate
    /// scheduler: the device flow polls without waiting.
    private func immediateApp(_ harness: AppHarness, environment: AppEnvironment? = nil) async -> (AppModel, ImmediateScheduler) {
        let scheduler = ImmediateScheduler(now: harness.scheduler.now)
        var environment = environment ?? harness.environment
        environment.scheduler = scheduler
        let app = AppModel(environment: environment)
        await app.load()
        await app.accounts.idle()
        return (app, scheduler)
    }

    @Test("shows the code to enter and waits for the user")
    func showsCode() async throws {
        let harness = try AppHarness()
        let app = await harness.loadedAppWithAccounts()
        let signIn = app.accounts.signIn
        harness.mockDeviceCode()
        harness.mockTokenRequests([authorizationPending])

        signIn.beginDotComSignIn()
        let authentication = Task { await signIn.authenticate() }
        await harness.scheduler.waitForSleepers(1)

        guard case .authentication(let waiting)? = signIn.state else {
            Issue.record("Expected the code to be shown, got \(String(describing: signIn.state))")
            return
        }
        #expect(waiting.code == SignInCode(
            userCode: "WDJB-MJHT",
            verificationURI: "https://github.com/login/device",
            expiresAt: harness.scheduler.now.addingTimeInterval(900)
        ))
        #expect(waiting.loading)
        #expect(waiting.error == nil)
        // The server's interval, before the first token request.
        #expect(harness.scheduler.sleeps == [.seconds(5)])
        #expect(harness.gitHub.requests("POST", "/login/oauth/access_token").isEmpty)

        let codeRequest = try #require(harness.gitHub.requests("POST", "/login/device/code").first)
        #expect(codeRequest.url.host() == "github.com")
        #expect(codeRequest.form["client_id"] == OAuthConfig.dotComClientID)
        #expect(codeRequest.form["scope"] == "repo user workflow")

        signIn.reset()
        await authentication.value
        await settle(app, harness)
    }

    @Test("signs in to GitHub.com once the code is entered and stores the account")
    func signsInToDotCom() async throws {
        let harness = try AppHarness()
        let (app, scheduler) = await immediateApp(harness)
        let signIn = app.accounts.signIn
        harness.mockDeviceCode()
        harness.mockTokenRequests([authorizationPending, grantedToken("gho_monalisa")])
        harness.mockUser("monalisa", id: 7)
        harness.gitHub.on("GET", "/user/repos", respond: .json(encoding: [apiRepository(owner: "monalisa", name: "dotfiles")]))
        let results = SignInResults()

        signIn.beginDotComSignIn(results.callback)
        await signIn.authenticate()

        guard case .success(let success)? = signIn.state else {
            Issue.record("Expected success, got \(String(describing: signIn.state))")
            return
        }
        #expect(success.account.login == "monalisa")
        #expect(success.account.token.isEmpty)
        #expect(app.accounts.accounts.map(\.login) == ["monalisa"])
        #expect(app.accounts.accounts.first?.clientID == OAuthConfig.dotComClientID)
        #expect(try harness.secrets.secret(service: "Espalier - https://api.github.com", account: "monalisa") == "gho_monalisa")
        #expect(scheduler.sleeps == [.seconds(5), .seconds(5)])
        #expect(harness.gitHub.requests("POST", "/login/oauth/access_token").count == 2)

        guard case .success(let account) = try #require(results.results.first) else {
            Issue.record("Expected a successful result")
            return
        }
        #expect(results.results.count == 1)
        #expect(account.token == "gho_monalisa")

        // In the welcome flow, the repositories to clone start loading.
        await app.accounts.idle()
        #expect(app.accounts.apiRepositories.repositories(for: account)?.repositories.map(\.name) == ["dotfiles"])
        await settle(app, harness)
    }

    @Test("doesn't load repositories to clone after the welcome flow")
    func noRepositoriesAfterWelcome() async throws {
        let harness = try AppHarness()
        harness.defaults.defaults.set(true, forKey: PreferenceKey.hasShownWelcomeFlow)
        let (app, _) = await immediateApp(harness)
        harness.mockDeviceCode()
        harness.mockTokenRequests([grantedToken()])
        harness.mockUser("monalisa", id: 7)

        app.accounts.signIn.beginDotComSignIn()
        await app.accounts.signIn.authenticate()
        await app.accounts.idle()

        #expect(app.accounts.signIn.state?.kind == .success)
        #expect(harness.gitHub.requests("GET", "/user/repos").isEmpty)
        await settle(app, harness)
    }

    @Test("signs in to an Enterprise server with its OAuth app and records its version")
    func signsInToEnterprise() async throws {
        let harness = try AppHarness()
        let (app, _) = await immediateApp(harness)
        let signIn = app.accounts.signIn
        harness.mockEnterpriseMeta(version: "3.14.2")
        harness.mockDeviceCode(verificationURI: "https://github.example.com/login/device")
        harness.mockTokenRequests([grantedToken("gho_ghes")])
        harness.mockUser("enterprise-user", id: 2, prefix: "/api/v3")

        signIn.beginEnterpriseSignIn()
        await signIn.setEndpoint("github.example.com", clientID: "  \(enterpriseClientID)\n")
        guard case .authentication(let ready)? = signIn.state else {
            Issue.record("Expected the authentication step, got \(String(describing: signIn.state))")
            return
        }
        #expect(ready.configuration == EndpointConfiguration(endpoint: enterpriseEndpoint, clientID: enterpriseClientID))
        #expect(!ready.isUnrecognizedEnterpriseServer)
        #expect(harness.environment.gitHub.endpointVersions.getEndpointVersion(enterpriseEndpoint) == SemVer("3.14.2"))

        await signIn.authenticate()

        let account = try #require(app.accounts.accounts.first)
        #expect(account.endpoint == enterpriseEndpoint)
        #expect(account.login == "enterprise-user")
        #expect(account.clientID == enterpriseClientID)

        let metaRequest = try #require(harness.gitHub.requests("GET", "/api/v3/meta").first)
        #expect(metaRequest.url.absoluteString == "https://github.example.com/api/v3/meta")
        #expect(metaRequest.header("Authorization") == nil)
        let codeRequest = try #require(harness.gitHub.requests("POST", "/login/device/code").first)
        #expect(codeRequest.url.absoluteString == "https://github.example.com/login/device/code")
        #expect(codeRequest.form["client_id"] == enterpriseClientID)
        let userRequest = try #require(harness.gitHub.requests("GET", "/api/v3/user").first)
        #expect(userRequest.url.absoluteString == "https://github.example.com/api/v3/user")
        await settle(app, harness)
    }

    @Test("an Enterprise server whose certificate isn't trusted says so")
    func untrustedCertificate() async throws {
        let harness = try AppHarness()
        let app = await harness.loadedAppWithAccounts()
        let signIn = app.accounts.signIn

        signIn.beginEnterpriseSignIn()
        harness.gitHub.on("GET", "/api/v3/meta", respond: .networkError(.serverCertificateUntrusted))
        await signIn.setEndpoint("https://github.example.com", clientID: enterpriseClientID)
        #expect(signIn.state?.kind == .endpointEntry)
        #expect(signIn.state?.error == .untrustedCertificate(host: "github.example.com"))
        let message = try #require(signIn.state?.error?.message)

        // A failure later in the flow, through GitHubKit, says the same.
        #expect(SignInModel.signInError(for: UntrustedCertificateError(host: "github.example.com"), endpoint: "https://github.example.com/api/v3")
            == .untrustedCertificate(host: "github.example.com"))
        #expect(apiFailure(from: UntrustedCertificateError(host: "github.example.com")).message == message)
        await settle(app, harness)
    }

    @Test("checks an Enterprise server before asking for a code")
    func checksEnterpriseServer() async throws {
        let harness = try AppHarness()
        let app = await harness.loadedAppWithAccounts()
        let signIn = app.accounts.signIn

        signIn.beginEnterpriseSignIn()
        await signIn.setEndpoint("https://github.example.com", clientID: " ")
        #expect(signIn.state == .endpointEntry(SignInState.EndpointEntry(
            address: "https://github.example.com",
            clientID: " ",
            error: .missingClientID,
            loading: false
        )))
        #expect(harness.gitHub.requests("GET", "/api/v3/meta").isEmpty)

        harness.gitHub.on("GET", "/api/v3/meta", respond: .networkError(.cannotFindHost))
        await signIn.setEndpoint("https://github.example.com", clientID: enterpriseClientID)
        #expect(signIn.state?.kind == .endpointEntry)
        #expect(signIn.state?.error == .cannotReach(host: "github.example.com"))

        harness.gitHub.on("GET", "/api/v3/meta", respond: .text("<html>Welcome</html>", status: 200))
        await signIn.setEndpoint("https://github.example.com", clientID: enterpriseClientID)
        #expect(signIn.state?.error == .notGitHubEnterprise(host: "github.example.com"))

        // A proxy that strips GitHub's headers still passes meta's fields.
        harness.gitHub.on("GET", "/api/v3/meta", respond: .json(["verifiable_password_authentication": false]))
        await signIn.setEndpoint("https://github.example.com", clientID: enterpriseClientID)
        #expect(signIn.state?.kind == .authentication)
        #expect(harness.gitHub.requests("POST", "/login/device/code").isEmpty)
        await settle(app, harness)
    }

    @Test("adds another account on the server once the new sign-in succeeds, keeping the one signed in")
    func addsAccountAfterSuccess() async throws {
        let harness = try AppHarness()
        try await harness.store(dotComAccount(login: "octocat", token: "gho_octocat"))
        harness.mockUser("octocat", id: 1)
        let (app, _) = await immediateApp(harness)
        let signIn = app.accounts.signIn
        harness.mockDeviceCode()
        harness.mockTokenRequests([oauthError("access_denied")])

        signIn.beginDotComSignIn()
        #expect(signIn.state?.kind == .authentication)
        await signIn.authenticate()

        #expect(signIn.state?.error == .accessDenied)
        #expect(signIn.state?.loading == false)
        #expect(app.accounts.accounts.map(\.login) == ["octocat"])

        harness.mockTokenRequests([grantedToken("gho_monalisa")])
        harness.mockUser("monalisa", id: 7)
        await signIn.authenticate()

        #expect(signIn.state?.kind == .success)
        #expect(app.accounts.accounts.map(\.login) == ["octocat", "monalisa"])
        #expect(try harness.secrets.secret(service: "Espalier - https://api.github.com", account: "octocat") == "gho_octocat")
        #expect(try harness.secrets.secret(service: "Espalier - https://api.github.com", account: "monalisa") == "gho_monalisa")
        #expect(harness.gitHub.requests("POST", "/login/device/code").count == 2)
        await settle(app, harness)
    }

    @Test("signing in again to one account refuses a code another account authorized, and keeps the accounts as they were")
    func refusesAnotherAccount() async throws {
        let harness = try AppHarness()
        try await harness.store(dotComAccount(login: "octocat", token: "gho_octocat"))
        harness.mockUser("octocat", id: 1)
        let (app, _) = await immediateApp(harness)
        let signIn = app.accounts.signIn
        harness.mockDeviceCode()
        harness.mockTokenRequests([grantedToken("gho_monalisa")])
        let results = SignInResults()

        // The browser is signed in to monalisa.
        harness.mockUser("monalisa", id: 7)
        await signIn.beginSignIn(endpoint: dotComEndpoint, login: "OctoCat", results.callback)

        #expect(signIn.state?.error == .wrongAccount(expected: "OctoCat", actual: "monalisa", host: "github.com"))
        #expect(results.results.isEmpty)
        #expect(app.accounts.accounts.map(\.login) == ["octocat"])
        #expect(try harness.secrets.secret(service: "Espalier - https://api.github.com", account: "monalisa") == nil)

        // The right account, ignoring case.
        harness.mockTokenRequests([grantedToken("gho_again")])
        harness.mockUser("octocat", id: 1)
        await signIn.authenticate()

        #expect(results.kinds == ["success"])
        #expect(app.accounts.accounts.map(\.token) == ["gho_again"])
        await settle(app, harness)
    }

    @Test("stops waiting for the user when cancelled")
    func cancelsWhileWaiting() async throws {
        let harness = try AppHarness()
        let app = await harness.loadedAppWithAccounts()
        let signIn = app.accounts.signIn
        harness.mockDeviceCode()
        harness.mockTokenRequests([grantedToken()])
        harness.mockUser("monalisa", id: 7)
        let results = SignInResults()

        signIn.beginDotComSignIn(results.callback)
        let authentication = Task { await signIn.authenticate() }
        await harness.scheduler.waitForSleepers(1)
        signIn.reset()
        await authentication.value

        #expect(signIn.state == nil)
        #expect(results.results == [.cancelled])
        #expect(harness.scheduler.sleeperCount == 0)
        #expect(harness.gitHub.requests("POST", "/login/oauth/access_token").isEmpty)
        #expect(app.accounts.accounts.isEmpty)
        await settle(app, harness)
    }

    @Test("shows that the code expired and gets a new one")
    func codeExpired() async throws {
        let harness = try AppHarness()
        let (app, _) = await immediateApp(harness)
        let signIn = app.accounts.signIn
        harness.mockDeviceCode(expiresIn: 8)
        harness.mockTokenRequests([authorizationPending])
        harness.mockUser("monalisa", id: 7)

        signIn.beginDotComSignIn()
        await signIn.authenticate()

        guard case .authentication(let expired)? = signIn.state else {
            Issue.record("Expected the authentication step")
            return
        }
        #expect(expired.error == .codeExpired)
        #expect(expired.code == nil)
        #expect(!expired.loading)
        // Polled at 5 s; at 10 s the code had expired.
        #expect(harness.gitHub.requests("POST", "/login/oauth/access_token").count == 1)

        harness.mockDeviceCode(userCode: "NEWC-ODE1")
        harness.mockTokenRequests([grantedToken()])
        await signIn.authenticate()

        #expect(signIn.state?.kind == .success)
        #expect(harness.gitHub.requests("POST", "/login/device/code").count == 2)
        await settle(app, harness)
    }

    @Test("fails when the user can't be loaded after authorizing")
    func userNotLoaded() async throws {
        let harness = try AppHarness()
        let (app, _) = await immediateApp(harness)
        let signIn = app.accounts.signIn
        harness.mockDeviceCode()
        harness.mockTokenRequests([grantedToken()])
        harness.gitHub.on("GET", "/user", respond: .json(["message": "Server Error"], status: 500))
        harness.gitHub.on("GET", "/user/emails", respond: .json(encoding: [createMockAPIEmail()]))
        let results = SignInResults()

        signIn.beginDotComSignIn(results.callback)
        await signIn.authenticate()

        // Not left loading.
        #expect(signIn.state?.error == .userNotLoaded)
        #expect(signIn.state?.loading == false)
        #expect(results.results.isEmpty)
        #expect(app.accounts.accounts.isEmpty)
        await settle(app, harness)
    }

    @Test("reports a token the keychain can't store")
    func tokenNotStored() async throws {
        let harness = try AppHarness()
        var environment = harness.environment
        environment.accountsStore = AccountsStore(
            dataStore: UserDefaultsDataStore(harness.defaults.defaults),
            secureStore: FailingSecretStore(),
            runtime: harness.gitHub.runtime
        )
        let (app, _) = await immediateApp(harness, environment: environment)
        let signIn = app.accounts.signIn
        harness.mockDeviceCode()
        harness.mockTokenRequests([grantedToken()])
        harness.mockUser("monalisa", id: 7)

        signIn.beginDotComSignIn()
        await signIn.authenticate()

        #expect(signIn.state?.error == .tokenNotStored("The keychain is locked."))
        #expect(app.accounts.accounts.isEmpty)
        await settle(app, harness)
    }

    @Test("opens the verification page, and only an https one")
    func opensVerificationPage() async throws {
        let harness = try AppHarness()
        let app = await harness.loadedAppWithAccounts()
        let signIn = app.accounts.signIn
        harness.mockDeviceCode()
        harness.mockTokenRequests([authorizationPending])

        #expect(!signIn.openVerificationPage())
        signIn.beginDotComSignIn()
        let authentication = Task { await signIn.authenticate() }
        await harness.scheduler.waitForSleepers(1)
        #expect(signIn.openVerificationPage())
        #expect(harness.workspace.openedURLs == [URL(string: "https://github.com/login/device")!])
        signIn.reset()
        await authentication.value

        harness.mockDeviceCode(verificationURI: "file:///Applications/Calculator.app")
        signIn.beginDotComSignIn()
        let second = Task { await signIn.authenticate() }
        await harness.scheduler.waitForSleepers(1)
        #expect(!signIn.openVerificationPage())
        #expect(harness.workspace.openedURLs.count == 1)
        signIn.reset()
        await second.value
        await settle(app, harness)
    }

    @Test("answers git's sign-in request with the new account")
    func answersGitPrompt() async throws {
        let harness = try AppHarness(responder: nil)
        let (app, _) = await immediateApp(harness)
        let signIn = app.accounts.signIn
        harness.mockDeviceCode()
        harness.mockTokenRequests([grantedToken("gho_from_git")])
        harness.mockUser("monalisa", id: 7)

        let answer = Task { await harness.prompts.promptForGitHubSignIn(endpoint: "https://github.com/") }
        await waitForState { harness.prompts.current != nil }
        let prompt = try #require(harness.prompts.current)

        await signIn.begin(answering: prompt)
        #expect(signIn.credentialHelperURL == "https://github.com/")
        #expect(signIn.state?.kind == .authentication)
        // The code waits until the user asks for it.
        #expect(harness.gitHub.requests("POST", "/login/device/code").isEmpty)

        await signIn.authenticate()

        let account = await answer.value
        #expect(account == TrampolineAccount(endpoint: dotComEndpoint, login: "monalisa", token: "gho_from_git"))
        #expect(harness.prompts.pending.isEmpty)
        await settle(app, harness)
    }

    @Test("reports git's sign-in to a callback, for the sheet that answers git's prompt itself")
    func gitSignInCallback() async throws {
        let harness = try AppHarness()
        let (app, _) = await immediateApp(harness)
        let signIn = app.accounts.signIn
        harness.mockDeviceCode()
        harness.mockTokenRequests([grantedToken("gho_from_git")])
        harness.mockUser("monalisa", id: 7)
        let results = SignInResults()

        await signIn.begin(gitCredentialURL: "https://github.com/octocat/hello.git", results.callback)
        #expect(signIn.credentialHelperURL == "https://github.com/octocat/hello.git")
        #expect(signIn.state?.kind == .authentication)
        // The code waits until the user asks for it.
        #expect(harness.gitHub.requests("POST", "/login/device/code").isEmpty)

        await signIn.authenticate()
        guard case .success(let account)? = results.results.first else {
            Issue.record("Expected a successful result, got \(results.kinds)")
            return
        }
        #expect(results.results.count == 1)
        #expect(account.token == "gho_from_git")

        // A URL that can't be parsed ends at once.
        let unparsable = SignInResults()
        await signIn.begin(gitCredentialURL: "not a URL", unparsable.callback)
        #expect(unparsable.kinds == ["cancelled"])
        await settle(app, harness)
    }

    @Test("dismisses git's sign-in request when the sign-in is cancelled")
    func dismissesGitPrompt() async throws {
        let harness = try AppHarness(responder: nil)
        let app = await harness.loadedAppWithAccounts()
        let signIn = app.accounts.signIn

        let answer = Task { await harness.prompts.promptForGitHubSignIn(endpoint: "https://github.com/") }
        await waitForState { harness.prompts.current != nil }
        await signIn.begin(answering: try #require(harness.prompts.current))
        signIn.reset()

        #expect(await answer.value == nil)
        #expect(signIn.credentialHelperURL == nil)
        await settle(app, harness)
    }

    @Test("asks to confirm an Enterprise Server git asked about")
    func confirmsGitEnterpriseServer() async throws {
        let harness = try AppHarness(responder: nil)
        let app = await harness.loadedAppWithAccounts()
        let signIn = app.accounts.signIn
        harness.mockEnterpriseMeta()

        let answer = Task { await harness.prompts.promptForGitHubSignIn(endpoint: "https://github.example.com/") }
        await waitForState { harness.prompts.current != nil }
        await signIn.begin(answering: try #require(harness.prompts.current))

        // No account told Espalier the server's OAuth app: the user enters it.
        #expect(signIn.state == .endpointEntry(SignInState.EndpointEntry(
            address: "https://github.example.com",
            clientID: "",
            error: nil,
            loading: false
        )))
        await signIn.setEndpoint("https://github.example.com", clientID: enterpriseClientID)
        guard case .authentication(let state)? = signIn.state else {
            Issue.record("Expected the authentication step")
            return
        }
        #expect(state.isUnrecognizedEnterpriseServer)

        signIn.reset()
        #expect(await answer.value == nil)
        await settle(app, harness)
    }

    @Test("signs in again with the OAuth app a signed-out account used")
    func signsInAgain() async throws {
        let harness = try AppHarness()
        let (app, _) = await immediateApp(harness)
        let signIn = app.accounts.signIn
        app.accounts.invalidatedAccounts = [enterpriseAccount(token: "")]
        harness.mockEnterpriseMeta()
        harness.mockDeviceCode(verificationURI: "https://github.example.com/login/device")
        harness.mockTokenRequests([grantedToken("gho_again")])
        harness.mockUser("enterprise-user", id: 2, prefix: "/api/v3")
        let results = SignInResults()

        await signIn.beginSignIn(endpoint: enterpriseEndpoint, results.callback)

        #expect(results.kinds == ["success"])
        #expect(app.accounts.accounts.map(\.login) == ["enterprise-user"])
        #expect(app.accounts.invalidatedAccounts.isEmpty)
        #expect(harness.gitHub.requests("POST", "/login/device/code").first?.form["client_id"] == enterpriseClientID)
        await settle(app, harness)
    }

    @Test("signs in again to GitHub.com, asking for a code at once")
    func recoversDotCom() async throws {
        let harness = try AppHarness()
        try await harness.store(dotComAccount())
        harness.mockUser("octocat", id: 1)
        let (app, _) = await immediateApp(harness)
        let signIn = app.accounts.signIn
        harness.mockDeviceCode()
        harness.mockTokenRequests([grantedToken("gho_reauthorized")])

        await signIn.beginSignIn(endpoint: dotComEndpoint)

        #expect(signIn.state?.kind == .success)
        #expect(app.accounts.accounts.map(\.token) == ["gho_reauthorized"])
        await settle(app, harness)
    }

    @Test("stops at the endpoint entry for an Enterprise server whose OAuth app isn't known")
    func signInAgainUnknownApp() async throws {
        let harness = try AppHarness()
        let app = await harness.loadedAppWithAccounts()
        let signIn = app.accounts.signIn

        await signIn.beginSignIn(endpoint: "https://api.octocorp.ghe.com/")

        // The address, not the API endpoint (api.api.<tenant>).
        #expect(signIn.state == .endpointEntry(SignInState.EndpointEntry(
            address: "https://octocorp.ghe.com/",
            clientID: "",
            error: nil,
            loading: false
        )))
        await settle(app, harness)
    }
}
