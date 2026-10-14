@testable import EspalierCore
import EspalierSupport
import Foundation
import GitKit
import Testing
import TestSupport

/// The credential helper end to end: real git asks espalier-askpass (as
/// `credential.helper`), which asks the app, against a local HTTP server
/// that requires Basic authentication.
@Suite("Trampoline credential helper")
struct TrampolineCredentialHelperTests {
    /// What fetch, pull, push, and clone add (`envForRemoteOperation`).
    let remoteEnv: [String: String?] = ["GIT_TERMINAL_PROMPT": "0"]

    func lsRemote(_ url: String, background: Bool = false, env: [String: String?] = [:]) async throws -> GitResult {
        let directory = try createTempDirectory()
        return try await git(
            ["ls-remote", url],
            directory,
            "lsRemote",
            options: GitExecutionOptions(env: remoteEnv.merging(env) { $1 }, isBackgroundTask: background)
        )
    }

    func endpoint(_ server: AuthHTTPServer) -> String {
        "http://127.0.0.1:\(server.port)/"
    }

    @Test("prompts for a generic credential and stores it once git succeeds")
    func promptAccepted() async throws {
        let server = try AuthHTTPServer(username: "joe", password: "s3cret")
        defer { server.stop() }
        let prompter = TestPrompter(genericGitAuthentication: { endpoint, _ in
            TrampolineAccount(endpoint: endpoint, login: "joe", token: "s3cret")
        })

        try await withTrampoline(prompter: prompter) { context in
            let result = try await lsRemote(server.url())

            #expect(result.stdout.contains("\(AuthHTTPServer.commit)\trefs/heads/main"))
            #expect(prompter.calls == [.genericGitAuthentication(endpoint: endpoint(server), username: nil)])
            #expect(server.authorizations.first == .some(nil))
            #expect(server.authorizations.dropFirst().allSatisfy { $0 == AuthHTTPServer.basic("joe", "s3cret") })

            // Git asks the helper to store the credential after it worked.
            #expect(context.genericGitAuth.getGenericUsername(endpoint(server)) == "joe")
            #expect(try context.genericGitAuth.getGenericPassword(endpoint(server), "joe") == "s3cret")
            #expect(try context.secrets.secret(service: "Espalier - \(endpoint(server))", account: "joe") == "s3cret")
        }
    }

    @Test("uses a stored generic credential without prompting")
    func genericCredentialFound() async throws {
        let server = try AuthHTTPServer(username: "joe", password: "s3cret")
        defer { server.stop() }
        let prompter = TestPrompter()

        try await withTrampoline(prompter: prompter) { context in
            try context.genericGitAuth.setGenericCredential(endpoint(server), "joe", "s3cret")

            let result = try await lsRemote(server.url())

            #expect(result.stdout.contains("refs/heads/main"))
            #expect(prompter.calls == [])
        }
    }

    @Test("uses the username in the remote URL")
    func usernameFromURL() async throws {
        let server = try AuthHTTPServer(username: "joe", password: "s3cret")
        defer { server.stop() }
        let prompter = TestPrompter(genericGitAuthentication: { endpoint, username in
            TrampolineAccount(endpoint: endpoint, login: username ?? "", token: "s3cret")
        })

        try await withTrampoline(prompter: prompter) { context in
            let url = "http://joe@127.0.0.1:\(server.port)/repo.git"
            _ = try await lsRemote(url)

            #expect(prompter.calls == [.genericGitAuthentication(endpoint: "http://joe@127.0.0.1:\(server.port)/", username: "joe")])
            // Stored under the endpoint without credentials.
            #expect(try context.genericGitAuth.getGenericPassword(endpoint(server), "joe") == "s3cret")

            // The next run finds the password for the URL's username.
            _ = try await lsRemote(url)
            #expect(prompter.calls.count == 1)
        }
    }

    @Test("finds a stored credential for a username the remote URL percent-encodes")
    func encodedUsernameFromURL() async throws {
        let server = try AuthHTTPServer(username: "joe@example.com", password: "s3cret")
        defer { server.stop() }
        let prompter = TestPrompter(genericGitAuthentication: { endpoint, username in
            TrampolineAccount(endpoint: endpoint, login: username ?? "", token: "s3cret")
        })

        try await withTrampoline(prompter: prompter) { context in
            let url = "http://joe%40example.com@127.0.0.1:\(server.port)/repo.git"
            _ = try await lsRemote(url)

            // The prompt is filled in with the username decoded, and it's
            // stored decoded, as git gives it.
            #expect(prompter.calls == [
                .genericGitAuthentication(endpoint: "http://joe%40example.com@127.0.0.1:\(server.port)/", username: "joe@example.com"),
            ])
            #expect(try context.genericGitAuth.getGenericPassword(endpoint(server), "joe@example.com") == "s3cret")

            // The next run finds the password for the URL's username.
            _ = try await lsRemote(url)
            #expect(prompter.calls.count == 1)
        }
    }

    @Test("rewrites the error when the user cancels the prompt")
    func promptCancelled() async throws {
        let server = try AuthHTTPServer(username: "joe", password: "s3cret")
        defer { server.stop() }
        let prompter = TestPrompter(genericGitAuthentication: { _, _ in nil })

        try await withTrampoline(prompter: prompter) { context in
            let error = await #expect(throws: GitError.self) {
                try await lsRemote(server.url())
            }

            #expect(prompter.calls == [.genericGitAuthentication(endpoint: endpoint(server), username: nil)])
            #expect(error?.message == getDescriptionForError(.httpsAuthenticationFailed, ""))
            #expect(error?.isRawMessage == false)
            #expect(error?.result.stderr.contains("terminal prompts disabled") == true)
            #expect(context.genericGitAuth.getGenericUsername(endpoint(server)) == nil)
            // Git never sent credentials.
            #expect(server.authorizations.allSatisfy { $0 == nil })
        }
    }

    @Test("doesn't prompt during a background task")
    func backgroundTask() async throws {
        let server = try AuthHTTPServer(username: "joe", password: "s3cret")
        defer { server.stop() }
        let prompter = TestPrompter(genericGitAuthentication: { endpoint, _ in
            TrampolineAccount(endpoint: endpoint, login: "joe", token: "s3cret")
        })

        try await withTrampoline(prompter: prompter) { _ in
            let error = await #expect(throws: GitError.self) {
                try await lsRemote(server.url(), background: true)
            }

            #expect(prompter.calls == [])
            #expect(error?.message == getDescriptionForError(.httpsAuthenticationFailed, ""))
        }
    }

    @Test("erases a stored credential the server rejects")
    func storeAndErase() async throws {
        let server = try AuthHTTPServer(username: "joe", password: "new")
        defer { server.stop() }
        let prompter = TestPrompter()

        try await withTrampoline(prompter: prompter) { context in
            try context.genericGitAuth.setGenericCredential(endpoint(server), "joe", "old")

            let error = await #expect(throws: GitError.self) {
                try await lsRemote(server.url())
            }

            #expect(error?.result.gitError == .httpsAuthenticationFailed)
            #expect(server.authorizations.contains(AuthHTTPServer.basic("joe", "old")))
            #expect(prompter.calls == [])
            // Git told the helper to erase what it rejected.
            #expect(context.genericGitAuth.getGenericUsername(endpoint(server)) == nil)
            #expect(try context.genericGitAuth.getGenericPassword(endpoint(server), "joe") == nil)
        }
    }

    @Test("uses the signed-in account of a GitHub host and stores nothing")
    func accountFound() async throws {
        let server = try AuthHTTPServer(username: "octocat", password: "gho_token")
        defer { server.stop() }
        let prompter = TestPrompter()
        let accounts = TestAccounts([
            TrampolineAccount(endpoint: "http://ghes.espalier.test/api/v3", login: "octocat", token: "gho_token"),
        ])

        try await withTrampoline(prompter: prompter, accounts: accounts) { context in
            // The test server is the proxy for the made-up host.
            let result = try await lsRemote("http://ghes.espalier.test/owner/repo.git", env: ["http_proxy": server.proxyURL])

            #expect(result.stdout.contains("refs/heads/main"))
            #expect(server.requests.allSatisfy { $0.host == "ghes.espalier.test" })
            #expect(prompter.calls == [])
            #expect(context.genericGitAuth.getGenericUsername("http://ghes.espalier.test/") == nil)
        }
    }

    @Test("asks to sign in to github.com when there's no account")
    func gitHubSignIn() async throws {
        let server = try AuthHTTPServer(username: "octocat", password: "gho_token")
        defer { server.stop() }
        let prompter = TestPrompter(gitHubSignIn: { _ in
            TrampolineAccount(endpoint: "https://api.github.com", login: "octocat", token: "gho_token")
        })

        try await withTrampoline(prompter: prompter) { context in
            let result = try await lsRemote("http://github.com/owner/repo.git", env: ["http_proxy": server.proxyURL])

            #expect(result.stdout.contains("refs/heads/main"))
            #expect(server.requests.allSatisfy { $0.host == "github.com" })
            #expect(prompter.calls == [.gitHubSignIn(endpoint: "http://github.com/")])
            // GitHub credentials are never stored as generic ones.
            #expect(context.genericGitAuth.getGenericUsername("http://github.com/") == nil)
        }
    }

    @Test("rewrites the error when the user cancels signing in")
    func gitHubSignInCancelled() async throws {
        let server = try AuthHTTPServer(username: "octocat", password: "gho_token")
        defer { server.stop() }
        let prompter = TestPrompter(gitHubSignIn: { _ in nil })

        try await withTrampoline(prompter: prompter) { _ in
            let error = await #expect(throws: GitError.self) {
                try await lsRemote("http://github.com/owner/repo.git", env: ["http_proxy": server.proxyURL])
            }

            #expect(prompter.calls == [.gitHubSignIn(endpoint: "http://github.com/")])
            #expect(error?.message == getDescriptionForError(.httpsAuthenticationFailed, ""))
        }
    }

    @Test("says to try again in Settings instead of signing in when the account's token couldn't be read", arguments: [false, true])
    func unreadableAccount(background: Bool) async throws {
        let server = try AuthHTTPServer(username: "octocat", password: "gho_token")
        defer { server.stop() }
        let prompter = TestPrompter(gitHubSignIn: { _ in
            TrampolineAccount(endpoint: "https://api.github.com", login: "octocat", token: "gho_token")
        })
        let message = "The keychain is locked."
        let accounts = TestAccounts(unreadable: ["https://api.github.com": message])

        try await withTrampoline(prompter: prompter, accounts: accounts) { _ in
            let error = await #expect(throws: GitError.self) {
                try await lsRemote("http://github.com/owner/repo.git", background: background, env: ["http_proxy": server.proxyURL])
            }

            #expect(prompter.calls == [])
            #expect(error?.message == message)
            #expect(error?.isRawMessage == false)
            #expect(server.authorizations.allSatisfy { $0 == nil })
        }
    }

    @Test("recognizes an enterprise host from its authentication realm")
    func enterpriseRealm() async throws {
        let server = try AuthHTTPServer(username: "octocat", password: "ghe_token", realm: "GitHub")
        defer { server.stop() }
        let prompter = TestPrompter(gitHubSignIn: { _ in
            TrampolineAccount(endpoint: "https://ghes.espalier.test/api/v3", login: "octocat", token: "ghe_token")
        })

        try await withTrampoline(prompter: prompter) { _ in
            let result = try await lsRemote("http://ghes.espalier.test/owner/repo.git", env: ["http_proxy": server.proxyURL])

            #expect(result.stdout.contains("refs/heads/main"))
            #expect(prompter.calls == [.gitHubSignIn(endpoint: "http://ghes.espalier.test/")])
        }
    }

    @Test("asks the accounts provider whether an unknown HTTPS host is a GitHub host")
    func isGitHubHostIsConsulted() async throws {
        let asked = TestCounter()
        let accounts = TestAccounts(isGitHubHost: { url in
            asked.increment()
            return url == "https://code.espalier.test/"
        })
        let prompter = TestPrompter()

        try await withTrampoline(prompter: prompter, accounts: accounts) { context in
            let invocation = TrampolineInvocation(path: "/", isBackgroundTask: false, runtime: context.runtime)
            let helper = TrampolineCredentialHelper(
                invocation: invocation,
                store: accounts,
                prompter: prompter,
                genericGitAuth: context.genericGitAuth,
                useExternalCredentialHelper: { false }
            )
            let command = TrampolineCommand(
                identifier: .credential,
                trampolineToken: "token",
                parameters: ["get"],
                environmentVariables: [:],
                workingDirectory: "/",
                forwardsStandardInput: true,
                parentProcessID: nil
            )

            // An enterprise host without an account: sign in.
            _ = await helper.handle(command, stdin: "protocol=https\nhost=code.espalier.test\n")
            #expect(prompter.calls == [.gitHubSignIn(endpoint: "https://code.espalier.test/")])

            // Anything else is generic.
            _ = await helper.handle(command, stdin: "protocol=https\nhost=git.espalier.test\n")
            #expect(prompter.calls.last == .genericGitAuthentication(endpoint: "https://git.espalier.test/", username: nil))
            #expect(asked.value == 2)

            // Known third-party realms are generic without asking.
            _ = await helper.handle(command, stdin: "protocol=https\nhost=gitlab.espalier.test\nwwwauth[]=Basic realm=\"GitLab\"\n")
            #expect(asked.value == 2)
        }
    }

    @Test("uses Git Credential Manager when the external helper is on", .hangGuard(minutes: 5))
    func externalHelper() async throws {
        let server = try AuthHTTPServer(username: "joe", password: "s3cret")
        defer { server.stop() }
        let prompter = TestPrompter(genericGitAuthentication: { endpoint, _ in
            TrampolineAccount(endpoint: endpoint, login: "joe", token: "from the prompt")
        })
        // A plain-text store in a temporary directory, so nothing reaches the
        // keychain, and no interface even if GCM wanted to prompt.
        let store = try createTempDirectory()
        let gcm = [
            "GCM_CREDENTIAL_STORE": "plaintext",
            "GCM_PLAINTEXT_STORE_PATH": store,
            "GCM_ALLOW_UNSAFE_REMOTES": "true",
            "GCM_PROVIDER": "generic",
            "GCM_GUI_PROMPT": "0",
        ]

        try await withTrampoline(prompter: prompter, environment: gcm, configure: { setUseExternalCredentialHelper(true, defaults: $0) }) { context in
            let directory = try createTempDirectory()
            let credential = GitCredential([
                ("protocol", "http"),
                ("host", "127.0.0.1:\(server.port)"),
                ("username", "joe"),
                ("password", "s3cret"),
            ])
            try await approveCredential(credential, directory, ["GCM_INTERACTIVE": "0"])

            let result = try await lsRemote(server.url())

            #expect(result.stdout.contains("refs/heads/main"))
            #expect(server.authorizations.contains(AuthHTTPServer.basic("joe", "s3cret")))
            // Neither Espalier's prompt nor its own storage was involved.
            #expect(prompter.calls == [])
            #expect(context.genericGitAuth.getGenericUsername(endpoint(server)) == nil)

            // When the server rejects it, git erases it from GCM.
            server.setCredentials(username: "joe", password: "changed")
            await #expect(throws: GitError.self) {
                try await lsRemote(server.url())
            }
            let lookup = GitCredential([("protocol", "http"), ("host", "127.0.0.1:\(server.port)")])
            await #expect(throws: GitCredentialCommandError.self) {
                try await fillCredential(lookup, directory, ["GCM_INTERACTIVE": "0"])
            }

            // A background task finds nothing and doesn't prompt.
            await #expect(throws: GitError.self) {
                try await lsRemote(server.url(), background: true)
            }
            #expect(prompter.calls == [])
        }
    }

    @Test("works from a helper path with spaces and quotes")
    func helperPathNeedsQuoting() async throws {
        let directory = POSIXPath.join(try createTempDirectory(), "it's a $HOME `dir`!")
        try FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: false)
        let helper = POSIXPath.join(directory, "espalier askpass")
        try FileManager.default.createSymbolicLink(atPath: helper, withDestinationPath: askpassHelperPath)

        let server = try AuthHTTPServer(username: "joe", password: "s3cret")
        defer { server.stop() }
        let prompter = TestPrompter(genericGitAuthentication: { endpoint, _ in
            TrampolineAccount(endpoint: endpoint, login: "joe", token: "s3cret")
        })

        try await withTrampoline(prompter: prompter, helperPath: helper) { context in
            let result = try await lsRemote(server.url())

            #expect(result.stdout.contains("refs/heads/main"))
            #expect(prompter.calls.count == 1)
            #expect(try context.genericGitAuth.getGenericPassword(endpoint(server), "joe") == "s3cret")
        }
    }

    @Test("serves concurrent git invocations their own credentials")
    func concurrentInvocations() async throws {
        let servers = try (0..<6).map { index in
            try AuthHTTPServer(username: "user\(index)", password: "password\(index)")
        }
        defer { servers.forEach { $0.stop() } }
        let ports = servers.map(\.port)
        let prompter = TestPrompter(genericGitAuthentication: { endpoint, _ in
            guard let index = ports.firstIndex(where: { endpoint.contains(":\($0)/") }) else { return nil }
            // Answer out of order.
            try? await Task.sleep(for: .milliseconds(50 * (6 - index)))
            return TrampolineAccount(endpoint: endpoint, login: "user\(index)", token: "password\(index)")
        })

        try await withTrampoline(prompter: prompter) { context in
            try await withThrowingTaskGroup { group in
                for server in servers {
                    group.addTask {
                        try await lsRemote(server.url()).stdout
                    }
                }
                for try await stdout in group {
                    #expect(stdout.contains("refs/heads/main"))
                }
            }

            for (index, server) in servers.enumerated() {
                #expect(try context.genericGitAuth.getGenericPassword(endpoint(server), "user\(index)") == "password\(index)")
            }
            #expect(prompter.calls.count == 6)
        }
    }
}

/// A thread-safe counter.
final class TestCounter: Sendable {
    private let count = Mutex(0)

    func increment() {
        count.withLock { $0 += 1 }
    }

    var value: Int {
        count.withLock { $0 }
    }
}

import Synchronization
