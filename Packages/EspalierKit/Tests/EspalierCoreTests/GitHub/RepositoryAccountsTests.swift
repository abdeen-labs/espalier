// Ported from desktop/app/test/unit/repositories-store-test.ts,
// stores/app-store-accounts-test.ts, and repository-account-test.ts.
//
// A repository's account against a mock GitHub: assigned once at launch to
// repositories saved before accounts were; when a repository is added, the
// only account that can see it, or the one the user picks among several on
// one host (an account whose access can't be checked is never passed over);
// each account's own GitHub repository rows; choosing another; asking for
// one; and signing out, which keeps or clears assignments as the user says,
// while an account signed out without the user keeps them.

@testable import EspalierCore
import EspalierCoreTestSupport
import Foundation
import GitHubKit
import GitKit
import Synchronization
import Testing
import TestSupport

@Suite("Repository accounts", .offline, .hangGuard(minutes: 5)) @MainActor
struct RepositoryAccountsTests {
    let first = dotComAccount(login: "first", id: 11, token: "gho_first")
    let second = dotComAccount(login: "second", id: 12, token: "gho_second")

    /// An empty repository whose origin is `url`.
    private func repository(origin url: String = "https://github.com/octocat/hello.git") async throws -> Repository {
        let repository = try setupEmptyRepository()
        try await runGit(["remote", "add", "origin", url], repository)
        return repository
    }

    /// A harness with `accounts` signed in, their launch refresh answered,
    /// and `GET /repos/octocat/hello` answered by each account's token:
    /// `answers` by login (a missing login sees nothing).
    private func harness(
        _ accounts: [Account],
        answers: [String: MockGitHub.Response] = [:],
        responder: PromptCenter.Responder? = PromptResponder.failing()
    ) async throws -> AppHarness {
        let harness = try AppHarness(responder: responder)
        for account in accounts {
            try await harness.store(account)
        }
        harness.mockUsers(accounts)
        let tokens = Dictionary(uniqueKeysWithValues: accounts.map { ("Bearer \($0.token)", $0.login) })
        harness.gitHub.on("GET", "/repos/octocat/hello") { request in
            guard let login = tokens[request.header("Authorization") ?? ""], let answer = answers[login] else {
                return .json(["message": "Not Found"], status: 404)
            }
            return answer
        }
        return harness
    }

    private func visible(_ permissions: APIRepositoryPermissions = APIRepositoryPermissions(admin: false, push: true, pull: true)) -> MockGitHub.Response {
        .json(encoding: apiFullRepository(permissions: permissions))
    }

    private func add(_ repository: Repository, to app: AppModel) async throws -> RepositoryID {
        let id = try #require(try await app.addRepositories([repository.path]).added.first)
        await app.idle()
        return id
    }

    // MARK: At launch

    @Test("assigns accounts once at launch to the repositories saved before accounts were, from every account saved then")
    func migratesAtLaunch() async throws {
        let harness = try AppHarness()
        // octocat's token is missing, so it's signed out as it loads: its
        // repository keeps it, to use once it signs in again.
        harness.defaults.defaults.set(
            #"[{"login":"octocat","endpoint":"https://api.github.com","emails":[],"avatarURL":"","id":1,"name":"octocat"}]"#,
            forKey: "users"
        )
        let list = """
            {"version": 1, "nextGitHubRepositoryID": 2, "repositories": [
              {"id": "11111111-0000-0000-0000-000000000001", "path": "/Users/joe/hello", "missing": true, "gitHubRepositoryID": 1},
              {"id": "11111111-0000-0000-0000-000000000002", "path": "/Users/joe/notes", "missing": true}
            ], "gitHubRepositories": [
              {"id": 1, "name": "hello", "owner": {"login": "octocat", "endpoint": "https://api.github.com"}, "permissions": "admin"}
            ]}
            """
        let file = harness.environment.directories.repositoryList
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(list.utf8).write(to: file)

        let app = await harness.loadedAppWithAccounts()
        await app.idle()

        #expect(app.accounts.accounts.isEmpty)
        #expect(app.repositories.map(\.accountLogin) == ["octocat", nil])
        let gitHubRepository = try #require(app.repositories.first?.gitHubRepository)
        #expect(app.gitHubRepositories[gitHubRepository.dbID]?.accountLogin == "octocat")
        // What one account was allowed isn't known for it.
        #expect(gitHubRepository.permissions == nil)

        // Saved at once: the next launch doesn't assign them again, even with
        // another account signed in.
        let saved = try JSONDecoder.repositoryListDecoder.decode(RepositoryListDocument.self, from: Data(contentsOf: file))
        #expect(!saved.awaitsAccountAssignments)
        try await harness.store(first)
        let relaunched = await harness.loadedAppWithAccounts()
        #expect(relaunched.repositories.map(\.accountLogin) == ["octocat", nil])
        await settle(relaunched, harness)
        await settle(app, harness)
    }

    // MARK: Adding

    @Test("assigns an added repository the only account on its host that can see it")
    func onlyAccountWithAccess() async throws {
        let harness = try await harness([first, second], answers: ["second": visible()])
        let app = await harness.loadedAppWithAccounts()

        let id = try await add(try await repository(), to: app)

        #expect(app.record(id)?.accountLogin == "second")
        #expect(app.accounts.account(for: try #require(app.record(id)))?.identity == second.identity)
        #expect(harness.prompts.history.isEmpty)
        await settle(app, harness)
    }

    @Test("asks which account when several on the host can see an added repository")
    func asksAmongSeveral() async throws {
        let harness = try await harness(
            [first, second],
            answers: ["first": visible(), "second": visible()],
            responder: PromptResponder.answering([.repositoryAccount(AccountIdentity(endpoint: dotComEndpoint, login: "second"))])
        )
        let app = await harness.loadedAppWithAccounts()

        let id = try await add(try await repository(), to: app)

        #expect(app.record(id)?.accountLogin == "second")
        guard case .repositoryAccount(let request)? = harness.prompts.history.first else {
            Issue.record("Expected the question about the account")
            return
        }
        #expect(request.candidates == [first.identity, second.identity])
        #expect(request.endpoint == dotComEndpoint)
        await settle(app, harness)
    }

    @Test("an account whose access can't be checked isn't passed over: the user picks")
    func undecidedAccountIsOffered() async throws {
        let harness = try await harness(
            [first, second],
            answers: ["first": .status(502), "second": visible()],
            responder: PromptResponder.answering([.repositoryAccount(AccountIdentity(endpoint: dotComEndpoint, login: "second"))])
        )
        let app = await harness.loadedAppWithAccounts()

        let id = try await add(try await repository(), to: app)

        #expect(app.record(id)?.accountLogin == "second")
        guard case .repositoryAccount(let request)? = harness.prompts.history.first else {
            Issue.record("Expected the question about the account")
            return
        }
        #expect(request.candidates == [second.identity, first.identity])
        await settle(app, harness)
    }

    @Test("a repository no account can see is added without one, associated with its host")
    func noAccountWithAccess() async throws {
        let harness = try await harness([first, second])
        let app = await harness.loadedAppWithAccounts()

        let id = try await add(try await repository(), to: app)

        #expect(app.record(id)?.accountLogin == nil)
        #expect(app.record(id)?.gitHubRepository?.fullName == "octocat/hello")
        #expect(harness.prompts.history.isEmpty)
        await settle(app, harness)
    }

    @Test("two repositories of one GitHub repository on different accounts keep apart what each account is allowed")
    func separateRows() async throws {
        let harness = try await harness(
            [first, second],
            answers: [
                "first": visible(APIRepositoryPermissions(admin: true, push: true, pull: true)),
                "second": visible(APIRepositoryPermissions(admin: false, push: false, pull: true)),
            ],
            responder: PromptResponder.answering([
                .repositoryAccount(AccountIdentity(endpoint: dotComEndpoint, login: "first")),
                .repositoryAccount(AccountIdentity(endpoint: dotComEndpoint, login: "second")),
            ])
        )
        let app = await harness.loadedAppWithAccounts()

        let firsts = try await add(try await repository(), to: app)
        let seconds = try await add(try await repository(), to: app)

        let a = try #require(app.record(firsts)?.gitHubRepository)
        let b = try #require(app.record(seconds)?.gitHubRepository)
        #expect(a.fullName == b.fullName)
        #expect(a.dbID != b.dbID)
        #expect(a.permissions == .admin)
        #expect(b.permissions == .read)
        await settle(app, harness)
    }

    // MARK: Choosing

    @Test("choosing another account moves the repository to that account's row, and asks GitHub with it")
    func updateRepositoryAccount() async throws {
        let harness = try await harness(
            [first, second],
            answers: [
                "first": visible(APIRepositoryPermissions(admin: true, push: true, pull: true)),
                "second": visible(APIRepositoryPermissions(admin: false, push: false, pull: true)),
            ],
            responder: PromptResponder.answering([.repositoryAccount(AccountIdentity(endpoint: dotComEndpoint, login: "first"))])
        )
        let app = await harness.loadedAppWithAccounts()
        let model = try await harness.addAndSelect(try await repository(), to: app)
        let before = try #require(model.record.gitHubRepository)
        #expect(before.permissions == .admin)

        try await app.updateRepositoryAccount(model.id, login: "SECOND")
        await app.idle()

        #expect(model.record.accountLogin == "second")
        let after = try #require(model.record.gitHubRepository)
        #expect(after.dbID != before.dbID)
        #expect(after.permissions == .read)
        let lastRequest = try #require(harness.gitHub.requests("GET", "/repos/octocat/hello").last)
        #expect(lastRequest.header("Authorization") == "Bearer gho_second")

        // None, then an account that isn't signed in.
        try await app.updateRepositoryAccount(model.id, login: nil)
        #expect(model.record.accountLogin == nil)
        let error = await #expect(throws: OperationError.self) {
            try await app.updateRepositoryAccount(model.id, login: "someone")
        }
        guard case .precondition? = error?.reason else {
            Issue.record("Expected a precondition, got \(String(describing: error))")
            return
        }
        #expect(model.record.accountLogin == nil)
        await settle(app, harness)
    }

    @Test("asks for the account of a repository without one, once for every caller at once, and assigns it")
    func ensureAsksOnce() async throws {
        let answered = AsyncEvent<Void>()
        let harness = try await harness([first, second]) { _ in
            try? await answered.wait()
            return .repositoryAccount(AccountIdentity(endpoint: dotComEndpoint, login: "second"))
        }
        let app = await harness.loadedAppWithAccounts()
        let id = try await add(try await repository(), to: app)
        #expect(app.record(id)?.accountLogin == nil)

        async let one = app.ensureRepositoryAccount(id)
        async let two = app.ensureRepositoryAccount(id)
        await waitForState { !harness.prompts.pending.isEmpty }
        answered.resolve()
        let (a, b) = await (one, two)

        #expect(a?.identity == second.identity)
        #expect(b?.identity == second.identity)
        #expect(harness.prompts.history.count == 1)
        #expect(app.record(id)?.accountLogin == "second")
        // Signed in: nothing is asked.
        #expect(await app.ensureRepositoryAccount(id)?.identity == second.identity)
        #expect(harness.prompts.history.count == 1)
        await settle(app, harness)
    }

    @Test("a repository whose account is signed out asks to sign in to it again")
    func ensureSignedOut() async throws {
        let harness = try await harness([first, second], answers: ["first": visible()], responder: PromptResponder.dismissing)
        let app = await harness.loadedAppWithAccounts()
        let id = try await add(try await repository(), to: app)
        try await app.accounts.signOut(first, confirmed: [.signOutAccount])

        #expect(await app.ensureRepositoryAccount(id) == nil)

        guard case .repositoryAccount(let request)? = harness.prompts.history.last else {
            Issue.record("Expected the question about the account")
            return
        }
        #expect(request.signedOutLogin == "first")
        // Dismissed: it keeps its account, signed out.
        #expect(app.record(id)?.accountLogin == "first")
        await settle(app, harness)
    }

    // MARK: Signing out

    @Test("signing out of an account repositories are assigned to asks first, and keeps the assignments unless told")
    func signOutKeeps() async throws {
        let harness = try await harness([first, second], answers: ["first": visible()])
        let app = await harness.loadedAppWithAccounts()
        let id = try await add(try await repository(), to: app)

        let error = await #expect(throws: OperationError.self) {
            try await app.accounts.signOut(first)
        }
        guard case .confirmationRequired(let confirmation)? = error?.reason else {
            Issue.record("Expected a confirmation, got \(String(describing: error))")
            return
        }
        #expect(confirmation.kind == .signOutAccount)
        #expect(confirmation.details == .account(login: "first", server: "GitHub.com", repositoryCount: 1))
        #expect(app.accounts.accounts.contains { $0.identity == first.identity })

        try await app.accounts.signOut(first, confirmed: [.signOutAccount])

        #expect(!app.accounts.accounts.contains { $0.identity == first.identity })
        #expect(app.record(id)?.accountLogin == "first")
        #expect(app.accounts.account(for: try #require(app.record(id))) == nil)
        // Another account on the host isn't used in its place.
        #expect(app.accounts.accounts.contains { $0.identity == second.identity })

        // Signed in again, it's the repository's account again.
        try await harness.signIn([first], to: app)
        #expect(app.accounts.account(for: try #require(app.record(id)))?.identity == first.identity)
        await settle(app, harness)
    }

    @Test("signing out can clear the assignments")
    func signOutClears() async throws {
        let harness = try await harness([first], answers: ["first": visible()])
        let app = await harness.loadedAppWithAccounts()
        let id = try await add(try await repository(), to: app)
        let assignedRow = try #require(app.record(id)?.gitHubRepository?.dbID)

        try await app.accounts.signOut(first, confirmed: [.signOutAccount], clearingAssignments: true)

        let record = try #require(app.record(id))
        #expect(record.accountLogin == nil)
        // Its GitHub repository is the row without an account now.
        let row = try #require(record.gitHubRepository?.dbID)
        #expect(row != assignedRow)
        #expect(app.gitHubRepositories[row]?.accountLogin == "")
        await settle(app, harness)
    }

    @Test("signing out of an account no repository is assigned to asks nothing")
    func signOutUnassigned() async throws {
        let harness = try await harness([first, second], answers: ["first": visible()])
        let app = await harness.loadedAppWithAccounts()
        _ = try await add(try await repository(), to: app)

        try await app.accounts.signOut(second)

        #expect(app.accounts.accounts.map(\.identity) == [first.identity])
        await settle(app, harness)
    }

    @Test("an account signed out without the user keeps its repositories' assignments")
    func invalidationKeeps() async throws {
        let harness = try await harness([first, second], answers: ["first": visible()])
        let app = await harness.loadedAppWithAccounts()
        let id = try await add(try await repository(), to: app)

        // GitHub rejected its token.
        try await harness.environment.accountsStore.invalidateToken(endpoint: dotComEndpoint, token: first.token)
        await waitForState { app.accounts.invalidatedAccounts.contains { $0.identity == first.identity } }

        #expect(app.record(id)?.accountLogin == "first")
        #expect(app.accounts.accounts.map(\.identity) == [second.identity])
        #expect(app.accounts.account(for: try #require(app.record(id))) == nil)
        await settle(app, harness)
    }
}

extension JSONDecoder {
    /// A decoder of the repository list's ISO 8601 dates.
    static var repositoryListDecoder: JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }
}
