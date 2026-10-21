// Creating a pull request: the fields it posts, a fork's head, a draft, and
// what GitHub's refusals become.

import Foundation
@testable import GitHubKit
import TestSupport
import Testing

@Suite("Creating pull requests", .offline)
struct CreatePullRequestTests {
    private static let path = "/repos/octocat/hello/pulls"

    let mock = MockGitHub()

    var api: API {
        API(endpoint: "https://api.github.com", token: "token", runtime: mock.runtime)
    }

    /// The pull request GitHub answers with.
    private static func created(draft: Bool = false) -> APIPullRequest {
        let hello = createMockAPIRepository(
            cloneURL: "https://github.com/octocat/hello.git",
            sshURL: "git@github.com:octocat/hello.git",
            htmlURL: "https://github.com/octocat/hello",
            name: "hello"
        )
        return APIPullRequest(
            number: 7,
            title: "Add a feature",
            createdAt: "2026-10-20T10:00:00Z",
            updatedAt: "2026-10-20T10:00:00Z",
            user: createMockAPIIdentity(),
            head: APIPullRequestRef(ref: "feature", sha: String(repeating: "a", count: 40), repo: hello),
            base: APIPullRequestRef(ref: "main", sha: String(repeating: "b", count: 40), repo: hello),
            body: "The details",
            state: .open,
            draft: draft
        )
    }

    private func create(headOwner: String? = nil, draft: Bool = false) async throws -> APIPullRequest {
        try await api.createPullRequest(
            owner: "octocat",
            name: "hello",
            title: "Add a feature",
            body: "The details",
            head: "feature",
            headOwner: headOwner,
            base: "main",
            draft: draft
        )
    }

    @Test("posts the title, body, head, base, and draft, and returns the pull request")
    func postsFields() async throws {
        mock.on("POST", Self.path, respond: .json(encoding: Self.created(), status: 201))

        let pullRequest = try await create()

        #expect(pullRequest.number == 7)
        #expect(pullRequest.head.ref == "feature")
        let request = try #require(mock.requests("POST", Self.path).first)
        #expect(request.json == [
            "title": "Add a feature",
            "body": "The details",
            "head": "feature",
            "base": "main",
            "draft": false,
        ])
    }

    @Test("a branch in a fork goes as owner:branch, and a draft says so")
    func forkHeadAndDraft() async throws {
        mock.on("POST", Self.path, respond: .json(encoding: Self.created(draft: true), status: 201))

        let pullRequest = try await create(headOwner: "hubot", draft: true)

        #expect(pullRequest.draft == true)
        let json = try #require(mock.requests("POST", Self.path).first?.json)
        #expect(json["head"] == "hubot:feature")
        #expect(json["draft"] == true)
    }

    /// A validation failure, as GitHub sends one: its summary and its
    /// errors.
    private static func validation(_ errors: JSONValue) -> MockGitHub.Response {
        .json(["message": "Validation Failed", "errors": errors, "documentation_url": "https://docs.github.com/rest"], status: 422)
    }

    @Test("GitHub's refusals become what went wrong", arguments: [
        NamedCase("a pull request already open for the branch", (
            response: validation([["resource": "PullRequest", "code": "custom", "message": "A pull request already exists for octocat:feature."]]),
            kind: CreatePullRequestError.Kind.alreadyExists,
            status: 422 as Int?
        )),
        NamedCase("no commits between the branches", (
            response: validation([["resource": "PullRequest", "code": "custom", "message": "No commits between main and feature"]]),
            kind: .noCommits,
            status: 422
        )),
        NamedCase("a base branch GitHub doesn't have", (
            response: validation([["resource": "PullRequest", "field": "base", "code": "invalid"]]),
            kind: .baseNotFound,
            status: 422
        )),
        NamedCase("a branch GitHub doesn't have", (
            response: validation([["resource": "PullRequest", "field": "head", "code": "invalid"]]),
            kind: .headNotFound,
            status: 422
        )),
        NamedCase("a draft in a repository without drafts", (
            response: validation([["resource": "PullRequest", "code": "custom", "message": "Draft pull requests are not supported in this repository."]]),
            kind: .draftsNotSupported,
            status: 422
        )),
        NamedCase("a missing title", (
            response: validation([["resource": "Issue", "field": "title", "code": "missing_field"]]),
            kind: .validationFailed,
            status: 422
        )),
        NamedCase("another validation failure", (
            response: validation([["resource": "Issue", "code": "custom", "field": "body", "message": "body is too long (maximum is 65536 characters)"]]),
            kind: .validationFailed,
            status: 422
        )),
        NamedCase("a repository the account can't see", (
            response: .json(["message": "Not Found"], status: 404),
            kind: .notFound,
            status: 404
        )),
        NamedCase("another refusal", (
            response: .json(["message": "Resource not accessible by integration"], status: 403),
            kind: .other,
            status: 403
        )),
        NamedCase("an answer that isn't a pull request", (
            response: .json(["number": "seven"], status: 201),
            kind: .other,
            status: 201
        )),
        NamedCase("no connection", (
            response: .networkError(.notConnectedToInternet),
            kind: .unreachable,
            status: nil
        )),
    ] as [NamedCase<(response: MockGitHub.Response, kind: CreatePullRequestError.Kind, status: Int?)>])
    func refusals(_ testCase: NamedCase<(response: MockGitHub.Response, kind: CreatePullRequestError.Kind, status: Int?)>) async {
        mock.on("POST", Self.path, respond: testCase.value.response)

        let error = await #expect(throws: CreatePullRequestError.self) {
            try await create()
        }

        #expect(error?.kind == testCase.value.kind)
        #expect(error?.status == testCase.value.status)
    }
}
