// Publishing a branch is a push (PushOperation.swift).

import EspalierSupport
import Foundation
import GitHubKit
import GitKit
import os

private let logger = Log.logger(category: "publish")

extension SyncModel {
    /// Creates the repository on GitHub, adds it as `origin`, pushes the
    /// default branch (when another branch is checked out) and then the
    /// current branch, and associates the repository with it. Returns the
    /// GitHub repository, after the repository's refresh.
    ///
    /// Nothing is pushed from a detached HEAD or an unborn branch.
    ///
    /// - Throws: `.precondition` when the repository already has an `origin`
    ///   remote (checked before anything is created on GitHub); `.api` when
    ///   GitHub refuses (its message, after "Couldn't create the repository
    ///   in <org>." for an organization) or can't be reached ("Couldn't
    ///   publish the repository. Check your internet connection and try
    ///   again."); the push's errors.
    @discardableResult
    public func publishRepository(_ request: PublishRepositoryRequest) async throws(OperationError) -> APIFullRepository {
        guard let repository, let app = repository.app else {
            throw notInList(.publishRepository)
        }
        let id = repository.id
        let api = API.fromAccount(request.account, runtime: repository.environment.gitHub)
        let descriptor = OperationDescriptor(kind: .publishRepository, lanes: [.network], refreshAfter: .full)

        let created = try await repository.perform(descriptor) { ctx -> APIFullRepository in
            // An `origin` already there is refused before GitHub creates the
            // repository: adding it afterwards would fail.
            let remotes = try await getRemotes(ctx.repository)
            if remotes.contains(where: { JSCompat.strictEquals($0.name, "origin") }) {
                throw OperationError(
                    .precondition("The repository already has a remote named origin."),
                    operation: .publishRepository,
                    repositoryID: id
                )
            }

            let apiRepository: APIFullRepository
            do {
                apiRepository = try await api.createRepository(
                    org: request.organization,
                    name: request.name,
                    description: request.description,
                    private: request.isPrivate
                )
            } catch {
                throw OperationError(.api(apiFailure(from: error)), operation: .publishRepository, repositoryID: id, underlying: error)
            }

            let origin = try await addRemote(ctx.repository, "origin", apiRepository.cloneURL)

            // skip pushing if the current branch is a detached HEAD or the
            // repository is unborn
            if let state = self.repository?.gitState, case .valid(let current) = state.tip {
                if let defaultBranch = state.branches.defaultBranch, !JSCompat.strictEquals(current.name, defaultBranch.name) {
                    _ = try await self.pushPrimitive(defaultBranch, to: origin, forceWithLease: false, in: ctx, progress: ctx.progress)
                }
                _ = try await self.pushPrimitive(current, to: origin, forceWithLease: false, in: ctx, progress: ctx.progress)
            }
            return apiRepository
        }

        associate(created, endpoint: request.account.endpoint)
        _ = await app.repositoryWithRefreshedGitHubRepository(id)
        await repository.awaitOperationRefresh(covering: .full)
        logger.info("Published \(created.repository.name, privacy: .private) to \(request.account.endpoint, privacy: .public)")
        return created
    }
}

/// A failed GitHub API request as `OperationError.Reason.api` carries it:
/// the message (GitHubKit's errors carry their copy) and the HTTP status,
/// when there was a response.
func apiFailure(from error: any Error) -> APIFailure {
    if let error = error as? APIError {
        return APIFailure(message: error.message, status: error.responseStatus)
    }
    if let error = error as? GitHubError {
        return APIFailure(message: error.message)
    }
    return APIFailure(message: error.localizedDescription)
}
