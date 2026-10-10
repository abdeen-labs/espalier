// Ported from desktop/app/test/unit/sign-in-store-test.ts
// Adapted to the OAuth device flow: `authenticate()` asks for a code.
// Enterprise addresses take an OAuth app's client ID, and the server is
// checked (`GET <api>/meta`), so those tests answer it. The thinnest cases
// are folded into others: "starts with null state" into "clears the state
// back to null", "transitions to EndpointEntry step" and "sets initial
// state correctly" into "resets previous state before starting", and
// "calls resultCallback when provided" was "calls resultCallback with
// cancelled". The "onDidUpdate" cases aren't ported: the model is
// `@Observable`, which every wait on its state (`waitForState`) relies on.

@testable import EspalierCore
import EspalierCoreTestSupport
import Foundation
import GitHubKit
import Testing
import TestSupport

/// A loaded app with some accounts signed in, and its mock GitHub answering
/// github.example.com's and example.ghe.com's `meta`.
@MainActor
private struct SignInFixture {
    let harness: AppHarness
    let app: AppModel

    var signIn: SignInModel {
        app.accounts.signIn
    }

    /// Waits for the accounts' work, keeping the mock GitHub up until then.
    func settle() async {
        await app.accounts.idle()
        withExtendedLifetime(harness) {}
    }
}

@MainActor
private func makeSignIn(accounts: [Account] = []) async throws -> SignInFixture {
    let harness = try AppHarness()
    for account in accounts {
        try await harness.store(account)
        harness.mockUser(account.login, id: account.id, prefix: account.endpoint == enterpriseEndpoint ? "/api/v3" : "")
    }
    harness.mockEnterpriseMeta()
    harness.mockEnterpriseMeta(path: "/meta", version: nil)
    let app = await harness.loadedAppWithAccounts()
    return SignInFixture(harness: harness, app: app)
}

@Suite("SignInStore", .offline, .hangGuard(minutes: 5)) @MainActor
struct SignInModelTests {
    @Suite("beginDotComSignIn") @MainActor
    struct BeginDotComSignIn {
        @Test("transitions to Authentication step when no existing account")
        func transitionsToAuthentication() async throws {
            let fixture = try await makeSignIn()
            let signIn = fixture.signIn
            signIn.beginDotComSignIn()
            let state = try #require(signIn.state)
            #expect(state.kind == .authentication)
            #expect(state.endpoint == getDotComAPIEndpoint())
            #expect(state.error == nil)
            #expect(state.loading == false)
            await fixture.settle()
        }

        @Test("transitions to ExistingAccountWarning when a dotcom account exists")
        func transitionsToExistingAccountWarning() async throws {
            let fixture = try await makeSignIn(accounts: [dotComAccount()])
            let signIn = fixture.signIn
            signIn.beginDotComSignIn()
            #expect(signIn.state?.kind == .existingAccountWarning)
            guard case .existingAccountWarning(let warning)? = signIn.state else {
                return
            }
            #expect(warning.existingAccount.login == "octocat")
            #expect(warning.existingAccount.token.isEmpty)
            await fixture.settle()
        }
    }

    @Suite("beginEnterpriseSignIn") @MainActor
    struct BeginEnterpriseSignIn {
        @Test("resets previous state before starting")
        func resetsPreviousState() async throws {
            let fixture = try await makeSignIn()
            let signIn = fixture.signIn
            // Start a dotcom sign-in first
            signIn.beginDotComSignIn()
            #expect(signIn.state?.kind == .authentication)

            // Starting enterprise sign-in should replace that state
            signIn.beginEnterpriseSignIn()
            #expect(signIn.state?.kind == .endpointEntry)
            #expect(signIn.state?.error == nil)
            #expect(signIn.state?.loading == false)
            await fixture.settle()
        }
    }

    @Suite("setEndpoint") @MainActor
    struct SetEndpoint {
        @Test("marks a new Enterprise server requested by Git for confirmation")
        func marksServerRequestedByGit() async throws {
            let fixture = try await makeSignIn()
            let signIn = fixture.signIn
            signIn.beginEnterpriseSignIn()
            await signIn.setEndpoint("https://github.example.com", clientID: enterpriseClientID, isEndpointFromGit: true)

            guard case .authentication(let state)? = signIn.state else {
                Issue.record("Expected the authentication step, got \(String(describing: signIn.state))")
                return
            }
            #expect(state.configuration.endpoint == "https://github.example.com/api/v3")
            #expect(state.configuration.clientID == enterpriseClientID)
            #expect(state.isUnrecognizedEnterpriseServer)
            await fixture.settle()
        }

        @Test("retains server confirmation guidance while asking for a code")
        func retainsGuidanceWhileAuthenticating() async throws {
            let fixture = try await makeSignIn()
            let harness = fixture.harness
            let signIn = fixture.signIn
            harness.mockDeviceCode(verificationURI: "https://github.example.com/login/device")
            harness.mockTokenRequests([authorizationPending])
            signIn.beginEnterpriseSignIn()
            await signIn.setEndpoint("https://github.example.com", clientID: enterpriseClientID, isEndpointFromGit: true)

            let authentication = Task { await signIn.authenticate() }
            await waitForState {
                if case .authentication(let state)? = signIn.state { state.code != nil } else { false }
            }

            guard case .authentication(let state)? = signIn.state else {
                Issue.record("Expected the authentication step")
                return
            }
            #expect(state.isUnrecognizedEnterpriseServer)
            #expect(state.code?.userCode == "WDJB-MJHT")
            #expect(state.loading)
            signIn.reset()
            await authentication.value
            await fixture.settle()
        }

        @Test("does not ask for a token before authenticating")
        func doesNotPollBeforeAuthenticating() async throws {
            let fixture = try await makeSignIn()
            let harness = fixture.harness
            let signIn = fixture.signIn
            signIn.beginEnterpriseSignIn()
            await signIn.setEndpoint("https://github.example.com", clientID: enterpriseClientID, isEndpointFromGit: true)
            let state = signIn.state

            #expect(harness.gitHub.requests("POST", "/login/device/code").isEmpty)
            #expect(harness.gitHub.requests("POST", "/login/oauth/access_token").isEmpty)
            #expect(signIn.state == state)
            await fixture.settle()
        }

        @Test("cancels a Git-requested sign-in before asking for a code")
        func cancelsBeforeAskingForACode() async throws {
            let fixture = try await makeSignIn()
            let signIn = fixture.signIn
            let results = SignInResults()
            signIn.beginEnterpriseSignIn(results.callback)
            await signIn.setEndpoint("https://github.example.com", clientID: enterpriseClientID, isEndpointFromGit: true)

            signIn.reset()

            #expect(signIn.state == nil)
            #expect(results.kinds == ["cancelled"])
            await fixture.settle()
        }

        @Test("shows guidance again after cancelling and starting a new sign-in")
        func showsGuidanceAgain() async throws {
            let fixture = try await makeSignIn()
            let signIn = fixture.signIn
            signIn.beginEnterpriseSignIn()
            await signIn.setEndpoint("https://github.example.com", clientID: enterpriseClientID, isEndpointFromGit: true)
            signIn.reset()

            signIn.beginEnterpriseSignIn()
            await signIn.setEndpoint("https://github.example.com", clientID: enterpriseClientID, isEndpointFromGit: true)

            guard case .authentication(let state)? = signIn.state else {
                Issue.record("Expected the authentication step")
                return
            }
            #expect(state.isUnrecognizedEnterpriseServer)
            await fixture.settle()
        }

        @Test("validates Git-requested endpoints before showing confirmation guidance")
        func validatesBeforeGuidance() async throws {
            let fixture = try await makeSignIn()
            let signIn = fixture.signIn
            signIn.beginEnterpriseSignIn()
            await signIn.setEndpoint("http://github.example.com", clientID: enterpriseClientID, isEndpointFromGit: true)

            let state = try #require(signIn.state)
            #expect(state.kind == .endpointEntry)
            #expect(state.error != nil)
            #expect(state.loading == false)
            await fixture.settle()
        }

        @Test("does not show server confirmation guidance", arguments: [
            "https://github.com",
            "https://api.github.com",
            "https://example.ghe.com",
        ])
        func noGuidance(url: String) async throws {
            let fixture = try await makeSignIn()
            let signIn = fixture.signIn
            signIn.beginEnterpriseSignIn()
            await signIn.setEndpoint(url, clientID: enterpriseClientID, isEndpointFromGit: true)

            guard case .authentication(let state)? = signIn.state else {
                Issue.record("Expected the authentication step for \(url), got \(String(describing: signIn.state))")
                return
            }
            #expect(!state.isUnrecognizedEnterpriseServer)
            await fixture.settle()
        }

        @Test("redirects github.com addresses to the dotcom flow", arguments: [
            NamedCase("redirects to dotcom flow for github.com URLs", "https://github.com"),
            NamedCase("redirects to dotcom flow for api.github.com URLs", "https://api.github.com"),
        ])
        func redirectsToDotCom(_ testCase: NamedCase<String>) async throws {
            let fixture = try await makeSignIn()
            let signIn = fixture.signIn
            signIn.beginEnterpriseSignIn()
            await signIn.setEndpoint(testCase.value, clientID: "")

            // Should redirect to the Authentication step with the dotcom endpoint
            #expect(signIn.state?.kind == .authentication)
            #expect(signIn.state?.endpoint == getDotComAPIEndpoint())
            await fixture.settle()
        }

        @Test("sets error for non-HTTPS URL")
        func setsErrorForHTTP() async throws {
            let fixture = try await makeSignIn()
            let signIn = fixture.signIn
            signIn.beginEnterpriseSignIn()
            await signIn.setEndpoint("http://github.example.com", clientID: enterpriseClientID)

            #expect(signIn.state?.kind == .endpointEntry)
            #expect(signIn.state?.error == .unsupportedProtocol)
            #expect(signIn.state?.error?.message == "Only https addresses are supported for GitHub Enterprise.")
            #expect(signIn.state?.loading == false)
            await fixture.settle()
        }

        @Test("warns of the existing account for a known Enterprise endpoint, whoever asked", arguments: [
            NamedCase("keeps the existing-account warning for a known Enterprise endpoint", (login: "enterprise-user", isEndpointFromGit: true)),
            NamedCase("shows ExistingAccountWarning if enterprise account exists", (login: "user", isEndpointFromGit: false)),
        ])
        func existingAccountWarning(_ testCase: NamedCase<(login: String, isEndpointFromGit: Bool)>) async throws {
            let fixture = try await makeSignIn(accounts: [enterpriseAccount(login: testCase.value.login)])
            let signIn = fixture.signIn
            signIn.beginEnterpriseSignIn()
            await signIn.setEndpoint("https://github.example.com", clientID: enterpriseClientID, isEndpointFromGit: testCase.value.isEndpointFromGit)

            #expect(signIn.state?.kind == .existingAccountWarning)
            await fixture.settle()
        }
    }

    @Suite("reset") @MainActor
    struct Reset {
        @Test("clears the state back to null")
        func clearsState() async throws {
            let fixture = try await makeSignIn()
            let signIn = fixture.signIn
            // "starts with null state".
            #expect(signIn.state == nil)
            signIn.beginDotComSignIn()
            #expect(signIn.state != nil)

            signIn.reset()
            #expect(signIn.state == nil)
            await fixture.settle()
        }

        @Test("calls resultCallback with cancelled")
        func callsCallbackWithCancelled() async throws {
            let fixture = try await makeSignIn()
            let signIn = fixture.signIn
            let results = SignInResults()
            signIn.beginDotComSignIn(results.callback)

            signIn.reset()
            #expect(results.results == [.cancelled])
            await fixture.settle()
        }
    }
}
