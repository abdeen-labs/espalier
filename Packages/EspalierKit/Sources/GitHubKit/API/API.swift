// Ported from desktop/app/src/lib/api.ts (the API class)

import EspalierSupport
import Foundation
import os

private let log = Log.logger(category: "github-api")

/// An object for making authenticated requests to the GitHub API
public struct API: Sendable {
    /// Calls `callback` whenever GitHub rejects a token. Cancel the returned
    /// registration to stop.
    @discardableResult
    public static func onTokenInvalidated(
        runtime: GitHubRuntime = .current,
        _ callback: @escaping TokenInvalidationCenter.Callback
    ) -> TokenInvalidationRegistration {
        runtime.tokenInvalidation.addListener(callback)
    }

    /// Create a new API client from the given account.
    public static func fromAccount(_ account: Account, runtime: GitHubRuntime = .current) -> API {
        API(endpoint: account.endpoint, token: account.token, runtime: runtime)
    }

    public let endpoint: String
    private let token: String
    private let runtime: GitHubRuntime

    /// Create a new API client for the endpoint, authenticated with the token.
    public init(endpoint: String, token: String, runtime: GitHubRuntime = .current) {
        self.endpoint = endpoint
        self.token = token
        self.runtime = runtime
    }

    /// Fetch an issue comment (i.e. a comment on an issue or pull request).
    ///
    /// - Parameters:
    ///   - owner: The owner of the repository
    ///   - name: The name of the repository
    ///   - commentId: The ID of the comment
    /// - Returns: The comment if it was found, null if it wasn't, or an error
    ///   occurred.
    public func fetchIssueComment(owner: String, name: String, commentId: String) async -> APIComment? {
        do {
            let response = try await ghRequest(.get, "repos/\(owner)/\(name)/issues/comments/\(commentId)")
            if response.status == HTTPStatusCode.notFound.rawValue {
                log.warning("fetchIssueComment: '\(owner, privacy: .public)/\(name, privacy: .public)/issues/comments/\(commentId, privacy: .public)' returned a 404")
                return nil
            }
            return try parsedResponse(response, as: APIComment.self)
        } catch {
            log.warning("fetchIssueComment: an error occurred for '\(owner, privacy: .public)/\(name, privacy: .public)/issues/comments/\(commentId, privacy: .public)': \(String(describing: error), privacy: .public)")
            return nil
        }
    }

    /// Fetch a pull request review comment (i.e. a comment that was posted as part
    /// of a review of a pull request).
    ///
    /// - Parameters:
    ///   - owner: The owner of the repository
    ///   - name: The name of the repository
    ///   - commentId: The ID of the comment
    /// - Returns: The comment if it was found, null if it wasn't, or an error
    ///   occurred.
    public func fetchPullRequestReviewComment(owner: String, name: String, commentId: String) async -> APIComment? {
        do {
            let response = try await ghRequest(.get, "repos/\(owner)/\(name)/pulls/comments/\(commentId)")
            if response.status == HTTPStatusCode.notFound.rawValue {
                log.warning("fetchPullRequestReviewComment: '\(owner, privacy: .public)/\(name, privacy: .public)/pulls/comments/\(commentId, privacy: .public)' returned a 404")
                return nil
            }
            return try parsedResponse(response, as: APIComment.self)
        } catch {
            log.warning("fetchPullRequestReviewComment: an error occurred for '\(owner, privacy: .public)/\(name, privacy: .public)/pulls/comments/\(commentId, privacy: .public)': \(String(describing: error), privacy: .public)")
            return nil
        }
    }

    /// Fetch a repo by its owner and name.
    public func fetchRepository(owner: String, name: String) async -> APIFullRepository? {
        do {
            let response = try await ghRequest(.get, "repos/\(owner)/\(name)")
            if response.status == HTTPStatusCode.notFound.rawValue {
                log.warning("fetchRepository: '\(owner, privacy: .public)/\(name, privacy: .public)' returned a 404")
                return nil
            }
            return try parsedResponse(response, as: APIFullRepository.self)
        } catch {
            log.warning("fetchRepository: an error occurred for '\(owner, privacy: .public)/\(name, privacy: .public)': \(String(describing: error), privacy: .public)")
            return nil
        }
    }

    /// Fetch info needed to clone a repository. That includes:
    ///  - The canonical clone URL for a repository, respecting the protocol
    ///    preference if provided.
    ///  - The default branch of the repository, in case the repository is empty.
    ///    Only available for GitHub repositories.
    ///
    /// Returns null if the request returned a 404 (NotFound). NotFound doesn't
    /// necessarily mean that the repository doesn't exist, it could exist and
    /// the current user just doesn't have the permissions to see it. GitHub.com
    /// doesn't differentiate between not found and permission denied for private
    /// repositories as that would leak the existence of a private repository.
    ///
    /// Note that unlike `fetchRepository` this method will throw for all errors
    /// except 404 NotFound responses.
    ///
    /// - Parameters:
    ///   - owner: The repository owner (nodejs in https://github.com/nodejs/node)
    ///   - name: The repository name (node in https://github.com/nodejs/node)
    ///   - protocol: The preferred Git protocol (https or ssh)
    public func fetchRepositoryCloneInfo(
        owner: String,
        name: String,
        protocol: GitProtocol?
    ) async throws -> APIRepositoryCloneInfo? {
        let response = try await ghRequest(
            .get,
            "repos/\(owner)/\(name)",
            // Make sure we don't run into cache issues when fetching the repositories,
            // specially after repositories have been renamed.
            reloadCache: true
        )

        if response.status == HTTPStatusCode.notFound.rawValue {
            return nil
        }

        let repo = try parsedResponse(response, as: APIRepository.self)
        return APIRepositoryCloneInfo(
            url: `protocol` == .ssh ? repo.sshURL : repo.cloneURL,
            defaultBranch: repo.defaultBranch
        )
    }

    /// Fetch all repos a user has access to in a streaming fashion. The callback
    /// will be called for each new page fetched from the API.
    public func streamUserRepositories(
        _ callback: @escaping @Sendable ([APIRepository]) -> Void,
        affiliation: AffiliationFilter? = nil,
        options: FetchAllOptions<APIRepository> = FetchAllOptions()
    ) async {
        do {
            let base = "user/repos"
            let path = affiliation.map { "\(base)?affiliation=\($0.rawValue)" } ?? base

            let onPage = options.onPage
            var shouldContinue: (@Sendable ([StreamedRepository]) async throws -> Bool)?
            if let continueWithRepositories = options.continue {
                shouldContinue = { results in
                    try await continueWithRepositories(results.compactMap(\.repository))
                }
            }

            // "But wait, repositories can't have a null owner" you say.
            // Ordinarily you'd be correct but turns out there's super
            // rare circumstances where a user has been deleted but the
            // repository hasn't. Such cases are usually addressed swiftly
            // but in some cases like GitHub Enterprise instances
            // they can linger for longer than we'd like so we'll make
            // sure to exclude any such dangling repository, chances are
            // they won't be cloneable anyway.
            let onStreamedPage: @Sendable ([StreamedRepository]) -> Void = { page in
                let repositories = page.compactMap(\.repository)
                callback(repositories)
                onPage?(repositories)
            }

            let streamOptions = FetchAllOptions<StreamedRepository>(
                perPage: options.perPage,
                continue: shouldContinue,
                onPage: onStreamedPage,
                getNextPagePath: options.getNextPagePath,
                suppressErrors: options.suppressErrors
            )
            _ = try await fetchAll(path, options: streamOptions)
        } catch {
            log.warning("streamUserRepositories: failed with endpoint \(endpoint, privacy: .public): \(String(describing: error), privacy: .public)")
        }
    }

    /// Fetch the logged in account.
    public func fetchAccount() async throws -> APIFullIdentity {
        do {
            let response = try await ghRequest(.get, "user")
            return try parsedResponse(response, as: APIFullIdentity.self)
        } catch {
            log.warning("fetchAccount: failed with endpoint \(endpoint, privacy: .public): \(String(describing: error), privacy: .public)")
            throw error
        }
    }

    /// Fetch the current user's emails. Throws when they can't be fetched.
    public func fetchEmails() async throws -> [APIEmail] {
        do {
            let response = try await ghRequest(.get, "user/emails")
            return try parsedResponse(response, as: [APIEmail].self)
        } catch {
            log.warning("fetchEmails: failed with endpoint \(endpoint, privacy: .public): \(String(describing: error), privacy: .public)")
            throw error
        }
    }

    /// Fetch all the orgs to which the user belongs; none when any page
    /// fails to load.
    public func fetchOrgs() async -> [APIOrganization] {
        do {
            return try await fetchAll("user/orgs", options: FetchAllOptions<APIOrganization>(suppressErrors: false))
        } catch {
            log.warning("fetchOrgs: failed with endpoint \(endpoint, privacy: .public): \(String(describing: error), privacy: .public)")
            return []
        }
    }

    /// Create a new GitHub repository with the given properties.
    public func createRepository(
        org: APIOrganization?,
        name: String,
        description: String,
        private isPrivate: Bool
    ) async throws -> APIFullRepository {
        do {
            let apiPath = org.map { "orgs/\($0.login)/repos" } ?? "user/repos"
            let response = try await ghRequest(.post, apiPath, body: [
                "name": .string(name),
                "description": .string(description),
                "private": .bool(isPrivate),
            ])

            return try parsedResponse(response, as: APIFullRepository.self)
        } catch let error as APIError {
            if let org {
                throw GitHubError("Couldn't create the repository in \(org.login). \(error.message)")
            }
            throw error
        } catch {
            if error is CancellationError { throw error }
            log.error("createRepository: failed with endpoint \(endpoint, privacy: .public): \(String(describing: error), privacy: .public)")
            throw GitHubError(
                "Couldn't publish the repository. Check your internet connection and try again."
            )
        }
    }

    /// Create a new GitHub fork of this repository (owner and name)
    public func forkRepository(owner: String, name: String) async throws -> APIFullRepository {
        do {
            let apiPath = "/repos/\(owner)/\(name)/forks"
            let response = try await ghRequest(.post, apiPath)
            return try parsedResponse(response, as: APIFullRepository.self)
        } catch {
            log.error("forkRepository: failed to fork \(owner, privacy: .public)/\(name, privacy: .public) at endpoint: \(endpoint, privacy: .public): \(String(describing: error), privacy: .public)")
            throw error
        }
    }

    /// Fetch the issues with the given state that have been created or updated
    /// since the given date.
    ///
    /// Pull requests, which the API returns as issues with a `pull_request`
    /// field, are left out.
    ///
    /// - Throws: Network errors and API errors, on any page, so a caller
    ///   never takes the pages loaded so far for every issue.
    public func fetchIssues(
        owner: String,
        name: String,
        state: APIIssueStateFilter,
        since: Date?
    ) async throws -> [APIIssue] {
        let url: String
        if let since {
            url = urlWithQueryString("repos/\(owner)/\(name)/issues", [
                "state": state.rawValue,
                "since": toGitHubIsoDateString(since),
            ])
        } else {
            url = urlWithQueryString("repos/\(owner)/\(name)/issues", ["state": state.rawValue])
        }

        do {
            let issues = try await fetchAll(url, options: FetchAllOptions<APIIssue>(suppressErrors: false))

            // PRs are issues! But we only want Really Seriously Issues.
            return issues.filter { $0.pullRequest == nil }
        } catch {
            log.warning("fetchIssues: failed for repository \(owner, privacy: .public)/\(name, privacy: .public): \(String(describing: error), privacy: .public)")
            throw error
        }
    }

    /// Fetch all open pull requests in the given repository.
    ///
    /// An error response throws, so a caller never takes the pages loaded so
    /// far for every open pull request.
    public func fetchAllOpenPullRequests(owner: String, name: String) async throws -> [APIPullRequest] {
        let url = urlWithQueryString("repos/\(owner)/\(name)/pulls", ["state": "open"])
        do {
            return try await fetchAll(url, options: FetchAllOptions<APIPullRequest>(suppressErrors: false))
        } catch {
            log.warning("failed fetching open PRs for repository \(owner, privacy: .public)/\(name, privacy: .public): \(String(describing: error), privacy: .public)")
            throw error
        }
    }

    /// Fetch all pull requests in the given repository that have been
    /// updated on or after the provided date.
    ///
    /// Note: The GitHub API doesn't support providing a last-updated
    /// limitation for PRs like it does for issues so we're emulating
    /// the issues API by sorting PRs descending by last updated and
    /// only grab as many pages as we need to until we no longer receive
    /// PRs that have been update more recently than the `since`
    /// parameter.
    ///
    /// If there's more than `maxResults` updated PRs since the last time
    /// we fetched this method will throw an error such that we can abort
    /// this strategy and commence loading all open PRs instead.
    public func fetchUpdatedPullRequests(
        owner: String,
        name: String,
        since: Date,
        // 320 is chosen because with a ramp-up page size starting with
        // a page size of 10 we'll reach 320 in exactly 7 pages. See
        // getNextPagePathWithIncreasingPageSize
        maxResults: Int = 320
    ) async throws -> [APIPullRequest] {
        let url = urlWithQueryString("repos/\(owner)/\(name)/pulls", [
            "state": "all",
            "sort": "updated",
            "direction": "desc",
        ])

        do {
            let prs = try await fetchAll(url, options: FetchAllOptions<APIPullRequest>(
                // We use a page size smaller than our default 100 here because we
                // expect that the majority use case will return much less than
                // 100 results. Given that as long as _any_ PR has changed we'll
                // get the full list back (PRs doesn't support ?since=) we want
                // to keep this number fairly conservative in order to not use
                // up bandwidth needlessly while balancing it such that we don't
                // have to use a lot of requests to update our database. We then
                // ramp up the page size (see getNextPagePathWithIncreasingPageSize)
                // if it turns out there's a lot of updated PRs.
                perPage: 10,
                continue: { results in
                    if results.count >= maxResults {
                        throw MaxResultsError("got max pull requests, aborting")
                    }

                    // Given that we sort the results in descending order by their
                    // updated_at field we can safely say that if the last item
                    // is modified after our sinceTime then haven't reached the
                    // end of updated PRs.
                    guard let last = results.last, let updated = parseGitHubDate(last.updatedAt) else {
                        return false
                    }
                    return updated > since
                },
                getNextPagePath: getNextPagePathWithIncreasingPageSize,
                // We can't ignore errors here as that might mean that we haven't
                // retrieved enough pages to fully capture the changes since the
                // last time we updated. Ignoring errors here would mean that we'd
                // store an incorrect lastUpdated field in the database.
                suppressErrors: false
            ))
            return prs.filter { pr in
                parseGitHubDate(pr.updatedAt).map { $0 >= since } ?? false
            }
        } catch {
            log.warning("failed fetching updated PRs for repository \(owner, privacy: .public)/\(name, privacy: .public): \(String(describing: error), privacy: .public)")
            throw error
        }
    }

    /// Fetch a single pull request in the given repository
    public func fetchPullRequest(owner: String, name: String, prNumber: String) async throws -> APIPullRequest {
        do {
            let path = "/repos/\(owner)/\(name)/pulls/\(prNumber)"
            let response = try await ghRequest(.get, path)
            return try parsedResponse(response, as: APIPullRequest.self)
        } catch {
            log.warning("failed fetching PR for \(owner, privacy: .public)/\(name, privacy: .public)/pulls/\(prNumber, privacy: .public): \(String(describing: error), privacy: .public)")
            throw error
        }
    }

    /// Fetch a single pull request review in the given repository
    public func fetchPullRequestReview(
        owner: String,
        name: String,
        prNumber: String,
        reviewId: String
    ) async -> APIPullRequestReview? {
        do {
            let path = "/repos/\(owner)/\(name)/pulls/\(prNumber)/reviews/\(reviewId)"
            let response = try await ghRequest(.get, path)
            return try parsedResponse(response, as: APIPullRequestReview.self)
        } catch {
            log.debug("failed fetching PR review \(reviewId, privacy: .public) for \(owner, privacy: .public)/\(name, privacy: .public)/pulls/\(prNumber, privacy: .public): \(String(describing: error), privacy: .public)")
            return nil
        }
    }

    /// Fetches all reviews from a given pull request.
    public func fetchPullRequestReviews(owner: String, name: String, prNumber: String) async -> [APIPullRequestReview] {
        do {
            let path = "/repos/\(owner)/\(name)/pulls/\(prNumber)/reviews"
            let response = try await ghRequest(.get, path)
            return try parsedResponse(response, as: [APIPullRequestReview].self)
        } catch {
            log.debug("failed fetching PR reviews for \(owner, privacy: .public)/\(name, privacy: .public)/pulls/\(prNumber, privacy: .public): \(String(describing: error), privacy: .public)")
            return []
        }
    }

    /// Fetches all review comments from a given pull request.
    public func fetchPullRequestReviewComments(
        owner: String,
        name: String,
        prNumber: String,
        reviewId: String
    ) async -> [APIComment] {
        do {
            let path = "/repos/\(owner)/\(name)/pulls/\(prNumber)/reviews/\(reviewId)/comments"
            let response = try await ghRequest(.get, path)
            return try parsedResponse(response, as: [APIComment].self)
        } catch {
            log.debug("failed fetching PR review comments for \(owner, privacy: .public)/\(name, privacy: .public)/pulls/\(prNumber, privacy: .public): \(String(describing: error), privacy: .public)")
            return []
        }
    }

    /// Fetches all review comments from a given pull request.
    public func fetchPullRequestComments(owner: String, name: String, prNumber: String) async -> [APIComment] {
        do {
            let path = "/repos/\(owner)/\(name)/pulls/\(prNumber)/comments"
            let response = try await ghRequest(.get, path)
            return try parsedResponse(response, as: [APIComment].self)
        } catch {
            log.debug("failed fetching PR comments for \(owner, privacy: .public)/\(name, privacy: .public)/pulls/\(prNumber, privacy: .public): \(String(describing: error), privacy: .public)")
            return []
        }
    }

    /// Fetches all comments from a given issue.
    public func fetchIssueComments(owner: String, name: String, issueNumber: String) async -> [APIComment] {
        do {
            let path = "/repos/\(owner)/\(name)/issues/\(issueNumber)/comments"
            let response = try await ghRequest(.get, path)
            return try parsedResponse(response, as: [APIComment].self)
        } catch {
            log.debug("failed fetching issue comments for \(owner, privacy: .public)/\(name, privacy: .public)/issues/\(issueNumber, privacy: .public): \(String(describing: error), privacy: .public)")
            return []
        }
    }

    /// Fetches every review of a pull request, oldest first, page by page
    /// (`fetchPullRequestReviews` reads the first page only, which misses new
    /// reviews on busy pull requests).
    ///
    /// - Throws: Network errors and API errors, so a caller never takes a
    ///   partial list for the whole.
    public func fetchAllPullRequestReviews(owner: String, name: String, prNumber: String) async throws -> [APIPullRequestReview] {
        let path = "repos/\(owner)/\(name)/pulls/\(prNumber)/reviews"
        return try await fetchAll(path, options: FetchAllOptions<APIPullRequestReview>(suppressErrors: false))
    }

    /// Fetches the comments on an issue or pull request created or updated
    /// at or after `since`, oldest first, page by page.
    ///
    /// - Throws: Network errors and API errors.
    public func fetchIssueComments(owner: String, name: String, issueNumber: String, since: Date) async throws -> [APIComment] {
        let path = urlWithQueryString("repos/\(owner)/\(name)/issues/\(issueNumber)/comments", [
            "since": toGitHubIsoDateString(since),
        ])
        return try await fetchAll(path, options: FetchAllOptions<APIComment>(suppressErrors: false))
    }

    /// Fetches the review comments on a pull request created or updated at
    /// or after `since`, page by page.
    ///
    /// - Throws: Network errors and API errors.
    public func fetchPullRequestComments(owner: String, name: String, prNumber: String, since: Date) async throws -> [APIComment] {
        let path = urlWithQueryString("repos/\(owner)/\(name)/pulls/\(prNumber)/comments", [
            "since": toGitHubIsoDateString(since),
        ])
        return try await fetchAll(path, options: FetchAllOptions<APIComment>(suppressErrors: false))
    }

    /// Get the combined status for the given ref: every page of its
    /// statuses.
    ///
    /// - Returns: nil when a page's response isn't the status (an API error).
    /// - Throws: Network errors.
    public func fetchCombinedRefStatus(
        owner: String,
        name: String,
        ref: String,
        reloadCache: Bool = false
    ) async throws -> APIRefStatus? {
        let safeRef = encodeURIComponent(ref)
        let path = "repos/\(owner)/\(name)/commits/\(safeRef)/status?per_page=100"

        do {
            let pages = try await fetchPages(path, as: APIRefStatus.self, reloadCache: reloadCache)
            return pages.first.map { first in
                APIRefStatus(state: first.state, totalCount: first.totalCount, statuses: pages.flatMap(\.statuses))
            }
        } catch let error where isResponseError(error) {
            log.debug("Failed fetching check runs for ref \(ref, privacy: .public) (\(owner, privacy: .public)/\(name, privacy: .public)): \(String(describing: error), privacy: .public)")
            return nil
        }
    }

    /// Get any check run results for the given ref: every page of them.
    ///
    /// - Returns: nil when a page's response isn't the check runs (an API
    ///   error).
    /// - Throws: Network errors.
    public func fetchRefCheckRuns(
        owner: String,
        name: String,
        ref: String,
        reloadCache: Bool = false
    ) async throws -> APIRefCheckRuns? {
        let safeRef = encodeURIComponent(ref)
        let path = "repos/\(owner)/\(name)/commits/\(safeRef)/check-runs?per_page=100"
        let headers = [
            "Accept": "application/vnd.github.antiope-preview+json",
        ]

        do {
            let pages = try await fetchPages(path, as: APIRefCheckRuns.self, customHeaders: headers, reloadCache: reloadCache)
            return pages.first.map { first in
                APIRefCheckRuns(totalCount: first.totalCount, checkRuns: pages.flatMap(\.checkRuns))
            }
        } catch let error where isResponseError(error) {
            log.debug("Failed fetching check runs for ref \(ref, privacy: .public) (\(owner, privacy: .public)/\(name, privacy: .public)): \(String(describing: error), privacy: .public)")
            return nil
        }
    }

    /// List workflow runs for a repository filtered by branch and event type of
    /// pull_request
    public func fetchPRWorkflowRunsByBranchName(
        owner: String,
        name: String,
        branchName: String
    ) async throws -> APIWorkflowRuns? {
        let path = "repos/\(owner)/\(name)/actions/runs?event=pull_request&branch=\(encodeURIComponent(branchName))"
        let customHeaders = [
            "Accept": "application/vnd.github.antiope-preview+json",
        ]
        let response = try await ghRequest(.get, path, customHeaders: customHeaders)
        do {
            return try parsedResponse(response, as: APIWorkflowRuns.self)
        } catch {
            log.debug("Failed fetching workflow runs for \(branchName, privacy: .public) (\(owner, privacy: .public)/\(name, privacy: .public))")
        }
        return nil
    }

    /// Return the workflow run for a given check_suite_id.
    ///
    /// A check suite is a reference for a set check runs.
    /// A workflow run is a reference for set a of workflows for the GitHub Actions
    /// check runner.
    ///
    /// If a check suite is comprised of check runs ran by actions, there will be
    /// one workflow run that represents that check suite. Thus, if this api should
    /// either return an empty array indicating there are no actions runs for that
    /// check_suite_id (so check suite was not ran by actions) or an array with a
    /// single element.
    public func fetchPRActionWorkflowRunByCheckSuiteId(
        owner: String,
        name: String,
        checkSuiteId: Int
    ) async throws -> APIWorkflowRun? {
        let path = "repos/\(owner)/\(name)/actions/runs?event=pull_request&check_suite_id=\(checkSuiteId)"
        let customHeaders = [
            "Accept": "application/vnd.github.antiope-preview+json",
        ]
        let response = try await ghRequest(.get, path, customHeaders: customHeaders)
        do {
            let apiWorkflowRuns = try parsedResponse(response, as: APIWorkflowRuns.self)

            if let first = apiWorkflowRuns.workflowRuns.first {
                return first
            }
        } catch {
            log.debug("Failed fetching workflow runs for \(checkSuiteId, privacy: .public) (\(owner, privacy: .public)/\(name, privacy: .public))")
        }
        return nil
    }

    /// List workflow run jobs for a given workflow run: every page of them.
    ///
    /// - Returns: nil when a page's response isn't the jobs (an API error).
    /// - Throws: Network errors.
    public func fetchWorkflowRunJobs(owner: String, name: String, workflowRunId: Int) async throws -> APIWorkflowJobs? {
        let path = "repos/\(owner)/\(name)/actions/runs/\(workflowRunId)/jobs?per_page=100"
        let customHeaders = [
            "Accept": "application/vnd.github.antiope-preview+json",
        ]
        do {
            let pages = try await fetchPages(path, as: APIWorkflowJobs.self, customHeaders: customHeaders)
            return pages.first.map { first in
                APIWorkflowJobs(totalCount: first.totalCount, jobs: pages.flatMap(\.jobs))
            }
        } catch let error where isResponseError(error) {
            log.debug("Failed fetching workflow jobs (\(owner, privacy: .public)/\(name, privacy: .public)) workflow run: \(workflowRunId, privacy: .public)")
        }
        return nil
    }

    /// Triggers GitHub to rerequest an existing check suite, without pushing new
    /// code to a repository.
    ///
    /// - Throws: Network errors, and an `APIError` when GitHub refuses.
    public func rerequestCheckSuite(owner: String, name: String, checkSuiteId: Int) async throws {
        let path = "/repos/\(owner)/\(name)/check-suites/\(checkSuiteId)/rerequest"

        do {
            try acceptedResponse(await ghRequest(.post, path))
        } catch {
            log.debug("Failed retry check suite id \(checkSuiteId, privacy: .public) (\(owner, privacy: .public)/\(name, privacy: .public)): \(String(describing: error), privacy: .public)")
            throw error
        }
    }

    /// Re-run all of the failed jobs and their dependent jobs in a workflow run
    /// using the id of the workflow run.
    ///
    /// - Throws: Network errors, and an `APIError` when GitHub refuses.
    public func rerunFailedJobs(owner: String, name: String, workflowRunId: Int) async throws {
        let path = "/repos/\(owner)/\(name)/actions/runs/\(workflowRunId)/rerun-failed-jobs"

        do {
            try acceptedResponse(await ghRequest(.post, path))
        } catch {
            log.debug("Failed to rerun failed workflow jobs for (\(owner, privacy: .public)/\(name, privacy: .public)): \(workflowRunId, privacy: .public): \(String(describing: error), privacy: .public)")
            throw error
        }
    }

    /// Re-run a job and its dependent jobs in a workflow run.
    ///
    /// - Throws: Network errors, and an `APIError` when GitHub refuses.
    public func rerunJob(owner: String, name: String, jobId: Int) async throws {
        let path = "/repos/\(owner)/\(name)/actions/jobs/\(jobId)/rerun"

        do {
            try acceptedResponse(await ghRequest(.post, path))
        } catch {
            log.debug("Failed to rerun workflow job (\(owner, privacy: .public)/\(name, privacy: .public)): \(jobId, privacy: .public): \(String(describing: error), privacy: .public)")
            throw error
        }
    }

    /// Gets a single check suite using its id
    public func fetchCheckSuite(owner: String, name: String, checkSuiteId: Int) async throws -> APICheckSuite? {
        let path = "/repos/\(owner)/\(name)/check-suites/\(checkSuiteId)"
        let response = try await ghRequest(.get, path)

        do {
            return try parsedResponse(response, as: APICheckSuite.self)
        } catch {
            log.debug("[fetchCheckSuite] Failed fetch check suite id \(checkSuiteId, privacy: .public) (\(owner, privacy: .public)/\(name, privacy: .public))")
        }

        return nil
    }

    /// Get branch protection info to determine if a user can push to a given branch.
    ///
    /// Note: if request fails, the default returned value assumes full access for the user
    public func fetchPushControl(owner: String, name: String, branch: String) async -> APIPushControl {
        let path = "repos/\(owner)/\(name)/branches/\(encodeURIComponent(branch))/push_control"

        let headers = [
            "Accept": "application/vnd.github.phandalin-preview",
        ]

        do {
            let response = try await ghRequest(.get, path, customHeaders: headers)
            return try parsedResponse(response, as: APIPushControl.self)
        } catch {
            log.info("[fetchPushControl] unable to check if branch is potentially pushable: \(String(describing: error), privacy: .public)")
            return APIPushControl(
                requiredStatusChecks: [],
                requiredApprovingReviewCount: 0,
                allowActor: true,
                pattern: nil,
                requiredSignatures: false,
                requiredLinearHistory: false,
                allowDeletions: true,
                allowForcePushes: true
            )
        }
    }

    /// Fetch the repository's protected branches.
    ///
    /// Returns an empty array when the request succeeds and no protected branches
    /// exist, or null when the protected branch list could not be refreshed.
    public func fetchProtectedBranches(owner: String, name: String) async -> [APIBranch]? {
        let path = "repos/\(owner)/\(name)/branches?protected=true"
        do {
            let response = try await ghRequest(.get, path)
            return try parsedResponse(response, as: [APIBranch].self)
        } catch {
            log.info("[fetchProtectedBranches] unable to list protected branches: \(String(describing: error), privacy: .public)")
            return nil
        }
    }

    /// Fetches all repository rules that apply to the provided branch.
    public func fetchRepoRulesForBranch(owner: String, name: String, branch: String) async -> [APIRepoRule] {
        let path = "repos/\(owner)/\(name)/rules/branches/\(encodeURIComponent(branch))"
        do {
            let response = try await ghRequest(.get, path)
            return try parsedResponse(response, as: [APIRepoRule].self)
        } catch {
            // If the repository isn't owned by the current user there's no way for us
            // to preemptively check whether rulesets are enabled so we give it a shot
            // but there's no need to log if it fails. Same with 404s, i.e the user
            // doesn't have access to the repo any more or it's been deleted.
            if !isRulesetsNotEnabledError(error) && !isNotFoundApiError(error) {
                log.info("[fetchRepoRulesForBranch] unable to fetch repo rules for branch: \(branch, privacy: .public) | \(path, privacy: .public): \(String(describing: error), privacy: .public)")
            }
            return []
        }
    }

    /// Fetches slim versions of all repo rulesets for the given repository. Utilize the cache
    /// in the app state instead of querying this if possible.
    public func fetchAllRepoRulesets(owner: String, name: String) async -> [APISlimRepoRuleset]? {
        let path = "repos/\(owner)/\(name)/rulesets"
        do {
            let response = try await ghRequest(.get, path)
            return try parsedResponse(response, as: [APISlimRepoRuleset].self)
        } catch {
            // If the repository isn't owned by the current user there's no way for us
            // to preemptively check whether rulesets are enabled so we give it a shot
            // but there's no need to log if it fails. Same with 404s, i.e the user
            // doesn't have access to the repo any more or it's been deleted.
            if !isRulesetsNotEnabledError(error) && !isNotFoundApiError(error) {
                log.info("[fetchAllRepoRulesets] unable to fetch all repo rulesets | \(path, privacy: .public): \(String(describing: error), privacy: .public)")
            }
            return nil
        }
    }

    /// Fetches the repo ruleset with the given ID. Utilize the cache in the app
    /// state instead of querying this if possible.
    public func fetchRepoRuleset(owner: String, name: String, id: Int) async -> APIRepoRuleset? {
        let path = "repos/\(owner)/\(name)/rulesets/\(id)"
        do {
            let response = try await ghRequest(.get, path)
            return try parsedResponse(response, as: APIRepoRuleset.self)
        } catch {
            log.info("[fetchRepoRuleset] unable to fetch repo ruleset for ID: \(id, privacy: .public) | \(path, privacy: .public): \(String(describing: error), privacy: .public)")
            return nil
        }
    }

    /// Get the allowed poll interval for fetching, in seconds. If an error
    /// occurs it will return null.
    public func getFetchPollInterval(owner: String, name: String) async -> Int? {
        let path = "repos/\(owner)/\(name)/git"
        do {
            let response = try await ghRequest(.head, path)
            if let interval = response.headers.get("x-poll-interval"), !interval.isEmpty {
                return parseInt(interval)
            }
            return nil
        } catch {
            log.warning("getFetchPollInterval: failed for \(owner, privacy: .public)/\(name, privacy: .public): \(String(describing: error), privacy: .public)")
            return nil
        }
    }

    /// Fetch the mentionable users for the repository.
    public func fetchMentionables(owner: String, name: String, etag: String?) async -> APIMentionablesResponse? {
        // NB: this custom `Accept` is required for the `mentionables` endpoint.
        var headers = [
            "Accept": "application/vnd.github.jerry-maguire-preview",
        ]

        if let etag {
            headers["If-None-Match"] = etag
        }

        do {
            let path = "repos/\(owner)/\(name)/mentionables/users"
            let response = try await ghRequest(.get, path, customHeaders: headers)

            if response.status == HTTPStatusCode.notFound.rawValue {
                log.warning("fetchMentionables: '\(path, privacy: .public)' returned a 404")
                return nil
            }

            if response.status == HTTPStatusCode.notModified.rawValue {
                return nil
            }
            let users = try parsedResponse(response, as: [APIMentionableUser].self)
            let etag = response.headers.get("etag").flatMap { $0.isEmpty ? nil : $0 }
            return APIMentionablesResponse(etag: etag, users: users)
        } catch {
            log.warning("fetchMentionables: failed for \(owner, privacy: .public)/\(name, privacy: .public): \(String(describing: error), privacy: .public)")
            return nil
        }
    }

    /// Retrieve the public profile information of a user with
    /// a given username.
    public func fetchUser(login: String) async throws -> APIFullIdentity? {
        do {
            let response = try await ghRequest(.get, "users/\(encodeURIComponent(login))")

            if response.status == HTTPStatusCode.notFound.rawValue {
                return nil
            }

            return try parsedResponse(response, as: APIFullIdentity.self)
        } catch {
            log.warning("fetchUser: failed with endpoint \(endpoint, privacy: .public): \(String(describing: error), privacy: .public)")
            throw error
        }
    }

    /// Creates a push protection bypass for a repository.
    ///
    /// This method sends a POST request to the GitHub API to create a bypass
    /// for push protection in a specified repository. The bypass is associated
    /// with a reason and a placeholder ID.
    ///
    /// - Parameters:
    ///   - owner: The owner of the repository.
    ///   - name: The name of the repository.
    ///   - reason: The reason for creating the bypass - false_positive, used_in_tests, will_fix_later.
    ///   - placeholderId: The placeholder ID associated with the bypass.
    ///   - bypassURL: The URL to retry the bypass creation on Github.com in case of failure.
    /// - Returns: The response of the bypass creation.
    /// - Throws: An error if the bypass creation fails, including a warning log.
    public func createPushProtectionBypass(
        owner: String,
        name: String,
        reason: BypassReason,
        placeholderId: String,
        bypassURL: String
    ) async throws -> APICreatePushProtectionBypassResponse {
        let path = "repos/\(owner)/\(name)/secret-scanning/push-protection-bypasses"
        let body: JSONValue = [
            "reason": .string(reason.rawValue),
            "placeholder_id": .string(placeholderId),
        ]

        do {
            let response = try await ghRequest(.post, path, body: body)
            return try parsedResponse(response, as: APICreatePushProtectionBypassResponse.self)
        } catch {
            let msg = """
                Couldn't create the push protection bypass.

                    Repository: \(owner)/\(name)
                    Reason: \(reason.rawValue)
                    Placeholder ID: \(placeholderId)

                    Try again at: \(bypassURL)
                """

            log.error("\(msg, privacy: .public): \(String(describing: error), privacy: .public)")
            throw GitHubError(msg)
        }
    }

    // MARK: - Requests

    /// Authenticated requests to a paginating resource such as issues.
    ///
    /// Follows the GitHub API hypermedia links to get the subsequent
    /// pages when available, buffers all items and returns them in
    /// one array when done.
    func fetchAll<T: Decodable & Sendable>(
        _ path: String,
        as type: T.Type = T.self,
        options: FetchAllOptions<T> = FetchAllOptions()
    ) async throws -> [T] {
        var buf: [T] = []
        let params: KeyValuePairs = ["per_page": "\(options.perPage ?? 100)"]

        var nextPath: String? = urlWithQueryString(path, params)
        repeat {
            guard let currentPath = nextPath else { break }
            let response = try await ghRequest(.get, currentPath)
            if options.suppressErrors != false && !response.ok {
                log.warning("fetchAll: '\(path, privacy: .public)' returned a \(response.status, privacy: .public)")
                return buf
            }

            if let page = try parsedResponse(response, as: [T]?.self) {
                buf.append(contentsOf: page)
                options.onPage?(page)
            }

            nextPath = options.getNextPagePath.map { $0(response) } ?? getNextPagePathFromLink(response)

            if nextPath != nil, let shouldContinue = options.continue, !(try await shouldContinue(buf)) {
                break
            }
        } while nextPath != nil

        return buf
    }

    /// Every page of a paginated resource whose response wraps its items in
    /// an object (statuses, check runs, jobs), following the Link headers,
    /// each parsed as `T`.
    ///
    /// - Throws: Network errors and API errors, on any page.
    private func fetchPages<T: Decodable>(
        _ path: String,
        as type: T.Type,
        customHeaders: [String: String] = [:],
        reloadCache: Bool = false
    ) async throws -> [T] {
        var pages: [T] = []
        var nextPath: String? = path
        while let currentPath = nextPath {
            let response = try await ghRequest(.get, currentPath, customHeaders: customHeaders, reloadCache: reloadCache)
            pages.append(try parsedResponse(response, as: T.self))
            nextPath = getNextPagePathFromLink(response)
        }
        return pages
    }

    /// Make an authenticated request to the client's endpoint with its token.
    private func request(
        _ endpoint: String,
        _ method: HTTPMethod,
        _ path: String,
        body: JSONValue? = nil,
        customHeaders: [String: String] = [:],
        reloadCache: Bool = false
    ) async throws -> HTTPResponse {
        try await GitHubKit.request(
            endpoint,
            token,
            method,
            path,
            jsonBody: body,
            customHeaders: customHeaders,
            reloadCache: reloadCache,
            runtime: runtime
        )
    }

    /// Make an authenticated request to the client's endpoint with its token.
    /// Used for GitHub API requests.
    private func ghRequest(
        _ method: HTTPMethod,
        _ path: String,
        body: JSONValue? = nil,
        customHeaders: [String: String] = [:],
        reloadCache: Bool = false
    ) async throws -> HTTPResponse {
        let response = try await request(
            endpoint,
            method,
            path,
            body: body,
            customHeaders: customHeaders,
            reloadCache: reloadCache
        )

        // Only consider invalid token when the status is 401 and the response has
        // the X-GitHub-Request-Id header, meaning it comes from GH(E) and not from
        // any kind of proxy/gateway.
        // We're also not considering a token has been invalidated when the reason
        // behind a 401 is the fact that any kind of 2 factor auth is required.
        if response.status == HTTPStatusCode.unauthorized.rawValue,
           response.headers.has("X-GitHub-Request-Id"),
           !response.headers.has("X-GitHub-OTP")
        {
            runtime.tokenInvalidation.emit(endpoint: endpoint, token: token)
        }

        tryUpdateEndpointVersionFromResponse(endpoint, response, runtime: runtime)

        return response
    }
}

/// Whether `error` came from a response (an API error, or a body that isn't
/// what was asked for) rather than from the connection.
private func isResponseError(_ error: any Error) -> Bool {
    error is APIError || error is DecodingError
}

/// Throws the API error a refused response carries, as `parsedResponse`
/// does.
private func acceptedResponse(_ response: HTTPResponse) throws {
    guard response.ok else {
        throw APIError(response: response, apiError: try? deserialize(response, as: APIErrorPayload.self))
    }
}

/// A repository from `/user/repos`, whose owner can be `null` when the owning
/// user was deleted. Such repositories (and any other that doesn't decode)
/// are `nil`, so one of them doesn't fail the whole page.
private struct StreamedRepository: Decodable, Sendable {
    let repository: APIRepository?

    init(from decoder: any Decoder) throws {
        repository = try? APIRepository(from: decoder)
    }
}
