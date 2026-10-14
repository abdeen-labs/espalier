// The menu capabilities. The first suite checks each rule on
// states built by hand; the second derives the capabilities from real
// repositories in the states the rules tell apart.

@testable import EspalierCore
import EspalierCoreTestSupport
import EspalierSupport
import Foundation
import GitHubKit
import GitKit
import Testing
import TestSupport

/// A branch for states built by hand.
private func branch(_ name: String, upstream: String? = nil, sha: String = "1111111111111111111111111111111111111111") -> Branch {
    Branch(
        name: name,
        upstream: upstream,
        tip: BranchTip(sha: sha),
        type: .local,
        ref: "refs/heads/\(name)"
    )
}

private let main = branch("main", upstream: "origin/main")
private let feature = branch("feature", upstream: "origin/feature")

/// A repository on `tip`, with `main` as its default branch and the
/// contribution target.
private func onBranch(_ tip: Branch = feature, _ change: (inout RepositoryCapabilities.RepositoryState) -> Void = { _ in }) -> RepositoryCapabilities.State {
    var repository = RepositoryCapabilities.RepositoryState(
        tip: .valid(branch: tip),
        defaultBranch: main,
        contributionTargetDefaultBranch: main,
        hasRemote: true
    )
    change(&repository)
    return RepositoryCapabilities.State(selection: .repository(repository), repositoryCount: 1)
}

@Suite("Capabilities: desktop's rules")
struct RepositoryCapabilitiesRulesTests {
    @Test("with nothing selected, only the app's commands are on")
    func nothingSelected() {
        let capabilities = RepositoryCapabilities(RepositoryCapabilities.State())
        #expect(capabilities.canShowAbout && capabilities.canShowSettings)
        #expect(capabilities.canCreateRepository && capabilities.canAddLocalRepository && capabilities.canCloneRepository)
        #expect(!capabilities.canShowRepositoryList)
        #expect(!capabilities.isRepositoryActive)
        #expect(repositoryCommands(capabilities).allSatisfy { !$0.value }, "\(repositoryCommands(capabilities).filter(\.value))")

        let withRepositories = RepositoryCapabilities(RepositoryCapabilities.State(repositoryCount: 2))
        #expect(withRepositories.canShowRepositoryList)
    }

    @Test("a selected repository turns on its commands")
    func repositoryActive() {
        let capabilities = RepositoryCapabilities(onBranch(feature) { $0.hasChangedFiles = true })
        #expect(capabilities.isRepositoryActive)
        let off = repositoryCommands(capabilities).filter { !$0.value }.map(\.key).sorted()
        // Off: GitHub's commands (not on GitHub), Force Push (not
        // diverged), the stash toggle (no stash), and removing an alias
        // (none).
        #expect(off == [
            "canCompareOnGitHub", "canCreateIssueOnGitHub", "canCreatePullRequest", "canForcePush", "canPreviewPullRequest",
            "canRemoveAlias", "canToggleStashedChanges", "canViewBranchOnGitHub", "canViewOnGitHub",
        ])
    }

    @Test("in the welcome flow, the app's commands and the repository's are off")
    func welcomeFlow() {
        var state = onBranch()
        state.isInWelcomeFlow = true
        let capabilities = RepositoryCapabilities(state)
        #expect(!capabilities.canShowAbout && !capabilities.canShowSettings)
        #expect(!capabilities.canCreateRepository && !capabilities.canAddLocalRepository && !capabilities.canCloneRepository)
        #expect(capabilities.canShowRepositoryList)
        #expect(!capabilities.isRepositoryActive)
        #expect(repositoryCommands(capabilities).allSatisfy { !$0.value })
    }

    @Test("with a sheet or alert open, every command is off")
    func modal() {
        var state = onBranch { $0.forcePushState = .available }
        state.isModalPresented = true
        let capabilities = RepositoryCapabilities(state)
        #expect(!capabilities.canShowAbout && !capabilities.canShowSettings && !capabilities.canShowRepositoryList)
        #expect(!capabilities.canCreateRepository && !capabilities.canAddLocalRepository && !capabilities.canCloneRepository)
        #expect(repositoryCommands(capabilities).allSatisfy { !$0.value })

        var missing = RepositoryCapabilities.State(selection: .missing(hasGitHubRepository: true), repositoryCount: 1)
        missing.isModalPresented = true
        #expect(!RepositoryCapabilities(missing).canRemoveRepository)
    }

    @Test("a missing repository can be removed, and viewed on GitHub when it's from there")
    func missing() {
        let fromGitHub = RepositoryCapabilities(RepositoryCapabilities.State(selection: .missing(hasGitHubRepository: true), repositoryCount: 1))
        #expect(fromGitHub.canRemoveRepository)
        #expect(fromGitHub.canViewOnGitHub)
        #expect(!fromGitHub.isRepositoryActive)
        #expect(repositoryCommands(fromGitHub).filter(\.value).map(\.key).sorted() == ["canChangeAlias", "canRemoveRepository", "canViewOnGitHub"])

        let local = RepositoryCapabilities(RepositoryCapabilities.State(selection: .missing(hasGitHubRepository: false), repositoryCount: 1))
        #expect(local.canRemoveRepository)
        #expect(!local.canViewOnGitHub)
    }

    @Test("on the default branch: no rename once published, no delete, no update from itself")
    func defaultBranch() {
        let published = RepositoryCapabilities(onBranch(main))
        #expect(!published.canRenameBranch)
        #expect(!published.canDeleteBranch)
        #expect(!published.canUpdateFromContributionTarget)
        #expect(published.canMergeBranch && published.canRebaseBranch && published.canSquashAndMergeBranch)

        let unpublished = RepositoryCapabilities(onBranch(branch("main")))
        #expect(unpublished.canRenameBranch)
        #expect(!unpublished.canDeleteBranch)
        #expect(!unpublished.canPull)

        // Without a known default branch, every branch counts as another.
        let unknownDefault = RepositoryCapabilities(onBranch(main) { $0.defaultBranch = nil; $0.contributionTargetDefaultBranch = nil })
        #expect(unknownDefault.canRenameBranch && unknownDefault.canDeleteBranch)
        #expect(!unknownDefault.canUpdateFromContributionTarget)
    }

    @Test("on another branch: rename, delete, update from the target, pull when published")
    func otherBranch() {
        let capabilities = RepositoryCapabilities(onBranch(feature))
        #expect(capabilities.canRenameBranch && capabilities.canDeleteBranch)
        #expect(capabilities.canUpdateFromContributionTarget)
        #expect(capabilities.contributionTargetDefaultBranch == main)
        #expect(capabilities.canPull && capabilities.canPush && capabilities.canFetch)
        #expect(capabilities.canCompareToBranch && capabilities.canCreateBranch)

        let unpublished = RepositoryCapabilities(onBranch(branch("feature")) { $0.hasRemote = false })
        #expect(!unpublished.canPull && !unpublished.canFetch)
        #expect(unpublished.canPush)
    }

    @Test("on a detached HEAD: no branch commands, push, pull requests, or compare")
    func detached() {
        let capabilities = RepositoryCapabilities(onBranch { state in
            state.tip = .detached(currentSha: "2222222222222222222222222222222222222222")
            state.hasChangedFiles = true
            state.isHostedOnGitHub = true
            state.hasStash = true
        })
        #expect(!capabilities.canRenameBranch && !capabilities.canDeleteBranch)
        #expect(!capabilities.canPush && !capabilities.canPull)
        #expect(!capabilities.canCreatePullRequest && !capabilities.canPreviewPullRequest)
        #expect(!capabilities.canCompareToBranch)
        #expect(!capabilities.canMergeBranch && !capabilities.canSquashAndMergeBranch && !capabilities.canRebaseBranch)
        #expect(!capabilities.canUpdateFromContributionTarget)
        #expect(!capabilities.canStashAllChanges)
        #expect(!capabilities.canToggleStashedChanges)
        #expect(capabilities.canCreateBranch && capabilities.canDiscardAllChanges && capabilities.canFetch)
        #expect(capabilities.canViewOnGitHub)
    }

    @Test("on an unborn branch: no new branch, branch commands, or push")
    func unborn() {
        let capabilities = RepositoryCapabilities(onBranch { $0.tip = .unborn(ref: "refs/heads/main") })
        #expect(!capabilities.canCreateBranch)
        #expect(!capabilities.canRenameBranch && !capabilities.canDeleteBranch)
        #expect(!capabilities.canPush && !capabilities.canPull)
        #expect(!capabilities.canMergeBranch)
        #expect(capabilities.canCompareToBranch && capabilities.canFetch)
    }

    @Test("with HEAD not yet known: no new branch")
    func unknownTip() {
        let capabilities = RepositoryCapabilities(onBranch { $0.tip = .unknown })
        #expect(!capabilities.canCreateBranch)
        #expect(capabilities.canRenameBranch && capabilities.canDeleteBranch)
        #expect(!capabilities.canMergeBranch)
    }

    @Test("while any operation is in progress: no new branch, switching, or deleting the current branch, which check out")
    func operationInProgress() {
        let capabilities = RepositoryCapabilities(onBranch { state in
            state.isOperationInProgress = true
            state.hasChangedFiles = true
        })
        #expect(capabilities.isRepositoryActive)
        #expect(!capabilities.canCreateBranch)
        #expect(!capabilities.canShowBranchesList)
        #expect(!capabilities.canDeleteBranch)
        #expect(capabilities.canRenameBranch)
        #expect(capabilities.canDiscardAllChanges)
        #expect(capabilities.canShowHistory)
        let idle = RepositoryCapabilities(onBranch())
        #expect(idle.canCreateBranch && idle.canShowBranchesList && idle.canDeleteBranch)
    }

    @Test("with conflicts: no stashing, but discarding all changes")
    func conflicts() {
        let capabilities = RepositoryCapabilities(onBranch { state in
            state.hasConflicts = true
            state.hasChangedFiles = true
        })
        #expect(!capabilities.canStashAllChanges)
        #expect(capabilities.canDiscardAllChanges)
        #expect(capabilities.canCreateBranch)

        let clean = RepositoryCapabilities(onBranch())
        #expect(!clean.canStashAllChanges && !clean.canDiscardAllChanges)
    }

    @Test("while a push, pull, or fetch runs: none of them")
    func networkOperation() {
        let capabilities = RepositoryCapabilities(onBranch { $0.isNetworkOperationRunning = true })
        #expect(!capabilities.canPush && !capabilities.canPull && !capabilities.canFetch)
        #expect(capabilities.canMergeBranch)
    }

    @Test("on GitHub: view, compare, branch, and pull request commands; issues when enabled")
    func gitHub() {
        let capabilities = RepositoryCapabilities(onBranch { state in
            state.isHostedOnGitHub = true
            state.issuesEnabled = true
        })
        #expect(capabilities.canViewOnGitHub && capabilities.canCompareOnGitHub && capabilities.canViewBranchOnGitHub)
        #expect(capabilities.canCreatePullRequest && capabilities.canPreviewPullRequest)
        #expect(capabilities.canCreateIssueOnGitHub)

        let unpublished = RepositoryCapabilities(onBranch(branch("topic")) { $0.isHostedOnGitHub = true })
        #expect(!unpublished.canCompareOnGitHub && !unpublished.canViewBranchOnGitHub)
        #expect(unpublished.canCreatePullRequest)
        #expect(!unpublished.canCreateIssueOnGitHub)
    }

    @Test("a branch that can be force pushed offers Force Push beside Push, disabled while Push is")
    func forcePush() {
        for state in [ForcePushBranchState.available, .recommended] {
            let capabilities = RepositoryCapabilities(onBranch { $0.forcePushState = state })
            #expect(capabilities.isForcePushAvailable && capabilities.canForcePush && capabilities.canPush)
        }
        let notAvailable = RepositoryCapabilities(onBranch { $0.forcePushState = .notAvailable })
        #expect(!notAvailable.isForcePushAvailable && !notAvailable.canForcePush)
        #expect(notAvailable.canPush)

        let busy = RepositoryCapabilities(onBranch { state in
            state.forcePushState = .available
            state.isNetworkOperationRunning = true
        })
        #expect(busy.isForcePushAvailable && !busy.canForcePush && !busy.canPush)
    }

    @Test("a stash on the current branch shows the toggle")
    func stash() {
        let hidden = RepositoryCapabilities(onBranch { state in
            state.hasStash = true
            state.hasChangedFiles = true
        })
        #expect(hidden.canToggleStashedChanges)
        #expect(!hidden.isShowingStashedChanges)
        #expect(hidden.canStashAllChanges)

        let shown = RepositoryCapabilities(onBranch { state in
            state.hasStash = true
            state.isShowingStash = true
        })
        #expect(shown.isShowingStashedChanges)

        let none = RepositoryCapabilities(onBranch())
        #expect(!none.canToggleStashedChanges)
    }

    @Test("the pull request command views the current branch's pull request")
    func pullRequest() {
        let capabilities = RepositoryCapabilities(onBranch { state in
            state.isHostedOnGitHub = true
            state.hasCurrentPullRequest = true
        })
        #expect(capabilities.hasCurrentPullRequest)
    }

    @Test("an alias can be created for a repository, missing or not, and changed or removed once it has one")
    func alias() {
        let none = RepositoryCapabilities(onBranch())
        #expect(none.canChangeAlias && !none.canRemoveAlias)

        var named = onBranch()
        named.alias = "Work"
        #expect(RepositoryCapabilities(named).canRemoveAlias)

        let missing = RepositoryCapabilities(RepositoryCapabilities.State(selection: .missing(hasGitHubRepository: false), alias: "Old"))
        #expect(missing.canChangeAlias && missing.canRemoveAlias)
        let nothing = RepositoryCapabilities(RepositoryCapabilities.State())
        #expect(!nothing.canChangeAlias && !nothing.canRemoveAlias)
    }

    @Test("a fork contributing to its parent updates from the parent's default branch")
    func contributionTarget() throws {
        let record = RepositoryRecord(id: RepositoryID(), path: "/repo", addedAt: Date())
        let upstreamMain = branch("upstream/main")
        let snapshot = BranchesSnapshot(defaultBranch: main, upstreamDefaultBranch: upstreamMain)
        #expect(findContributionTargetDefaultBranch(record, snapshot) == main)

        var gitHubRecord = record
        gitHubRecord.gitHubRepository = gitHubRepoFixture(owner: "me", name: "repo")
        #expect(findContributionTargetDefaultBranch(gitHubRecord, snapshot) == upstreamMain)
        #expect(findContributionTargetDefaultBranch(gitHubRecord, BranchesSnapshot(defaultBranch: main)) == main)
    }
}

/// The capabilities' repository commands by name.
private func repositoryCommands(_ capabilities: RepositoryCapabilities) -> [(key: String, value: Bool)] {
    [
        ("canPush", capabilities.canPush), ("canForcePush", capabilities.canForcePush),
        ("canPull", capabilities.canPull), ("canFetch", capabilities.canFetch),
        ("canRemoveRepository", capabilities.canRemoveRepository), ("canViewOnGitHub", capabilities.canViewOnGitHub),
        ("canChangeAlias", capabilities.canChangeAlias), ("canRemoveAlias", capabilities.canRemoveAlias),
        ("canOpenInShell", capabilities.canOpenInShell), ("canShowInFinder", capabilities.canShowInFinder),
        ("canOpenInEditor", capabilities.canOpenInEditor), ("canOpenWithEditor", capabilities.canOpenWithEditor),
        ("canCreateIssueOnGitHub", capabilities.canCreateIssueOnGitHub), ("canCreateWorktree", capabilities.canCreateWorktree),
        ("canShowWorktreesList", capabilities.canShowWorktreesList),
        ("canShowRepositorySettings", capabilities.canShowRepositorySettings),
        ("canShowChanges", capabilities.canShowChanges), ("canShowHistory", capabilities.canShowHistory),
        ("canShowBranchesList", capabilities.canShowBranchesList), ("canGoToCommitMessage", capabilities.canGoToCommitMessage),
        ("canCreateBranch", capabilities.canCreateBranch), ("canRenameBranch", capabilities.canRenameBranch),
        ("canDeleteBranch", capabilities.canDeleteBranch), ("canDiscardAllChanges", capabilities.canDiscardAllChanges),
        ("canStashAllChanges", capabilities.canStashAllChanges),
        ("canUpdateFromContributionTarget", capabilities.canUpdateFromContributionTarget),
        ("canCompareToBranch", capabilities.canCompareToBranch), ("canMergeBranch", capabilities.canMergeBranch),
        ("canSquashAndMergeBranch", capabilities.canSquashAndMergeBranch), ("canRebaseBranch", capabilities.canRebaseBranch),
        ("canCompareOnGitHub", capabilities.canCompareOnGitHub), ("canViewBranchOnGitHub", capabilities.canViewBranchOnGitHub),
        ("canCreatePullRequest", capabilities.canCreatePullRequest),
        ("canPreviewPullRequest", capabilities.canPreviewPullRequest),
        ("canToggleStashedChanges", capabilities.canToggleStashedChanges),
    ]
}

@Suite("Capabilities from repositories", .offline) @MainActor
struct RepositoryCapabilitiesModelTests {
    @Test("with no repository, the app's commands only")
    func noRepository() async throws {
        let app = try await AppHarness().loadedApp()
        app.preferences.hasShownWelcomeFlow = true

        let capabilities = app.capabilities
        #expect(!capabilities.isRepositoryActive)
        #expect(!capabilities.canShowRepositoryList)
        #expect(capabilities.canCreateRepository && capabilities.canCloneRepository && capabilities.canShowSettings)
        #expect(repositoryCommands(capabilities).allSatisfy { !$0.value })

        // The welcome flow shows until it has been shown.
        app.preferences.hasShownWelcomeFlow = false
        #expect(!app.capabilities.canCreateRepository)
    }

    @Test("a repository on its default branch with nothing to do")
    func cleanDefaultBranch() async throws {
        let fixture = try await makeSelectedRepository()
        fixture.app.preferences.hasShownWelcomeFlow = true

        let capabilities = fixture.app.capabilities
        #expect(capabilities.isRepositoryActive)
        #expect(capabilities.canPush && capabilities.canPull && capabilities.canFetch)
        #expect(!capabilities.canRenameBranch && !capabilities.canDeleteBranch)
        #expect(!capabilities.canUpdateFromContributionTarget)
        #expect(capabilities.contributionTargetDefaultBranch?.name == "main")
        #expect(!capabilities.canDiscardAllChanges && !capabilities.canStashAllChanges)
        #expect(!capabilities.canViewOnGitHub && !capabilities.canCreatePullRequest)
        #expect(fixture.app.capabilities(isModalPresented: true).canPush == false)
    }

    @Test("on another branch with changes: rename, delete, update from main, stash, discard")
    func featureBranchWithChanges() async throws {
        let fixture = try await makeSelectedRepository { local in
            try await runGit(["checkout", "-b", "feature"], local)
        }
        fixture.app.preferences.hasShownWelcomeFlow = true
        try fixture.write("README.md", "# changed\n")
        await fixture.model.refresh(.status, reason: .user)

        let capabilities = fixture.app.capabilities
        #expect(capabilities.canRenameBranch && capabilities.canDeleteBranch)
        #expect(capabilities.canUpdateFromContributionTarget)
        #expect(capabilities.canStashAllChanges && capabilities.canDiscardAllChanges)
        #expect(!capabilities.canPull)
    }

    @Test("a stash on the current branch shows the toggle")
    func stashPresent() async throws {
        let fixture = try await makeSelectedRepository()
        fixture.app.preferences.hasShownWelcomeFlow = true
        try fixture.write("README.md", "# changed\n")
        await fixture.model.refresh(.status, reason: .user)
        try await fixture.model.stash.stashAllChanges()
        try fixture.write("README.md", "# changed again\n")
        await fixture.model.refresh(.full, reason: .user)

        let capabilities = fixture.app.capabilities
        #expect(capabilities.canToggleStashedChanges)
        await fixture.app.idle()
    }

    @Test("diverged from the upstream: a force push")
    func forcePushAvailable() async throws {
        let fixture = try await makeSelectedRepository()
        fixture.app.preferences.hasShownWelcomeFlow = true
        try await pushCommitFromAnotherClone(fixture.remote, path: "remote.txt", contents: "remote\n")
        try await commitFile(fixture.local, "local.txt", "local\n")
        try await runGit(["fetch"], fixture.local)
        await fixture.model.refresh(.full, reason: .user)
        #expect(fixture.model.gitState.aheadBehind == AheadBehind(ahead: 1, behind: 1))

        #expect(fixture.app.capabilities.canForcePush)
    }

    @Test("on a detached HEAD")
    func detachedHead() async throws {
        let fixture = try await makeSelectedRepository { local in
            try await runGit(["checkout", "--detach"], local)
        }
        fixture.app.preferences.hasShownWelcomeFlow = true

        let capabilities = fixture.app.capabilities
        #expect(capabilities.isRepositoryActive)
        #expect(!capabilities.canPush && !capabilities.canRenameBranch && !capabilities.canDeleteBranch)
        #expect(!capabilities.canCompareToBranch && !capabilities.canMergeBranch)
        #expect(capabilities.canCreateBranch && capabilities.canFetch)
    }

    @Test("on an unborn branch")
    func unbornBranch() async throws {
        let harness = try AppHarness()
        let app = await harness.loadedApp()
        app.preferences.hasShownWelcomeFlow = true
        _ = try await harness.addAndSelect(try setupEmptyRepositoryDefaultMain(), to: app)

        let capabilities = app.capabilities
        #expect(capabilities.isRepositoryActive)
        #expect(!capabilities.canCreateBranch && !capabilities.canPush && !capabilities.canRenameBranch)
        #expect(!capabilities.canFetch)
        #expect(capabilities.canCompareToBranch)
    }

    @Test("while a rebase waits on conflicts")
    func rebaseConflicts() async throws {
        let fixture = try await makeSelectedRepository { local in
            try await runGit(["checkout", "-b", "feature"], local)
            try await commitFile(local, "README.md", "# feature\n")
            try await runGit(["checkout", "main"], local)
            try await commitFile(local, "README.md", "# main\n")
            try await runGit(["checkout", "feature"], local)
            _ = try await runGitAllowingFailure(["rebase", "main"], local)
        }
        fixture.app.preferences.hasShownWelcomeFlow = true
        await fixture.model.operations.enrichmentIdle()
        guard case .rebase? = fixture.model.operations.conflictState else {
            Issue.record("Expected a rebase waiting on conflicts")
            return
        }

        let capabilities = fixture.app.capabilities
        #expect(!capabilities.canCreateBranch)
        #expect(!capabilities.canDiscardAllChanges)
        #expect(!capabilities.canStashAllChanges)
    }

    @Test("while a merge waits on conflicts: no new branch or switching (they check out), but discarding")
    func mergeConflicts() async throws {
        let fixture = try await makeSelectedRepository { local in
            try await runGit(["checkout", "-b", "feature"], local)
            try await commitFile(local, "README.md", "# feature\n")
            try await runGit(["checkout", "main"], local)
            try await commitFile(local, "README.md", "# main\n")
            _ = try await runGitAllowingFailure(["merge", "feature"], local)
        }
        fixture.app.preferences.hasShownWelcomeFlow = true
        await fixture.model.operations.enrichmentIdle()
        guard case .merge? = fixture.model.operations.conflictState else {
            Issue.record("Expected a merge waiting on conflicts")
            return
        }

        let capabilities = fixture.app.capabilities
        #expect(!capabilities.canStashAllChanges)
        #expect(capabilities.canDiscardAllChanges)
        // Checking out is refused while any operation is in progress.
        #expect(!capabilities.canCreateBranch)
        #expect(!capabilities.canShowBranchesList)
        #expect(fixture.model.capabilitiesState.isOperationInProgress)
        #expect(!fixture.model.capabilitiesState.isRebaseInProgress)
    }

    @Test("a missing repository can only be removed, or given an alias")
    func missingRepository() async throws {
        let fixture = try await makeSelectedRepository()
        fixture.app.preferences.hasShownWelcomeFlow = true
        try FileManager.default.removeItem(atPath: fixture.local.path)
        await fixture.model.refresh(.full, reason: .user)
        await fixture.app.idle()
        #expect(fixture.model.record.isMissing)

        let capabilities = fixture.app.capabilities
        #expect(!capabilities.isRepositoryActive)
        #expect(capabilities.canRemoveRepository)
        #expect(!capabilities.canViewOnGitHub)
        #expect(repositoryCommands(capabilities).filter(\.value).map(\.key) == ["canRemoveRepository", "canChangeAlias"])

        fixture.app.setAlias("Old project", for: fixture.model.id)
        #expect(fixture.app.capabilities.canRemoveAlias)
        await fixture.app.idle()
    }

    @Test("a repository being cloned has no repository commands")
    func cloningRepository() async throws {
        let fixture = try await makeSelectedRepository()
        fixture.app.preferences.hasShownWelcomeFlow = true
        fixture.app.select(.clone(CloneID()))

        let capabilities = fixture.app.capabilities
        #expect(!capabilities.isRepositoryActive)
        #expect(repositoryCommands(capabilities).allSatisfy { !$0.value })
        #expect(capabilities.canShowRepositoryList)
        await fixture.app.idle()
    }

    @Test("on GitHub: its commands, and issues as the repository, or a fork's parent, allows")
    func onGitHub() async throws {
        let fixture = try await makeSelectedRepository()
        fixture.app.preferences.hasShownWelcomeFlow = true
        let owner = Owner(login: "me", endpoint: getDotComAPIEndpoint(), id: 1)
        func repository(htmlURL: String? = "https://github.com/me/repo", issues: Bool?, archived: Bool?, parent: GitHubRepository? = nil) -> GitHubRepository {
            GitHubRepository(name: "repo", owner: owner, dbID: 1, htmlURL: htmlURL, issuesEnabled: issues, isArchived: archived, parent: parent)
        }
        func capabilities(_ gitHubRepository: GitHubRepository) -> RepositoryCapabilities {
            fixture.app.updateRecord(fixture.model.id) { $0.gitHubRepository = gitHubRepository }
            return fixture.app.capabilities
        }

        let hosted = capabilities(repository(issues: nil, archived: nil))
        #expect(hosted.canViewOnGitHub && hosted.canCompareOnGitHub && hosted.canViewBranchOnGitHub)
        #expect(hosted.canCreatePullRequest && hosted.canPreviewPullRequest)
        #expect(hosted.canCreateIssueOnGitHub)
        #expect(!capabilities(repository(issues: false, archived: nil)).canCreateIssueOnGitHub)
        #expect(!capabilities(repository(issues: true, archived: true)).canCreateIssueOnGitHub)

        // A fork goes by its parent.
        let closedParent = repository(issues: false, archived: nil)
        #expect(!capabilities(repository(issues: true, archived: nil, parent: closedParent)).canCreateIssueOnGitHub)
        let openParent = repository(issues: nil, archived: false)
        #expect(capabilities(repository(issues: false, archived: true, parent: openParent)).canCreateIssueOnGitHub)

        // Without a web URL it isn't hosted on GitHub.
        let unhosted = capabilities(repository(htmlURL: nil, issues: true, archived: nil))
        #expect(!unhosted.canViewOnGitHub && !unhosted.canCreatePullRequest)
        await fixture.app.idle()
    }
}
