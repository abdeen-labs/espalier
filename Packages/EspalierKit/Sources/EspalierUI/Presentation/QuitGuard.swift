// The quit guard: quitting asks first when an operation the user started
// that writes to a repository is still running, or when a commit message
// would be lost (drafts live in memory).

import EspalierCore
import GitKit
import Foundation

/// Why quitting needs a confirmation.
nonisolated public struct QuitGuardReasons: Sendable, Equatable {
    /// The first running operation the user started, if any.
    public var runningOperation: OperationKind?
    /// The repositories whose commit message would be lost, by display name.
    public var repositoriesWithUnfinishedMessages: [String]

    public init(runningOperation: OperationKind? = nil, repositoriesWithUnfinishedMessages: [String] = []) {
        self.runningOperation = runningOperation
        self.repositoriesWithUnfinishedMessages = repositoriesWithUnfinishedMessages
    }

    /// Whether quitting can go ahead without asking.
    public var isEmpty: Bool {
        runningOperation == nil && repositoriesWithUnfinishedMessages.isEmpty
    }

    /// The alert, its counts in `numberFormat`, or nil when there's nothing
    /// to ask: one alert covers both reasons, with the operation's title.
    public func alert(_ numberFormat: NumberFormat) -> AlertContent? {
        var title: String?
        var messages: [String] = []
        if let runningOperation {
            title = "Quit while \(runningOperation.runningPhrase) is running?"
            // Quitting cancels a clone and removes what it cloned, which
            // leaves nothing unfinished.
            messages.append(runningOperation == .clone
                ? "Quitting now cancels the clone."
                : "Quitting now can leave the repository in an unfinished state.")
        }
        let drafts = repositoriesWithUnfinishedMessages
        if !drafts.isEmpty {
            title = title ?? "Quit with an unfinished commit message?"
            if drafts.count == 1 {
                messages.append("Your commit message in \(drafts[0]) will be lost.")
            } else {
                messages.append("Your commit messages in \(formatCount(drafts.count, numberFormat)) repositories will be lost.")
            }
        }
        guard let title else {
            return nil
        }
        return AlertContent(
            title: title,
            message: messages.joined(separator: "\n\n"),
            buttons: [AlertContent.Button("Quit Anyway", role: .destructive), AlertContent.Button("Cancel", role: .cancel)]
        )
    }
}

/// Decides whether quitting (or closing the window, which quits) asks first.
@MainActor
public enum QuitGuard {
    /// Why quitting needs a confirmation now: the first operation the user
    /// started that writes to a repository (`writesToRepository`: quitting
    /// during a fetch or a push leaves nothing unfinished), and the
    /// repositories whose commit message would be lost
    /// (`repositoriesWithUnfinishedDrafts`), by display name, in list order.
    /// A clone in progress counts too: quitting cancels it.
    public static func reasons(_ app: AppModel) -> QuitGuardReasons {
        let running = app.runningMutations
            .filter { !$0.operation.isBackgroundTask && $0.operation.kind.writesToRepository }
            .sorted { $0.operation.startedAt < $1.operation.startedAt }
        let names = Dictionary(app.repositories.map { ($0.id, $0.displayName) }, uniquingKeysWith: { first, _ in first })
        let isCloning = app.clones.clones.contains { $0.phase != .cancelling }
        return QuitGuardReasons(
            runningOperation: running.first?.operation.kind ?? (isCloning ? .clone : nil),
            repositoriesWithUnfinishedMessages: app.repositoriesWithUnfinishedDrafts.compactMap { names[$0] }
        )
    }
}

extension OperationKind {
    /// The operation in a sentence ("a rebase", "a push"), for "Quit while
    /// <operation> is running?". Kinds added later read "an operation".
    nonisolated public var runningPhrase: String {
        Self.runningPhrases[self] ?? "an operation"
    }

    nonisolated private static let runningPhrases: [OperationKind: String] = [
        .commit: "a commit",
        .undoCommit: "undoing a commit",
        .resetToCommit: "a reset",
        .discardChanges: "discarding changes",
        .discardLines: "discarding changes",
        .stash: "a stash",
        .restoreStash: "restoring a stash",
        .applyStash: "applying a stash",
        .dropStash: "discarding a stash",
        .checkoutBranch: "a checkout",
        .checkoutCommit: "a checkout",
        .checkoutPullRequest: "checking out a pull request",
        .createBranch: "creating a branch",
        .renameBranch: "renaming a branch",
        .deleteBranch: "deleting a branch",
        .deleteRemoteBranch: "deleting a branch",
        .createTag: "creating a tag",
        .deleteTag: "deleting a tag",
        .merge: "a merge",
        .finishMerge: "a merge",
        .abortMerge: "a merge",
        .rebase: "a rebase",
        .continueRebase: "a rebase",
        .abortRebase: "a rebase",
        .cherryPick: "a cherry-pick",
        .continueCherryPick: "a cherry-pick",
        .abortCherryPick: "a cherry-pick",
        .squash: "a squash",
        .reorder: "a reorder",
        .revert: "a revert",
        .continueRevert: "a revert",
        .abortRevert: "a revert",
        .undoMultiCommitOperation: "an undo",
        .applyConflictResolutions: "resolving conflicts",
        .chooseConflictSide: "resolving conflicts",
        .undoConflictSide: "resolving conflicts",
        .fetch: "a fetch",
        .fetchRefspec: "a fetch",
        .pull: "a pull",
        .push: "a push",
        .publishBranch: "publishing a branch",
        .publishRepository: "publishing a repository",
        .setRemoteURL: "updating a remote",
        .convertToFork: "creating a fork",
        .saveGitIgnore: "saving .gitignore",
        .installLFSHooks: "installing Git LFS",
        .addWorktree: "adding a worktree",
        .removeWorktree: "removing a worktree",
        .moveWorktree: "moving a worktree",
        .pruneBranches: "pruning branches",
        .restoreBranch: "restoring a branch",
        .clone: "a clone",
        .addRepository: "adding a repository",
        .removeRepository: "removing a repository",
        .relocateRepository: "locating a repository",
        .trustRepository: "trusting a repository",
        .createRepository: "creating a repository",
        .openInEditor: "opening an editor",
        .openInShell: "opening a shell",
        .updateLFSFilters: "updating Git LFS filters",
        .generateCommitMessage: "generating a commit message",
        .resolveConflicts: "resolving conflicts",
        .setGlobalGitConfig: "updating your Git settings",
        .setRepositoryGitConfig: "updating the repository's Git settings",
        .signOut: "signing out",
    ]
}
