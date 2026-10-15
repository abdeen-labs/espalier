// Pull request sync against a mock GitHub (the first load, updates since
// the last one, closed and head-less pull requests, the 320-result and API
// error fallbacks, repositories without pull requests), the cache, sharing
// among clones, the current pull request, and pruning fork remotes.

@testable import EspalierCore
import EspalierCoreTestSupport
import EspalierSupport
import Foundation
import GitHubKit
import GitKit
import Synchronization
import Testing
import TestSupport

@Suite("Pull request store", .offline, .hangGuard(minutes: 5)) @MainActor
struct PullRequestStoreTests {
    private func numbers(_ fixture: GitHubFixture) -> [Int] {
        fixture.model.gitHub.openPullRequests.map(\.pullRequestNumber)
    }

    @Test("the first refresh loads the open pull requests, newest first")
    func firstLoad() async throws {
        let fixture = try await makeGitHubFixture { _, pulls in
            pulls.open = [apiPullRequest(1), apiPullRequest(3, draft: true, body: "Body"), apiPullRequest(2)]
        }
        await fixture.model.gitHub.refreshPullRequests()

        #expect(numbers(fixture) == [3, 2, 1])
        let newest = try #require(fixture.model.gitHub.openPullRequests.first)
        #expect(newest.title == "Pull request 3")
        #expect(newest.draft)
        #expect(newest.body == "Body")
        #expect(newest.author == "hubot")
        #expect(newest.head.ref == "feature")
        // The base is the list's row for the repository.
        #expect(newest.base.gitHubRepository == fixture.model.record.gitHubRepository)
        let requests = fixture.gitHub.requests("GET", "/repos/octocat/hello/pulls")
        #expect(requests.count == 1)
        #expect(requests.first?.query["state"] == "open")
        #expect(requests.first?.query["per_page"] == "100")
        #expect(!fixture.model.gitHub.isLoadingPullRequests)
        await fixture.settle()
    }

    @Test("later refreshes load the pull requests updated since, keep the open ones, and drop closed and head-less ones")
    func incremental() async throws {
        let fixture = try await makeGitHubFixture { _, pulls in
            pulls.open = [
                apiPullRequest(1, updatedAt: "2026-10-01T10:00:00Z"),
                apiPullRequest(2, updatedAt: "2026-10-02T10:00:00Z"),
            ]
        }
        let gitHub = fixture.model.gitHub
        await gitHub.refreshPullRequests()
        #expect(numbers(fixture) == [2, 1])

        fixture.pulls.updated = [
            apiPullRequest(4, updatedAt: "2026-10-05T10:00:00Z", headRepository: nil),
            apiPullRequest(3, updatedAt: "2026-10-04T10:00:00Z"),
            apiPullRequest(2, state: .closed, updatedAt: "2026-10-03T10:00:00Z"),
            apiPullRequest(1, title: "Renamed", updatedAt: "2026-10-02T10:00:00Z"),
        ]
        await gitHub.refreshPullRequests()
        #expect(numbers(fixture) == [3, 1])
        #expect(gitHub.openPullRequests.last?.title == "Renamed")

        let updated = fixture.gitHub.requests("GET", "/repos/octocat/hello/pulls").last
        #expect(updated?.query["state"] == "all")
        #expect(updated?.query["sort"] == "updated")
        #expect(updated?.query["direction"] == "desc")
        #expect(updated?.query["per_page"] == "10")

        // The next refresh starts from the newest update seen.
        fixture.pulls.updated = [apiPullRequest(4, updatedAt: "2026-10-05T10:00:00Z", headRepository: nil)]
        await gitHub.refreshPullRequests()
        #expect(numbers(fixture) == [3, 1])
        #expect(requestCount(fixture.gitHub, "GET", "/repos/octocat/hello/pulls", query: "state", "open") == 1)
        await fixture.settle()
    }

    @Test("the one pull request updated at the last update, unchanged, changes nothing; a changed list prunes unused fork remotes")
    func unchangedAndPruning() async throws {
        let fixture = try await makeGitHubFixture(mock: { _, pulls in
            pulls.open = [apiPullRequest(1, updatedAt: "2026-10-01T10:00:00Z")]
        }, prepare: { local in
            try await runGit(["remote", "add", "espalier-unused", "https://github.com/unused/hello.git"], local)
            try await runGit(["config", "remote.espalier-unused.espalierFork", "true"], local)
        })
        let gitHub = fixture.model.gitHub
        await gitHub.refreshPullRequests()
        await fixture.settle()
        // A list from GitHub prunes the fork remotes nothing uses.
        #expect(try await remoteURLs(fixture.local)["espalier-unused"] == nil)

        try await runGit(["remote", "add", "espalier-unused", "https://github.com/unused/hello.git"], fixture.local)
        try await runGit(["config", "remote.espalier-unused.espalierFork", "true"], fixture.local)
        fixture.pulls.updated = [apiPullRequest(1, updatedAt: "2026-10-01T10:00:00Z")]
        await gitHub.refreshPullRequests()
        await fixture.settle()
        // Nothing changed: nothing was pruned.
        #expect(try await remoteURLs(fixture.local)["espalier-unused"] != nil)
        #expect(numbers(fixture) == [1])

        fixture.pulls.updated = [apiPullRequest(1, title: "New title", updatedAt: "2026-10-02T10:00:00Z")]
        await gitHub.refreshPullRequests()
        await fixture.settle()
        #expect(try await remoteURLs(fixture.local)["espalier-unused"] == nil)
        await fixture.settle()
    }

    @Test("over 320 updated pull requests, the open ones are loaded again instead")
    func maxResultsFallback() async throws {
        let fixture = try await makeGitHubFixture { _, pulls in
            pulls.open = [apiPullRequest(1, updatedAt: "2026-10-01T10:00:00Z")]
        }
        let gitHub = fixture.model.gitHub
        await gitHub.refreshPullRequests()

        fixture.pulls.updated = (2...330).map { apiPullRequest($0, state: .closed, updatedAt: "2026-10-05T10:00:00Z") }
        fixture.pulls.updatedHasNextPage = true
        fixture.pulls.open = [apiPullRequest(500, updatedAt: "2026-10-06T10:00:00Z"), apiPullRequest(1, updatedAt: "2026-10-01T10:00:00Z")]
        await gitHub.refreshPullRequests()

        #expect(numbers(fixture) == [500, 1])
        #expect(requestCount(fixture.gitHub, "GET", "/repos/octocat/hello/pulls", query: "state", "open") == 2)
        // The next refresh is an update again, from the reloaded list.
        fixture.pulls.updated = [apiPullRequest(500, updatedAt: "2026-10-06T10:00:00Z")]
        fixture.pulls.updatedHasNextPage = false
        await gitHub.refreshPullRequests()
        #expect(fixture.gitHub.requests("GET", "/repos/octocat/hello/pulls").last?.query["state"] == "all")
        await fixture.settle()
    }

    @Test("an API error falls back to the open pull requests; when that fails too, the list stays")
    func apiErrorFallback() async throws {
        let fixture = try await makeGitHubFixture { _, pulls in
            pulls.open = [apiPullRequest(1), apiPullRequest(2)]
        }
        let gitHub = fixture.model.gitHub
        await gitHub.refreshPullRequests()

        fixture.pulls.updatedStatus = 403
        fixture.pulls.open = [apiPullRequest(2)]
        await gitHub.refreshPullRequests()
        #expect(numbers(fixture) == [2])

        // The pull requests stay when the open ones fail too.
        fixture.pulls.openStatus = 500
        await gitHub.refreshPullRequests()
        #expect(numbers(fixture) == [2])
        await fixture.settle()
    }

    @Test("a repository without pull requests loads its open ones each time; one whose pull requests all went away shows none")
    func zeroPullRequests() async throws {
        let fixture = try await makeGitHubFixture()
        let gitHub = fixture.model.gitHub
        await gitHub.refreshPullRequests()
        await gitHub.refreshPullRequests()
        #expect(numbers(fixture).isEmpty)
        #expect(requestCount(fixture.gitHub, "GET", "/repos/octocat/hello/pulls", query: "state", "open") == 2)

        // Pull requests appear, then the fallback finds none open: the list
        // empties.
        fixture.pulls.open = [apiPullRequest(1)]
        await gitHub.refreshPullRequests()
        #expect(numbers(fixture) == [1])
        fixture.pulls.updatedStatus = 403
        fixture.pulls.open = []
        await gitHub.refreshPullRequests()
        #expect(numbers(fixture).isEmpty)
        await fixture.settle()
    }

    @Test("the pull requests come back from the cache after a relaunch, and the next refresh is an update")
    func cache() async throws {
        let fixture = try await makeGitHubFixture { _, pulls in
            pulls.open = [apiPullRequest(1, updatedAt: "2026-10-01T10:00:00Z"), apiPullRequest(2, updatedAt: "2026-10-02T10:00:00Z")]
        }
        await fixture.model.gitHub.refreshPullRequests()
        fixture.pulls.updated = [apiPullRequest(2, updatedAt: "2026-10-02T10:00:00Z")]
        // GitHub can't be reached: whatever shows comes from the cache.
        fixture.pulls.openStatus = 500
        fixture.pulls.updatedStatus = 500

        // The relaunched app selects the repository and refreshes it.
        let relaunched = await fixture.harness.loadedAppWithAccounts()
        let model = try #require(relaunched.repository(fixture.model.id))
        await waitForState { model.gitHub.openPullRequests.count == 2 }
        #expect(model.gitHub.openPullRequests.map(\.pullRequestNumber) == [2, 1])

        fixture.pulls.updatedStatus = 200
        await model.gitHub.refreshPullRequests()
        #expect(model.gitHub.openPullRequests.map(\.pullRequestNumber) == [2, 1])
        // The cache's last update carried over: the relaunched app asked for
        // updates first (its failure fell back to the open ones, which
        // failed too), and so did the last refresh.
        let states = fixture.gitHub.requests("GET", "/repos/octocat/hello/pulls").map { $0.query["state"] }
        #expect(states.first == "open")
        #expect(states.dropFirst().first == "all")
        #expect(states.last == "all")
        await settle(relaunched, fixture.harness)
        await fixture.settle()
    }

    @Test("a corrupt cache is removed, and the pull requests load again from GitHub")
    func corruptCache() async throws {
        let fixture = try await makeGitHubFixture { _, pulls in
            pulls.open = [apiPullRequest(7)]
        }
        let dbID = try #require(fixture.model.record.gitHubRepository?.dbID)
        let url = GitHubCacheKind.pullRequests.url(in: fixture.harness.environment.directories, gitHubRepositoryID: dbID)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("[".utf8).write(to: url)

        await fixture.model.gitHub.refreshPullRequests()
        #expect(numbers(fixture) == [7])
        #expect(fixture.gitHub.requests("GET", "/repos/octocat/hello/pulls").first?.query["state"] == "open")
        let file = try JSONDecoder().decode(PullRequestCacheFile.self, from: Data(contentsOf: url))
        #expect(file.pullRequests.map(\.number) == [7])
        #expect(file.repository == CachedRepositoryIdentity(endpoint: dotComEndpoint, owner: "octocat", name: "hello"))
        await fixture.settle()
    }

    @Test("the author's avatar URL is kept, in the cache too; a cache written before it was kept loads without it until the pull request is fetched again")
    func authorAvatarURL() async throws {
        let monalisa = "https://avatars.githubusercontent.com/u/2?v=4"
        let fixture = try await makeGitHubFixture { _, pulls in
            pulls.open = [
                apiPullRequest(1, updatedAt: "2026-10-01T10:00:00Z", authorAvatarURL: monalisa),
                apiPullRequest(2, updatedAt: "2026-10-02T10:00:00Z", authorAvatarURL: monalisa),
                // An empty avatar URL is none.
                apiPullRequest(3, updatedAt: "2026-10-03T10:00:00Z", authorAvatarURL: ""),
            ]
        }
        await fixture.model.gitHub.refreshPullRequests()
        #expect(fixture.model.gitHub.openPullRequests.map(\.authorAvatarURL) == [nil, monalisa, monalisa])
        let dbID = try #require(fixture.model.record.gitHubRepository?.dbID)
        let url = GitHubCacheKind.pullRequests.url(in: fixture.harness.environment.directories, gitHubRepositoryID: dbID)
        let written = try JSONDecoder().decode(PullRequestCacheFile.self, from: Data(contentsOf: url))
        #expect(written.pullRequests.map(\.authorAvatarURL) == [monalisa, monalisa, nil])

        // The cache as it was written before avatar URLs were kept.
        var file = try #require(try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
        let records = try #require(file["pullRequests"] as? [[String: Any]])
        #expect(records.map { $0["authorAvatarURL"] as? String } == [monalisa, monalisa, nil])
        file["pullRequests"] = records.map { record in record.filter { $0.key != "authorAvatarURL" } }
        try JSONSerialization.data(withJSONObject: file).write(to: url)

        // A relaunched app that can't reach GitHub shows what's cached.
        fixture.pulls.openStatus = 500
        fixture.pulls.updatedStatus = 500
        let relaunched = await fixture.harness.loadedAppWithAccounts()
        let model = try #require(relaunched.repository(fixture.model.id))
        await waitForState { model.gitHub.openPullRequests.count == 3 }
        await settle(relaunched, fixture.harness)
        await model.gitHub.idle()
        #expect(model.gitHub.openPullRequests.map(\.author) == ["hubot", "hubot", "hubot"])
        #expect(model.gitHub.openPullRequests.map(\.authorAvatarURL) == [nil, nil, nil])

        // Pull request 2 changed on GitHub: its author's avatar URL is back.
        fixture.pulls.updated = [apiPullRequest(2, updatedAt: "2026-10-04T10:00:00Z", authorAvatarURL: monalisa)]
        fixture.pulls.updatedStatus = 200
        await model.gitHub.refreshPullRequests()
        #expect(model.gitHub.openPullRequests.map(\.authorAvatarURL) == [nil, monalisa, nil])
        await settle(relaunched, fixture.harness)
        await fixture.settle()
    }

    @Test("clones of the same GitHub repository share its pull requests, and both show them loading")
    func sharedAmongClones() async throws {
        let gate = MockResponseGate()
        let fixture = try await makeGitHubFixture { gitHub, pulls in
            pulls.open = [apiPullRequest(1)]
            gitHub.on("GET", "/repos/octocat/hello/pulls") { _ in
                gate.wait()
                return .json(encoding: [apiPullRequest(1)])
            }
        }
        // A second clone of the same repository.
        let second = try await cloneRepository(fixture.remote)
        try await runGit(["remote", "set-url", "origin", "https://github.com/octocat/hello.git"], second)
        try await runGit(["config", "http.proxy", "http://127.0.0.1:1"], second)
        let secondID = try #require(try await fixture.app.addRepositories([second.path]).added.first)
        let secondModel = try #require(fixture.app.repository(secondID))
        await fixture.settle()
        #expect(secondModel.record.gitHubRepository?.dbID == fixture.model.record.gitHubRepository?.dbID)

        let refresh = Task { await fixture.model.gitHub.refreshPullRequests() }
        await waitForState { fixture.model.gitHub.isLoadingPullRequests && secondModel.gitHub.isLoadingPullRequests }
        gate.open()
        await refresh.value

        #expect(!fixture.model.gitHub.isLoadingPullRequests)
        #expect(!secondModel.gitHub.isLoadingPullRequests)
        #expect(secondModel.gitHub.openPullRequests.map(\.pullRequestNumber) == [1])
        await secondModel.gitHub.idle()
        await fixture.settle()
    }

    @Test("the current pull request is the open one whose head is the branch's upstream in the current remote's repository")
    func currentPullRequest() async throws {
        let fixture = try await makeGitHubFixture(mock: { _, pulls in
            pulls.open = [
                apiPullRequest(4, head: "feature", headRepository: hubotFork),
                apiPullRequest(5, head: "feature"),
                apiPullRequest(6, head: "other"),
            ]
        }, prepare: { local in
            try await runGit(["checkout", "-b", "feature"], local)
            try await commitFile(local, "feature.txt", "feature\n")
            try await runGit(["push", "-u", "origin", "feature"], local)
        })
        let gitHub = fixture.model.gitHub
        await gitHub.refreshPullRequests()
        #expect(gitHub.currentPullRequest?.pullRequestNumber == 5)
        #expect(gitHub.currentPullRequestURL == URL(string: "https://github.com/octocat/hello/pull/5"))

        // Another branch has none.
        try await runGit(["checkout", "main"], fixture.local)
        await fixture.model.refresh(.full, reason: .user)
        #expect(gitHub.currentPullRequest == nil)

        // A fork's pull request, checked out as pr/4 from the fork's remote.
        try await runGit(["remote", "add", "espalier-hubot", "https://github.com/hubot/hello.git"], fixture.local)
        try await runGit(["update-ref", "refs/remotes/espalier-hubot/feature", "HEAD"], fixture.local)
        try await runGit(["checkout", "-b", "pr/4", "--track", "espalier-hubot/feature"], fixture.local)
        await fixture.model.refresh(.full, reason: .user)
        #expect(gitHub.currentPullRequest?.pullRequestNumber == 4)
        await fixture.settle()
    }

    @Test("pull requests by number come from the list, else from GitHub")
    func pullRequestByNumber() async throws {
        let fixture = try await makeGitHubFixture { gitHub, pulls in
            pulls.open = [apiPullRequest(1)]
            gitHub.on("GET", "/repos/octocat/hello/pulls/9", respond: .json(encoding: apiPullRequest(9, title: "Closed one", state: .closed)))
            gitHub.on("GET", "/repos/octocat/hello/pulls/10", respond: .status(404))
        }
        let gitHub = fixture.model.gitHub
        await gitHub.refreshPullRequests()
        #expect(await gitHub.pullRequest(number: 1)?.title == "Pull request 1")
        #expect(fixture.gitHub.requests("GET", "/repos/octocat/hello/pulls/1").isEmpty)
        #expect(await gitHub.pullRequest(number: 9)?.title == "Closed one")
        #expect(await gitHub.pullRequest(number: 10) == nil)
        await fixture.settle()
    }
}

/// Holds a mock response until opened (with a bound, so a broken test
/// can't hang).
final class MockResponseGate: Sendable {
    private let semaphore = DispatchSemaphore(value: 0)
    private let isOpen = Mutex(false)
    private let arrivals = Mutex<(count: Int, waiters: [CheckedContinuation<Void, Never>])>((0, []))

    /// Blocks the calling thread (a mock's) until `open()`.
    func wait() {
        let waiters = arrivals.withLock { arrivals in
            arrivals.count += 1
            defer { arrivals.waiters = [] }
            return arrivals.waiters
        }
        for waiter in waiters {
            waiter.resume()
        }
        if isOpen.withLock({ $0 }) {
            return
        }
        _ = semaphore.wait(timeout: .now() + 30)
    }

    /// Waits until a request is held at the gate.
    func waitForArrival() async {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            let arrived = arrivals.withLock { arrivals in
                if arrivals.count > 0 {
                    return true
                }
                arrivals.waiters.append(continuation)
                return false
            }
            if arrived {
                continuation.resume()
            }
        }
    }

    func open() {
        isOpen.withLock { $0 = true }
        semaphore.signal()
        semaphore.signal()
        semaphore.signal()
    }
}
