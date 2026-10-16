// Ported from desktop/app/src/lib/menu-update.ts
//
// Derived data: the menu bar reads it, and nothing is sent anywhere.

import EspalierSupport
import Foundation
import GitHubKit
import GitKit

/// What the menu bar's commands can do now, and the labels that change with
/// the state.
///
/// Built from the app with `AppModel.capabilities`, or from a `State` for
/// tests and previews. Commands with fixed labels take them from the UI;
/// this has the labels that change ("Force Push…", "Remove…", "Open in
/// <Editor>", ...).
///
/// - "Repository active" doesn't depend on the window being hidden:
///   Espalier quits when its window closes, and a hidden app shows no menu.
/// - Create Issue on GitHub is disabled with no repository active, and no
///   command escapes a modal (`isModalPresented`).
/// - While an operation is in progress (any, in any phase), Switch Branch…,
///   New Branch…, and Delete… (the current branch) are off: checking out
///   then is refused (`MultiCommitOperationsModel.checkoutRefusal`).
/// - A rebase git was interrupted in counts as a rebase in progress.
public struct RepositoryCapabilities: Sendable, Equatable {
    // MARK: App

    /// About Espalier.
    public let canShowAbout: Bool
    /// Settings….
    public let canShowSettings: Bool
    /// New Repository….
    public let canCreateRepository: Bool
    /// Add Local Repository….
    public let canAddLocalRepository: Bool
    /// Clone Repository….
    public let canCloneRepository: Bool
    /// Switch Repository: there are repositories.
    public let canShowRepositoryList: Bool

    // MARK: The repository

    /// Whether a repository that exists is selected, outside the welcome
    /// flow and any modal: the Repository and Branch menus' commands apply.
    public let isRepositoryActive: Bool

    /// Push: on a branch, with no network operation running. Push never
    /// forces.
    public let canPush: Bool
    /// Force Push: as Push, and the current branch can be force pushed
    /// (`isForcePushAvailable`).
    public let canForcePush: Bool
    /// Pull: the current branch is published (its upstream exists).
    public let canPull: Bool
    /// Fetch: the repository has a remote.
    public let canFetch: Bool
    /// Remove…: also for a missing repository.
    public let canRemoveRepository: Bool
    /// Create Alias or Change Alias: also for a missing repository.
    public let canChangeAlias: Bool
    /// Remove Alias: the repository has an alias.
    public let canRemoveAlias: Bool
    /// View on GitHub: the repository is on GitHub (also when missing).
    public let canViewOnGitHub: Bool
    /// Open in <Shell>.
    public let canOpenInShell: Bool
    /// Show in Finder.
    public let canShowInFinder: Bool
    /// Open in <Editor>.
    public let canOpenInEditor: Bool
    /// Open With….
    public let canOpenWithEditor: Bool
    /// Create Issue on GitHub: issues are enabled on GitHub (on the parent,
    /// for a fork) and the repository isn't archived.
    public let canCreateIssueOnGitHub: Bool
    /// New Worktree….
    public let canCreateWorktree: Bool
    /// Show Worktrees.
    public let canShowWorktreesList: Bool
    /// Repository Settings….
    public let canShowRepositorySettings: Bool
    /// Changes.
    public let canShowChanges: Bool
    /// History.
    public let canShowHistory: Bool
    /// Switch Branch…: no operation in progress.
    public let canShowBranchesList: Bool
    /// Go to Commit Message.
    public let canGoToCommitMessage: Bool

    // MARK: Branches and changes

    /// New Branch…: HEAD is known, not unborn, and no operation in progress
    /// (the new branch is checked out).
    public let canCreateBranch: Bool
    /// Rename…: on a branch that isn't the default one, or isn't published.
    public let canRenameBranch: Bool
    /// Delete…: on a branch that isn't the default one, and no operation in
    /// progress (deleting the current branch checks out another).
    public let canDeleteBranch: Bool
    /// Discard All Changes…: there are changes and no rebase in progress.
    public let canDiscardAllChanges: Bool
    /// Stash All Changes: there are changes, on a branch, with no conflicts.
    public let canStashAllChanges: Bool
    /// Update from <target>: on a branch other than the contribution
    /// target's default branch, which exists.
    public let canUpdateFromContributionTarget: Bool
    /// Compare to Branch: HEAD isn't detached.
    public let canCompareToBranch: Bool
    /// Merge into Current Branch…: on a branch.
    public let canMergeBranch: Bool
    /// Squash and Merge into Current Branch…: on a branch.
    public let canSquashAndMergeBranch: Bool
    /// Rebase Current Branch…: on a branch.
    public let canRebaseBranch: Bool
    /// Compare on GitHub: on GitHub, and the branch is published (its
    /// upstream exists).
    public let canCompareOnGitHub: Bool
    /// View Branch on GitHub: on GitHub, and the branch is published (its
    /// upstream exists).
    public let canViewBranchOnGitHub: Bool
    /// Create Pull Request, or View Pull Request on GitHub: on GitHub, on a
    /// branch with commits.
    public let canCreatePullRequest: Bool
    /// Preview Pull Request: as `canCreatePullRequest`.
    public let canPreviewPullRequest: Bool
    /// Show or Hide Stashed Changes: the current branch has a stash.
    public let canToggleStashedChanges: Bool

    // MARK: Labels

    /// Whether Force Push is offered: the current branch has diverged from
    /// its upstream (`ForcePushBranchState` available or recommended).
    public let isForcePushAvailable: Bool
    /// "Force Push…" when force pushing asks first, else "Force Push".
    public let forcePushTitle: String
    /// "Remove…" when removing asks first, else "Remove".
    public let removeRepositoryTitle: String
    /// "Change Alias" when the repository has an alias, else "Create Alias"
    /// (the menu bar adds "…").
    public let aliasTitle: String
    /// "Open in <Shell>", or "Open in Shell" with a custom shell.
    public let openInShellTitle: String
    /// "Open in <Editor>", or "Open in External Editor" with a custom
    /// editor or none known.
    public let openInEditorTitle: String
    /// "Update from <target>", the target truncated to 25 characters
    /// ("Update from Default Branch" when unknown).
    public let updateFromContributionTargetTitle: String
    /// The branch "Update from" merges: the parent's default branch for a
    /// fork contributing to it, else the default branch.
    public let contributionTargetDefaultBranch: Branch?
    /// "Hide Stashed Changes" while the stash shows, else "Show Stashed
    /// Changes".
    public let toggleStashedChangesTitle: String
    /// Whether the stash shows, so the toggle hides it.
    public let isShowingStashedChanges: Bool
    /// "View Pull Request on GitHub" when the branch has a pull request,
    /// else "Create Pull Request".
    public let createPullRequestTitle: String
    /// Whether the current branch has a pull request, so the command views
    /// it.
    public let hasCurrentPullRequest: Bool
}

extension RepositoryCapabilities {
    /// Everything the rules read.
    public struct State: Sendable, Equatable {
        /// What's selected.
        public var selection: Selection
        /// How many repositories the list has.
        public var repositoryCount: Int
        /// Whether the welcome flow shows.
        public var isInWelcomeFlow: Bool
        /// Whether a sheet or alert is open: every command is disabled.
        public var isModalPresented: Bool
        /// `confirmRepoRemoval`.
        public var confirmRepositoryRemoval: Bool
        /// `confirmForcePush`.
        public var confirmForcePush: Bool
        /// `IntegrationsModel.editorLabel`.
        public var editorLabel: String?
        /// `IntegrationsModel.shellLabel`.
        public var shellLabel: String?
        /// The selected repository's alias, missing or not.
        public var alias: String?

        public init(
            selection: Selection = .none,
            repositoryCount: Int = 0,
            isInWelcomeFlow: Bool = false,
            isModalPresented: Bool = false,
            confirmRepositoryRemoval: Bool = true,
            confirmForcePush: Bool = true,
            editorLabel: String? = nil,
            shellLabel: String? = Shell.default.rawValue,
            alias: String? = nil
        ) {
            self.selection = selection
            self.repositoryCount = repositoryCount
            self.isInWelcomeFlow = isInWelcomeFlow
            self.isModalPresented = isModalPresented
            self.confirmRepositoryRemoval = confirmRepositoryRemoval
            self.confirmForcePush = confirmForcePush
            self.editorLabel = editorLabel
            self.shellLabel = shellLabel
            self.alias = alias
        }
    }

    /// What's selected.
    public enum Selection: Sendable, Equatable {
        case none
        /// A repository being cloned.
        case cloning
        /// A repository whose folder is gone, or not a repository.
        case missing(hasGitHubRepository: Bool)
        case repository(RepositoryState)
    }

    /// The selected repository's state the rules read.
    public struct RepositoryState: Sendable, Equatable {
        public var tip: Tip
        /// Whether the current branch is published
        /// (`RepositoryGitState.isCurrentBranchPublished`): its upstream
        /// exists.
        public var isBranchPublished: Bool
        /// The default branch.
        public var defaultBranch: Branch?
        /// `findContributionTargetDefaultBranch`.
        public var contributionTargetDefaultBranch: Branch?
        /// Whether the current branch has a stash.
        public var hasStash: Bool
        /// Whether the changes list shows the stash.
        public var isShowingStash: Bool
        /// Whether a push, pull, or fetch runs.
        public var isNetworkOperationRunning: Bool
        /// Whether the repository has a remote.
        public var hasRemote: Bool
        /// Whether a rebase, squash, or reorder is in progress: stopped with
        /// conflicts, or interrupted between commits.
        public var isRebaseInProgress: Bool
        /// Whether any operation is in progress (a merge, rebase,
        /// cherry-pick, squash, reorder, or revert, in any phase).
        public var isOperationInProgress: Bool
        /// Whether an operation waits on conflicts, or files are conflicted.
        public var hasConflicts: Bool
        /// Whether the working directory has changes.
        public var hasChangedFiles: Bool
        /// Whether the repository is on GitHub (its GitHub repository has a
        /// web URL).
        public var isHostedOnGitHub: Bool
        /// `getRepoIssuesEnabled`.
        public var issuesEnabled: Bool
        /// Whether pushing can or should force.
        public var forcePushState: ForcePushBranchState
        /// Whether the current branch has a pull request.
        public var hasCurrentPullRequest: Bool

        public init(
            tip: Tip = .unknown,
            isBranchPublished: Bool = false,
            defaultBranch: Branch? = nil,
            contributionTargetDefaultBranch: Branch? = nil,
            hasStash: Bool = false,
            isShowingStash: Bool = false,
            isNetworkOperationRunning: Bool = false,
            hasRemote: Bool = false,
            isRebaseInProgress: Bool = false,
            isOperationInProgress: Bool = false,
            hasConflicts: Bool = false,
            hasChangedFiles: Bool = false,
            isHostedOnGitHub: Bool = false,
            issuesEnabled: Bool = false,
            forcePushState: ForcePushBranchState = .notAvailable,
            hasCurrentPullRequest: Bool = false
        ) {
            self.tip = tip
            self.isBranchPublished = isBranchPublished
            self.defaultBranch = defaultBranch
            self.contributionTargetDefaultBranch = contributionTargetDefaultBranch
            self.hasStash = hasStash
            self.isShowingStash = isShowingStash
            self.isNetworkOperationRunning = isNetworkOperationRunning
            self.hasRemote = hasRemote
            self.isRebaseInProgress = isRebaseInProgress
            self.isOperationInProgress = isOperationInProgress
            self.hasConflicts = hasConflicts
            self.hasChangedFiles = hasChangedFiles
            self.isHostedOnGitHub = isHostedOnGitHub
            self.issuesEnabled = issuesEnabled
            self.forcePushState = forcePushState
            self.hasCurrentPullRequest = hasCurrentPullRequest
        }
    }

    /// Applies the rules to `state`.
    public init(_ state: State) {
        let enabled = !state.isModalPresented
        let repository: RepositoryState?
        if case .repository(let selected) = state.selection {
            repository = selected
        } else {
            repository = nil
        }
        let active = enabled && repository != nil && !state.isInWelcomeFlow
        let repo = active ? repository : nil

        // Facts about the repository and its tip.
        let tip = repo?.tip ?? .unknown
        let branch = tip.branch
        let onBranch = branch != nil
        let onDetachedHead: Bool
        let branchIsUnborn: Bool
        let tipStateIsUnknown: Bool
        switch tip {
        case .detached: (onDetachedHead, branchIsUnborn, tipStateIsUnknown) = (true, false, false)
        case .unborn: (onDetachedHead, branchIsUnborn, tipStateIsUnknown) = (false, true, false)
        case .unknown: (onDetachedHead, branchIsUnborn, tipStateIsUnknown) = (false, false, true)
        case .valid: (onDetachedHead, branchIsUnborn, tipStateIsUnknown) = (false, false, false)
        }
        // If we are on the default branch, an unborn branch, or a detached
        // HEAD, there's not much we can do.
        let onNonDefaultBranch: Bool = if let branch, let defaultBranch = repo?.defaultBranch {
            !JSCompat.strictEquals(branch.name, defaultBranch.name)
        } else {
            true
        }
        // The sync button offers Publish for the same branches.
        let hasPublishedBranch = onBranch && repo?.isBranchPublished == true
        let branchHasStashEntry = onBranch && repo?.hasStash == true
        let target = repo?.contributionTargetDefaultBranch
        let onContributionTargetDefaultBranch = branch.map { branch in
            target.map { JSCompat.strictEquals($0.name, branch.name) } ?? false
        } ?? false
        let networkActionInProgress = repo?.isNetworkOperationRunning ?? false
        let hasRemote = repo?.hasRemote ?? false
        let rebaseInProgress = repo?.isRebaseInProgress ?? false
        let operationInProgress = repo?.isOperationInProgress ?? false
        let hasConflicts = repo?.hasConflicts ?? false
        let hasChangedFiles = repo?.hasChangedFiles ?? false
        let isHostedOnGitHub = repo?.isHostedOnGitHub ?? false
        let canBranch = active && !branchIsUnborn && !onDetachedHead

        // App-wide commands, limited in the welcome flow and without
        // repositories.
        canShowAbout = enabled && !state.isInWelcomeFlow
        canShowSettings = enabled && !state.isInWelcomeFlow
        canCreateRepository = enabled && !state.isInWelcomeFlow
        canAddLocalRepository = enabled && !state.isInWelcomeFlow
        canCloneRepository = enabled && !state.isInWelcomeFlow
        canShowRepositoryList = enabled && state.repositoryCount > 0

        // Repository-scoped commands.
        isRepositoryActive = active
        canOpenInShell = active
        canShowInFinder = active
        canOpenInEditor = active
        canOpenWithEditor = active
        canShowRepositorySettings = active
        canGoToCommitMessage = active
        canShowChanges = active
        canShowHistory = active
        canShowBranchesList = active && !operationInProgress
        canShowWorktreesList = active
        canCreateWorktree = active

        // A missing repository can still be removed, and viewed on GitHub.
        var missingWithGitHubRepository = false
        var isMissing = false
        if enabled, !active, case .missing(let hasGitHubRepository) = state.selection {
            isMissing = true
            missingWithGitHubRepository = hasGitHubRepository
        }
        canRemoveRepository = active || isMissing
        canChangeAlias = active || isMissing
        canRemoveAlias = (active || isMissing) && state.alias != nil
        canViewOnGitHub = (active && isHostedOnGitHub) || missingWithGitHubRepository
        canCreateIssueOnGitHub = active && repo?.issuesEnabled == true

        canRenameBranch = (onNonDefaultBranch || !hasPublishedBranch) && canBranch
        canDeleteBranch = onNonDefaultBranch && canBranch && !operationInProgress
        canUpdateFromContributionTarget = active && onBranch && target != nil && !onContributionTargetDefaultBranch
        canMergeBranch = active && onBranch
        canSquashAndMergeBranch = active && onBranch
        canRebaseBranch = active && onBranch
        canCompareOnGitHub = active && isHostedOnGitHub && hasPublishedBranch
        canViewBranchOnGitHub = active && isHostedOnGitHub && hasPublishedBranch
        canCreatePullRequest = canBranch && isHostedOnGitHub
        canPreviewPullRequest = canBranch && isHostedOnGitHub
        canPush = canBranch && !networkActionInProgress
        let forcePushState = repository?.forcePushState ?? .notAvailable
        isForcePushAvailable = forcePushState != .notAvailable
        canForcePush = canPush && isForcePushAvailable
        canPull = active && hasPublishedBranch && !networkActionInProgress
        canFetch = active && hasRemote && !networkActionInProgress
        canCreateBranch = active && !tipStateIsUnknown && !branchIsUnborn && !rebaseInProgress && !operationInProgress
        canDiscardAllChanges = active && hasChangedFiles && !rebaseInProgress
        canStashAllChanges = active && hasChangedFiles && onBranch && !rebaseInProgress && !hasConflicts
        canCompareToBranch = active && !onDetachedHead
        canToggleStashedChanges = active && branchHasStashEntry

        // Labels: without a repository's state (none, cloning, missing) they
        // take their defaults.
        let repositoryState = repository
        forcePushTitle = state.confirmForcePush ? "Force Push…" : "Force Push"
        removeRepositoryTitle = state.confirmRepositoryRemoval ? "Remove…" : "Remove"
        aliasTitle = state.alias == nil ? "Create Alias" : "Change Alias"
        openInShellTitle = "Open in \(state.shellLabel ?? "Shell")"
        openInEditorTitle = "Open in \(state.editorLabel ?? "External Editor")"
        contributionTargetDefaultBranch = repositoryState?.contributionTargetDefaultBranch
        let targetName = contributionTargetDefaultBranch?.name ?? "Default Branch"
        updateFromContributionTargetTitle = "Update from \(truncateWithEllipsis(targetName, 25))"
        isShowingStashedChanges = repositoryState?.isShowingStash ?? false
        toggleStashedChangesTitle = isShowingStashedChanges ? "Hide Stashed Changes" : "Show Stashed Changes"
        hasCurrentPullRequest = repositoryState?.hasCurrentPullRequest ?? false
        createPullRequestTitle = hasCurrentPullRequest ? "View Pull Request on GitHub" : "Create Pull Request"
    }
}

extension AppModel {
    /// The menu bar's capabilities for the current selection and settings.
    ///
    /// Derived from observable state, so a view reading it updates when
    /// anything it depends on changes.
    public var capabilities: RepositoryCapabilities {
        capabilities(isModalPresented: false)
    }

    /// The menu bar's capabilities, all disabled while a sheet or alert is
    /// open (`isModalPresented`).
    public func capabilities(isModalPresented: Bool) -> RepositoryCapabilities {
        RepositoryCapabilities(capabilitiesState(isModalPresented: isModalPresented))
    }

    /// What the capability rules read, from the models.
    func capabilitiesState(isModalPresented: Bool = false) -> RepositoryCapabilities.State {
        let selectionState: RepositoryCapabilities.Selection
        var alias: String?
        switch selection {
        case nil:
            selectionState = .none
        case .clone?:
            selectionState = .cloning
        case .repository(let id)?:
            if let model = repository(id) {
                selectionState = model.record.isMissing
                    ? .missing(hasGitHubRepository: model.record.gitHubRepository != nil)
                    : .repository(model.capabilitiesState)
                alias = model.record.alias
            } else {
                selectionState = .none
            }
        }
        return RepositoryCapabilities.State(
            selection: selectionState,
            repositoryCount: repositories.count,
            isInWelcomeFlow: !preferences.hasShownWelcomeFlow,
            isModalPresented: isModalPresented,
            confirmRepositoryRemoval: preferences.confirmRepositoryRemoval,
            confirmForcePush: preferences.confirmForcePush,
            editorLabel: integrations.editorLabel,
            shellLabel: integrations.shellLabel,
            alias: alias
        )
    }
}

extension RepositoryModel {
    /// The repository's state the capability rules read.
    var capabilitiesState: RepositoryCapabilities.RepositoryState {
        let state = gitState
        let conflictState = operations.conflictState
        // A rebase interrupted between commits has no conflicts, but is one.
        let isRebaseInProgress: Bool = if case .rebase = conflictState { true } else { operations.current?.family == .rebase }
        let isShowingStash: Bool = if case .stash = changes.selection { true } else { false }
        return RepositoryCapabilities.RepositoryState(
            tip: state.tip,
            isBranchPublished: state.isCurrentBranchPublished,
            defaultBranch: state.branches.defaultBranch,
            contributionTargetDefaultBranch: findContributionTargetDefaultBranch(record, state.branches),
            hasStash: stash.current != nil,
            isShowingStash: isShowingStash,
            isNetworkOperationRunning: networkOperation != nil,
            hasRemote: state.remotes.currentRemote != nil,
            isRebaseInProgress: isRebaseInProgress,
            isOperationInProgress: operations.current != nil || conflictState != nil,
            hasConflicts: conflictState != nil || hasConflictedFiles(changes.workingDirectory),
            hasChangedFiles: !changes.workingDirectory.files.isEmpty,
            isHostedOnGitHub: isRepositoryHostedOnGitHub(record),
            issuesEnabled: getRepoIssuesEnabled(record),
            forcePushState: operations.forcePushState,
            hasCurrentPullRequest: gitHub.currentPullRequest != nil
        )
    }
}

/// The default branch a repository's work goes to: for a GitHub repository,
/// the parent's default branch when it is a fork contributing to it
/// (`upstreamDefaultBranch`), else the default branch.
public func findContributionTargetDefaultBranch(_ repository: RepositoryRecord, _ branches: BranchesSnapshot) -> Branch? {
    isRepositoryWithGitHubRepository(repository)
        ? branches.upstreamDefaultBranch ?? branches.defaultBranch
        : branches.defaultBranch
}

/// Whether the repository is on GitHub: it has a GitHub repository with a
/// web URL.
private func isRepositoryHostedOnGitHub(_ repository: RepositoryRecord) -> Bool {
    repository.gitHubRepository?.htmlURL != nil
}

/// Whether issues can be created for the repository: on its parent for a
/// fork, otherwise on it, issues aren't disabled and it isn't archived.
private func getRepoIssuesEnabled(_ repository: RepositoryRecord) -> Bool {
    guard let gitHubRepository = repository.gitHubRepository else {
        return false
    }

    if let parent = gitHubRepository.parent {
        // issues enabled on parent repo
        return parent.issuesEnabled != false && parent.isArchived != true
    }

    // issues enabled on repo
    return gitHubRepository.issuesEnabled != false && gitHubRepository.isArchived != true
}

/// Truncate a single line unicode string by a given maxLength and add
/// ellipsis if necessary.
///
/// Lengths are counted in code points, a variation selector (U+FE00 to
/// U+FE0F) counting with the character before it.
private func truncateWithEllipsis(_ str: String, _ maxLength: Int) -> String {
    if str.utf16.count <= maxLength {
        return str
    }

    let codePoints = Array(str.unicodeScalars)
    if codePoints.count <= maxLength {
        return str
    }

    // combine variation selectors with corresponding characters
    var characters: [String.UnicodeScalarView] = []
    for code in codePoints {
        if (0xFE00...0xFE0F).contains(code.value) {
            if !characters.isEmpty {
                characters[characters.count - 1].append(code)
            }
        } else {
            characters.append(String.UnicodeScalarView([code]))
        }
    }

    if characters.count <= maxLength {
        return str
    }

    let result = characters.prefix(maxLength).map { String($0) }.joined()
    return "\(result)\u{2026}"
}
