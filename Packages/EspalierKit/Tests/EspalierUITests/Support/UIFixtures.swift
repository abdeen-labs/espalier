// Fixed values for the UI's tests: a fixed clock, files, confirmations, and
// one value per error kind.

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

/// Fixed values for tests.
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
        ("resetWithChanges", .resetWithChanges(sha: "a1b2c3d")),
        ("overwriteStash", .overwriteStash(checkingOut: nil)),
        ("commitFilteredChanges", .commitFilteredChanges(hiddenPaths: files)),
        ("commitWithUnknownCoAuthors", .commitWithUnknownCoAuthors(["octocat", "hubot"])),
        ("commitOversizedFiles", .commitOversizedFiles(["Assets/movie.mov"])),
        ("commitConflictMarkers", .commitConflictMarkers(["Sources/App/RepositoryLoader.swift"])),
        ("overwriteCommitMessage", .overwriteCommitMessage()),
        ("removeWorktree", .removeWorktree(name: "feature-login", path: "/Users/joe/Developer/espalier-feature-login")),
        ("abortWithResolvedConflicts", .abortWithResolvedConflicts(operation: "Rebase")),
        ("deleteBranch", .deleteBranch("feature/login", existsOnRemote: false)),
        ("deleteBranch-remote", .deleteBranch("feature/login", existsOnRemote: true)),
        ("deleteRemoteBranch", .deleteRemoteBranch("origin/feature/login")),
        ("deleteTag", .deleteTag("v1.2.0")),
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
                .integration(.editor(message: "Espalier couldn't find a supported editor. Install Visual Studio Code, then restart Espalier and try again.", suggestDefaultEditor: true, openPreferences: false)),
                operation: .openInEditor, recoveries: [.downloadSuggestedEditor, .openSettings(.integrations)]
            )),
            ("integration-shell", OperationError(
                .integration(.shell(message: "Espalier couldn't find Kitty at /Applications/kitty.app. Choose an available shell in Settings ▸ Integrations.")),
                operation: .openInShell, recoveries: [.openSettings(.integrations)]
            )),
            ("fileSystem", OperationError(.fileSystem("The folder “espalier” couldn’t be moved to the Trash."), operation: .removeRepository, repositoryID: id)),
            ("other", OperationError(.other("Something went wrong."), operation: .fetch, repositoryID: id)),
        ]
    }
}
