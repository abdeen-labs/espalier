// Initializing Git LFS is offered after adding or cloning repositories that
// use it (`AddRepositoriesResult.usingLFS`, `CloneResult.usesLFS`). The
// global filters are `IntegrationsModel.updateGlobalLFSFilters()`'s.

import EspalierSupport
import Foundation
import GitKit
import os

private let logger = Log.logger(category: "lfs")

/// More repositories than this are counted, not listed.
private let maxRepositoriesToList = 10

/// Asking to initialize Git LFS in repositories that use it, with its
/// copy.
public struct LFSInitializationPrompt: Sendable, Equatable {
    /// The repositories to initialize.
    public let repositories: [RepositoryID]
    public let title: String
    /// The question.
    public let message: String
    /// The folders, under the message; empty when there are more than ten
    /// (the message counts them instead).
    public let paths: [String]
    public let initializeButton: String
    public let cancelButton: String
}

extension AppModel {
    /// The question to ask before initializing Git LFS in `ids`; nil when
    /// none of them is in the list.
    public func lfsInitializationPrompt(for ids: [RepositoryID]) -> LFSInitializationPrompt? {
        let records = ids.compactMap(record)
        guard !records.isEmpty else {
            return nil
        }
        let message: String
        var paths: [String] = []
        if records.count > maxRepositoriesToList {
            message = "\(records.count) repositories use Git LFS. Initialize Git LFS to contribute to them."
        } else {
            let plural = records.count != 1
            let repositories = plural ? "The repositories use" : "This repository uses"
            let pronoun = plural ? "them" : "it"
            message = "\(repositories) Git LFS. Initialize Git LFS to contribute to \(pronoun)."
            paths = records.map(\.path)
        }
        return LFSInitializationPrompt(
            repositories: records.map(\.id),
            title: "Initialize Git LFS",
            message: message,
            paths: paths,
            initializeButton: "Initialize Git LFS",
            cancelButton: "Not Now"
        )
    }

    /// Initializes Git LFS in each repository (see
    /// `RepositoryModel.installLFSHooks()`). One that fails doesn't stop the
    /// others.
    ///
    /// - Returns: The failures, one per repository that failed, in order.
    @discardableResult
    public func initializeLFS(in ids: [RepositoryID]) async -> [OperationError] {
        var failures: [OperationError] = []
        for id in ids {
            guard let repository = repository(id) else {
                failures.append(OperationError(.precondition("The repository is no longer in the list."), operation: .installLFSHooks, repositoryID: id))
                continue
            }
            do {
                try await repository.installLFSHooks()
            } catch {
                logger.error("Could not initialize Git LFS: \(error.message, privacy: .public)")
                failures.append(error)
            }
        }
        return failures
    }
}

extension RepositoryModel {
    /// Initializes Git LFS in the repository: installs its hooks and
    /// configuration (`git lfs install --force`, forced because the user has
    /// already been asked). That writes the global Git LFS filters too, so
    /// it runs with Espalier's other global configuration writes, one at a
    /// time.
    ///
    /// - Throws: Git LFS's error; `busy` while another operation runs here.
    public func installLFSHooks() async throws(OperationError) {
        guard let app else {
            throw OperationError(.precondition("The repository is no longer in the list."), operation: .installLFSHooks, repositoryID: id)
        }
        let writer = app.integrations.globalConfigWriter
        let environment = environment
        try await perform(OperationDescriptor(kind: .installLFSHooks, refreshAfter: [])) { ctx in
            let repository = ctx.repository
            try await writer.run {
                try await environment.withRuntimes {
                    // At this point we've asked the user if we should install
                    // them, so force installation.
                    try await GitKit.installLFSHooks(repository, true)
                }
            }
        }
    }
}
