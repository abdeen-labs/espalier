/// The operations Espalier runs on a repository, and clone.
///
/// The kind names an operation in activity state (`ActiveOperation.kind`),
/// errors (`OperationError.operation`), busy refusals (`busy(kind)`), and the
/// refresh reason an operation's own refresh carries.
public enum OperationKind: String, Sendable, Hashable, CaseIterable {
    // Changes, commits, and stashes.
    case commit, undoCommit, resetToCommit, discardChanges, discardLines, stash, restoreStash, applyStash, dropStash

    // Branches and tags.
    case checkoutBranch, checkoutCommit, createBranch, renameBranch, deleteBranch, deleteRemoteBranch, createTag, deleteTag

    // Merge, rebase, and cherry-pick.
    case merge, finishMerge, abortMerge, rebase, continueRebase, abortRebase, cherryPick, continueCherryPick, abortCherryPick

    // Other multi-commit operations and conflict resolution.
    case squash, reorder, revert, continueRevert, abortRevert, undoMultiCommitOperation, applyConflictResolutions

    // Remotes.
    case fetch, pull, push, publishBranch, publishRepository, fetchRefspec, setRemoteURL, convertToFork

    // Repository maintenance and worktrees.
    case saveGitIgnore, installLFSHooks, addWorktree, removeWorktree, moveWorktree, pruneBranches, restoreBranch

    /// Cloning a repository, an app-level operation.
    case clone

    // App-level intents that report `OperationError`s without running in a
    // repository's lanes: the repository list, integrations, and AI.
    case addRepository, removeRepository, relocateRepository, trustRepository, createRepository
    case openInEditor, openInShell, updateLFSFilters
    /// Opening a file in its default application ("Open with Default
    /// Program").
    case openFile
    /// Writing the global git configuration: the author, the default branch
    /// for new repositories.
    case setGlobalGitConfig
    /// Writing a repository's own git configuration: its author
    /// (Repository Settings ▸ Git Config).
    case setRepositoryGitConfig
    case generateCommitMessage, resolveConflicts
    /// Adding, changing, or removing an AI provider.
    case updateAIProviders

    /// Signing out of a GitHub account.
    case signOut

    /// Giving GitHub Desktop's links (`x-github-client`, `github-mac`) to
    /// Espalier or back to GitHub Desktop.
    case setLinkHandler
    /// Passing a GitHub Desktop link on to GitHub Desktop.
    case forwardLink
    /// Installing the command line tool at `/usr/local/bin/espalier`.
    case installCommandLineTool
    /// Opening a link, or a folder from the command line tool, that
    /// Espalier can't act on.
    case openLink

    /// Checking out a pull request: finding its branch, adding its fork's
    /// remote. The checkout itself is `checkoutBranch`.
    case checkoutPullRequest
    /// Creating a pull request, in the app or on GitHub's form, after
    /// publishing or pushing the branch (the push is `push` or
    /// `publishBranch`).
    case createPullRequest

    // Read-only loads whose failures are shown: the changes diff, and a
    // stash's files and diffs.
    case loadChangesDiff, loadStashedChanges

    // Read-only loads whose failures `Loadable` states and history intents
    // report: history pages, comparisons, and pull request previews
    // (`loadHistory`); changesets, diffs, and file contents (`loadDiff`).
    case loadHistory, loadDiff

    /// Whether the operation writes to the repository (its index, working
    /// tree, HEAD, refs, or configuration), as opposed to only talking to a
    /// remote or to the app. Quitting while one runs asks first.
    public var writesToRepository: Bool {
        switch self {
        case .fetch, .fetchRefspec, .push, .publishRepository, .deleteRemoteBranch, .clone,
             .addRepository, .removeRepository, .relocateRepository, .createRepository,
             .openInEditor, .openInShell, .openFile, .updateLFSFilters, .setGlobalGitConfig, .generateCommitMessage, .resolveConflicts,
             .updateAIProviders, .signOut, .createPullRequest, .setLinkHandler, .forwardLink, .installCommandLineTool, .openLink:
            false
        case .loadChangesDiff, .loadStashedChanges, .loadHistory, .loadDiff:
            false
        default:
            true
        }
    }
}
