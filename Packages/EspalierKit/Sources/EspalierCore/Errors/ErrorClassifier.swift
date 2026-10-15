// Ported from desktop/app/src/ui/dispatcher/error-handlers.ts
//
// The matchers are evaluated in order, once, where the operation fails, and
// produce one reason with its recoveries.

import EspalierSupport
import Foundation
import GitHubKit
import GitKit

/// What the classifier needs to know beyond the error and the operation.
struct ClassificationContext: Sendable {
    /// The operation is a background task: its error is never presented as
    /// an error.
    var isBackgroundTask = false

    /// An account matches the repository's GitHub endpoint: only then is a
    /// fork offered.
    var hasAccountForRepository = false

    /// The current branch has a stash entry: "Stash Changes and Continue"
    /// isn't offered then.
    var currentBranchHasStash = false

    /// The page in the user's GitHub settings for Espalier's OAuth app, for
    /// the repository's account, where an organization's access is
    /// requested.
    var applicationSettingsURL: URL?

    /// HEAD is an unborn branch, where git can't stash ("You do not have
    /// the initial commit yet"), so "Stash Changes and Continue" isn't
    /// offered.
    var isUnbornBranch = false

    /// The rebase state in the git directory that Espalier can't continue
    /// or abort (`getLeftoverRebase`), looked for when git refuses to start
    /// a rebase over one.
    var leftoverRebase: LeftoverRebase?
}

/// Turns what an operation threw into an `OperationError`.
enum ErrorClassifier {
    /// Classifies `error`, thrown by the operation `descriptor` describes in
    /// the repository `record`, evaluating the matchers in order.
    ///
    /// An `OperationError` passes through unchanged. Side effects are the
    /// caller's: a `.missingRepository` reason for a record that isn't marked
    /// missing means marking it.
    static func classify(
        _ error: any Error,
        descriptor: OperationDescriptor,
        record: RepositoryRecord?,
        context: ClassificationContext
    ) async -> OperationError {
        if let error = error as? OperationError {
            return error
        }

        func make(_ reason: OperationError.Reason, _ recoveries: [Recovery] = []) -> OperationError {
            var recoveries = recoveries
            // Any error of a clone offers "Retry Clone".
            if let retry = descriptor.retry, retry.kind == .clone {
                recoveries.insert(.retry(retry), at: 0)
            }
            return OperationError(
                reason,
                operation: descriptor.kind,
                repositoryID: record?.id,
                retry: descriptor.retry,
                isBackgroundTask: context.isBackgroundTask,
                underlying: error,
                gitContext: descriptor.gitContext,
                recoveries: recoveries
            )
        }

        if error is CancellationError {
            return make(.cancelled(.taskCancelled))
        }

        let gitError = error as? GitError
        let dugiteError = gitError?.result.gitError
        let stderr = gitError?.result.stderr ?? ""

        // 1. Secret scanning push protection.
        if dugiteError == .pushWithSecretDetected {
            let secrets = extractSecretScanningResults(getRemoteMessage(stderr))
            return make(.pushProtectionBlocked(secrets), record.map { [.reviewPushProtection($0.id, secrets)] } ?? [])
        }

        // 2. A discard whose Trash failed.
        if let trashFailure = error as? TrashFailedError {
            return make(
                .trashFailed(files: trashFailure.files),
                record.map { [.discardPermanently($0.id, trashFailure.files)] } ?? []
            )
        }

        // 3. A workflow file pushed without the `workflow` scope.
        if let gitError, let gitHubRepository = record?.gitHubRepository,
           let rejectedPath = getRejectedWorkflowPath(gitError.message) {
            return make(
                .workflowScopeRequired(rejectedPath: rejectedPath),
                [.signIn(endpoint: gitHubRepository.endpoint, then: descriptor.retry)]
            )
        }

        // 4. Rebase conflicts during a merge or pull aren't errors. Pull
        // returns `.conflicted` and the status pass rebuilds the rebase, so
        // nothing reaches here; anything that does falls through to the
        // default.

        // 5. Local changes that would be overwritten.
        if let dugiteError, [.localChangesOverwritten, .mergeWithLocalChanges, .rebaseWithLocalChanges, .rebaseWithStagedChanges].contains(dugiteError),
           let retry = descriptor.retry, let record {
            let files = parseFilesToBeOverwritten(stderr)
            let canStash = !context.currentBranchHasStash && retry.kind != .restoreStash && !context.isUnbornBranch
            return make(.localChangesOverwritten(files: files), canStash ? [.stashChangesAndRetry(record.id, retry)] : [])
        }

        // 5b. Untracked files are where a stash entry's files go, so nothing
        // was restored. Stashing them can't help: the entry would replace the
        // one being restored.
        if let inTheWay = error as? StashFilesInTheWayError {
            return make(.localChangesOverwritten(files: inTheWay.files))
        }

        // 5c. A rebase's state Espalier can't continue or abort, which git
        // won't start a rebase over: "Clear Old Rebase and Continue" clears
        // it and runs the operation again. A rebase Espalier shows is the
        // default's: finish or abort it.
        if dugiteError == .rebaseAlreadyInProgress, let leftover = context.leftoverRebase,
           let retry = descriptor.retry, let record {
            return make(.precondition(leftover.message), [.clearLeftoverRebaseAndRetry(record.id, retry)])
        }

        // 6. A missing repository. Every error of a repository already marked
        // missing is one.
        if let record {
            if record.isMissing {
                return make(.missingRepository)
            }
            if dugiteError == .notAGitRepository {
                return make(.missingRepository)
            }
            if isErrorWithCode(error), !(await pathExists(record.path)) {
                return make(.missingRepository)
            }
        }

        // 7. Background tasks: `isBackgroundTask` is carried on every error;
        // rows 1-6 have already applied.

        // 8. SAML single sign-on needs signing in again.
        if let dugiteError, isAuthFailureError(dugiteError), let gitHubRepository = record?.gitHubRepository,
           let organization = getSAMLReauthOrganization(getRemoteMessage(stderr)) {
            return make(
                .samlReauthorizationRequired(organization: organization, endpoint: gitHubRepository.endpoint),
                [.signIn(endpoint: gitHubRepository.endpoint, then: descriptor.retry)]
            )
        }

        // 8b. An organization's OAuth App access restrictions. Signing in again
        // (the default's advice) can't help, so this comes before the
        // authentication failures.
        if gitError != nil, let organization = getOAuthAppRestrictedOrganization(getRemoteMessage(stderr)) {
            return make(
                .oauthAppAccessRestricted(organization: organization),
                context.applicationSettingsURL.map { [.requestOrganizationAccess($0)] } ?? []
            )
        }

        // 9. A push that needs a pull first, or a force push whose lease
        // found the remote branch moved ("stale info", which dugite's
        // patterns don't name).
        if dugiteError == .pushNotFastForward || (gitError != nil && isStaleLeaseRejection(stderr)), let record {
            return make(.pushRejectedNonFastForward, [.fetch(record.id)])
        }

        // 10. No permission to push to the GitHub repository. A fork is offered
        // only when an account matches.
        if let dugiteError, isAuthFailureError(dugiteError), let record, let gitHubRepository = record.gitHubRepository,
           descriptor.retry?.kind == .push, !hasWritePermission(gitHubRepository) {
            return make(
                .insufficientPermissions(repositoryFullName: gitHubRepository.fullName),
                context.hasAccountForRepository ? [.createFork(record.id)] : []
            )
        }

        // 11. Git LFS filters that don't match; the global git config can be
        // edited too.
        if dugiteError == .lfsAttributeDoesNotMatch {
            return make(.lfsAttributeMismatch, [.updateLFSFilters, .editGlobalGitConfig])
        }

        // 12. Conflicts of a merge or pull aren't errors; merge and pull return
        // `.conflicted`.

        // 13. A shell that couldn't be opened.
        if let shellError = error as? ShellError {
            return make(.integration(.shell(message: shellError.message)), [.openSettings(.integrations)])
        }

        // 14. An editor that couldn't be opened.
        if let editorError = error as? ExternalEditorError {
            var recoveries: [Recovery] = []
            if editorError.metadata.openPreferences {
                recoveries.append(.openSettings(.integrations))
            } else if editorError.metadata.suggestDefaultEditor {
                recoveries.append(.downloadSuggestedEditor)
            }
            return make(
                .integration(.editor(
                    message: editorError.message,
                    suggestDefaultEditor: editorError.metadata.suggestDefaultEditor,
                    openPreferences: editorError.metadata.openPreferences
                )),
                recoveries
            )
        }

        // 15. An upstream remote that already exists is state, not an error
        // (`sync.upstreamRemoteConflict`).

        // 16. The default.
        if let gitError {
            let failure = GitFailure(gitError)
            if let dugiteError, isAuthFailureError(dugiteError) {
                return make(.authenticationFailed(failure), [.openSettings(.accounts)])
            }
            if dugiteError == .pushWithFileSizeExceedingLimit {
                return make(.fileSizeLimitExceeded(files: getFileFromExceedsError(stderr)))
            }
            return make(.git(failure))
        }

        if isFileSystemError(error) {
            return make(.fileSystem(error.localizedDescription))
        }
        return make(.other(error.localizedDescription))
    }

    /// Whether git refused to push a ref because its `--force-with-lease`
    /// lease didn't hold: ` ! [rejected] main -> main (stale info)`.
    private static func isStaleLeaseRejection(_ stderr: String) -> Bool {
        stderr.contains("[rejected]") && stderr.contains(" (stale info)") && stderr.contains("error: failed to push some refs")
    }

    /// An error from the system, with a code such as `ENOENT`.
    static func isErrorWithCode(_ error: any Error) -> Bool {
        if let error = error as? ExecError {
            return error.code != nil
        }
        return isFileSystemError(error)
    }

    private static func isFileSystemError(_ error: any Error) -> Bool {
        if error is POSIXError || error is CocoaError {
            return true
        }
        let nsError = error as NSError
        return nsError.domain == NSPOSIXErrorDomain || nsError.domain == NSCocoaErrorDomain
    }
}
