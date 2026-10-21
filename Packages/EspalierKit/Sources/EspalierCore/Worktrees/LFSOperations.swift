// Initializing Git LFS is offered after adding or cloning repositories that
// use it (`AddRepositoriesResult.usingLFS`, `CloneResult.usesLFS`). The
// global filters are `IntegrationsModel.updateGlobalLFSFilters()`'s.
//
// Git LFS installs four hooks. A repository's own hooks in their place are
// replaced only when the user chooses to (`Decision.replaceLFSHooks`), and
// they're moved to the Trash first.

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

/// A repository's hooks that initializing Git LFS would replace with Git
/// LFS's own (`Decision.replaceLFSHooks`).
public struct LFSHooksToReplace: Sendable, Equatable {
    public let repositoryID: RepositoryID
    /// The repository's folder.
    public let path: String
    /// The hooks' paths, in the order Git LFS installs them. They're in the
    /// folder git runs the repository's hooks from: `core.hooksPath`'s, which
    /// can be outside the repository, or the git directory's `hooks`.
    public let hooks: [String]

    public init(repositoryID: RepositoryID, path: String, hooks: [String]) {
        self.repositoryID = repositoryID
        self.path = path
        self.hooks = hooks
    }

    /// The lines `Decision.replaceLFSHooks` lists, one per hook: for one
    /// repository, each hook's path in the repository's folder, or its
    /// whole path when it's elsewhere; for several, the whole paths, each
    /// once (a hooks folder that several repositories share, as a global
    /// `core.hooksPath`, would repeat them).
    public static func listLines(_ repositories: [LFSHooksToReplace]) -> [String] {
        if repositories.count == 1 {
            let repository = repositories[0]
            let folder = repository.path + "/"
            return repository.hooks.map { hook in
                JSCompat.startsWith(hook, folder) ? String(decoding: hook.utf8.dropFirst(folder.utf8.count), as: UTF8.self) : hook
            }
        }
        var listed: Set<ExactString> = []
        return repositories.flatMap(\.hooks).filter { listed.insert(ExactString($0)).inserted }
    }
}

/// The answer to `Decision.replaceLFSHooks`.
public struct LFSHooksAnswer: Sendable, Equatable {
    /// The hooks the question named.
    public let asked: [LFSHooksToReplace]
    /// Whether to replace them; otherwise the repositories they're in
    /// aren't initialized.
    public let replace: Bool

    public init(asked: [LFSHooksToReplace], replace: Bool) {
        self.asked = asked
        self.replace = replace
    }

    /// The hooks the question named in the repository `id`.
    func hooks(in id: RepositoryID) -> [String] {
        asked.first { $0.repositoryID == id }?.hooks ?? []
    }

    /// Whether the question named every hook in `found`. When it didn't,
    /// the hooks changed after it was asked.
    func covers(_ found: [LFSHooksToReplace]) -> Bool {
        found.allSatisfy { repository in
            let named = hooks(in: repository.repositoryID).exactSet
            return repository.hooks.allSatisfy { named.contains(ExactString($0)) }
        }
    }
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

    /// Initializes Git LFS in each repository
    /// (`RepositoryModel.installLFSHooks(replacing:)`), once the global
    /// filters are installed without overwriting other values. The hooks in
    /// the way of Git LFS's, in all the repositories, are asked about before
    /// any repository changes: the answer replaces them, or leaves the
    /// repositories they're in as they are while the others are
    /// initialized. One repository that fails doesn't stop the others.
    ///
    /// - Parameter answer: The answer to `replaceLFSHooks`, once given.
    /// - Returns: The failures, one per repository that failed, in order.
    /// - Throws: `decisionRequired(.replaceLFSHooks)` with every
    ///   repository's hooks in the way, when `answer` doesn't name them all
    ///   (none was given, or the hooks changed since); `.lfsAttributeMismatch`
    ///   when the global filters have other values, and the global
    ///   configuration's other errors. Either before any repository changes.
    @discardableResult
    public func initializeLFS(
        in ids: [RepositoryID],
        replacingHooks answer: LFSHooksAnswer? = nil
    ) async throws(OperationError) -> [OperationError] {
        let repositories = ids.compactMap { repository($0) }
        if !repositories.isEmpty {
            try await installGlobalLFSFiltersOnce()
        }
        let toReplace = await lfsHooksToReplace(in: repositories)
        if !toReplace.isEmpty, answer?.covers(toReplace) != true {
            throw OperationError(.decisionRequired(.replaceLFSHooks(toReplace)), operation: .installLFSHooks)
        }

        var failures: [OperationError] = []
        for id in ids {
            guard let repository = repository(id) else {
                failures.append(OperationError(.precondition("The repository is no longer in the list."), operation: .installLFSHooks, repositoryID: id))
                continue
            }
            var replacing: [String] = []
            if toReplace.contains(where: { $0.repositoryID == id }) {
                guard let answer, answer.replace else {
                    // The user kept the repository's hooks.
                    continue
                }
                replacing = answer.hooks(in: id)
            }
            do {
                try await repository.installLFSHooks(replacing: replacing)
            } catch {
                let failure = reportedFailure(error, in: repository)
                logger.error("Could not initialize Git LFS: \(failure.message, privacy: .public)")
                failures.append(failure)
            }
        }
        return failures
    }

    /// Installs the global Git LFS filters without overwriting other values,
    /// with Espalier's other global configuration writes.
    ///
    /// - Throws: `.lfsAttributeMismatch` when they have other values.
    private func installGlobalLFSFiltersOnce() async throws(OperationError) {
        let writer = integrations.globalConfigWriter
        let environment = environment
        do {
            try await writer.run {
                try await environment.withRuntimes {
                    try await GitKit.installGlobalLFSFilters(false)
                }
            }
        } catch {
            throw await integrations.classify(error, as: .installLFSHooks)
        }
    }

    /// Each repository's hooks in the way of Git LFS's, as they are now. A
    /// repository whose hooks can't be looked at is left to its
    /// initialization to report.
    private func lfsHooksToReplace(in repositories: [RepositoryModel]) async -> [LFSHooksToReplace] {
        let environment = environment
        var result: [LFSHooksToReplace] = []
        for repository in repositories {
            let gitRepository = repository.gitRepository
            let found = try? await environment.withRuntimes {
                try await getHooksInTheWayOfLFS(gitRepository)
            }
            if let found, !found.names.isEmpty {
                result.append(LFSHooksToReplace(repositoryID: repository.id, path: repository.record.path, hooks: found.paths))
            }
        }
        return result
    }

    /// The failure reported for a repository whose initialization failed:
    /// its error, except that hooks found in the way that weren't asked
    /// about (they changed since) are reported, not asked about again.
    private func reportedFailure(_ error: OperationError, in repository: RepositoryModel) -> OperationError {
        guard case .decisionRequired = error.reason else {
            return error
        }
        return OperationError(
            .precondition("Git LFS wasn't initialized in \(repository.record.path) because its hooks changed in the meantime."),
            operation: .installLFSHooks,
            repositoryID: repository.id
        )
    }
}

extension RepositoryModel {
    /// Initializes Git LFS in the repository: installs its hooks and the
    /// global filters (`git lfs install`), without overwriting filters set
    /// to other values. That writes the global configuration, so it runs
    /// with Espalier's other global configuration writes, one at a time.
    ///
    /// Hooks in the way of Git LFS's (`getHooksInTheWayOfLFS`) are replaced
    /// only when `replacing` names each of them: once the global filters
    /// are Git LFS's, they're moved to the Trash, and Git LFS installs its
    /// own (`git lfs install --force`).
    ///
    /// - Parameter replacing: The paths of the hooks the user chose to
    ///   replace.
    /// - Throws: `decisionRequired(.replaceLFSHooks)` naming the hooks in
    ///   the way when `replacing` doesn't name them all, with nothing
    ///   changed; `.lfsAttributeMismatch` when the global filters have other
    ///   values, with no hook moved; a file system error when a hook can't
    ///   be moved to the Trash; Git LFS's error; `busy` while another
    ///   operation runs here.
    public func installLFSHooks(replacing: [String] = []) async throws(OperationError) {
        guard let app else {
            throw OperationError(.precondition("The repository is no longer in the list."), operation: .installLFSHooks, repositoryID: id)
        }
        let writer = app.integrations.globalConfigWriter
        let environment = environment
        let trash = environment.trash
        let id = id
        let path = record.path
        try await perform(OperationDescriptor(kind: .installLFSHooks, refreshAfter: [])) { ctx in
            let repository = ctx.repository
            try await writer.run {
                try await environment.withRuntimes {
                    try await installLFS(in: repository, replacing: replacing, trash: trash, repositoryID: id, path: path)
                }
            }
        }
    }
}

/// `RepositoryModel.installLFSHooks(replacing:)`'s work, with the
/// repository's lanes and the global configuration writer's turn held.
@concurrent
private func installLFS(
    in repository: Repository,
    replacing: [String],
    trash: any TrashService,
    repositoryID: RepositoryID,
    path: String
) async throws {
    let inTheWay = try await getHooksInTheWayOfLFS(repository)
    guard !inTheWay.names.isEmpty else {
        try await GitKit.installLFSHooks(repository, false)
        return
    }
    let approved = replacing.exactSet
    guard inTheWay.paths.allSatisfy({ approved.contains(ExactString($0)) }) else {
        throw OperationError(
            .decisionRequired(.replaceLFSHooks([LFSHooksToReplace(repositoryID: repositoryID, path: path, hooks: inTheWay.paths)])),
            operation: .installLFSHooks,
            repositoryID: repositoryID
        )
    }
    // Global filters with other values stop it here, before any hook moves.
    try await GitKit.installGlobalLFSFilters(false)
    for (name, hookPath) in zip(inTheWay.names, inTheWay.paths) {
        do {
            try await trash.moveToTrash(hookPath)
        } catch {
            throw OperationError(
                .fileSystem("Espalier couldn't move the \(name) hook to the Trash, so Git LFS wasn't initialized."),
                operation: .installLFSHooks,
                repositoryID: repositoryID,
                underlying: error
            )
        }
    }
    // What's left where Git LFS installs its hooks is its own or empty, and
    // the global filters are its own, so forcing replaces nothing else.
    try await GitKit.installLFSHooks(repository, true)
}
