// The one place the menus read `RepositoryCapabilities` (its rules and menu
// labels) from. Commands it has no rule for are allowed whenever a
// repository is active (or, for app-wide ones, whenever no modal is up), and
// their handlers refine.

import EspalierCore
import GitHubKit
import GitKit

/// Whether the window's state allows each action, and the titles that
/// depend on the state ("Force Push…", "Remove…", "Update from main").
@MainActor
struct CommandAvailability {
    let context: WindowContext

    /// The capabilities now, all off while a modal is up.
    var capabilities: RepositoryCapabilities {
        context.capabilities
    }

    /// Whether the state allows `kind`.
    func isEnabled(_ kind: ActionKind) -> Bool {
        let capabilities = capabilities
        switch kind {
        case .about: return capabilities.canShowAbout
        case .openSettings: return capabilities.canShowSettings
        case .newRepository: return capabilities.canCreateRepository
        case .addLocalRepository, .addRepositories: return capabilities.canAddLocalRepository
        case .cloneRepository: return capabilities.canCloneRepository
        case .switchRepository: return capabilities.canShowRepositoryList
        case .push, .forcePush, .publishRepository, .publishBranch: return capabilities.canPush
        case .pull: return capabilities.canPull
        case .fetch: return capabilities.canFetch
        case .removeRepository: return capabilities.canRemoveRepository
        case .changeAlias: return capabilities.canChangeAlias
        case .removeAlias: return capabilities.canRemoveAlias
        case .viewOnGitHub: return capabilities.canViewOnGitHub
        case .openInTerminal: return capabilities.canOpenInShell
        case .showInFinder: return capabilities.canShowInFinder
        case .openInEditor: return capabilities.canOpenInEditor
        case .openWith: return capabilities.canOpenWithEditor
        case .createIssueOnGitHub: return capabilities.canCreateIssueOnGitHub
        case .newWorktree: return capabilities.canCreateWorktree
        case .showWorktrees: return capabilities.canShowWorktreesList
        case .repositorySettings: return capabilities.canShowRepositorySettings
        case .showChanges: return capabilities.canShowChanges
        case .showHistory: return capabilities.canShowHistory
        case .showNextPlace, .showPreviousPlace: return capabilities.canShowChanges && capabilities.canShowHistory
        case .switchBranch: return capabilities.canShowBranchesList
        case .goToCommitMessage: return capabilities.canGoToCommitMessage
        case .newBranch: return capabilities.canCreateBranch
        // Rename and Delete: the handlers apply the rules for the current
        // branch; a branch row names its branch, which can be renamed or
        // deleted whatever the current branch is.
        case .renameBranch, .deleteBranch: return capabilities.isRepositoryActive
        case .discardAllChanges: return capabilities.canDiscardAllChanges
        case .stashAllChanges: return capabilities.canStashAllChanges
        case .updateFromDefaultBranch: return capabilities.canUpdateFromContributionTarget
        case .compareToBranch: return capabilities.canCompareToBranch
        case .mergeIntoCurrentBranch: return capabilities.canMergeBranch
        case .squashAndMergeIntoCurrentBranch: return capabilities.canSquashAndMergeBranch
        case .rebaseCurrentBranch: return capabilities.canRebaseBranch
        case .compareOnGitHub: return capabilities.canCompareOnGitHub
        case .viewBranchOnGitHub: return capabilities.canViewBranchOnGitHub
        case .createPullRequest: return capabilities.canCreatePullRequest
        case .previewPullRequest: return capabilities.canPreviewPullRequest
        case .toggleStashedChanges: return capabilities.canToggleStashedChanges
        // Clone's and Publish's Sign In… is on their sheet, and the
        // sign-in sheet shows over it.
        case .signIn: return !context.modals.isPresentingSheet(id: SignInSheet.sheetID)
        default:
            // Commands `RepositoryCapabilities` has no rule for.
            return kind.isRepositoryScoped ? capabilities.isRepositoryActive : !context.isModalPresented
        }
    }

    /// The title `action` has in the current state, if it differs from its
    /// kind's.
    func title(for action: ActionID) -> String? {
        let capabilities = capabilities
        switch action {
        case .push: return capabilities.pushTitle
        case .removeRepository: return capabilities.removeRepositoryTitle
        case .changeAlias: return "\(capabilities.aliasTitle)…"
        case .openInTerminal: return capabilities.openInShellTitle
        case .openInEditor: return capabilities.openInEditorTitle
        case .stashAllChanges: return capabilities.stashAllChangesTitle
        case .updateFromDefaultBranch: return capabilities.updateFromContributionTargetTitle
        case .toggleStashedChanges: return capabilities.toggleStashedChangesTitle
        case .createPullRequest: return capabilities.createPullRequestTitle
        case .cherryPick(let shas, _):
            let count = shas?.count ?? context.repository?.history.selection.shas.count ?? 1
            return count > 1 ? "Cherry-pick \(count) Commits…" : "Cherry-pick Commit…"
        case .squash(let shas, _):
            let count = shas?.count ?? context.repository?.history.selection.shas.count ?? 0
            return count > 1 ? "Squash \(count) Commits…" : "Squash Commits…"
        case .toggleSidebar:
            return context.state.isSidebarHidden ? "Show Sidebar" : "Hide Sidebar"
        case .toggleInspector:
            return context.state.isInspectorPresented ? "Hide Inspector" : "Show Inspector"
        default:
            return nil
        }
    }
}

extension RepositoryModel {
    /// Whether the repository can be used (not missing, not unsafe).
    var isUsable: Bool {
        guard !record.isMissing else {
            return false
        }
        switch availability {
        case .missing, .unsafe: return false
        case .unknown, .available: return true
        }
    }
}
