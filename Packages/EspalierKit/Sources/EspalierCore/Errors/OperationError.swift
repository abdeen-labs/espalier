import Foundation
import GitHubKit
import GitKit

/// An operation failed, was refused, or needs the user first.
///
/// Every mutating intent throws only this. `reason` says what happened;
/// `title`, `message`, and `recoveries` are what the user sees for it.
public struct OperationError: Error, Sendable {
    /// The operation that failed.
    public let operation: OperationKind
    /// The repository it ran in, if any.
    public let repositoryID: RepositoryID?
    public let reason: Reason
    /// How to run the operation again with the same arguments, if it can be.
    public let retry: (any RetryableOperation)?
    /// Whether a background task failed: never presented as an error, kept
    /// as the repository's `lastBackgroundFailure`.
    public let isBackgroundTask: Bool
    /// The error the operation threw.
    public let underlying: (any Error)?
    /// What the operation was doing, for the title.
    public let gitContext: GitErrorContext?
    /// What the user can do about it.
    public let recoveries: [Recovery]

    public init(
        _ reason: Reason,
        operation: OperationKind,
        repositoryID: RepositoryID? = nil,
        retry: (any RetryableOperation)? = nil,
        isBackgroundTask: Bool = false,
        underlying: (any Error)? = nil,
        gitContext: GitErrorContext? = nil,
        recoveries: [Recovery] = []
    ) {
        self.reason = reason
        self.operation = operation
        self.repositoryID = repositoryID
        self.retry = retry
        self.isBackgroundTask = isBackgroundTask
        self.underlying = underlying
        self.gitContext = gitContext
        self.recoveries = recoveries
    }

    /// Why an operation didn't complete.
    public enum Reason: Sendable, Equatable {
        /// Git failed (dugite's error, message, exit code, and output).
        case git(GitFailure)
        /// Git couldn't authenticate with the remote.
        case authenticationFailed(GitFailure)
        /// The repository is gone, or isn't a repository any more.
        case missingRepository
        /// Git refuses to work in the repository because another user owns it.
        case unsafeRepository(path: String)
        /// The remote has commits the branch doesn't.
        case pushRejectedNonFastForward
        /// GitHub's push protection found secrets in the pushed commits.
        case pushProtectionBlocked([SecretScanResult])
        /// Pushing a workflow file needs the `workflow` scope.
        case workflowScopeRequired(rejectedPath: String)
        /// The organization requires signing in again for SAML single sign-on.
        case samlReauthorizationRequired(organization: String, endpoint: String)
        /// The organization's OAuth App access restrictions don't allow
        /// Espalier (an organization owner must approve it); signing in
        /// again doesn't help.
        case oauthAppAccessRestricted(organization: String)
        /// The account can't push to the GitHub repository.
        case insufficientPermissions(repositoryFullName: String)
        /// The push includes files over GitHub's 100 MB limit.
        case fileSizeLimitExceeded(files: [String])
        /// Local changes would be overwritten (checkout, merge, rebase, ...).
        case localChangesOverwritten(files: [String])
        /// The global Git LFS filters aren't the ones Git LFS expects.
        case lfsAttributeMismatch
        /// Moving discarded changes to the Trash failed.
        case trashFailed(files: [WorkingDirectoryFileChange])
        /// Another operation is running in the repository.
        case busy(OperationKind)
        /// The user must confirm first; call again with the kind confirmed.
        case confirmationRequired(Confirmation)
        /// The user must choose first; call again with the choice.
        case decisionRequired(Decision)
        /// The operation can't run in the current state, with the message to
        /// show ("The current branch has no commits yet.", say).
        case precondition(String)
        /// The operation stopped before it completed, without an error.
        case cancelled(CancellationReason)
        /// A GitHub API request failed (publish, fork, bypass).
        case api(APIFailure)
        /// An AI request failed or can't be made.
        case ai(AIFailure)
        /// An editor or shell couldn't be opened.
        case integration(IntegrationFailure)
        /// A file system operation failed.
        case fileSystem(String)
        /// Anything else.
        case other(String)
    }
}

/// Why an operation stopped without an error.
public enum CancellationReason: Sendable, Equatable {
    /// The user chose "Abort" after the named hook failed.
    case hookAborted(String)
    /// The user cancelled (a clone, an AI request).
    case userCancelled
    /// The task waiting for the operation was cancelled before it started.
    case taskCancelled
}

/// A failed git command, as the user sees it.
public struct GitFailure: Sendable, Equatable {
    /// The error dugite recognized, if any.
    public let gitError: DugiteError?
    /// The error's description, or git's own output.
    public let message: String
    /// Whether `message` is git's raw output (show it monospaced, scrolled
    /// to the end).
    public let isRawMessage: Bool
    public let exitCode: Int
    /// Git's standard error.
    public let stderr: String
    /// The command's arguments.
    public let args: [String]

    public init(gitError: DugiteError?, message: String, isRawMessage: Bool, exitCode: Int, stderr: String, args: [String]) {
        self.gitError = gitError
        self.message = message
        self.isRawMessage = isRawMessage
        self.exitCode = exitCode
        self.stderr = stderr
        self.args = args
    }

    public init(_ error: GitError) {
        self.init(
            gitError: error.result.gitError,
            message: error.message,
            isRawMessage: error.isRawMessage,
            exitCode: error.result.exitCode,
            stderr: error.result.stderr,
            args: error.args
        )
    }
}

/// A failed GitHub API request.
public struct APIFailure: Sendable, Equatable {
    public let message: String
    /// The HTTP status, when there was a response.
    public let status: Int?

    public init(message: String, status: Int? = nil) {
        self.message = message
        self.status = status
    }
}

/// A failed or impossible AI request.
public enum AIFailure: Sendable, Equatable {
    /// The user hasn't agreed to send data to the provider yet
    /// (`AIModel.disclosure(for:)` has what to show).
    case consentRequired(provider: String)
    /// The selected model can't be used: its credential is missing or
    /// unreadable (the message says which).
    case modelUnavailable(String)
    /// The provider failed; the title and message are
    /// `getAIErrorDisplayInfo`'s for the error.
    case provider(title: String?, message: String)
    /// AI features are turned off in Settings.
    case disabled
    /// No provider with a model is configured: the sparkle's setup popover.
    case noProvider
    /// Several models are configured and none is chosen for the feature:
    /// the UI asks which (`AIModel.availableModels`).
    case modelSelectionRequired

    public var message: String {
        switch self {
        case .consentRequired(let provider): "Before the first request to \(provider), confirm what will be sent."
        case .modelUnavailable(let message): message
        case .provider(_, let message): message
        case .disabled: "AI features are turned off in Settings."
        case .noProvider:
            "Add a provider to use your own API key with OpenAI-compatible endpoints, Azure, Anthropic, or local providers like Ollama."
        case .modelSelectionRequired: "Choose a model to use."
        }
    }
}

/// An editor or shell that couldn't be opened (`ExternalEditorError` and
/// `ShellError`).
public enum IntegrationFailure: Sendable, Equatable {
    case editor(message: String, suggestDefaultEditor: Bool, openPreferences: Bool)
    case shell(message: String)

    public var message: String {
        switch self {
        case .editor(let message, _, _), .shell(let message): message
        }
    }
}

/// What an operation run again from a recovery did, as its intent returned
/// it, so the window reports it as it reports the first run (a toast, Undo,
/// publishing first).
public enum OperationOutcome: Sendable, Equatable {
    /// Nothing to report besides the refreshed state.
    case nothing
    case checkout(CheckoutResult, repositoryID: RepositoryID)
    case merge(MergeOutcome, repositoryID: RepositoryID)
    /// A rebase, cherry-pick, squash, or reorder.
    case multiCommit(MultiCommitResult, repositoryID: RepositoryID)
    case push(PushOutcome, repositoryID: RepositoryID)
    /// Reset to Commit.
    case reset(ResetResult, repositoryID: RepositoryID)
}

/// An operation that can be run again with the same arguments.
///
/// Retry values are structs in their owners' files (`CheckoutRetry`,
/// `PushRetry`, ...). `perform(in:)` calls the owner's intent, so there is
/// no central retry switch, and returns what the intent returned.
public protocol RetryableOperation: Sendable {
    /// The operation it runs again (`.push`, `.clone`, ...).
    var kind: OperationKind { get }

    /// What the retry is about, for copy such as "Would you like to retry
    /// cloning <name>?". Nil by default.
    var displayName: String? { get }

    /// The title of its recovery button, when it isn't "Retry" ("Delete
    /// Anyway" for a worktree git refused to delete). Nil by default.
    var recoveryTitle: String? { get }

    /// Runs the operation again.
    @discardableResult
    @MainActor func perform(in app: AppModel) async throws(OperationError) -> OperationOutcome

    /// Runs the operation again with confirmations the user gave since: the
    /// operation asked for them when it ran again (a squash's "Squash Will
    /// Require Force Push" after "Stash Changes and Continue"). They're
    /// added to those it was first given. By default `perform(in:)`, for
    /// operations that ask for none.
    @discardableResult
    @MainActor func perform(in app: AppModel, confirmed: Set<ConfirmationKind>) async throws(OperationError) -> OperationOutcome
}

extension RetryableOperation {
    public var displayName: String? {
        nil
    }

    @discardableResult
    @MainActor
    public func perform(in app: AppModel, confirmed: Set<ConfirmationKind>) async throws(OperationError) -> OperationOutcome {
        try await perform(in: app)
    }

    public var recoveryTitle: String? {
        nil
    }
}

/// Moving discarded changes to the Trash failed. The discard throws it;
/// the classifier makes it `.trashFailed`.
public struct TrashFailedError: Error, Sendable {
    public let files: [WorkingDirectoryFileChange]
    public let underlying: (any Error)?

    public init(files: [WorkingDirectoryFileChange], underlying: (any Error)?) {
        self.files = files
        self.underlying = underlying
    }
}

// MARK: - Presentation

extension OperationError {
    /// The title of an error with nothing more specific to say.
    public static let genericTitle = "Error"

    /// The error's title: the reason's own, else the failed operation's,
    /// else `genericTitle`.
    public var title: String {
        switch reason {
        case .ai(.provider(let title?, _)):
            return title
        case .pushRejectedNonFastForward:
            return "Newer Commits on Remote"
        case .pushProtectionBlocked:
            return "Push Blocked: Secret Detected"
        case .workflowScopeRequired:
            return "Push Rejected"
        case .samlReauthorizationRequired:
            return "Re-authorization Required"
        case .oauthAppAccessRestricted:
            return "Organization Access Restricted"
        case .insufficientPermissions:
            return "Do you want to fork this repository?"
        case .lfsAttributeMismatch:
            return "Update Existing Git LFS Filters?"
        case .trashFailed:
            return "Discard Changes Permanently?"
        case .integration(.editor):
            return "Unable to Open External Editor"
        case .integration(.shell):
            return "Unable to Open Shell"
        case .confirmationRequired(let confirmation):
            return confirmation.title
        case .decisionRequired(let decision):
            return decision.title
        case .fileSizeLimitExceeded:
            return "File Size Limit Exceeded"
        default:
            break
        }

        switch retry?.kind {
        case .clone?: return "Clone Failed"
        case .push?: return "Push Failed"
        case .removeWorktree?: return "Delete Worktree Failed"
        default: break
        }

        switch gitContext {
        case .createRepository?: return "Couldn't Create Repository"
        case .commit?: return "Commit Failed"
        default: return signingFailure == nil ? Self.genericTitle : "Signing Failed"
        }
    }

    /// The message: git's error description, or the reason's copy.
    public var message: String {
        var message = baseMessage
        if retry?.kind == .clone, let name = retry?.displayName {
            message += "\n\nWould you like to retry cloning \(name)?"
        }
        if retry?.kind == .removeWorktree, let name = retry?.displayName {
            message += "\n\nDelete the worktree \(name) anyway?"
        }
        return message
    }

    /// Whether `message` is git's raw output, to show monospaced and
    /// scrolled to the end.
    public var isRawGitOutput: Bool {
        switch reason {
        case .git(let failure), .authenticationFailed(let failure):
            failure.isRawMessage
        default:
            false
        }
    }

    /// The git failure behind the error, if git failed.
    public var gitFailure: GitFailure? {
        switch reason {
        case .git(let failure), .authenticationFailed(let failure):
            return failure
        default:
            return (underlying as? GitError).map(GitFailure.init)
        }
    }

    private var baseMessage: String {
        switch reason {
        case .git(let failure), .authenticationFailed(let failure):
            return failure.message
        case .missingRepository:
            return gitFailure?.message ?? "This isn't a Git repository."
        case .unsafeRepository(let path):
            return "The Git repository at \(path) appears to belong to another user on this Mac. A repository you don't trust can run files in it automatically.\n\nIf you trust its owner, add an exception for this folder to continue."
        case .pushRejectedNonFastForward:
            return "The remote branch has commits that your local branch doesn't, so Espalier can't push yet. Fetch them first, then combine them with your commits."
        case .pushProtectionBlocked:
            return "Secret scanning found one or more secrets in the commits you tried to push.\n\nAllowing a secret risks exposing it. Consider removing it from your commits and their history."
        case .workflowScopeRequired(let path):
            return "The server rejected the push because it changes the workflow file \(path). To push changes to workflow files, Espalier needs more permissions.\n\nOpen your browser to give Espalier permission to update workflow files?"
        case .samlReauthorizationRequired(let organization, _):
            return "The \u{201C}\(organization)\u{201D} organization requires SAML single sign-on. To access this repository, sign in again and give Espalier permission to access the organization's repositories.\n\nOpen your browser to give Espalier permission?"
        case .oauthAppAccessRestricted(let organization):
            return "The \"\(organization)\" organization has enabled OAuth App access restrictions, so Espalier can't access its repositories until an organization owner approves Espalier. Signing in again won't change that.\n\nYou can ask for approval on Espalier's page in your GitHub settings."
        case .insufficientPermissions(let fullName):
            return "You don't have write access to \(fullName). If you should, ask a repository administrator."
        case .fileSizeLimitExceeded:
            return gitFailure?.message
                ?? "The push includes a file larger than GitHub's 100 MB limit. Remove the file from your history and try again."
        case .localChangesOverwritten(let files):
            let overwritten = files.isEmpty ? "" : " These files would be overwritten:"
            return "Can't \(retryActionName) while your branch has uncommitted changes.\(overwritten)"
        case .lfsAttributeMismatch:
            return "Your global Git config already has Git LFS filters, but not the values Git LFS expects. Update them now?"
        case .trashFailed:
            return "Espalier couldn't move the discarded changes to the Trash. This can happen on a volume without a Trash, or when Espalier isn't allowed to move the files.\n\nIf you discard them permanently, you can't get them back from the Trash."
        case .busy(let kind):
            return "Espalier can't start this while another operation (\(kind.rawValue)) is running in the repository."
        case .confirmationRequired(let confirmation):
            return confirmation.message
        case .decisionRequired(let decision):
            return decision.message
        case .precondition(let message), .fileSystem(let message), .other(let message):
            return message
        case .cancelled(.hookAborted(let hookName)):
            return "The \(hookName) hook failed."
        case .cancelled:
            return "The operation was cancelled."
        case .api(let failure):
            return failure.message
        case .ai(let failure):
            return failure.message
        case .integration(let failure):
            return failure.message
        }
    }

    /// The action named in "Unable to <action> when changes are present on
    /// your branch."
    private var retryActionName: String {
        switch retry?.kind ?? operation {
        case .checkoutBranch, .checkoutCommit: "check out"
        case .pull: "pull"
        case .merge: "merge"
        case .rebase: "rebase"
        case .clone: "clone"
        case .fetch: "fetch"
        case .push: "push"
        case .cherryPick, .createBranch: "cherry-pick"
        case .squash: "squash"
        case .reorder: "reorder"
        case .discardChanges: "discard changes"
        case .restoreStash: "restore stashed changes"
        case .applyStash: "apply stashed changes"
        default: "continue"
        }
    }

    /// Whether the user stopped the operation (a hook abort, a cancel): no
    /// error to show.
    public var isCancellation: Bool {
        if case .cancelled = reason { true } else { false }
    }
}

extension OperationError: Equatable {
    /// Errors are equal when the same operation failed in the same
    /// repository for the same reason (what states such as `Loadable`
    /// compare); the underlying error and the retry aren't compared.
    public static func == (lhs: OperationError, rhs: OperationError) -> Bool {
        lhs.operation == rhs.operation
            && lhs.repositoryID == rhs.repositoryID
            && lhs.reason == rhs.reason
            && lhs.isBackgroundTask == rhs.isBackgroundTask
            && lhs.gitContext == rhs.gitContext
    }
}

extension OperationError: CustomStringConvertible, LocalizedError {
    public var description: String {
        "\(operation.rawValue): \(message)"
    }

    public var errorDescription: String? {
        message
    }
}
