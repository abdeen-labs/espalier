// Ported from desktop/app/test/unit/trampoline-credential-helper-test.ts
//
// Which credentials the credential helper gives a request, by the repository
// git runs in: its assigned account, of several on one host, only on its
// GitHub repository's exact origin; asking for one only for git commands the
// user started; the fallback account of a clone; never another endpoint's.
// The helper is driven directly with git's request, without a server.

@testable import EspalierCore
import EspalierSupport
import Foundation
import GitHubKit
import GitKit
import Testing
import TestSupport

@Suite("Trampoline repository accounts")
struct TrampolineRepositoryAccountTests {
    static let dotCom = "https://api.github.com"
    static let first = TrampolineAccount(endpoint: dotCom, login: "first", token: "first-token")
    static let second = TrampolineAccount(endpoint: dotCom, login: "second", token: "second-token")
    static let path = "/Users/joe/Developer/app"

    /// What the helper prints for `get` with `stdin`: the credential, or nil.
    private func get(
        _ stdin: String,
        accounts: TestAccounts,
        prompter: TestPrompter = TestPrompter(),
        path: String = Self.path,
        background: Bool = false,
        fallback: GitFallbackAccount? = nil
    ) async throws -> (output: String?, invocation: TrampolineInvocation) {
        try await withTrampoline(prompter: prompter, accounts: accounts) { context in
            let invocation = TrampolineInvocation(path: path, isBackgroundTask: background, fallbackAccount: fallback, runtime: context.runtime)
            let helper = TrampolineCredentialHelper(
                invocation: invocation,
                store: accounts,
                prompter: prompter,
                genericGitAuth: context.genericGitAuth,
                useExternalCredentialHelper: { false }
            )
            return (await helper.handle(TrampolineCredentialHelperTests.getCommand, stdin: stdin), invocation)
        }
    }

    private func repository(endpoint: String? = Self.dotCom, login: String?) -> TrampolineRepository {
        TrampolineRepository(id: RepositoryID(), endpoint: endpoint, accountLogin: login)
    }

    @Test("gives the repository's own account, of two on one host")
    func assignedOfTwo() async throws {
        let accounts = TestAccounts([Self.first, Self.second], repositories: [Self.path: repository(login: "second")])

        let output = try await get("protocol=https\nhost=github.com\n", accounts: accounts).output

        #expect(output?.contains("username=second\n") == true)
        #expect(output?.contains("password=second-token\n") == true)
        #expect(output?.contains("first-token") == false)
        #expect(accounts.promptedRepositories.isEmpty)
    }

    @Test("matches the assigned login ignoring case")
    func loginCase() async throws {
        let accounts = TestAccounts([Self.first], repositories: [Self.path: repository(login: "FIRST")])

        let output = try await get("protocol=https\nhost=github.com\n", accounts: accounts).output

        #expect(output?.contains("password=first-token\n") == true)
    }

    @Test("sends a token only to its repository's exact origin: scheme, host, and port", arguments: [
        NamedCase("the server's port", (request: "protocol=https\nhost=ghes.espalier.test:8443\n", sent: true)),
        NamedCase("the default port", (request: "protocol=https\nhost=ghes.espalier.test\n", sent: false)),
        NamedCase("another port", (request: "protocol=https\nhost=ghes.espalier.test:9443\n", sent: false)),
        NamedCase("plain HTTP", (request: "protocol=http\nhost=ghes.espalier.test:8443\n", sent: false)),
        NamedCase("another host", (request: "protocol=https\nhost=other.espalier.test:8443\n", sent: false)),
    ])
    func exactOrigin(_ testCase: NamedCase<(request: String, sent: Bool)>) async throws {
        let endpoint = "https://ghes.espalier.test:8443/api/v3"
        let account = TrampolineAccount(endpoint: endpoint, login: "octocat", token: "ghes-token")
        let accounts = TestAccounts(
            [account],
            repositories: [Self.path: repository(endpoint: endpoint, login: "octocat")],
            isGitHubHost: { _ in true },
            repositoryAccount: { _ in account }
        )

        let output = try await get(testCase.value.request, accounts: accounts).output

        #expect((output?.contains("ghes-token") ?? false) == testCase.value.sent)
        // Another origin never asks for the repository's account either.
        #expect(accounts.promptedRepositories.isEmpty)
    }

    @Test("asks for the account of a repository without one, and uses the one chosen")
    func asksWithoutAccount() async throws {
        let accounts = TestAccounts([Self.first, Self.second], repositories: [Self.path: repository(login: nil)], repositoryAccount: { _ in Self.second })

        let output = try await get("protocol=https\nhost=github.com\n", accounts: accounts).output

        #expect(output?.contains("password=second-token\n") == true)
        #expect(accounts.promptedRepositories.map(\.accountLogin) == [nil])
    }

    @Test("asks again for a repository whose account is signed out, without using another account on its host")
    func asksWhenSignedOut() async throws {
        let accounts = TestAccounts([Self.first], repositories: [Self.path: repository(login: "gone")])

        let output = try await get("protocol=https\nhost=github.com\n", accounts: accounts).output

        #expect(output == nil)
        #expect(accounts.promptedRepositories.map(\.accountLogin) == ["gone"])
    }

    @Test("ignores a chosen account on another endpoint")
    func chosenOnAnotherEndpoint() async throws {
        let enterprise = TrampolineAccount(endpoint: "https://ghe.example.com/api/v3", login: "first", token: "ghe-token")
        let accounts = TestAccounts([Self.first], repositories: [Self.path: repository(login: nil)], repositoryAccount: { _ in enterprise })

        let output = try await get("protocol=https\nhost=github.com\n", accounts: accounts).output

        #expect(output == nil)
    }

    @Test("a background task never asks, and gets nothing without the repository's account", arguments: [
        NamedCase("no account", Optional<String>.none),
        NamedCase("signed out", Optional("gone")),
    ])
    func backgroundNeverAsks(_ testCase: NamedCase<String?>) async throws {
        let accounts = TestAccounts([Self.first], repositories: [Self.path: repository(login: testCase.value)], repositoryAccount: { _ in Self.first })

        let output = try await get("protocol=https\nhost=github.com\n", accounts: accounts, background: true).output

        #expect(output == nil)
        #expect(accounts.promptedRepositories.isEmpty)
    }

    @Test("never lends the repository's account to another GitHub endpoint")
    func neverLends() async throws {
        let prompter = TestPrompter()
        let accounts = TestAccounts([Self.first], repositories: [Self.path: repository(login: "first")])

        let output = try await get("protocol=https\nhost=octocorp.ghe.com\n", accounts: accounts, prompter: prompter).output

        #expect(output == nil)
        #expect(prompter.calls == [])
        #expect(accounts.promptedRepositories.isEmpty)
    }

    @Test("a repository on another host than its GitHub repository's uses the generic credentials there")
    func otherHostIsGeneric() async throws {
        let prompter = TestPrompter(genericGitAuthentication: { endpoint, _ in
            TrampolineAccount(endpoint: endpoint, login: "joe", token: "generic")
        })
        let accounts = TestAccounts([Self.first], repositories: [Self.path: repository(login: "first")])

        let output = try await get("protocol=https\nhost=git.example.com\n", accounts: accounts, prompter: prompter).output

        #expect(output?.contains("password=generic\n") == true)
        #expect(prompter.calls == [.genericGitAuthentication(endpoint: "https://git.example.com/", username: nil)])
    }

    @Test("associates a repository without a GitHub repository with the endpoint git asks about, then asks for its account")
    func associatesUnknownHost() async throws {
        let endpoints = TestStrings()
        let account = TrampolineAccount(endpoint: "https://ghes.espalier.test/api/v3", login: "octocat", token: "ghes-token")
        let accounts = TestAccounts(
            repositories: [Self.path: repository(endpoint: nil, login: nil)],
            isGitHubHost: { _ in true },
            associate: { repository, endpoint in
                endpoints.append(endpoint)
                return TrampolineRepository(id: repository.id, endpoint: endpoint, accountLogin: nil)
            },
            repositoryAccount: { _ in account }
        )

        let output = try await get("protocol=https\nhost=ghes.espalier.test\n", accounts: accounts).output

        #expect(endpoints.values == ["https://ghes.espalier.test/api/v3"])
        #expect(output?.contains("password=ghes-token\n") == true)
        #expect(accounts.promptedRepositories.count == 1)
    }

    @Test("a repository without a GitHub repository isn't associated with a host that isn't GitHub's")
    func doesNotAssociateGenericHost() async throws {
        let endpoints = TestStrings()
        let accounts = TestAccounts(
            repositories: [Self.path: repository(endpoint: nil, login: nil)],
            associate: { repository, endpoint in
                endpoints.append(endpoint)
                return repository
            }
        )

        _ = try await get("protocol=https\nhost=git.example.com\n", accounts: accounts)

        #expect(endpoints.values.isEmpty)
        #expect(accounts.promptedRepositories.isEmpty)
    }

    @Test("says the repository's account's token couldn't be read, without asking")
    func unreadable() async throws {
        let accounts = TestAccounts(
            unreadable: [Self.dotCom: "The keychain is locked."],
            repositories: [Self.path: repository(login: "first")],
            repositoryAccount: { _ in Self.first }
        )

        let (output, invocation) = try await get("protocol=https\nhost=github.com\n", accounts: accounts)

        #expect(output == nil)
        #expect(invocation.unreadableAccountMessage == "The keychain is locked.")
        #expect(accounts.promptedRepositories.isEmpty)
    }

    @Test("uses the fallback account where no repository is, only on its endpoint and while it's signed in", arguments: [
        NamedCase("signed in, on the endpoint", (fallback: GitFallbackAccount(endpoint: "https://api.github.com", login: "second"), host: "github.com", sent: Optional("second-token"))),
        NamedCase("another login's case", (fallback: GitFallbackAccount(endpoint: "https://api.github.com", login: "SECOND"), host: "github.com", sent: Optional("second-token"))),
        NamedCase("not signed in", (fallback: GitFallbackAccount(endpoint: "https://api.github.com", login: "gone"), host: "github.com", sent: String?.none)),
        NamedCase("another endpoint", (fallback: GitFallbackAccount(endpoint: "https://ghe.example.com/api/v3", login: "second"), host: "github.com", sent: String?.none)),
    ])
    func fallback(_ testCase: NamedCase<(fallback: GitFallbackAccount, host: String, sent: String?)>) async throws {
        let accounts = TestAccounts([Self.first, Self.second])

        let output = try await get("protocol=https\nhost=\(testCase.value.host)\n", accounts: accounts, path: "/tmp/clone", fallback: testCase.value.fallback).output

        if let sent = testCase.value.sent {
            #expect(output?.contains("password=\(sent)\n") == true)
        } else {
            #expect(output == nil)
        }
        #expect(output?.contains("first-token") != true)
    }

    @Test("prefers the repository's account to a fallback account")
    func repositoryOverFallback() async throws {
        let accounts = TestAccounts([Self.first, Self.second], repositories: [Self.path: repository(login: "first")])

        let output = try await get(
            "protocol=https\nhost=github.com\n",
            accounts: accounts,
            fallback: GitFallbackAccount(endpoint: Self.dotCom, login: "second")
        ).output

        #expect(output?.contains("password=first-token\n") == true)
    }

    @Test("an origin matches its endpoint's web site exactly")
    func origins() throws {
        #expect(isSameOrigin(try JSURL("https://github.com/owner/repo.git"), "https://api.github.com"))
        #expect(!isSameOrigin(try JSURL("http://github.com/owner/repo.git"), "https://api.github.com"))
        #expect(isSameOrigin(try JSURL("https://ghe.example.com:8443/x"), "https://ghe.example.com:8443/api/v3"))
        #expect(!isSameOrigin(try JSURL("https://ghe.example.com/x"), "https://ghe.example.com:8443/api/v3"))
        #expect(!isSameOrigin(try JSURL("https://ghe.example.com:8443/x"), "https://ghe.example.com/api/v3"))
        #expect(isSameOrigin(try JSURL("https://octocorp.ghe.com/x"), "https://api.octocorp.ghe.com/"))
    }
}

/// Strings recorded from any thread.
final class TestStrings: Sendable {
    private let strings = Mutex<[String]>([])

    func append(_ string: String) {
        strings.withLock { $0.append(string) }
    }

    var values: [String] {
        strings.withLock { $0 }
    }
}

import Synchronization
