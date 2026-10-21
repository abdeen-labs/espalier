// These cover every row of `ErrorClassifier`'s table in order, with stderr
// recorded from git and from dugite's and GitHub's documented output.

@testable import EspalierCore
import EspalierCoreTestSupport
import Foundation
import GitHubKit
import GitKit
import Testing
import TestSupport

/// A git error as `git()` would throw it for `stderr`.
private func gitError(_ stderr: String, exitCode: Int = 1, args: [String] = ["push"]) -> GitError {
    let dugiteError = Dugite.parseError(stderr)
    let result = GitResult(
        stdoutData: Data(),
        stderrData: Data(stderr.utf8),
        exitCode: exitCode,
        gitError: dugiteError,
        gitErrorDescription: dugiteError.flatMap { getDescriptionForError($0, stderr) },
        path: "/repo"
    )
    return GitError(result: result, args: args, terminalOutput: stderr)
}

/// A retry of a given kind.
private struct FakeRetry: RetryableOperation {
    let kind: OperationKind

    init(_ kind: OperationKind) {
        self.kind = kind
    }

    @MainActor
    func perform(in app: AppModel) async throws(OperationError) -> OperationOutcome {
        .nothing
    }
}

private let readOnlyGitHubRepository = ModelFixtures.gitHubRepository(permissions: .read)

private func classify(
    _ error: any Error,
    kind: OperationKind = .push,
    retry: (any RetryableOperation)? = nil,
    gitContext: GitErrorContext? = nil,
    record: RepositoryRecord? = ModelFixtures.record(path: "/"),
    context: ClassificationContext = ClassificationContext()
) async -> OperationError {
    await ErrorClassifier.classify(
        error,
        descriptor: OperationDescriptor(kind: kind, gitContext: gitContext, retry: retry),
        record: record,
        context: context
    )
}

/// A recovery's case without its payload, for checking which recoveries an
/// error offers.
enum RecoveryKind: Equatable {
    /// Runs an operation of this kind again.
    case retry(OperationKind)
    case stashChangesAndRetry, clearLeftoverRebaseAndRetry, fetch, discardPermanently, updateLFSFilters, editGlobalGitConfig
    case createFork, signIn, reviewPushProtection, downloadSuggestedEditor, requestOrganizationAccess
    case openSettings(SettingsPane)
}

extension Recovery {
    /// The recovery's case.
    var kind: RecoveryKind {
        switch self {
        case .retry(let operation): .retry(operation.kind)
        case .stashChangesAndRetry: .stashChangesAndRetry
        case .clearLeftoverRebaseAndRetry: .clearLeftoverRebaseAndRetry
        case .fetch: .fetch
        case .discardPermanently: .discardPermanently
        case .updateLFSFilters: .updateLFSFilters
        case .editGlobalGitConfig: .editGlobalGitConfig
        case .createFork: .createFork
        case .signIn: .signIn
        case .reviewPushProtection: .reviewPushProtection
        case .openSettings(let pane): .openSettings(pane)
        case .downloadSuggestedEditor: .downloadSuggestedEditor
        case .requestOrganizationAccess: .requestOrganizationAccess
        }
    }
}

/// GitHub pads its remote lines with spaces; the bypass URL ends at one.
private let trailingSpaces = String(repeating: " ", count: 8)

private let secretDetectedStderr = """
    Enumerating objects: 8, done.
    Total 6 (delta 1), reused 0 (delta 0), pack-reused 0 (from 0)
    remote: Resolving deltas: 100% (1/1), done.
    remote: error: GH013: Repository rule violations found for refs/heads/main.
    remote:
    remote: - GITHUB PUSH PROTECTION
    remote:   —————————————————————————————————————————
    remote:     Resolve the following violations before pushing again
    remote:
    remote:     - Push cannot contain secrets
    remote:
    remote:
    remote:      (?) Learn how to resolve a blocked push
    remote:      https://docs.github.com/code-security/secret-scanning/working-with-secret-scanning-and-push-protection/working-with-push-protection-from-the-command-line#resolving-a-blocked-push
    remote:
    remote:
    remote:       —— GitHub Personal Access Token ——————————————————————
    remote:        locations:
    remote:          - commit: a6cf64dbe7fcefb6d90238a8d13d831db5dec3e9
    remote:            path: README.md:4
    remote:          - commit: 34800b208dd1432b6d7bff2789e09a3c89ab037d
    remote:            path: README.md:4
    remote:
    remote:        (?) To push, remove secret from commit(s) or follow this URL to allow the secret.
    remote:        https://github.com/tidy-dev/public_playground/security/secret-scanning/unblock-secret/2w2db5WJQCitzO0A2UDh0yyB3Ob\(trailingSpaces)
    remote:
    remote:
    remote:
    To https://github.com/tidy-dev/public_playground.git
     ! [remote rejected] main -> main (push declined due to repository rule violations)
    error: failed to push some refs to 'https://github.com/tidy-dev/public_playground.git'

    """

private let workflowRejectedStderr = """
    To https://github.com/octocat/app.git
     ! [remote rejected] main -> main (refusing to allow an OAuth App to create or update workflow `.github/workflows/ci.yml` without `workflow` scope)
    error: failed to push some refs to 'https://github.com/octocat/app.git'

    """

private let samlStderr = """
    remote: The 'octo-org' organization has enabled or enforced SAML SSO. To access
    remote: this repository, you must re-authorize the OAuth Application 'Espalier'.
    fatal: unable to access 'https://github.com/octo-org/app.git/': The requested URL returned error: 403

    """

/// GitHub's git server refusing an OAuth app an organization hasn't
/// approved (the API's message, over `remote:` lines).
private let oauthRestrictedStderr = """
    remote: Although you appear to have the correct authorization credentials,
    remote: the `octo-org' organization has enabled OAuth App access restrictions, meaning that data
    remote: access to third-parties is limited. For more information on these restrictions, including
    remote: how to enable this app, visit https://docs.github.com/articles/restricting-access-to-your-organization-s-data/
    fatal: unable to access 'https://github.com/octo-org/app.git/': The requested URL returned error: 403

    """

private let pushRejectedStderr = """
    To /tmp/remote.git
     ! [rejected]        main -> main (fetch first)
    error: failed to push some refs to '/tmp/remote.git'
    hint: Updates were rejected because the remote contains work that you do not
    hint: have locally. This is usually caused by another repository pushing to
    hint: the same ref. If you want to integrate the remote changes, use
    hint: 'git pull' before pushing again.

    """

private let authenticationFailedStderr = "fatal: Authentication failed for 'https://github.com/octocat/app.git/'\n"

private let localChangesStderr = """
    error: Your local changes to the following files would be overwritten by checkout:
    \tREADME.md
    \tsrc/app.swift
    Please commit your changes or stash them before you switch branches.
    Aborting

    """

private let fileTooLargeStderr = """
    remote: error: GH001: Large files detected. You may want to try Git Large File Storage - https://git-lfs.github.com.
    remote: error: Trace: 2bd2bfca1605d4e0847936332f1b6c07
    remote: error: See http://git.io/iEPt8g for more information.
    remote: error: File some-file.mp4 is 292.85 MB; this exceeds GitHub's file size limit of 100.00 MB
    To https://github.com/shiftkey/too-large-repository.git
     ! [remote rejected] master -> master (pre-receive hook declined)
    error: failed to push some refs to 'https://github.com/shiftkey/too-large-repository.git'
    """

@Suite("Error classifier") @MainActor
struct ErrorClassifierTests {
    // MARK: 1. secretScanningPushProtectionErrorHandler

    @Test("1. a push blocked by push protection lists the secrets")
    func pushProtection() async {
        let error = await classify(gitError(secretDetectedStderr), retry: FakeRetry(.push))
        guard case .pushProtectionBlocked(let secrets) = error.reason else {
            Issue.record("Unexpected reason \(error.reason)")
            return
        }
        #expect(secrets.count == 1)
        #expect(secrets.first?.description == "GitHub Personal Access Token")
        #expect(secrets.first?.id == "2w2db5WJQCitzO0A2UDh0yyB3Ob")
        #expect(secrets.first?.locations.map(\.path) == ["README.md", "README.md"])
        #expect(error.recoveries.map(\.kind) == [.reviewPushProtection])
    }

    // MARK: 2. discardChangesHandler

    @Test("2. a failed move to the Trash offers to discard permanently")
    func trashFailed() async {
        let file = ModelFixtures.file("notes.txt")
        let error = await classify(TrashFailedError(files: [file], underlying: CocoaError(.fileWriteNoPermission)), kind: .discardChanges)
        #expect(error.reason == .trashFailed(files: [file]))
        #expect(error.recoveries.map(\.kind) == [.discardPermanently])
    }

    @Test("2b. a discard stopped by items in the way of its restored files is a precondition, with nothing offered")
    func discardItemsInTheWay() async {
        let inTheWay = DiscardItemsInTheWayError(paths: ["config"], trashError: CocoaError(.fileWriteNoPermission))
        let error = await classify(inTheWay, kind: .discardChanges)
        guard case .precondition = error.reason else {
            Issue.record("Unexpected reason \(error.reason)")
            return
        }
        #expect(error.recoveries.isEmpty)
    }

    // MARK: 3. refusedWorkflowUpdate

    @Test("3. a push rejected for a workflow file asks to sign in again, for GitHub repositories")
    func workflowScope() async {
        let record = ModelFixtures.record(path: "/", gitHubRepository: ModelFixtures.gitHubRepository())
        let error = await classify(gitError(workflowRejectedStderr), retry: FakeRetry(.push), record: record)
        #expect(error.reason == .workflowScopeRequired(rejectedPath: ".github/workflows/ci.yml"))
        #expect(error.recoveries.map(\.kind) == [.signIn])

        let notGitHub = await classify(gitError(workflowRejectedStderr), retry: FakeRetry(.push))
        guard case .git = notGitHub.reason else {
            Issue.record("Unexpected reason \(notGitHub.reason)")
            return
        }
    }

    // MARK: 4. rebaseConflictsHandler

    @Test("4. rebase conflicts reaching the classifier stay git errors (pull intercepts them)")
    func rebaseConflicts() async {
        let stderr = "error: could not apply 1234567... Change\nhint: Resolve all conflicts manually, mark them as resolved with\n"
        let error = await classify(gitError(stderr), kind: .pull, gitContext: .pull(currentBranch: "main", theirBranch: "origin/main"))
        #expect(error.gitFailure?.gitError == .rebaseConflicts)
        guard case .git = error.reason else {
            Issue.record("Unexpected reason \(error.reason)")
            return
        }
    }

    // MARK: 5. localChangesOverwrittenHandler

    @Test("5. local changes that would be overwritten list the files and offer to stash")
    func localChangesOverwritten() async {
        let record = ModelFixtures.record(path: "/")
        let retry = FakeRetry(.checkoutBranch)
        let error = await classify(gitError(localChangesStderr), kind: .checkoutBranch, retry: retry, record: record)
        #expect(error.reason == .localChangesOverwritten(files: ["README.md", "src/app.swift"]))
        #expect(error.recoveries.map(\.kind) == [.stashChangesAndRetry])
    }

    @Test("5. on a detached HEAD, local changes that would be overwritten offer no stash")
    func localChangesOverwrittenOnDetachedHead() async {
        var context = ClassificationContext()
        context.isDetachedHead = true
        let error = await classify(gitError(localChangesStderr), kind: .checkoutBranch, retry: FakeRetry(.checkoutBranch), context: context)
        #expect(error.reason == .localChangesOverwritten(files: ["README.md", "src/app.swift"]))
        #expect(error.recoveries.isEmpty)
    }

    @Test("5. no stash is offered when restoring or applying a stash", arguments: [OperationKind.restoreStash, .applyStash])
    func localChangesOverwrittenWithoutStash(kind: OperationKind) async {
        let error = await classify(gitError(localChangesStderr), kind: kind, retry: FakeRetry(kind))
        #expect(error.reason == .localChangesOverwritten(files: ["README.md", "src/app.swift"]))
        #expect(error.recoveries.isEmpty)
    }

    @Test("5. without a retry, local changes that would be overwritten are a git error")
    func localChangesOverwrittenWithoutRetry() async {
        let error = await classify(gitError(localChangesStderr), kind: .checkoutBranch)
        #expect(error.gitFailure?.gitError == .localChangesOverwritten)
        guard case .git = error.reason else {
            Issue.record("Unexpected reason \(error.reason)")
            return
        }
    }

    @Test("5. staged changes in the way of a rebase offer to stash, listing no files")
    func stagedChangesInTheWay() async {
        let stderr = "error: cannot pull with rebase: Your index contains uncommitted changes.\nerror: Please commit or stash them.\n"
        let error = await classify(gitError(stderr, exitCode: 128, args: ["pull"]), kind: .pull, retry: FakeRetry(.pull))
        #expect(error.reason == .localChangesOverwritten(files: []))
        #expect(error.recoveries.map(\.kind) == [.stashChangesAndRetry])

        let withoutRetry = await classify(gitError(stderr, exitCode: 128, args: ["pull"]), kind: .pull)
        #expect(withoutRetry.gitFailure?.gitError == .rebaseWithStagedChanges)
    }

    @Test("5b. a stash entry's files in the way of untracked files are listed, with nothing offered")
    func stashFilesInTheWay() async {
        let error = await classify(StashFilesInTheWayError(files: ["notes.txt"]), kind: .restoreStash, retry: FakeRetry(.restoreStash))
        #expect(error.reason == .localChangesOverwritten(files: ["notes.txt"]))
        #expect(error.recoveries.isEmpty)
    }

    @Test("5c. a stash entry gone since it was listed is refused, with nothing offered")
    func stashEntryGone() async {
        let error = await classify(StashEntryNotFoundError(stashSha: "abc"), kind: .applyStash, retry: FakeRetry(.applyStash))
        guard case .precondition = error.reason else {
            Issue.record("Unexpected reason \(error.reason)")
            return
        }
        #expect(error.recoveries.isEmpty)
    }

    @Test("5d. a rebase's state Espalier can't continue or abort offers to clear it and continue; one it shows doesn't")
    func leftoverRebase() async {
        let stderr = """
            fatal: It seems that there is already a rebase-merge directory, and
            I wonder if you are in the middle of another rebase.  If that is the
            case, please try
            \tgit rebase (--continue | --abort | --skip)
            If that is not the case, please
            \trm -fr ".git/rebase-merge"
            and run me again.  I am stopping in case you still have something
            valuable there.

            """
        let record = ModelFixtures.record(path: "/")
        let retry = FakeRetry(.pull)
        var context = ClassificationContext()
        context.leftoverRebase = LeftoverRebase(hasAutostash: false)
        let error = await classify(gitError(stderr, exitCode: 128, args: ["pull"]), kind: .pull, retry: retry, record: record, context: context)
        guard case .precondition = error.reason, case .clearLeftoverRebaseAndRetry(let id, let then)? = error.recoveries.first else {
            Issue.record("Unexpected reason \(error.reason), recoveries \(error.recoveries.map(\.kind))")
            return
        }
        #expect(id == record.id)
        #expect(then.kind == .pull)
        #expect(error.recoveries.map(\.kind) == [.clearLeftoverRebaseAndRetry])

        context.leftoverRebase = LeftoverRebase(hasAutostash: true)

        // A rebase Espalier shows, or no way to run the operation again: git's
        // error, finish or abort it.
        let shown = await classify(gitError(stderr, exitCode: 128, args: ["pull"]), kind: .pull, retry: retry, record: record)
        let withoutRetry = await classify(gitError(stderr, exitCode: 128, args: ["pull"]), kind: .pull, record: record, context: context)
        for error in [shown, withoutRetry] {
            #expect(error.gitFailure?.gitError == .rebaseAlreadyInProgress)
            #expect(error.recoveries.isEmpty)
        }
    }

    // MARK: 6. missingRepositoryHandler

    @Test("6. not a git repository, or a system error with the path gone, means missing")
    func missingRepository() async throws {
        let notARepository = await classify(gitError("fatal: not a git repository (or any of the parent directories): .git\n", exitCode: 128))
        #expect(notARepository.reason == .missingRepository)

        let gone = ModelFixtures.record(path: try createTempDirectory() + "/gone")
        let spawnFailed = await classify(POSIXError(.ENOENT), record: gone)
        #expect(spawnFailed.reason == .missingRepository)

        let stillThere = ModelFixtures.record(path: try createTempDirectory())
        let otherFailure = await classify(POSIXError(.EACCES), record: stillThere)
        guard case .fileSystem = otherFailure.reason else {
            Issue.record("Unexpected reason \(otherFailure.reason)")
            return
        }
    }

    @Test("6. every error of a repository already missing is a missing repository")
    func alreadyMissing() async {
        let error = await classify(gitError(pushRejectedStderr), record: ModelFixtures.record(path: "/", isMissing: true))
        #expect(error.reason == .missingRepository)
    }

    // MARK: 7. backgroundTaskHandler

    @Test("7. background errors are classified the same and marked")
    func background() async {
        var context = ClassificationContext()
        context.isBackgroundTask = true
        let error = await classify(gitError(pushRejectedStderr), context: context)
        #expect(error.isBackgroundTask)
        #expect(error.reason == .pushRejectedNonFastForward)
    }

    // MARK: 8. samlReauthRequired

    @Test("8. SAML single sign-on asks to sign in again")
    func saml() async {
        let gitHubRepository = ModelFixtures.gitHubRepository()
        let record = ModelFixtures.record(path: "/", gitHubRepository: gitHubRepository)
        let error = await classify(gitError(samlStderr, exitCode: 128), retry: FakeRetry(.push), record: record)
        #expect(error.reason == .samlReauthorizationRequired(organization: "octo-org", endpoint: gitHubRepository.endpoint))
        #expect(error.recoveries.map(\.kind) == [.signIn])
    }

    // MARK: 8b. OAuth App access restrictions

    @Test("8b. an organization's OAuth App access restrictions name the organization and offer to request access, not to sign in again")
    func oauthAppAccessRestricted() async throws {
        let record = ModelFixtures.record(path: "/", gitHubRepository: ModelFixtures.gitHubRepository(owner: "octo-org"))
        var context = ClassificationContext()
        context.hasAccountForRepository = true
        let settings = try #require(URL(string: "https://github.com/settings/connections/applications/Ov23li"))
        context.applicationSettingsURL = settings
        let error = await classify(gitError(oauthRestrictedStderr, exitCode: 128), kind: .fetch, retry: FakeRetry(.fetch), record: record, context: context)
        #expect(Dugite.parseError(oauthRestrictedStderr) == .httpsAuthenticationFailed)
        #expect(error.reason == .oauthAppAccessRestricted(organization: "octo-org"))
        #expect(error.recoveries.map(\.kind) == [.requestOrganizationAccess])
        guard case .requestOrganizationAccess(let url)? = error.recoveries.first else {
            Issue.record("Unexpected recoveries \(error.recoveries)")
            return
        }
        #expect(url == settings)

        // A push without write access: still the restriction, not a fork.
        let push = await classify(gitError(oauthRestrictedStderr, exitCode: 128), retry: FakeRetry(.push), record: ModelFixtures.record(path: "/", gitHubRepository: readOnlyGitHubRepository), context: context)
        #expect(push.reason == .oauthAppAccessRestricted(organization: "octo-org"))

        // Without the account's OAuth app, nothing to open.
        let noAccount = await classify(gitError(oauthRestrictedStderr, exitCode: 128), kind: .fetch, record: record)
        #expect(noAccount.reason == .oauthAppAccessRestricted(organization: "octo-org"))
        #expect(noAccount.recoveries.isEmpty)
    }

    @Test("8b. the organization is found however GitHub quotes it and wherever git wraps the line")
    func oauthAppAccessRestrictedForms() {
        for message in [
            "the `octo-org' organization has enabled OAuth App access restrictions, meaning",
            "the `octo-org` organization has enabled OAuth App access restrictions",
            "the 'octo-org' organization has enabled OAuth\nApp access restrictions",
            "the octo-org organization has enabled oauth app access\nrestrictions",
        ] {
            #expect(getOAuthAppRestrictedOrganization(message) == "octo-org", "\(message)")
        }
        #expect(getOAuthAppRestrictedOrganization("The 'octo-org' organization has enabled or enforced SAML SSO.") == nil)
        #expect(getRemoteMessage(oauthRestrictedStderr).contains("organization has enabled OAuth App access restrictions"))
    }

    @Test("8b. Request Access on GitHub opens the account's page for Espalier", .offline)
    func requestOrganizationAccess() async throws {
        let harness = try AppHarness()
        let app = await harness.loadedApp()
        let url = try #require(URL(string: "https://github.com/settings/connections/applications/Ov23li"))
        let recovery = Recovery.requestOrganizationAccess(url)
        #expect(recovery.isHeadless)
        try await recovery.perform(in: app)
        #expect(harness.workspace.openedURLs == [url])
    }

    // MARK: 9. pushNeedsPullHandler

    @Test("9. a rejected push offers to fetch")
    func pushNeedsPull() async {
        let error = await classify(gitError(pushRejectedStderr), retry: FakeRetry(.push))
        #expect(error.reason == .pushRejectedNonFastForward)
        #expect(error.recoveries.map(\.kind) == [.fetch])
    }

    // MARK: 10. insufficientGitHubRepoPermissions

    @Test("10. an authentication failure pushing without write access offers a fork when an account matches")
    func insufficientPermissions() async {
        let record = ModelFixtures.record(path: "/", gitHubRepository: readOnlyGitHubRepository)
        var context = ClassificationContext()
        context.hasAccountForRepository = true
        let error = await classify(gitError(authenticationFailedStderr, exitCode: 128), retry: FakeRetry(.push), record: record, context: context)
        #expect(error.reason == .insufficientPermissions(repositoryFullName: "octocat/app"))
        #expect(error.recoveries.map(\.kind) == [.createFork])

        let noAccount = await classify(gitError(authenticationFailedStderr, exitCode: 128), retry: FakeRetry(.push), record: record)
        #expect(noAccount.reason == .insufficientPermissions(repositoryFullName: "octocat/app"))
        #expect(noAccount.recoveries.isEmpty)

        let fetching = await classify(gitError(authenticationFailedStderr, exitCode: 128), kind: .fetch, retry: FakeRetry(.fetch), record: record)
        guard case .authenticationFailed = fetching.reason else {
            Issue.record("Unexpected reason \(fetching.reason)")
            return
        }
    }

    // MARK: 11. lfsAttributeMismatchHandler

    @Test("11. mismatched Git LFS filters offer to update them, or to edit the global git config")
    func lfsAttributeMismatch() async {
        let stderr = #"The filter.lfs.clean attribute should be "git-lfs clean -- %f" but is "git lfs clean %f""#
        let error = await classify(gitError(stderr), kind: .updateLFSFilters, record: nil)
        #expect(error.reason == .lfsAttributeMismatch)
        #expect(error.recoveries.map(\.kind) == [.updateLFSFilters, .editGlobalGitConfig])
        #expect(error.recoveries.map(\.isHeadless) == [true, true])
    }

    // MARK: 12. mergeConflictHandler

    @Test("12. merge conflicts reaching the classifier stay git errors (merge intercepts them)")
    func mergeConflicts() async {
        let stderr = "CONFLICT (content): Merge conflict in README.md\nAutomatic merge failed; fix conflicts and then commit the result.\n"
        let error = await classify(gitError(stderr), kind: .merge, gitContext: .merge(currentBranch: "main", theirBranch: "feature"))
        #expect(error.gitFailure?.gitError == .mergeConflicts)
        guard case .git = error.reason else {
            Issue.record("Unexpected reason \(error.reason)")
            return
        }
    }

    // MARK: 13. openShellErrorHandler

    @Test("13. a shell that can't open offers settings")
    func shell() async {
        let error = await classify(ShellError("Could not find executable for 'iTerm2'"), kind: .openInShell, record: nil)
        #expect(error.reason == .integration(.shell(message: "Could not find executable for 'iTerm2'")))
        #expect(error.recoveries.map(\.kind) == [.openSettings(.integrations)])
    }

    // MARK: 14. externalEditorErrorHandler

    @Test("14. an editor that can't open offers settings or the suggested editor")
    func editor() async {
        let settings = await classify(
            ExternalEditorError("Visual Studio Code is not installed.", metadata: .init(openPreferences: true)),
            kind: .openInEditor,
            record: nil
        )
        #expect(settings.reason == .integration(.editor(message: "Visual Studio Code is not installed.", suggestDefaultEditor: false, openPreferences: true)))
        #expect(settings.recoveries.map(\.kind) == [.openSettings(.integrations)])

        let suggestion = await classify(
            ExternalEditorError("No suitable editors installed.", metadata: .init(suggestDefaultEditor: true)),
            kind: .openInEditor,
            record: nil
        )
        #expect(suggestion.recoveries.map(\.kind) == [.downloadSuggestedEditor])
    }

    // MARK: 16. defaultErrorHandler

    @Test("16. other git errors carry git's message")
    func gitDefault() async {
        let error = await classify(gitError("fatal: bad revision 'beta..origin/beta'\n", exitCode: 128), kind: .checkoutBranch)
        #expect(error.reason == .git(GitFailure(gitError(
            "fatal: bad revision 'beta..origin/beta'\n",
            exitCode: 128
        ))))
        #expect(!error.isRawGitOutput)
        #expect(error.recoveries.isEmpty)

        let raw = await classify(gitError("fatal: something unexpected happened\n"), kind: .checkoutBranch)
        #expect(raw.isRawGitOutput)
        #expect(raw.message == "fatal: something unexpected happened\n")
    }

    @Test("16. authentication failures offer the accounts settings")
    func authenticationFailed() async {
        let error = await classify(gitError(authenticationFailedStderr, exitCode: 128), kind: .fetch, retry: FakeRetry(.fetch))
        guard case .authenticationFailed(let failure) = error.reason else {
            Issue.record("Unexpected reason \(error.reason)")
            return
        }
        #expect(failure.gitError == .httpsAuthenticationFailed)
        #expect(error.recoveries.map(\.kind) == [.openSettings(.accounts)])
    }

    @Test("16. a push with files over GitHub's limit lists them")
    func fileSizeLimit() async {
        let error = await classify(gitError(fileTooLargeStderr), retry: FakeRetry(.push))
        #expect(error.reason == .fileSizeLimitExceeded(files: ["some-file.mp4 (292.85 MB)"]))
    }

    @Test("16. errors that aren't git's are file system or other errors")
    func nonGit() async {
        struct Unexpected: Error, LocalizedError {
            var errorDescription: String? { "Something broke." }
        }
        let other = await classify(Unexpected(), kind: .checkoutBranch)
        #expect(other.reason == .other("Something broke."))

        let fileSystem = await classify(CocoaError(.fileWriteOutOfSpace), kind: .checkoutBranch, record: ModelFixtures.record(path: "/"))
        guard case .fileSystem = fileSystem.reason else {
            Issue.record("Unexpected reason \(fileSystem.reason)")
            return
        }
    }

    @Test("operation errors pass through and cancellations stay cancellations")
    func passThrough() async {
        let precondition = OperationError(.precondition("The current branch has no commits yet."), operation: .merge)
        let passed = await classify(precondition)
        #expect(passed == precondition)

        let cancelled = await classify(CancellationError(), kind: .fetch)
        #expect(cancelled.reason == .cancelled(.taskCancelled))
        #expect(cancelled.isCancellation)
    }

    // MARK: Retries

    @Test("a failed clone offers to retry it")
    func cloneRetry() async {
        let clone = await classify(gitError("fatal: repository 'https://github.com/x/y.git/' not found\n", exitCode: 128), kind: .clone, retry: FakeRetry(.clone), record: nil)
        #expect(clone.recoveries.map(\.kind) == [.retry(.clone)])
    }
}
