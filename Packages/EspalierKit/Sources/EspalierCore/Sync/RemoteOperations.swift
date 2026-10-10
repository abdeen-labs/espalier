import EspalierSupport
import Foundation
import GitHubKit
import GitKit
import os

private let logger = Log.logger(category: "remotes")

extension SyncModel {
    /// Changes the URL of the remote named `remoteName`, then refreshes the
    /// remotes. The URL is trimmed, and an unchanged URL changes nothing. The
    /// GitHub association follows at the next selection or association
    /// refresh.
    ///
    /// Holds the network lane: network operations read the remote's URL.
    public func setRemoteURL(_ url: String, for remoteName: String) async throws(OperationError) {
        guard let repository else {
            throw notInList(.setRemoteURL)
        }
        let trimmedURL = JSCompat.trim(url)
        if let remote = repository.gitState.remotes.all.first(where: { JSCompat.strictEquals($0.name, remoteName) }),
           JSCompat.strictEquals(remote.url, trimmedURL) {
            return
        }
        let descriptor = OperationDescriptor(kind: .setRemoteURL, lanes: [.network], refreshAfter: .remotes)
        try await repository.perform(descriptor) { ctx in
            _ = try await GitKit.setRemoteURL(ctx.repository, remoteName, trimmedURL)
        }
        await repository.awaitOperationRefresh(covering: .remotes)
    }

    /// Points the `upstream` remote at the fork's parent, then refreshes.
    public func updateUpstreamRemote() async throws(OperationError) {
        guard let repository else {
            throw notInList(.setRemoteURL)
        }
        guard let gitHubRepository = repository.record.gitHubRepository else {
            throw precondition("Only a GitHub repository's upstream remote can be updated.", .setRemoteURL)
        }
        guard let parent = gitHubRepository.parent else {
            throw precondition("Only a fork's upstream remote can be updated.", .setRemoteURL)
        }
        guard let url = parent.cloneURL else {
            throw precondition("The parent repository's URL isn't known yet. Try again in a moment.", .setRemoteURL)
        }

        let descriptor = OperationDescriptor(kind: .setRemoteURL, lanes: [.network], refreshAfter: .full)
        try await repository.perform(descriptor) { ctx in
            _ = try await GitKit.setRemoteURL(ctx.repository, upstreamRemoteName, url)
        }
        upstreamRemoteConflict = nil
        await repository.awaitOperationRefresh(covering: .full)
    }

    /// Leaves the conflicting `upstream` remote alone from now on (permanent
    /// for the repository).
    public func ignoreUpstreamRemote() {
        upstreamRemoteConflict = nil
        guard let repository, let app = repository.app else {
            return
        }
        app.updateRecord(repository.id) { $0.ignoresExistingUpstreamRemote = true }
    }

    /// Makes sure a fork has an `upstream` remote pointing at its parent:
    /// adds it when there's none; an `upstream` remote pointing elsewhere
    /// becomes `upstreamRemoteConflict`, unless the user chose to ignore it.
    /// Runs when the repository is selected, as background work: never
    /// presented, skipped behind another network operation.
    ///
    /// - Returns: Whether it ran (false when skipped).
    @discardableResult
    func addUpstreamRemoteIfNeeded() async -> Bool {
        guard let repository else {
            return true
        }
        let record = repository.record
        if record.ignoresExistingUpstreamRemote {
            return true
        }
        guard let gitHubRepository = record.gitHubRepository, let parent = gitHubRepository.parent else {
            return true
        }

        let descriptor = OperationDescriptor(kind: .setRemoteURL, lanes: [.network], policy: .background, refreshAfter: [])
        let result: UpstreamRemoteCheckResult?
        do {
            result = try await repository.performIfIdle(descriptor) { ctx -> UpstreamRemoteCheckResult in
                let remotes = try await getRemotes(ctx.repository)
                if findUpstreamRemote(parent, remotes) != nil {
                    return .matches
                }
                if let existing = remotes.first(where: { JSCompat.strictEquals($0.name, upstreamRemoteName) }) {
                    return .conflict(existing)
                }
                // Parent repositories are fully loaded, so this always has one.
                guard let url = parent.cloneURL else {
                    return .matches
                }
                try await addRemote(ctx.repository, upstreamRemoteName, url)
                return .added
            }
        } catch {
            SyncModel.logFailure("Adding the upstream remote failed", error)
            return true
        }

        switch result {
        case nil:
            return false
        case .matches?:
            upstreamRemoteConflict = nil
        case .added?:
            upstreamRemoteConflict = nil
            logger.info("Added the upstream remote for \(parent.fullName, privacy: .private)")
            repository.requestRefresh(.remotes, reason: .operation(.setRemoteURL))
        case .conflict(let existing)?:
            // Ignored meanwhile: nothing to ask.
            guard !repository.record.ignoresExistingUpstreamRemote else {
                return true
            }
            let conflict = UpstreamRemoteConflict(
                repositoryName: repository.record.name,
                parentFullName: parent.fullName,
                existingRemote: existing,
                expectedURL: parent.cloneURL ?? ""
            )
            if upstreamRemoteConflict != conflict {
                upstreamRemoteConflict = conflict
            }
        }
        return true
    }

    /// Brings `upstreamRemoteConflict` up to date with refreshed remotes:
    /// forgotten once the `upstream` remote points at the parent, is gone,
    /// or the repository is no longer a fork; its URL updated when it
    /// changed elsewhere.
    func reconcileUpstreamRemoteConflict() {
        guard let conflict = upstreamRemoteConflict, let repository else {
            return
        }
        let remotes = repository.gitState.remotes
        guard repository.record.gitHubRepository?.parent != nil,
              !repository.record.ignoresExistingUpstreamRemote,
              remotes.upstreamRemote == nil,
              let upstream = remotes.all.first(where: { JSCompat.strictEquals($0.name, upstreamRemoteName) })
        else {
            upstreamRemoteConflict = nil
            return
        }
        if !JSCompat.strictEquals(upstream.url, conflict.existingRemote.url) {
            upstreamRemoteConflict = UpstreamRemoteConflict(
                repositoryName: conflict.repositoryName,
                parentFullName: conflict.parentFullName,
                existingRemote: upstream,
                expectedURL: conflict.expectedURL
            )
        }
    }
}

/// What the check for a fork's `upstream` remote found.
private enum UpstreamRemoteCheckResult: Sendable {
    /// It points at the parent (or nothing can be done).
    case matches
    /// It was missing and was added.
    case added
    /// It points elsewhere.
    case conflict(Remote)
}
