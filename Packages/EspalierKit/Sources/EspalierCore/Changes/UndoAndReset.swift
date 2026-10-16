import EspalierSupport
import Foundation
import GitKit

/// Undoes the commit again, with the confirmations given the first time.
public struct UndoCommitRetry: RetryableOperation {
    public let repositoryID: RepositoryID
    public let commit: Commit
    public let confirmed: Set<ConfirmationKind>

    public init(repositoryID: RepositoryID, commit: Commit, confirmed: Set<ConfirmationKind> = []) {
        self.repositoryID = repositoryID
        self.commit = commit
        self.confirmed = confirmed
    }

    public var kind: OperationKind {
        .undoCommit
    }

    @discardableResult
    @MainActor
    public func perform(in app: AppModel) async throws(OperationError) -> OperationOutcome {
        try await perform(in: app, confirmed: [])
    }

    @discardableResult
    @MainActor
    public func perform(in app: AppModel, confirmed: Set<ConfirmationKind>) async throws(OperationError) -> OperationOutcome {
        try await app.requireRepository(repositoryID, for: kind).commit.undo(commit, confirmed: self.confirmed.union(confirmed))
        return .nothing
    }
}

/// Resets the branch to the commit again, with the confirmations given the
/// first time.
public struct ResetToCommitRetry: RetryableOperation {
    public let repositoryID: RepositoryID
    public let commit: Commit
    public let confirmed: Set<ConfirmationKind>

    public init(repositoryID: RepositoryID, commit: Commit, confirmed: Set<ConfirmationKind> = []) {
        self.repositoryID = repositoryID
        self.commit = commit
        self.confirmed = confirmed
    }

    public var kind: OperationKind {
        .resetToCommit
    }

    @discardableResult
    @MainActor
    public func perform(in app: AppModel) async throws(OperationError) -> OperationOutcome {
        try await perform(in: app, confirmed: [])
    }

    @discardableResult
    @MainActor
    public func perform(in app: AppModel, confirmed: Set<ConfirmationKind>) async throws(OperationError) -> OperationOutcome {
        let result = try await app.requireRepository(repositoryID, for: kind).commit.reset(to: commit, confirmed: self.confirmed.union(confirmed))
        return .reset(result, repositoryID: repositoryID)
    }
}

/// What Reset to Commit did. `summary` is the toast's copy.
public struct ResetResult: Sendable, Equatable {
    /// The branch reset, or nil on a detached HEAD.
    public let branchName: String?
    /// The commit the branch is at now.
    public let sha: String

    public init(branchName: String?, sha: String) {
        self.branchName = branchName
        self.sha = sha
    }

    /// "Reset main to a1b2c3d".
    public var summary: String {
        "Reset \(branchName ?? "HEAD") to \(shortenSHA(sha))"
    }
}

extension CommitModel {
    // MARK: Amending

    /// Whether amending can start: HEAD has a commit, on a branch or
    /// detached, and no rebase is in progress (a rebase moves HEAD commit by
    /// commit, and its panel continues it).
    public var canStartAmending: Bool {
        guard let repository else {
            return false
        }
        if case .rebase? = repository.gitState.inProgress {
            return false
        }
        return repository.gitState.tip.sha != nil
    }

    /// Starts amending the tip commit: its message and co-authors fill the
    /// draft, and the next commit replaces it.
    ///
    /// A message the user was writing is set aside and comes back when
    /// amending stops or the amend is committed.
    ///
    /// - Throws: `.confirmationRequired(.rewritePublishedCommits)` ("Amend
    ///   Pushed Commit?") when the commit was pushed, HEAD is on a
    ///   branch, and `confirmForcePush` is on; `.precondition` when there's
    ///   no commit to amend.
    public func startAmending(confirmed: Set<ConfirmationKind> = []) async throws(OperationError) {
        guard let repository, let app = repository.app else {
            throw OperationError(.precondition("The repository is no longer in the list."), operation: .commit)
        }
        guard let tipSHA = repository.gitState.tip.sha else {
            throw OperationError(.precondition("There is no commit to amend."), operation: .commit, repositoryID: repository.id)
        }
        let commit = try await loadCommit(tipSHA, in: repository, operation: .commit)

        let isLocalCommit = repository.gitState.localCommitSHAs.contains { JSCompat.strictEquals($0, commit.sha) }
        if app.preferences.confirmForcePush, !isLocalCommit, repository.gitState.tip.isValidBranch,
           !confirmed.contains(.rewritePublishedCommits) {
            throw OperationError(
                .confirmationRequired(.rewritePublishedCommits(operation: "Amend")),
                operation: .commit,
                repositoryID: repository.id
            )
        }

        let restored = restoredDraft(for: commit, in: repository)
        setAsideDraftForAmending()
        draft = restored
        draftLoadedForAmend = restored
        setAmending(commit)
    }

    // MARK: Undoing

    /// The commit "Undo" applies to: the newest local commit when it's HEAD,
    /// has no tags, nothing is being amended, and no operation waits on
    /// conflicts. Nil otherwise.
    public var undoableCommitSHA: String? {
        guard let repository, amending == nil, repository.operations.conflictState == nil,
              repository.gitState.inProgress == nil,
              let sha = repository.gitState.localCommitSHAs.first,
              let tipSHA = repository.gitState.tip.sha, JSCompat.strictEquals(sha, tipSHA)
        else {
            return nil
        }
        // We don't allow undoing commits that have tags associated to them,
        // since then the commit won't be completely deleted because the tag
        // will still point to it.
        if repository.gitState.tags?.values.contains(where: { JSCompat.strictEquals($0, sha) }) == true {
            return nil
        }
        return sha
    }

    /// Undoes `commit`, which must be HEAD and not pushed: the branch moves
    /// to its first parent, keeping its changes in the working directory
    /// (`git reset <parent>`), and its message and co-authors fill the draft.
    /// Undoing a first commit makes the branch unborn again with every file
    /// untracked, restoring files deleted since.
    ///
    /// Amending stops first. Returns after the status refresh.
    ///
    /// - Throws: `.confirmationRequired(.undoCommitWithChanges)` when there
    ///   are changes and `confirmUndoCommit` is on, and always for a merge
    ///   commit; `.precondition` when `commit` isn't HEAD, was pushed, a
    ///   merge, rebase, or similar is in progress, or a first commit is
    ///   undone on a detached HEAD.
    public func undo(_ commit: Commit, confirmed: Set<ConfirmationKind> = []) async throws(OperationError) {
        guard let repository, let app = repository.app else {
            throw OperationError(.precondition("The repository is no longer in the list."), operation: .undoCommit)
        }
        try repository.operations.requireNoOperationInProgress(.undoCommit)
        guard let tipSHA = repository.gitState.tip.sha, JSCompat.strictEquals(tipSHA, commit.sha) else {
            throw OperationError(.precondition(notLatestCommitMessage), operation: .undoCommit, repositoryID: repository.id)
        }
        guard repository.gitState.localCommitSHAs.contains(where: { JSCompat.strictEquals($0, commit.sha) }) else {
            throw OperationError(.precondition(pushedCommitMessage), operation: .undoCommit, repositoryID: repository.id)
        }
        if commit.parentSHAs.isEmpty, !repository.gitState.tip.isValidBranch {
            throw OperationError(
                .precondition("The first commit can only be undone on a branch."),
                operation: .undoCommit,
                repositoryID: repository.id
            )
        }

        let isWorkingDirectoryClean = repository.changes.workingDirectory.files.isEmpty
        // Warn the user if there are changes in the working directory
        // This warning can be disabled, except when the user tries to undo
        // a merge commit.
        if !confirmed.contains(.undoCommitWithChanges),
           (app.preferences.confirmUndoCommit && !isWorkingDirectoryClean) || commit.isMergeCommit {
            throw OperationError(
                .confirmationRequired(.undoCommitWithChanges(
                    sha: commit.sha,
                    isMergeCommit: commit.isMergeCommit,
                    isWorkingDirectoryClean: isWorkingDirectoryClean
                )),
                operation: .undoCommit,
                repositoryID: repository.id
            )
        }

        if amending != nil {
            stopAmending()
        }

        let tip = repository.gitState.tip
        let repositoryID = repository.id
        let retry = UndoCommitRetry(repositoryID: repositoryID, commit: commit, confirmed: confirmed)
        try await repository.perform(OperationDescriptor(kind: .undoCommit)) { ctx in
            try await requireUnchangedHistory(at: commit.sha, tip: tip, operation: .undoCommit, repositoryID: repositoryID, retry: retry, in: ctx)
            if commit.parentSHAs.isEmpty {
                try await undoFirstCommit(ctx.repository, operation: .undoCommit, repositoryID: repositoryID)
            } else {
                try await GitKit.reset(ctx.repository, .mixed, commit.parentSHAs[0])
            }
        }

        draft = restoredDraft(for: commit, in: repository)
        await repository.awaitOperationRefresh(covering: .status)
    }

    // MARK: Resetting

    /// Resets the branch to `commit`, keeping every change since in the
    /// working directory (`git reset <commit>`, mixed).
    ///
    /// `commit` must be below HEAD with only unpushed commits after it (it may
    /// itself be the first pushed one). Returns after the status refresh.
    ///
    /// - Returns: The branch reset and the commit it's at.
    /// - Throws: `.confirmationRequired` always, no preference turning it
    ///   off: `.resetToCommit` on a clean working directory,
    ///   `.resetWithChanges` with changes (a clean directory's answer
    ///   doesn't cover changes made since); `.precondition` when `commit` is
    ///   HEAD, isn't on the branch, has pushed commits after it, or an
    ///   operation is in progress.
    @discardableResult
    public func reset(to commit: Commit, confirmed: Set<ConfirmationKind> = []) async throws(OperationError) -> ResetResult {
        guard let repository else {
            throw OperationError(.precondition("The repository is no longer in the list."), operation: .resetToCommit)
        }
        try repository.operations.requireNoOperationInProgress(.resetToCommit)
        guard let tipSHA = repository.gitState.tip.sha else {
            throw OperationError(.precondition("There is no commit to reset from."), operation: .resetToCommit, repositoryID: repository.id)
        }
        if JSCompat.strictEquals(tipSHA, commit.sha) {
            throw OperationError(
                .precondition("The branch is already at this commit."),
                operation: .resetToCommit,
                repositoryID: repository.id
            )
        }

        // Ask first, warning about changes in the working directory.
        let tip = repository.gitState.tip
        let hasChanges = !repository.changes.workingDirectory.files.isEmpty
        let isConfirmed = confirmed.contains(.resetWithChanges) || (!hasChanges && confirmed.contains(.resetToCommit))
        guard isConfirmed else {
            throw OperationError(
                .confirmationRequired(.resetToCommit(sha: commit.sha, branch: tip.branch?.name, hasChanges: hasChanges)),
                operation: .resetToCommit,
                repositoryID: repository.id
            )
        }

        let repositoryID = repository.id
        let retry = ResetToCommitRetry(repositoryID: repositoryID, commit: commit, confirmed: confirmed)
        try await repository.perform(OperationDescriptor(kind: .resetToCommit)) { ctx in
            try await requireResettable(to: commit.sha, tip: tip, repositoryID: repositoryID, retry: retry, in: ctx)
            try await GitKit.reset(ctx.repository, .mixed, commit.sha)
        }
        await repository.awaitOperationRefresh(covering: .status)
        return ResetResult(branchName: tip.branch?.name, sha: commit.sha)
    }

    // MARK: Messages

    /// The draft for a commit's message: its summary and body, and in GitHub
    /// repositories its co-authors (`Commit.coAuthors`) moved out of the body
    /// into the co-authors. Co-authors already in the draft stay when the
    /// commit has none.
    func restoredDraft(for commit: Commit, in repository: RepositoryModel) -> CommitDraft {
        var restored = CommitDraft(
            summary: commit.summary,
            description: commit.body,
            coAuthors: draft.coAuthors,
            showCoAuthoredBy: draft.showCoAuthoredBy
        )
        guard repository.record.gitHubRepository != nil else {
            return restored
        }
        let message = restoredMessage(commit, existingCoAuthors: draft.coAuthors)
        restored.summary = message.summary
        restored.description = message.description
        if let coAuthors = message.coAuthors {
            restored.coAuthors = coAuthors
            if !coAuthors.isEmpty {
                restored.showCoAuthoredBy = true
            }
        }
        return restored
    }

    /// Loads a commit, classifying a failure as `operation`'s.
    private func loadCommit(_ sha: String, in repository: RepositoryModel, operation: OperationKind) async throws(OperationError) -> Commit {
        let gitRepository = repository.gitRepository
        let record = repository.record
        let result: Result<Commit?, OperationError> = await repository.environment.withRuntimes {
            do {
                return .success(try await getCommit(gitRepository, sha))
            } catch {
                return .failure(await classifyLoadFailure(error, kind: operation, record: record))
            }
        }
        switch result {
        case .success(let commit?):
            return commit
        case .success(nil):
            throw OperationError(.precondition("Could not load commit: '\(sha)'"), operation: operation, repositoryID: repository.id)
        case .failure(let error):
            throw error
        }
    }
}

private let notLatestCommitMessage = "Only the latest commit on the branch can be undone."
private let pushedCommitMessage = "Only commits that haven't been pushed can be undone."

// MARK: - Checks made with the lane held

/// Fails unless HEAD is still `sha` and no merge, rebase, or similar is in
/// progress, so an undo never resets a commit other than the one the user
/// saw, and the commit is still unpushed. A rebase's state Espalier can't
/// continue or abort, alone, offers to clear it and run `retry`.
@concurrent
private func requireUnchangedHistory(
    at sha: String,
    tip: Tip,
    operation: OperationKind,
    repositoryID: RepositoryID,
    retry: any RetryableOperation,
    in ctx: OperationContext
) async throws {
    try await requireNothingInProgressOnDisk(
        operation,
        refusal: "Resolve conflicts to continue.",
        retry: retry,
        repositoryID: repositoryID,
        in: ctx
    )
    guard let head = try await resolveHEAD(ctx.repository), JSCompat.strictEquals(head, sha) else {
        throw OperationError(.precondition(notLatestCommitMessage), operation: operation, repositoryID: repositoryID)
    }
    let localCommits = await loadLocalCommitSHAs(ctx.repository, tip: tip)
    guard localCommits.contains(where: { JSCompat.strictEquals($0, sha) }) else {
        throw OperationError(.precondition(pushedCommitMessage), operation: operation, repositoryID: repositoryID)
    }
}

/// Fails unless `sha` is an ancestor of HEAD (not HEAD itself) with only
/// unpushed commits after it; `sha` itself may be pushed. Refused while an
/// operation is in progress, as `requireUnchangedHistory` is.
@concurrent
private func requireResettable(
    to sha: String,
    tip: Tip,
    repositoryID: RepositoryID,
    retry: any RetryableOperation,
    in ctx: OperationContext
) async throws {
    try await requireNothingInProgressOnDisk(
        .resetToCommit,
        refusal: "Resolve conflicts to continue.",
        retry: retry,
        repositoryID: repositoryID,
        in: ctx
    )
    let ancestry = try await git(
        ["merge-base", "--is-ancestor", "--end-of-options", sha, "HEAD"],
        ctx.repository.path,
        "isAncestor",
        options: GitExecutionOptions(successExitCodes: [0, 1])
    )
    guard ancestry.exitCode == 0 else {
        throw OperationError(.precondition("The commit isn't on the current branch."), operation: .resetToCommit, repositoryID: repositoryID)
    }
    // The commits the reset takes off the branch; local commits are at most
    // `commitBatchSize`, as the refresh loads them.
    let range = try await git(
        ["rev-list", "--max-count=\(commitBatchSize + 1)", revRange(sha, "HEAD"), "--"],
        ctx.repository.path,
        "resetRange"
    )
    let discarded = JSCompat.split(JSCompat.trim(range.stdout), "\n").filter { !$0.isEmpty }
    guard !discarded.isEmpty else {
        throw OperationError(.precondition("The branch is already at this commit."), operation: .resetToCommit, repositoryID: repositoryID)
    }
    let localCommits = await loadLocalCommitSHAs(ctx.repository, tip: tip).exactSet
    guard discarded.allSatisfy({ localCommits.contains(ExactString($0)) }) else {
        throw OperationError(
            .precondition("Only commits that haven't been pushed can be reset."),
            operation: .resetToCommit,
            repositoryID: repositoryID
        )
    }
}

/// HEAD's commit, or nil on an unborn branch.
private func resolveHEAD(_ repository: Repository) async throws -> String? {
    let result = try await git(
        ["rev-parse", "--verify", "--quiet", "HEAD^{commit}"],
        repository.path,
        "resolveHEAD",
        options: GitExecutionOptions(successExitCodes: [0, 1])
    )
    let sha = JSCompat.trim(result.stdout)
    return result.exitCode == 0 && !sha.isEmpty ? sha : nil
}

// MARK: - Undoing the first commit

/// Makes the branch unborn again, keeping every file as an untracked one.
///
/// What are we doing here? The state of the working directory here is
/// rather important, because we want to ensure that any deleted files are
/// restored to your working directory for the next stage. Doing doing a
/// `git checkout -- .` here isn't suitable because we should preserve the
/// other working directory changes.
///
/// `git checkout HEAD --` always gets paths, an empty index isn't unstaged
/// (git refuses), and a vanished repository reads as missing.
@concurrent
private func undoFirstCommit(_ repository: Repository, operation: OperationKind, repositoryID: RepositoryID) async throws {
    guard let status = try await getStatus(repository) else {
        throw OperationError(.missingRepository, operation: operation, repositoryID: repositoryID)
    }

    let deletedFilePaths = status.workingDirectory.files.filter { $0.status.kind == .deleted }.map(\.path)
    if !deletedFilePaths.isEmpty {
        try await checkoutPaths(repository, deletedFilePaths)
    }

    // Now that we have the working directory changes, as well the restored
    // deleted files, we can remove the HEAD ref to make the current branch
    // disappear
    try await deleteRef(repository, "HEAD", "Reverting first commit")

    // Finally, ensure any changes in the index are unstaged. This ensures all
    // files in the repository will be untracked.
    let staged = try await git(["ls-files", "--cached", "-z"], repository.path, "undoFirstCommit")
    if !staged.stdoutData.isEmpty {
        try await unstageAllFiles(repository)
    }
}

// MARK: - Co-authors

/// A commit's message as the draft takes it.
struct RestoredMessage: Sendable, Equatable {
    let summary: String
    let description: String
    /// The co-authors from its trailers; nil when it has none (the draft's
    /// stay).
    let coAuthors: [Author]?
}

/// A commit's message with its co-authors (`Commit.coAuthors`) taken out of
/// the body (`Commit.bodyNoCoAuthors`), for the draft after Undo Commit or
/// when amending. A co-author already in the draft with the same name and
/// email keeps its username.
func restoredMessage(_ commit: Commit, existingCoAuthors: [Author]) -> RestoredMessage {
    guard !commit.coAuthors.isEmpty else {
        return RestoredMessage(summary: commit.summary, description: commit.body, coAuthors: nil)
    }

    let known = existingCoAuthors.compactMap { author -> KnownAuthor? in
        if case .known(let known) = author { known } else { nil }
    }
    let coAuthors = commit.coAuthors.map { coAuthor -> Author in
        let existing = known.first { known in
            JSCompat.strictEquals(known.name, coAuthor.name)
                && JSCompat.strictEquals(known.email, coAuthor.email)
                && known.username != nil
        }
        return .known(existing ?? KnownAuthor(name: coAuthor.name, email: coAuthor.email, username: nil))
    }

    return RestoredMessage(summary: commit.summary, description: JSCompat.trim(commit.bodyNoCoAuthors), coAuthors: coAuthors)
}
