// Fixed values for captures: a fixed date, one value per confirmation,
// decision, prompt, and error kind, and the leaf views' content values.

import EspalierCore
import Foundation
import GitHubKit
import GitKit
@testable import EspalierUI

/// A retry that does nothing, for errors with recoveries.
struct FixtureRetry: RetryableOperation {
    let kind: OperationKind
    var displayName: String?

    @MainActor
    func perform(in app: AppModel) async throws(OperationError) -> OperationOutcome {
        .nothing
    }
}

/// Fixed values for captures.
enum UIFixtures {
    // MARK: Time

    /// The fixed "now": 6 October 2026, 10:00 UTC.
    static let now = Date(timeIntervalSince1970: 1_791_280_800)
    static let timeZone = TimeZone(identifier: "UTC")!

    static func minutesAgo(_ minutes: Double) -> Date {
        now.addingTimeInterval(-minutes * 60)
    }

    // MARK: Identity

    static let repositoryID = RepositoryID(rawValue: UUID(uuidString: "2F1D2A6E-6C1B-4C6B-9C4E-7B0B5F1A9E01")!)

    static let files = [
        "Sources/App/RepositoryLoader.swift",
        "Sources/App/EmptyState.swift",
        "README.md",
    ]

    static let manyFiles = (1...14).map { "Sources/Feature/File\($0).swift" }

    // MARK: Confirmations, every kind

    static let confirmations: [(name: String, confirmation: Confirmation)] = [
        ("removeRepository", .removeRepository(name: "espalier", path: "/Users/joe/Developer/espalier")),
        ("discardChanges-one", .discardChanges(["README.md"])),
        ("discardChanges", .discardChanges(files)),
        ("discardChanges-many", .discardChanges(manyFiles)),
        ("discardAllChanges", .discardAllChanges(files)),
        ("discardLines", .discardLines(path: "Sources/App/RepositoryLoader.swift")),
        ("discardStash", .discardStash()),
        ("checkoutCommit", .checkoutCommit(sha: "a1b2c3d4e5f6a7b8c9d0e1f2a3b4c5d6e7f8a9b0")),
        ("leaveCommitsBehind", .leaveCommitsBehind(count: 1, sha: "a1b2c3d4e5f6a7b8c9d0e1f2a3b4c5d6e7f8a9b0")),
        ("leaveCommitsBehind-many", .leaveCommitsBehind(count: 3, sha: "a1b2c3d4e5f6a7b8c9d0e1f2a3b4c5d6e7f8a9b0")),
        ("forcePush", .forcePush(upstreamBranch: "origin/main")),
        ("rewritePublishedCommits", .rewritePublishedCommits(operation: "Rebase")),
        ("undoCommitWithChanges", .undoCommitWithChanges(sha: "a1b2c3d", isMergeCommit: false, isWorkingDirectoryClean: false)),
        ("undoCommitWithChanges-merge", .undoCommitWithChanges(sha: "a1b2c3d", isMergeCommit: true, isWorkingDirectoryClean: true)),
        ("resetToCommit", .resetToCommit(sha: "a1b2c3d", branch: "main", hasChanges: false)),
        ("resetWithChanges", .resetToCommit(sha: "a1b2c3d", branch: "main", hasChanges: true)),
        ("commitFilteredChanges", .commitFilteredChanges(hiddenPaths: files)),
        ("commitWithUnknownCoAuthors", .commitWithUnknownCoAuthors(["octocat", "hubot"])),
        ("commitOversizedFiles", .commitOversizedFiles(["Assets/movie.mov"])),
        ("commitConflictMarkers", .commitConflictMarkers(["Sources/App/RepositoryLoader.swift"])),
        ("overwriteCommitMessage", .overwriteCommitMessage()),
        ("removeWorktree", .removeWorktree(name: "feature-login", path: "/Users/joe/Developer/espalier-feature-login")),
        ("removeMissingWorktree", .removeMissingWorktree(name: "feature-login", path: "/Users/joe/Developer/espalier-feature-login")),
        ("removeMissingWorktree-checkout", .removeMissingWorktree(name: "feature-login", path: "/Users/joe/Developer/espalier-feature-login", branch: "feature/login")),
        ("abortWithResolvedConflicts", .abortWithResolvedConflicts(operation: "Rebase")),
        ("deleteBranch", .deleteBranch("feature/login", existsOnRemote: false)),
        ("deleteBranch-remote", .deleteBranch("feature/login", existsOnRemote: true)),
        ("deleteRemoteBranch", .deleteRemoteBranch("origin/feature/login")),
        ("deleteTag", .deleteTag("v1.2.0")),
        ("replaceCommandLineTool", .replaceCommandLineTool(path: "/usr/local/bin/espalier", existing: .link("/opt/homebrew/bin/espalier"))),
        ("replaceCommandLineTool-file", .replaceCommandLineTool(path: "/usr/local/bin/espalier", existing: .file)),
        ("replaceCommandLineTool-unexamined", .replaceCommandLineTool(path: "/usr/local/bin/espalier", existing: .unexamined)),
        ("checkoutLinkedBranch", .checkoutLinkedBranch("feature/login", repository: "espalier")),
        ("checkoutLinkedPullRequest", .checkoutLinkedPullRequest(number: 128, title: "Show fetch progress in the toolbar", repository: "espalier", forkRemote: nil)),
        ("checkoutLinkedPullRequest-fork", .checkoutLinkedPullRequest(
            number: 128,
            title: "Show fetch progress in the toolbar",
            repository: "espalier",
            forkRemote: Remote(name: "espalier-hubot", url: "https://github.com/hubot/espalier.git")
        )),
    ]

    // MARK: Decisions

    static let decisions: [(name: String, decision: Decision)] = [
        ("uncommittedChanges", .uncommittedChanges(currentBranch: "main", targetBranch: "feature/login")),
        ("externalEditor", .externalEditor(editors: ["Cursor", "Visual Studio Code", "Xcode", "Zed"])),
        ("replaceLFSHooks", .replaceLFSHooks([
            LFSHooksToReplace(
                repositoryID: repositoryID,
                path: "/Users/joe/Developer/espalier",
                hooks: ["/Users/joe/Developer/espalier/.git/hooks/pre-push", "/Users/joe/Developer/espalier/.git/hooks/post-merge"]
            ),
        ])),
        ("replaceLFSHooks-several", .replaceLFSHooks([
            LFSHooksToReplace(repositoryID: repositoryID, path: "/Users/joe/Developer/espalier", hooks: ["/Users/joe/Developer/espalier/.git/hooks/pre-push"]),
            LFSHooksToReplace(
                repositoryID: RepositoryID(rawValue: UUID(uuidString: "7C4B9E2A-1D3F-4A5B-8C6D-9E0F1A2B3C4D")!),
                path: "/Users/joe/Developer/espalier-site",
                hooks: ["pre-push", "post-checkout", "post-commit", "post-merge"].map { "/Users/joe/Developer/espalier-site/.husky/_/\($0)" }
            ),
        ])),
    ]

    // MARK: Prompts

    static let prompts: [(name: String, prompt: Prompt)] = [
        ("addSSHHost", .addSSHHost(host: "github.com", ip: "140.82.112.3", keyType: "ED25519", fingerprint: "SHA256:+DiY3wvvV6TuJJhbpZisF/zLDA0zPMSvHdkr4UvCOqU")),
        ("sshKeyPassphrase", .sshKeyPassphrase(keyPath: "/Users/joe/.ssh/id_ed25519", canRemember: true)),
        // ssh cut the path at 100 bytes, so the key can't be read to remember its passphrase.
        ("sshKeyPassphrase-unidentified", .sshKeyPassphrase(keyPath: "/Users/joe/Library/Mobile Documents/com~apple~CloudDocs/Keys/deploy-keys/espalier-production-deploy-", canRemember: false)),
        ("sshUserPassword", .sshUserPassword(username: "joe@git.example.com")),
        ("genericGitAuthentication", .genericGitAuthentication(endpoint: "https://git.example.com/joe/espalier.git", username: nil)),
        ("genericGitAuthentication-user", .genericGitAuthentication(endpoint: "https://git.example.com/joe/espalier.git", username: "joe")),
        ("gitHubSignIn", .gitHubSignIn(endpoint: "https://github.com/joe/espalier.git")),
        ("hookFailed", .hookFailed(hookName: "pre-commit", terminalOutput: "Running swiftlint…\nSources/App/RepositoryLoader.swift:12:5: error: Force Unwrapping Violation\nDone linting! Found 1 violation, 1 serious in 42 files.\n")),
    ]

    // MARK: Errors, every reason

    static func gitFailure(_ message: String, raw: Bool = false) -> GitFailure {
        GitFailure(gitError: nil, message: message, isRawMessage: raw, exitCode: 128, stderr: message, args: ["checkout", "main"])
    }

    static var errors: [(name: String, error: OperationError)] {
        let id = repositoryID
        let modified = WorkingDirectoryFileChange(path: files[0], status: .modified(), selection: DiffSelection.fromInitialSelection(.all))
        let secret = SecretScanResult(
            id: "2t4Zn0Ag4Gk9b6TVTWSeRLVebuA",
            description: "GitHub Personal Access Token",
            locations: [SecretLocation(commitSha: "a1b2c3d4e5f6", path: "Sources/App/Config.swift", lineNumber: 12)],
            bypassURL: "https://github.com/joe/espalier/security/secret-scanning/unblock-secret/2t4Zn0Ag4Gk9b6TVTWSeRLVebuA",
            requiresApproval: false
        )
        return [
            ("git", OperationError(
                .git(gitFailure("Your local changes to the following files would be overwritten by checkout. Please commit your changes or stash them before you switch branches.")),
                operation: .checkoutBranch, repositoryID: id
            )),
            ("git-raw", OperationError(
                .git(gitFailure("error: The following untracked working tree files would be overwritten by merge:\n\tSources/App/New.swift\nPlease move or remove them before you merge.\nAborting\nMerge with strategy ort failed.", raw: true)),
                operation: .merge, repositoryID: id
            )),
            ("git-commit", OperationError(
                .git(gitFailure("Commit failed - exit code 1 received, with output: 'error: gpg failed to sign the data'")),
                operation: .commit, repositoryID: id, gitContext: .commit
            )),
            // git's output when GPG's pinentry needs a terminal.
            ("signing-pinentry", OperationError(
                .git(gitFailure("""
                    error: gpg failed to sign the data:
                    [GNUPG:] KEY_CONSIDERED 812FB5A8314569283AF4BD0A924353156B8D318C 2
                    [GNUPG:] BEGIN_SIGNING H10
                    [GNUPG:] PINENTRY_LAUNCHED 19687 curses 1.3.3 - - . - 501/20 0
                    gpg: signing failed: Inappropriate ioctl for device
                    [GNUPG:] FAILURE sign 83918950
                    gpg: signing failed: Inappropriate ioctl for device

                    fatal: failed to write commit object

                    """, raw: true)),
                operation: .commit, repositoryID: id, gitContext: .commit
            )),
            // A merge commit signed by a key that's only in an SSH agent,
            // with no agent.
            ("signing-ssh-agent", OperationError(
                .git(gitFailure("error: Couldn't get agent socket?\n\nfatal: failed to write commit object\n", raw: true)),
                operation: .merge, repositoryID: id
            )),
            ("clone", OperationError(
                .git(gitFailure("fatal: repository 'https://github.com/joe/missing.git/' not found", raw: true)),
                operation: .clone,
                retry: FixtureRetry(kind: .clone, displayName: "joe/missing"),
                recoveries: [.retry(FixtureRetry(kind: .clone, displayName: "joe/missing"))]
            )),
            ("authenticationFailed", OperationError(
                .authenticationFailed(gitFailure("Authentication failed. Some common reasons:\n\n- You're not signed in to your account. Sign in from Espalier ▸ Settings ▸ Accounts.\n- Your sign-in needs refreshing. Sign out, then sign in again.")),
                operation: .fetch, repositoryID: id, recoveries: [.openSettings(.accounts)]
            )),
            ("pushRejectedNonFastForward", OperationError(
                .pushRejectedNonFastForward, operation: .push, repositoryID: id,
                retry: FixtureRetry(kind: .push), recoveries: [.fetch(id)]
            )),
            ("pushProtectionBlocked", OperationError(
                .pushProtectionBlocked([secret]), operation: .push, repositoryID: id,
                retry: FixtureRetry(kind: .push), recoveries: [.reviewPushProtection(id, [secret])]
            )),
            ("workflowScopeRequired", OperationError(
                .workflowScopeRequired(rejectedPath: ".github/workflows/ci.yml"), operation: .push, repositoryID: id,
                retry: FixtureRetry(kind: .push), recoveries: [.signIn(endpoint: "https://api.github.com", then: FixtureRetry(kind: .push))]
            )),
            ("samlReauthorizationRequired", OperationError(
                .samlReauthorizationRequired(organization: "octo-org", endpoint: "https://api.github.com"), operation: .fetch, repositoryID: id,
                recoveries: [.signIn(endpoint: "https://api.github.com", then: FixtureRetry(kind: .fetch))]
            )),
            ("oauthAppAccessRestricted", OperationError(
                .oauthAppAccessRestricted(organization: "octo-org"), operation: .fetch, repositoryID: id,
                recoveries: [.requestOrganizationAccess(URL(string: "https://github.com/settings/connections/applications/Ov23li")!)]
            )),
            ("insufficientPermissions", OperationError(
                .insufficientPermissions(repositoryFullName: "octo-org/website"), operation: .push, repositoryID: id,
                retry: FixtureRetry(kind: .push), recoveries: [.createFork(id)]
            )),
            ("fileSizeLimitExceeded", OperationError(
                .fileSizeLimitExceeded(files: ["Assets/movie.mov", "Assets/archive.zip"]), operation: .push, repositoryID: id,
                retry: FixtureRetry(kind: .push)
            )),
            ("localChangesOverwritten", OperationError(
                .localChangesOverwritten(files: files), operation: .checkoutBranch, repositoryID: id,
                retry: FixtureRetry(kind: .checkoutBranch),
                recoveries: [.stashChangesAndRetry(id, FixtureRetry(kind: .checkoutBranch))]
            )),
            ("localChangesOverwritten-stash", OperationError(
                .localChangesOverwritten(files: files), operation: .checkoutBranch, repositoryID: id,
                retry: FixtureRetry(kind: .checkoutBranch)
            )),
            ("lfsAttributeMismatch", OperationError(
                .lfsAttributeMismatch, operation: .updateLFSFilters, recoveries: [.updateLFSFilters, .editGlobalGitConfig]
            )),
            ("trashFailed", OperationError(
                .trashFailed(files: [modified]), operation: .discardChanges, repositoryID: id,
                recoveries: [.discardPermanently(id, [modified])]
            )),
            ("precondition", OperationError(.precondition("The current branch has no commits yet."), operation: .createBranch, repositoryID: id)),
            ("api", OperationError(
                .api(APIFailure(message: "The organization octo-org doesn't allow you to create repositories.", status: 403)),
                operation: .publishRepository, repositoryID: id
            )),
            ("integration-editor", OperationError(
                .integration(.editor(message: "Couldn't find a supported editor. Install Visual Studio Code, then try again.", suggestDefaultEditor: true, openPreferences: false)),
                operation: .openInEditor, recoveries: [.downloadSuggestedEditor, .openSettings(.integrations)]
            )),
            ("integration-shell", OperationError(
                .integration(.shell(message: "Couldn't find Kitty at /Applications/kitty.app. Choose an available shell in Settings ▸ Integrations.")),
                operation: .openInShell, recoveries: [.openSettings(.integrations)]
            )),
            ("fileSystem", OperationError(.fileSystem("The folder “espalier” couldn’t be moved to the Trash."), operation: .removeRepository, repositoryID: id)),
            ("other", OperationError(.other("Something went wrong."), operation: .fetch, repositoryID: id)),
        ]
    }

    // MARK: Sync button, the nine states

    static var syncStates: [(name: String, state: SyncButtonState)] {
        let lastFetched = minutesAgo(5)
        return [
            // A push on its blue capsule, the arc filling in the arrow's place.
            ("1-progress", SyncButtonState(
                kind: .progress(
                    title: "Pushing to origin",
                    description: "Writing objects: 64% (58/90)",
                    value: 0.42,
                    shown: .push(remote: "origin", aheadBehind: AheadBehind(ahead: 2, behind: 0), tagsToPush: 0)
                ),
                lastFetched: lastFetched
            )),
            // A fetch before git reports how far it has got: the arc turning.
            ("1-progress-starting", SyncButtonState(
                kind: .progress(title: "Fetching origin", description: "Hang on…", value: 0, shown: .fetch(remote: "origin")),
                lastFetched: lastFetched
            )),
            ("2-publishRepository", SyncButtonState(kind: .publishRepository)),
            ("3-fetchUnborn", SyncButtonState(kind: .fetchUnborn(remote: "origin"), lastFetched: nil)),
            ("4-detachedHead", SyncButtonState(kind: .detachedHead(rebaseInProgress: false), lastFetched: lastFetched)),
            ("4-detachedHead-rebase", SyncButtonState(kind: .detachedHead(rebaseInProgress: true), lastFetched: lastFetched)),
            ("5-publishBranch", SyncButtonState(kind: .publishBranch(isGitHubRepository: true, remote: "origin"), lastFetched: lastFetched)),
            ("6-forcePush", SyncButtonState(kind: .forcePush(remote: "origin", aheadBehind: AheadBehind(ahead: 2, behind: 3), tagsToPush: 0), lastFetched: lastFetched)),
            ("7-pull", SyncButtonState(kind: .pull(remote: "origin", withRebase: false, aheadBehind: AheadBehind(ahead: 0, behind: 3), tagsToPush: 0, canForcePush: false), lastFetched: lastFetched)),
            ("7-pull-diverged", SyncButtonState(kind: .pull(remote: "origin", withRebase: true, aheadBehind: AheadBehind(ahead: 2, behind: 3), tagsToPush: 0, canForcePush: true), lastFetched: lastFetched)),
            ("8-push", SyncButtonState(kind: .push(remote: "origin", aheadBehind: AheadBehind(ahead: 2, behind: 0), tagsToPush: 1), lastFetched: lastFetched)),
            ("9-fetch", SyncButtonState(kind: .fetch(remote: "origin"), lastFetched: lastFetched)),
            ("9-fetch-failure", SyncButtonState(
                kind: .fetch(remote: "origin"),
                lastFetched: lastFetched,
                backgroundFailure: BackgroundFailureSummary(title: "Error", message: "Could not resolve host: github.com", recoveryTitles: ["Retry"])
            )),
        ]
    }

    // MARK: Toasts and the capsule

    @MainActor static let toasts: [(name: String, content: ToastContent)] = [
        ("merged", ToastContent(message: "Merged feature/login into main")),
        ("cherryPick-undo", ToastContent(message: "Copied 2 commits to feature/login.", undoTitle: "Undo", undoShortcut: "⌘Z")),
        ("revert-undo", ToastContent(message: MultiCommitResult.reverted(summary: "Add sign-in sheet").summary ?? "", undoTitle: "Undo", undoShortcut: "⌘Z")),
        ("reset", ToastContent(message: ResetResult(branchName: "main", sha: "a1b2c3d4e5f6a7b8c9d0e1f2a3b4c5d6e7f8a9b0").summary)),
        ("busy", ToastContent(message: "Another operation is in progress", systemImage: "hourglass", tone: .notice)),
        ("ignored-tracked", ToastContent(message: "config.json is still tracked, so its changes still show.", systemImage: "info.circle.fill", tone: .notice)),
        ("removedWorktree", Toast.removedWorktree(RemovedWorktreeNotice(worktreeName: "espalier-login", shownName: "espalier")).content),
        ("refused", Toast.refused("Finish or abort the merge first.").content),
    ]

    static let capsules: [(name: String, content: OperationCapsuleContent)] = [
        ("rebase-running", .running(title: "Rebase in progress", detail: "Commit 2 of 5 · Wire device flow", progress: 0.4)),
        ("merge-running", .running(title: "Merge in progress", detail: nil, progress: nil)),
        ("rebase-conflicted", .conflicted(message: "Resolve conflicts to continue rebasing main.")),
        ("rebase-interrupted", .interrupted(message: "Rebasing main was interrupted. Continue or abort the rebase.")),
        ("applyingPatches", .unsupported(message: GitOperationInProgress.applyingPatches.unsupportedSummary ?? "")),
        ("bisect", .unsupported(message: GitOperationInProgress.bisect.unsupportedSummary ?? "")),
    ]

    // MARK: The location control

    static let locationStates: [(name: String, state: LocationControlState)] = [
        ("noRepositories", LocationControlState(repository: .noRepositories, branch: .hidden)),
        ("selectRepository", LocationControlState(repository: .selectRepository, branch: .hidden)),
        ("branch", LocationControlState(repository: .repository(name: "espalier", path: "/Users/joe/Developer/espalier"), branch: .branch(name: "main"))),
        ("unborn", LocationControlState(repository: .repository(name: "espalier", path: "/Users/joe/Developer/espalier"), branch: .unborn(ref: "main"))),
        ("detached", LocationControlState(repository: .repository(name: "espalier", path: "/Users/joe/Developer/espalier"), branch: .detached(sha: "a1b2c3d4e5f6"))),
        ("checkingOut", LocationControlState(
            repository: .repository(name: "espalier", path: "/Users/joe/Developer/espalier"),
            branch: .checkingOut(target: "feature/login", description: "Switching to Branch", progress: 0.4)
        )),
        // Before git reports how far it has got: a spinner.
        ("checkingOut-starting", LocationControlState(
            repository: .repository(name: "espalier", path: "/Users/joe/Developer/espalier"),
            branch: .checkingOut(target: "feature/login", description: "Switching to Branch", progress: 0)
        )),
        ("rebasing", LocationControlState(repository: .repository(name: "espalier", path: "/Users/joe/Developer/espalier"), branch: .rebasing(target: "main"))),
        ("blocked", LocationControlState(
            repository: .repository(name: "espalier", path: "/Users/joe/Developer/espalier"),
            branch: .branch(name: "main"),
            branchBlockedReason: "Finish or abort the merge first."
        )),
    ]
}
