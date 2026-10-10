// Ported from desktop/app/test/unit/stores/github-user-store-test.ts
// Plus tests of the issues and mentionable users stores and their caches.

@testable import EspalierCore
import EspalierCoreTestSupport
import Foundation
import GitHubKit
import GitKit
import Testing
import TestSupport

private let mona = MentionableUser(
    login: "octocat",
    name: "Mona Lisa",
    email: "octocat@example.com",
    avatarURL: "https://avatars.example.com/octocat"
)

// A user that hasn't configured a real name (name === null).
private let namelessUser = MentionableUser(
    login: "hubot",
    name: nil,
    email: "hubot@example.com",
    avatarURL: "https://avatars.example.com/hubot"
)

private let users = [mona, namelessUser]

private func user(_ login: String, name: String? = nil) -> MentionableUser {
    MentionableUser(login: login, name: name, email: "\(login)@example.com", avatarURL: "https://avatars.example.com/\(login)")
}

@Suite("matchMentionableUsers")
struct MatchMentionableUsersTests {
    @Test("does not match users without a name when searching for \"null\"")
    func nullName() {
        // A `null` name interpolated as the literal string "null" would make
        // nameless users match the query "null".
        #expect(matchMentionableUsers(users, "null") == [])
    }

    @Test("does not drag in a nameless user on a leading \"n\"")
    func leadingN() {
        let logins = matchMentionableUsers(users, "n").map(\.login)

        // "octocat Mona Lisa" legitimately contains an "n" (Mona); the nameless
        // "hubot" must not be matched via the literal "null".
        #expect(!logins.contains("hubot"))
    }

    @Test("matches one user by login or real name, in any case", arguments: [
        NamedCase("matches a user by their login even when they have no name", (query: "hubot", login: "hubot")),
        NamedCase("matches a user by their real name", (query: "mona", login: "octocat")),
        NamedCase("matches case-insensitively for uppercase queries", (query: "MONA", login: "octocat")),
    ])
    func matches(_ testCase: NamedCase<(query: String, login: String)>) {
        let hits = matchMentionableUsers(users, testCase.value.query)

        #expect(hits.count == 1)
        #expect(hits.first?.login == testCase.value.login)
    }

    @Test("ranks by where the query starts in \"login name\", then by login", arguments: [
        // "scar" starts at index 0 of "scarecrow" but at index 1 of "oscar", so
        // scarecrow should rank first.
        NamedCase("ranks earlier matches ahead of later ones", (
            users: [user("oscar"), user("scarecrow")],
            query: "scar",
            logins: ["scarecrow", "oscar"]
        )),
        // "scar" matches at index 0 of login "scarf" but at index 4 of the haystack
        // "zzz scar face" (i.e. the "login " prefix is still part of the search
        // string), so the login match must rank first.
        NamedCase("ranks a login match ahead of a name-only match", (
            users: [user("zzz", name: "Scar Face"), user("scarf")],
            query: "scar",
            logins: ["scarf", "zzz"]
        )),
        // Both match "team" at index 0, so the secondary alphabetical-by-login
        // sort decides the order.
        NamedCase("breaks ties alphabetically by login", (
            users: [user("team-zoo"), user("team-ant")],
            query: "team",
            logins: ["team-ant", "team-zoo"]
        )),
    ])
    func ranks(_ testCase: NamedCase<(users: [MentionableUser], query: String, logins: [String])>) {
        let logins = matchMentionableUsers(testCase.value.users, testCase.value.query).map(\.login)

        #expect(logins == testCase.value.logins)
    }

    @Test("honors the maxHits limit")
    func maxHits() {
        let many = (0..<5).map { user("matcher\($0)") }

        #expect(matchMentionableUsers(many, "matcher", maxHits: 3).count == 3)
    }

    @Test("treats an empty-string name the same as a null name")
    func emptyName() {
        let withEmptyName = user("foo", name: "")
        let withNullName = user("foo", name: nil)

        // Both forms match by login and neither one is dragged in by "null".
        #expect(matchMentionableUsers([withEmptyName], "foo").count == 1)
        #expect(matchMentionableUsers([withNullName], "foo").count == 1)
        #expect(matchMentionableUsers([withEmptyName], "null").count == 0)
    }
}

@Suite("Issue matching")
struct IssueMatchingTests {
    private let issues = [
        IssueHit(title: "Crash on launch", number: 12),
        IssueHit(title: "Launch screen typo", number: 7),
        IssueHit(title: "Add dark mode", number: 120),
    ]

    @Test("with no text, the highest numbers first")
    func noText() {
        #expect(matchIssues(issues, "").map(\.number) == [120, 12, 7])
        #expect(matchIssues(issues, "", maxHits: 1).map(\.number) == [120])
    }

    @Test("ranks by where \"<number> <title>\" matches, then by title")
    func ranking() {
        #expect(matchIssues(issues, "launch").map(\.number) == [7, 12])
        // Both match at the start: the titles decide.
        #expect(matchIssues(issues, "12").map(\.number) == [120, 12])
        #expect(matchIssues(issues, "DARK").map(\.number) == [120])
        #expect(matchIssues(issues, "nothing") == [])
    }

    @Test("finds text by UTF-16 offset, as JavaScript's indexOf")
    func utf16() {
        #expect(utf16IndexOf("a😀b", "b") == 3)
        #expect(utf16IndexOf("abc", "") == 0)
        #expect(utf16IndexOf("abc", "d") == nil)
        #expect(utf16IndexOf("é", "e\u{301}") == nil)
    }
}

@Suite("Autocompletion stores", .offline) @MainActor
struct AutocompleteStoresTests {
    private func issue(_ number: Int, _ title: String, state: APIIssueState = .open, updatedAt: String = "2026-10-01T10:00:00Z") -> APIIssue {
        APIIssue(number: number, title: title, state: state, updatedAt: updatedAt)
    }

    @Test("the first refresh loads the open issues; later ones load the issues updated since and drop the closed ones")
    func issuesSync() async throws {
        let fixture = try await makeGitHubFixture { gitHub, _ in
            gitHub.on("GET", "/repos/octocat/hello/issues") { request in
                if request.query["state"] == "open" {
                    return .json(encoding: [
                        APIIssue(number: 1, title: "First", state: .open, updatedAt: "2026-10-01T10:00:00Z"),
                        APIIssue(number: 2, title: "Second", state: .open, updatedAt: "2026-10-02T10:00:00Z"),
                    ])
                }
                return .json(encoding: [
                    APIIssue(number: 2, title: "Second", state: .closed, updatedAt: "2026-10-03T10:00:00Z"),
                    APIIssue(number: 3, title: "Third", state: .open, updatedAt: "2026-10-04T10:00:00Z"),
                ])
            }
        }
        let issues = fixture.model.gitHub.issues
        await issues.refresh()
        #expect(await issues.issues(matching: "").map(\.number) == [2, 1])

        await issues.refresh()
        #expect(await issues.issues(matching: "").map(\.number) == [3, 1])
        let requests = fixture.gitHub.requests("GET", "/repos/octocat/hello/issues")
        #expect(requests.map { $0.query["state"] } == ["open", "all"])
        #expect(requests.last?.query["since"] == "2026-10-02T10:00:00Z")

        // The issues survive a relaunch in the cache, and the next refresh
        // asks for updates since the newest.
        let relaunched = await fixture.harness.loadedAppWithAccounts()
        let model = try #require(relaunched.repository(fixture.model.id))
        #expect(await model.gitHub.issues.issues(matching: "thi").map(\.number) == [3])
        await model.gitHub.issues.refresh()
        #expect(fixture.gitHub.requests("GET", "/repos/octocat/hello/issues").last?.query["since"] == "2026-10-04T10:00:00Z")
        await settle(relaunched, fixture.harness)
        await fixture.settle()
    }

    @Test("a user fetch refreshes a fork's issues from the repository it contributes to (desktop refreshed the fork's own)")
    func userFetchOnFork() async throws {
        let fixture = try await makeGitHubFixture(select: true)
        let parent = try #require(fixture.model.record.gitHubRepository)
        let fork = ModelFixtures.gitHubRepository(owner: "hubot", name: "hello", dbID: parent.dbID + 100, parent: parent)
        fixture.app.updateRecord(fixture.model.id) { $0.gitHubRepository = fork }
        await fixture.settle()
        let before = fixture.gitHub.requests("GET", "/repos/octocat/hello/issues").count

        fixture.model.gitHub.userFetchDidComplete()
        await fixture.model.gitHub.idle()

        #expect(fixture.gitHub.requests("GET", "/repos/octocat/hello/issues").count == before + 1)
        #expect(fixture.gitHub.requests("GET", "/repos/hubot/hello/issues").isEmpty)
        await fixture.settle()
    }

    @Test("typing # refreshes the issues at most once a minute")
    func issuesThrottle() async throws {
        let fixture = try await makeGitHubFixture()
        let issues = fixture.model.gitHub.issues
        issues.requestRefresh()
        await fixture.model.gitHub.idle()
        issues.requestRefresh()
        await fixture.model.gitHub.idle()
        #expect(fixture.gitHub.requests("GET", "/repos/octocat/hello/issues").count == 1)

        await fixture.scheduler.advance(by: .seconds(61))
        issues.requestRefresh()
        await fixture.model.gitHub.idle()
        #expect(fixture.gitHub.requests("GET", "/repos/octocat/hello/issues").count == 2)
        await fixture.settle()
    }

    @Test("mentionable users load at most every 10 minutes, with the last ETag; a 304 keeps them")
    func mentionables() async throws {
        let fixture = try await makeGitHubFixture { gitHub, _ in
            gitHub.on("GET", "/repos/octocat/hello/mentionables/users", sequence: [
                .json(encoding: [
                    APIMentionableUser(avatarURL: "https://avatars.example.com/mona", email: "mona@example.com", login: "mona", name: "Mona"),
                    APIMentionableUser(avatarURL: "https://avatars.example.com/nobody", email: nil, login: "nobody", name: nil),
                ], headers: ["ETag": "\"v1\""]),
                .status(304),
            ])
        }
        let users = fixture.model.gitHub.users
        await users.updateMentionables()
        let loaded = await users.mentionableUsers()
        #expect(loaded.map(\.login) == ["mona", "nobody", "Copilot"])
        #expect(loaded[1].email == "nobody@users.noreply.github.com")
        #expect(loaded[2].email == "198982749+Copilot@users.noreply.github.com")
        #expect(await users.mentionableUsers(matching: "mon").map(\.login) == ["mona"])

        // Within 10 minutes nothing is asked.
        await users.updateMentionables()
        #expect(fixture.gitHub.requests("GET", "/repos/octocat/hello/mentionables/users").count == 1)

        await fixture.scheduler.advance(by: .seconds(10 * 60 + 1))
        await users.updateMentionables()
        let requests = fixture.gitHub.requests("GET", "/repos/octocat/hello/mentionables/users")
        #expect(requests.count == 2)
        #expect(requests.last?.header("If-None-Match") == "\"v1\"")
        #expect(requests.last?.header("Accept") == "application/vnd.github.jerry-maguire-preview")
        #expect(await users.mentionableUsers().map(\.login) == ["mona", "nobody", "Copilot"])
        await fixture.settle()
    }

    @Test("looks users up by login: their public email, else the stealth one; not organizations")
    func userByLogin() async throws {
        let fixture = try await makeGitHubFixture { gitHub, _ in
            gitHub.on("GET", "/users/mona", respond: .json(encoding: APIFullIdentity(
                id: 5, htmlURL: "https://github.com/mona", login: "mona", avatarURL: "https://avatars.example.com/mona",
                name: "Mona", email: "mona@example.com", type: .user
            )))
            gitHub.on("GET", "/users/quiet", respond: .json(encoding: APIFullIdentity(
                id: 6, htmlURL: "https://github.com/quiet", login: "quiet", avatarURL: "", name: nil, email: nil, type: .user
            )))
            gitHub.on("GET", "/users/acme", respond: .json(encoding: APIFullIdentity(
                id: 7, htmlURL: "https://github.com/acme", login: "acme", avatarURL: "", name: "Acme", email: nil, type: .organization
            )))
            gitHub.on("GET", "/users/missing", respond: .status(404))
        }
        let users = fixture.model.gitHub.users
        #expect(await users.user(byLogin: "mona") == MentionableUser(login: "mona", name: "Mona", email: "mona@example.com", avatarURL: "https://avatars.example.com/mona"))
        let quiet = await users.user(byLogin: "quiet")
        #expect(quiet?.email == "6+quiet@users.noreply.github.com")
        #expect(quiet?.name == "quiet")
        #expect(await users.user(byLogin: "acme") == nil)
        #expect(await users.user(byLogin: "missing") == nil)
        await fixture.settle()
    }

    @Test("a corrupt or foreign cache file is dropped and rebuilt from GitHub")
    func corruptCaches() async throws {
        let fixture = try await makeGitHubFixture { gitHub, _ in
            gitHub.on("GET", "/repos/octocat/hello/issues", respond: .json(encoding: [
                APIIssue(number: 4, title: "Fresh", state: .open, updatedAt: "2026-10-01T10:00:00Z"),
            ]))
        }
        let dbID = try #require(fixture.model.record.gitHubRepository?.dbID)
        let directories = fixture.harness.environment.directories
        let issuesURL = GitHubCacheKind.issues.url(in: directories, gitHubRepositoryID: dbID)
        let mentionablesURL = GitHubCacheKind.mentionables.url(in: directories, gitHubRepositoryID: dbID)
        try FileManager.default.createDirectory(at: issuesURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: mentionablesURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("{not json".utf8).write(to: issuesURL)
        // A file for another repository under the same ID.
        let foreign = MentionablesCacheFile(
            version: MentionablesCacheFile.currentVersion,
            repository: CachedRepositoryIdentity(endpoint: dotComEndpoint, owner: "someone", name: "else"),
            lastUpdated: fixture.scheduler.now,
            eTag: "\"x\"",
            users: [MentionableUser(login: "stranger", name: nil, email: "s@example.com", avatarURL: "")]
        )
        try JSONEncoder().encode(foreign).write(to: mentionablesURL)

        // Nothing has read the caches yet (the repository isn't selected).
        let model = fixture.model
        #expect(await model.gitHub.issues.issues(matching: "").isEmpty)
        #expect(!FileManager.default.fileExists(atPath: issuesURL.path))
        #expect(await model.gitHub.users.mentionableUsers().map(\.login) == ["Copilot"])

        await model.gitHub.issues.refresh()
        await model.gitHub.users.updateMentionables()
        #expect(await model.gitHub.issues.issues(matching: "").map(\.number) == [4])
        // The foreign file's ETag isn't sent.
        #expect(fixture.gitHub.requests("GET", "/repos/octocat/hello/mentionables/users").last?.header("If-None-Match") == nil)
        let rebuilt = try JSONDecoder().decode(IssuesCacheFile.self, from: Data(contentsOf: issuesURL))
        #expect(rebuilt.issues.map(\.number) == [4])
        let mentionables = try JSONDecoder().decode(MentionablesCacheFile.self, from: Data(contentsOf: mentionablesURL))
        #expect(mentionables.repository.matches(endpoint: dotComEndpoint, owner: "octocat", name: "hello"))
        await fixture.settle()
    }
}
