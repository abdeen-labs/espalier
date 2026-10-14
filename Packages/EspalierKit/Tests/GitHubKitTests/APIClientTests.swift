// The API client: endpoints, requests (redirects, pagination, Enterprise
// versions), and GitHub host detection.

import Foundation
@testable import GitHubKit
import Synchronization
import TestSupport
import Testing

@Suite("API client", .offline)
struct APIClientTests {
    @Suite("endpoints")
    struct Endpoints {
        @Test("maps API endpoints to HTML URLs")
        func htmlURLs() {
            #expect(getHTMLURL("https://api.github.com") == "https://github.com")
            #expect(getHTMLURL("https://github.mycompany.com/api/v3") == "https://github.mycompany.com")
            #expect(getHTMLURL("http://github.mycompany.com/api/v3") == "http://github.mycompany.com")
            // Node's legacy URL parsing drops the port.
            #expect(getHTMLURL("https://github.mycompany.com:8443/api/v3") == "https://github.mycompany.com")
            #expect(getHTMLURL("https://api.octocorp.ghe.com/") == "https://octocorp.ghe.com/")
        }

        @Test("maps HTML URLs to enterprise API endpoints")
        func enterpriseAPIURLs() {
            #expect(getEnterpriseAPIURL("https://github.mycompany.com") == "https://github.mycompany.com/api/v3")
            #expect(getEnterpriseAPIURL("http://github.mycompany.com:8080/") == "https://github.mycompany.com:8080/api/v3")
            #expect(getEnterpriseAPIURL("https://octocorp.ghe.com") == "https://api.octocorp.ghe.com/")
            #expect(getAPIEndpoint("https://github.com") == "https://api.github.com")
            #expect(getAPIEndpoint("https://github.mycompany.com") == "https://github.mycompany.com/api/v3")
        }

        @Test("maps repository URLs to the endpoints accounts are stored under")
        func endpointsForRepositories() throws {
            #expect(getEndpointForRepository("https://github.com/desktop/desktop") == "https://api.github.com")
            #expect(getEndpointForRepository("http://github.mycompany.com/my-team/my-project") == "https://github.mycompany.com/api/v3")
            #expect(getEndpointForRepository("https://github.mycompany.com:8443/team/project") == "https://github.mycompany.com:8443/api/v3")
            #expect(getEndpointForRepository("https://octocorp.ghe.com/team/project") == "https://api.octocorp.ghe.com/")

            let enterprise = try EndpointConfiguration.enterprise(address: "github.mycompany.com", clientID: "client")
            let account = Account(login: "a", endpoint: enterprise.endpoint, token: "t", emails: [], avatarURL: "", id: 1, name: "")
            #expect(getAccountForEndpoint([account], getEndpointForRepository("https://github.mycompany.com/team/project")) == account)
        }

        @Test("classifies endpoints")
        func classifiesEndpoints() {
            #expect(isDotCom("https://api.github.com"))
            #expect(isDotCom("https://github.com/"))
            #expect(isDotCom("http://github.com:8080/x"))
            #expect(!isDotCom("https://github.mycompany.com/"))
            #expect(!isDotCom("not a url"))
            #expect(isGHE("https://api.octocorp.ghe.com/"))
            #expect(isGHE("https://octocorp.ghe.com/"))
            #expect(!isGHE("https://ghe.com/"))
            #expect(isGHES("https://github.mycompany.com/api/v3"))
            #expect(!isGHES("https://api.octocorp.ghe.com/"))
            #expect(isGist("https://gist.github.com/"))
            #expect(!isGist("https://github.com/"))
        }

        @Test("finds the account for a GitHub repository")
        func accountForRepository() {
            let dotCom = Account(login: "a", endpoint: getDotComAPIEndpoint(), token: "t", emails: [], avatarURL: "", id: 1, name: "")
            let enterprise = Account(login: "b", endpoint: "https://ghe.io/api/v3", token: "t", emails: [], avatarURL: "", id: 2, name: "")
            let repository = gitHubRepoFixture(owner: "o", name: "r", endpoint: "https://ghe.io/api/v3")

            #expect(getAccountForRepository([dotCom, enterprise], repository) == enterprise)
            #expect(getAccountForRepository([dotCom, enterprise], nil) == nil)
        }

        @Test("links to the page where the user revokes the OAuth app")
        func applicationSettingsURL() {
            #expect(
                getOAuthApplicationSettingsURL(endpoint: "https://api.github.com", clientID: "Ov23li")
                    == "https://github.com/settings/connections/applications/Ov23li"
            )
            #expect(
                getOAuthApplicationSettingsURL(endpoint: "https://api.octocorp.ghe.com/", clientID: "Ov23li")
                    == "https://octocorp.ghe.com/settings/connections/applications/Ov23li"
            )
        }
    }

    @Suite("requests")
    struct Requests {
        let mock = MockGitHub()

        var api: API {
            API(endpoint: "https://api.github.com", token: "token", runtime: mock.runtime)
        }

        @Test("sends desktop's headers with the token")
        func sendsHeaders() async throws {
            mock.on("GET", "/user", respond: .json(encoding: createMockAPIFullIdentity()))

            _ = try await api.fetchAccount()

            let request = try #require(mock.requests.first)
            #expect(request.header("Accept") == "application/vnd.github.v3+json, application/json")
            #expect(request.header("Content-Type") == "application/json")
            // MockGitHub's runtime has `getUserAgent(appVersion: "1.0.0")`.
            #expect(request.header("User-Agent") == "Espalier/1.0.0 (Macintosh)")
            #expect(request.header("Authorization") == "Bearer token")
        }

        @Test("keeps the token on same-origin redirects and drops it on others")
        func redirects() async throws {
            mock.on("GET", "/repos/old/name", respond: .redirect(to: URL(string: "https://api.github.com/repositories/1")!, status: 301))
            mock.on("GET", "/repositories/1", respond: .json(encoding: createMockAPIRepository()))
            mock.on("GET", "/repos/moved/away", respond: .redirect(to: URL(string: "https://elsewhere.example.com/repo")!, status: 302))
            mock.on("GET", "/repo", respond: .json(encoding: createMockAPIRepository()))

            #expect(await api.fetchRepository(owner: "old", name: "name") != nil)
            #expect(await api.fetchRepository(owner: "moved", name: "away") != nil)

            #expect(mock.requests("GET", "/repositories/1").first?.header("Authorization") == "Bearer token")
            #expect(mock.requests("GET", "/repo").first?.url.host() == "elsewhere.example.com")
            #expect(mock.requests("GET", "/repo").first?.header("Authorization") == nil)
        }

        @Test("sends JSON bodies")
        func sendsJSONBodies() async throws {
            mock.on("POST", "/user/repos", respond: .json(encoding: createMockAPIRepository(name: "new-repo"), status: 201))

            let repository = try await api.createRepository(org: nil, name: "new-repo", description: "A repo", private: true)

            #expect(repository.name == "new-repo")
            #expect(mock.requests.first?.json == ["name": "new-repo", "description": "A repo", "private": true])
        }

        @Test("throws a GitHubError when creating a repository fails")
        func createRepositoryErrors() async {
            mock.on("POST", "/orgs/desktop/repos", respond: .json(["message": "Validation Failed"], status: 422))
            mock.on("POST", "/user/repos", respond: .networkError(.notConnectedToInternet))
            let org = APIOrganization(id: 1, url: "", login: "desktop", avatarURL: "")

            let refused = await #expect(throws: GitHubError.self) {
                try await api.createRepository(org: org, name: "r", description: "", private: false)
            }
            // GitHub's reason comes through (desktop guessed one).
            #expect(refused?.message.contains("Validation Failed") == true)
            await #expect(throws: GitHubError.self) {
                try await api.createRepository(org: nil, name: "r", description: "", private: false)
            }
        }

        @Test("follows pagination links")
        func followsPagination() async throws {
            mock.on("GET", "/user/orgs") { request in
                if request.query["page"] == "2" {
                    return .json(encoding: [APIOrganization(id: 2, url: "", login: "two", avatarURL: "")])
                }
                return .json(
                    encoding: [APIOrganization(id: 1, url: "", login: "one", avatarURL: "")],
                    headers: ["Link": #"<https://api.github.com/user/orgs?per_page=100&page=2>; rel="next", <https://api.github.com/user/orgs?per_page=100&page=2>; rel="last""#]
                )
            }

            let orgs = await api.fetchOrgs()

            #expect(orgs.map(\.login) == ["one", "two"])
            #expect(mock.requests.map { $0.query["per_page"] } == ["100", "100"])
        }

        @Test("organizations and issues fail when a page fails (desktop kept the pages before it)")
        func failedPages() async throws {
            mock.on("GET", "/user/orgs") { request in
                if request.query["page"] == "2" {
                    return .json(["message": "Server Error"], status: 500)
                }
                return .json(
                    encoding: [APIOrganization(id: 1, url: "", login: "one", avatarURL: "")],
                    headers: ["Link": #"<https://api.github.com/user/orgs?page=2>; rel="next""#]
                )
            }
            mock.on("GET", "/repos/desktop/desktop/issues") { request in
                if request.query["page"] == "2" {
                    return .json(["message": "Server Error"], status: 500)
                }
                return .json(
                    [["number": 1, "title": "Issue", "state": "open", "updated_at": "2019-05-10T16:00:00Z"]],
                    headers: ["Link": #"<https://api.github.com/repos/desktop/desktop/issues?state=all&page=2>; rel="next""#]
                )
            }

            #expect(await api.fetchOrgs().isEmpty)
            await #expect(throws: APIError.self) {
                try await api.fetchIssues(owner: "desktop", name: "desktop", state: .all, since: nil)
            }
        }

        @Test("a ref's statuses and check runs and a workflow run's jobs load every page; a failed page fails them")
        func checksPages() async throws {
            /// Answers `path` with `first`, linking to a second page that
            /// has `second` or fails.
            func serve(_ path: String, _ first: some Encodable & Sendable, _ second: some Encodable & Sendable, failing: Bool) {
                mock.on("GET", path) { request in
                    if request.query["page"] == "2" {
                        return failing ? .json(["message": "Server Error"], status: 500) : .json(encoding: second)
                    }
                    return .json(encoding: first, headers: ["Link": "<https://api.github.com\(path)?per_page=100&page=2>; rel=\"next\""])
                }
            }
            func status(_ id: Int) -> APIRefStatusItem {
                APIRefStatusItem(state: .success, targetURL: nil, description: nil, context: "ci/\(id)", id: id)
            }
            func checkRun(_ id: Int) -> APIRefCheckRun {
                APIRefCheckRun(
                    id: id, url: "", status: .completed, conclusion: .success, name: "check \(id)",
                    checkSuite: APIRefCheckRunCheckSuite(id: 1), app: nil, completedAt: nil, startedAt: nil, htmlURL: nil, pullRequests: []
                )
            }
            func job(_ id: Int) -> APIWorkflowJob {
                APIWorkflowJob(id: id, name: "job \(id)", status: .completed, conclusion: .success, completedAt: nil, startedAt: "", steps: nil, htmlURL: nil)
            }
            func serveAll(failing: Bool) {
                serve(
                    "/repos/desktop/desktop/commits/abc/status",
                    APIRefStatus(state: .success, totalCount: 2, statuses: [status(1)]),
                    APIRefStatus(state: .success, totalCount: 2, statuses: [status(2)]),
                    failing: failing
                )
                serve(
                    "/repos/desktop/desktop/commits/abc/check-runs",
                    APIRefCheckRuns(totalCount: 2, checkRuns: [checkRun(1)]),
                    APIRefCheckRuns(totalCount: 2, checkRuns: [checkRun(2)]),
                    failing: failing
                )
                serve(
                    "/repos/desktop/desktop/actions/runs/7/jobs",
                    APIWorkflowJobs(totalCount: 2, jobs: [job(1)]),
                    APIWorkflowJobs(totalCount: 2, jobs: [job(2)]),
                    failing: failing
                )
            }

            serveAll(failing: false)
            let statuses = try await api.fetchCombinedRefStatus(owner: "desktop", name: "desktop", ref: "abc")
            #expect(statuses?.statuses.map(\.id) == [1, 2])
            let checkRuns = try await api.fetchRefCheckRuns(owner: "desktop", name: "desktop", ref: "abc")
            #expect(checkRuns?.checkRuns.map(\.id) == [1, 2])
            let jobs = try await api.fetchWorkflowRunJobs(owner: "desktop", name: "desktop", workflowRunId: 7)
            #expect(jobs?.jobs.map(\.id) == [1, 2])
            #expect(mock.requests.allSatisfy { $0.query["per_page"] == "100" })

            serveAll(failing: true)
            #expect(try await api.fetchCombinedRefStatus(owner: "desktop", name: "desktop", ref: "abc") == nil)
            #expect(try await api.fetchRefCheckRuns(owner: "desktop", name: "desktop", ref: "abc") == nil)
            #expect(try await api.fetchWorkflowRunJobs(owner: "desktop", name: "desktop", workflowRunId: 7) == nil)
        }

        @Test("re-running checks throws when GitHub refuses or can't be reached")
        func rerunsRefused() async throws {
            mock.on("POST", "/repos/desktop/desktop/actions/jobs/1/rerun", respond: .status(201))
            mock.on("POST", "/repos/desktop/desktop/actions/runs/2/rerun-failed-jobs", respond: .json(["message": "Must have admin rights to Repository."], status: 403))
            mock.on("POST", "/repos/desktop/desktop/check-suites/3/rerequest", respond: .networkError(.notConnectedToInternet))

            try await api.rerunJob(owner: "desktop", name: "desktop", jobId: 1)
            let refused = await #expect(throws: APIError.self) {
                try await api.rerunFailedJobs(owner: "desktop", name: "desktop", workflowRunId: 2)
            }
            #expect(refused?.responseStatus == 403)
            #expect(refused?.apiError?.message == "Must have admin rights to Repository.")
            await #expect(throws: (any Error).self) {
                try await api.rerequestCheckSuite(owner: "desktop", name: "desktop", checkSuiteId: 3)
            }
        }

        @Test("stops fetching updated pull requests at the since date")
        func fetchesUpdatedPullRequests() async throws {
            @Sendable func pullRequest(_ number: Int, updatedAt: String) -> APIPullRequest {
                let ref = APIPullRequestRef(ref: "main", sha: "abc", repo: nil)
                return APIPullRequest(
                    number: number,
                    title: "PR \(number)",
                    createdAt: "2024-01-01T00:00:00Z",
                    updatedAt: updatedAt,
                    user: createMockAPIIdentity(),
                    head: ref,
                    base: ref,
                    body: nil,
                    state: .open
                )
            }
            mock.on("GET", "/repos/desktop/desktop/pulls") { request in
                if request.query["page"] == "2" {
                    return .json(encoding: [pullRequest(3, updatedAt: "2024-01-03T00:00:00Z")])
                }
                return .json(
                    encoding: [pullRequest(1, updatedAt: "2024-01-05T00:00:00Z"), pullRequest(2, updatedAt: "2024-01-04T12:00:00Z")],
                    headers: ["Link": #"<https://api.github.com/repos/desktop/desktop/pulls?per_page=10&page=2>; rel="next""#]
                )
            }
            let since = try Date("2024-01-04T00:00:00Z", strategy: .iso8601)

            let prs = try await api.fetchUpdatedPullRequests(owner: "desktop", name: "desktop", since: since)

            #expect(prs.map(\.number) == [1, 2])
            // The second page was needed, because the last PR on the first page
            // was updated after `since`.
            #expect(mock.requests.count == 2)
            let first = try #require(mock.requests.first)
            #expect(first.query == ["state": "all", "sort": "updated", "direction": "desc", "per_page": "10"])
        }

        @Test("throws when too many pull requests changed")
        func throwsMaxResults() async throws {
            let ref = APIPullRequestRef(ref: "main", sha: "abc", repo: nil)
            let pr = APIPullRequest(
                number: 1,
                title: "PR",
                createdAt: "2024-01-01T00:00:00Z",
                updatedAt: "2024-01-05T00:00:00Z",
                user: nil,
                head: ref,
                base: ref,
                body: nil,
                state: .open
            )
            mock.on("GET", "/repos/desktop/desktop/pulls", respond: .json(
                encoding: [pr, pr],
                headers: ["Link": #"<https://api.github.com/repos/desktop/desktop/pulls?page=2>; rel="next""#]
            ))

            await #expect(throws: MaxResultsError.self) {
                try await api.fetchUpdatedPullRequests(owner: "desktop", name: "desktop", since: .distantPast, maxResults: 2)
            }
        }

        @Test("throws when the open pull requests can't all be loaded (desktop kept a partial list)")
        func openPullRequestsFail() async throws {
            let ref = APIPullRequestRef(ref: "main", sha: "abc", repo: nil)
            let pr = APIPullRequest(number: 1, title: "PR", createdAt: "", updatedAt: "", user: nil, head: ref, base: ref, body: nil, state: .open)
            mock.on("GET", "/repos/desktop/desktop/pulls") { request in
                if request.query["page"] == "2" {
                    return .json(["message": "API rate limit exceeded"], status: 403)
                }
                return .json(
                    encoding: [pr],
                    headers: ["Link": #"<https://api.github.com/repos/desktop/desktop/pulls?state=open&page=2>; rel="next""#]
                )
            }

            await #expect(throws: APIError.self) {
                try await api.fetchAllOpenPullRequests(owner: "desktop", name: "desktop")
            }
            #expect(mock.requests.first?.query == ["state": "open", "per_page": "100"])
        }

        @Test("asks for the comments since a date and throws on errors")
        func commentsSince() async throws {
            let comment = APIComment(id: 9, body: "Hi", htmlURL: "", user: createMockAPIIdentity(), createdAt: "2024-01-05T00:00:00Z")
            mock.on("GET", "/repos/desktop/desktop/issues/5/comments", respond: .json(encoding: [comment]))
            mock.on("GET", "/repos/desktop/desktop/pulls/5/comments", respond: .json(["message": "Not Found"], status: 404))
            let since = try Date("2024-01-04T00:00:00Z", strategy: .iso8601)

            let comments = try await api.fetchIssueComments(owner: "desktop", name: "desktop", issueNumber: "5", since: since)
            #expect(comments.map(\.id) == [9])
            #expect(mock.requests.first?.query == ["since": "2024-01-04T00:00:00Z", "per_page": "100"])

            await #expect(throws: APIError.self) {
                try await api.fetchPullRequestComments(owner: "desktop", name: "desktop", prNumber: "5", since: since)
            }
            #expect(mock.requests.last?.query["since"] == "2024-01-04T00:00:00Z")
        }

        @Test("skips repositories whose owner was deleted")
        func skipsOwnerlessRepositories() async throws {
            var ownerless = try JSONValue.parse(JSONEncoder().encode(createMockAPIRepository(name: "orphan")))
            if case .object(var fields) = ownerless {
                fields["owner"] = .null
                ownerless = .object(fields)
            }
            let kept = try JSONValue.parse(JSONEncoder().encode(createMockAPIRepository(name: "kept")))
            mock.on("GET", "/user/repos", respond: .json([ownerless, kept]))
            let pages = Mutex<[[String]]>([])

            await api.streamUserRepositories({ page in
                pages.withLock { $0.append(page.map(\.name)) }
            }, affiliation: .owner)

            #expect(pages.withLock { $0 } == [["kept"]])
            #expect(mock.requests.first?.query["affiliation"] == "owner")
        }

        @Test("records GitHub Enterprise Server versions from responses")
        func recordsEnterpriseVersions() async throws {
            let endpoint = "https://ghe.example.com/api/v3"
            mock.on("GET", "/api/v3/user", respond: .json(
                encoding: createMockAPIFullIdentity(),
                headers: ["X-GitHub-Enterprise-Version": "3.4.2"]
            ))
            let api = API(endpoint: endpoint, token: "token", runtime: mock.runtime)

            #expect(!supportsRerunningChecks(endpoint, runtime: mock.runtime))
            _ = try await api.fetchAccount()

            #expect(mock.runtime.endpointVersions.getEndpointVersion(endpoint) == SemVer("3.4.2"))
            #expect(supportsRerunningChecks(endpoint, runtime: mock.runtime))
        }

        @Test("leaves pull requests out of issues")
        func fetchesIssuesWithoutPullRequests() async throws {
            mock.on("GET", "/repos/desktop/desktop/issues", respond: .json([
                ["number": 1, "title": "Issue", "state": "open", "updated_at": "2019-05-10T16:00:00Z"],
                [
                    "number": 2,
                    "title": "Pull request",
                    "state": "open",
                    "updated_at": "2019-05-10T16:00:00Z",
                    "pull_request": ["url": "https://api.github.com/repos/desktop/desktop/pulls/2"],
                ],
            ]))
            let since = try Date("2019-05-10T16:00:00Z", strategy: .iso8601)

            let issues = try await api.fetchIssues(owner: "desktop", name: "desktop", state: .all, since: since)

            #expect(issues.map(\.number) == [1])
            let request = try #require(mock.requests.first)
            #expect(request.query == ["state": "all", "since": "2019-05-10T16:00:00Z", "per_page": "100"])
            #expect(request.url.query(percentEncoded: true)?.contains("since=2019-05-10T16%3A00%3A00Z") == true)
        }

        @Test("reads the fetch poll interval")
        func readsPollInterval() async {
            mock.on("HEAD", "/repos/desktop/desktop/git", respond: .status(200, headers: ["X-Poll-Interval": "60"]))

            #expect(await api.getFetchPollInterval(owner: "desktop", name: "desktop") == 60)
        }

        @Test("returns nothing for unchanged mentionables")
        func mentionablesNotModified() async throws {
            mock.on("GET", "/repos/desktop/desktop/mentionables/users", respond: .status(304))

            #expect(await api.fetchMentionables(owner: "desktop", name: "desktop", etag: "\"abc\"") == nil)
            let request = try #require(mock.requests.first)
            #expect(request.header("If-None-Match") == "\"abc\"")
            #expect(request.header("Accept") == "application/vnd.github.jerry-maguire-preview")
        }

        @Test("assumes full access when push control can't be read")
        func pushControlDefaults() async {
            mock.on("GET", "/repos/desktop/desktop/branches/feature%2Fx/push_control", respond: .status(404))

            let pushControl = await api.fetchPushControl(owner: "desktop", name: "desktop", branch: "feature/x")

            #expect(pushControl.allowActor)
            #expect(pushControl.requiredStatusChecks.isEmpty)
            #expect(mock.requests.first?.path == "/repos/desktop/desktop/branches/feature%2Fx/push_control")
        }

        @Test("decodes repository rules, ignoring other rules' parameters")
        func decodesRepoRules() async {
            mock.on("GET", "/repos/desktop/desktop/rules/branches/main", respond: .json([
                ["ruleset_id": 1, "type": "pull_request", "parameters": ["required_approving_review_count": 1]],
                ["ruleset_id": 2, "type": "commit_message_pattern", "parameters": ["operator": "starts_with", "pattern": "abc"]],
                ["ruleset_id": 3, "type": "merge_queue"],
            ]))

            let rules = await api.fetchRepoRulesForBranch(owner: "desktop", name: "desktop", branch: "main")

            #expect(rules == [
                APIRepoRule(rulesetID: 1, type: .pullRequest),
                APIRepoRule(
                    rulesetID: 2,
                    type: .commitMessagePattern,
                    parameters: APIRepoRuleMetadataParameters(name: "", negate: false, pattern: "abc", operator: .startsWith)
                ),
                APIRepoRule(rulesetID: 3, type: APIRepoRuleType(rawValue: "merge_queue")),
            ])
        }
    }

    @Suite("isGitHubHost")
    struct IsGitHubHost {
        let mock = MockGitHub()

        @Test("recognizes hosts without a request")
        func recognizesKnownHosts() async {
            #expect(await isGitHubHost("https://github.com/desktop/desktop", runtime: mock.runtime) == true)
            #expect(await isGitHubHost("https://octocorp.ghe.com/a/b", runtime: mock.runtime) == true)
            #expect(await isGitHubHost("https://gitlab.com/a/b", runtime: mock.runtime) == false)
            #expect(await isGitHubHost("https://foo.visualstudio.com/a/b", runtime: mock.runtime) == false)
            #expect(await isGitHubHost("https://github.example.com/a/b", runtime: mock.runtime) == true)
            #expect(await isGitHubHost("https://bitbucket.example.com/a/b", runtime: mock.runtime) == false)
            #expect(mock.requests.isEmpty)
        }

        @Test("asks an unknown host's meta endpoint")
        func asksMetaEndpoint() async throws {
            mock.on("HEAD", "/api/v3/meta", respond: .status(200, headers: ["X-GitHub-Request-Id": "1"]))

            #expect(await isGitHubHost("https://code.example.com/a/b", runtime: mock.runtime) == true)

            let request = try #require(mock.requests.first)
            #expect(request.url.host() == "code.example.com")
            #expect(request.query["ghd"] != nil)
            #expect(request.header("Authorization") == nil)
        }

        @Test("says no when the meta endpoint isn't GitHub's")
        func rejectsOtherServers() async {
            mock.on("HEAD", "/api/v3/meta", respond: .status(404))

            #expect(await isGitHubHost("https://code.example.com/a/b", runtime: mock.runtime) == false)
        }

        @Test("can't tell when the request fails or redirects")
        func unknownOnFailure() async {
            mock.on("HEAD", "/api/v3/meta", sequence: [
                .networkError(.cannotFindHost),
                .status(302, headers: ["Location": "https://login.example.com/"]),
            ])

            #expect(await isGitHubHost("https://code.example.com/a/b", runtime: mock.runtime) == nil)
            #expect(await isGitHubHost("https://code.example.com/a/b", runtime: mock.runtime) == nil)
        }
    }

    @Suite("SemVer")
    struct SemVerTests {
        @Test("parses like semver.parse")
        func parses() {
            #expect(SemVer("3.1.0") == SemVer(major: 3, minor: 1, patch: 0))
            #expect(SemVer(" v3.1.0 ") == SemVer(major: 3, minor: 1, patch: 0))
            #expect(SemVer("3.1.0-rc.1+build")?.prerelease == [.alphanumeric("rc"), .numeric(1)])
            #expect(SemVer("3.1") == nil)
            #expect(SemVer("03.1.0") == nil)
            #expect(SemVer("enterprise-3.1.0") == nil)
        }

        @Test("orders by precedence")
        func orders() {
            #expect(SemVer("1.0.0-alpha")! < SemVer("1.0.0-alpha.1")!)
            #expect(SemVer("1.0.0-alpha.1")! < SemVer("1.0.0-beta")!)
            #expect(SemVer("1.0.0-rc.1")! < SemVer("1.0.0")!)
            #expect(SemVer("1.0.0")! < SemVer("1.10.0")!)
        }

        @Test("checks ranges like semver.satisfies")
        func satisfies() {
            #expect(SemVer("3.4.0")!.satisfies(">= 3.4.0"))
            #expect(!SemVer("3.3.9")!.satisfies(">= 3.4.0"))
            #expect(SemVer("3.5.1")!.satisfies(">=3.4 <3.6"))
            #expect(!SemVer("3.6.0")!.satisfies(">=3.4 <3.6"))
            #expect(SemVer("2.0.0")!.satisfies("> 1"))
            #expect(!SemVer("1.9.9")!.satisfies("> 1"))
            #expect(SemVer("1.9.9")!.satisfies("<= 1"))
            #expect(SemVer("3.1.7")!.satisfies("3.1.x"))
            #expect(SemVer("4.0.0")!.satisfies("< 3 || >= 4"))
            #expect(!SemVer("3.0.0-beta")!.satisfies(">= 2.0.0"))
            #expect(SemVer("3.0.0-beta.2")!.satisfies(">= 3.0.0-beta.1"))
            #expect(SemVer("1.2.3")!.satisfies("*"))
        }
    }
}
