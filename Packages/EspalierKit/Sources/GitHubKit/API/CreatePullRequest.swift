// Creating a pull request (`POST /repos/{owner}/{repo}/pulls`), and what
// GitHub's refusals mean.

import EspalierSupport
import Foundation
import os

private let log = Log.logger(category: "github-api")

/// Why GitHub didn't create a pull request, with the message to show.
public struct CreatePullRequestError: Error, LocalizedError, CustomStringConvertible, Sendable, Equatable {
    /// What went wrong.
    public enum Kind: Sendable, Equatable {
        /// A pull request for the branch is already open.
        case alreadyExists
        /// The base branch already has every commit of the branch.
        case noCommits
        /// The base branch isn't on GitHub.
        case baseNotFound
        /// The branch isn't on GitHub (it was never pushed, or it's gone).
        case headNotFound
        /// The repository doesn't allow draft pull requests.
        case draftsNotSupported
        /// GitHub refused the pull request for another reason it gave.
        case validationFailed
        /// GitHub can't find the repository, or the account can't see it.
        case notFound
        /// GitHub couldn't be reached.
        case unreachable
        /// Anything else: another refusal, or an answer that couldn't be read.
        case other
    }

    public let kind: Kind
    public let message: String
    /// The HTTP status, when GitHub answered.
    public let status: Int?

    public init(_ kind: Kind, message: String, status: Int? = nil) {
        self.kind = kind
        self.message = message
        self.status = status
    }

    public var errorDescription: String? { message }
    public var description: String { message }

    /// GitHub's refusal of a new pull request in `repository` ("owner/name")
    /// from `head` (as GitHub names it: `hubot:feature` from a fork) into
    /// `base`, by its status and the validation errors it lists.
    static func refusal(_ error: APIError, repository: String, head: String, base: String) -> CreatePullRequestError {
        let status = error.responseStatus
        let items = error.apiError?.errors ?? []
        let messages = ([error.apiError?.message] + items.map(\.message)).compactMap { $0 }.filter { !$0.isEmpty }
        func mentions(_ phrase: String) -> Bool {
            messages.contains { $0.range(of: phrase, options: .caseInsensitive) != nil }
        }
        func names(_ field: String) -> Bool {
            items.contains { $0.field == field }
        }

        switch status {
        // Unprocessable Entity: a validation failure.
        case 422:
            if mentions("a pull request already exists") {
                return CreatePullRequestError(.alreadyExists, message: "There's already an open pull request for \(head).", status: status)
            }
            if mentions("no commits between") {
                return CreatePullRequestError(.noCommits, message: "\(base) already has every commit on \(head).", status: status)
            }
            if mentions("draft pull requests are not supported") {
                return CreatePullRequestError(.draftsNotSupported, message: "\(repository) doesn't allow draft pull requests.", status: status)
            }
            if names("base") {
                return CreatePullRequestError(.baseNotFound, message: "\(base) isn't a branch on \(repository).", status: status)
            }
            if names("head") {
                return CreatePullRequestError(.headNotFound, message: "\(head) isn't on GitHub.", status: status)
            }
            if names("title"), items.allSatisfy({ ($0.message ?? "").isEmpty }) {
                return CreatePullRequestError(.validationFailed, message: "Enter a title for the pull request.", status: status)
            }
            // GitHub's own reasons, else its summary ("Validation Failed").
            let reasons = items.compactMap(\.message).filter { !$0.isEmpty }
            let details = reasons.isEmpty ? error.message : reasons.joined(separator: " ")
            return CreatePullRequestError(.validationFailed, message: details, status: status)
        case HTTPStatusCode.notFound.rawValue:
            return CreatePullRequestError(
                .notFound,
                message: "GitHub can't find \(repository), or your account can't open pull requests in it.",
                status: status
            )
        default:
            return CreatePullRequestError(.other, message: error.message, status: status)
        }
    }
}

extension API {
    /// Opens a pull request in `owner`/`name` from `head` into `base`.
    ///
    /// - Parameters:
    ///   - head: The branch the changes are on, as GitHub names it (the
    ///     upstream's name).
    ///   - headOwner: The owner of the fork `head` is in, for a pull request
    ///     from a fork into its parent (`hubot:feature`); nil when `head` is
    ///     in `owner`/`name`.
    ///   - base: The branch it merges into, in `owner`/`name`.
    ///   - draft: Whether it opens as a draft.
    /// - Returns: The pull request GitHub created.
    /// - Throws: `CreatePullRequestError` when GitHub refuses or can't be
    ///   reached; `UntrustedCertificateError` for a server whose certificate
    ///   isn't trusted; `CancellationError` when the task is cancelled.
    public func createPullRequest(
        owner: String,
        name: String,
        title: String,
        body: String,
        head: String,
        headOwner: String? = nil,
        base: String,
        draft: Bool
    ) async throws -> APIPullRequest {
        let qualifiedHead = headOwner.map { "\($0):\(head)" } ?? head
        let repository = "\(owner)/\(name)"

        let response: HTTPResponse
        do {
            response = try await ghRequest(.post, "repos/\(owner)/\(name)/pulls", body: [
                "title": .string(title),
                "body": .string(body),
                "head": .string(qualifiedHead),
                "base": .string(base),
                "draft": .bool(draft),
            ])
        } catch let error as UntrustedCertificateError {
            throw error
        } catch {
            if error is CancellationError || (error as? URLError)?.code == .cancelled {
                throw CancellationError()
            }
            log.error("createPullRequest: couldn't reach \(endpoint, privacy: .public) for \(repository, privacy: .public): \(String(describing: error), privacy: .public)")
            throw CreatePullRequestError(.unreachable, message: "GitHub couldn't be reached.")
        }

        do {
            return try parsedResponse(response, as: APIPullRequest.self)
        } catch let error as APIError {
            log.error("createPullRequest: \(repository, privacy: .public) refused with \(error.responseStatus, privacy: .public): \(error.message, privacy: .public)")
            throw CreatePullRequestError.refusal(error, repository: repository, head: qualifiedHead, base: base)
        } catch {
            log.error("createPullRequest: unreadable answer from \(repository, privacy: .public) (\(response.status, privacy: .public)): \(String(describing: error), privacy: .public)")
            throw CreatePullRequestError(
                .other,
                message: "GitHub's answer couldn't be read. The pull request may have been created.",
                status: response.status
            )
        }
    }
}
