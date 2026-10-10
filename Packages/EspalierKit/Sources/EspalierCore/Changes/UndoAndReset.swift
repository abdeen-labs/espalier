import EspalierSupport
import Foundation
import GitKit
import os

private let logger = Log.logger(category: "commit")

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
        try await app.requireRepository(repositoryID, for: kind).commit.reset(to: commit, confirmed: self.confirmed.union(confirmed))
        return .nothing
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

        let restored = await restoredDraft(for: commit, in: repository)
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

        draft = await restoredDraft(for: commit, in: repository)
        await repository.awaitOperationRefresh(covering: .status)
    }

    // MARK: Resetting

    /// Resets the branch to `commit`, keeping every change since in the
    /// working directory (`git reset <commit>`, mixed).
    ///
    /// `commit` must be below HEAD with only unpushed commits after it (it may
    /// itself be the first pushed one). Returns after the status refresh.
    ///
    /// - Throws: `.confirmationRequired(.resetWithChanges)` when there are
    ///   changes (no preference turns it off); `.precondition` when `commit`
    ///   is HEAD, isn't on the branch, has pushed commits after it, or an
    ///   operation is in progress.
    public func reset(to commit: Commit, confirmed: Set<ConfirmationKind> = []) async throws(OperationError) {
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

        // Warn the user if there are changes in the working directory
        if !repository.changes.workingDirectory.files.isEmpty, !confirmed.contains(.resetWithChanges) {
            throw OperationError(
                .confirmationRequired(.resetWithChanges(sha: commit.sha)),
                operation: .resetToCommit,
                repositoryID: repository.id
            )
        }

        let tip = repository.gitState.tip
        let repositoryID = repository.id
        let retry = ResetToCommitRetry(repositoryID: repositoryID, commit: commit, confirmed: confirmed)
        try await repository.perform(OperationDescriptor(kind: .resetToCommit)) { ctx in
            try await requireResettable(to: commit.sha, tip: tip, repositoryID: repositoryID, retry: retry, in: ctx)
            try await GitKit.reset(ctx.repository, .mixed, commit.sha)
        }
        await repository.awaitOperationRefresh(covering: .status)
    }

    // MARK: Messages

    /// The draft for a commit's message: its summary and body, and in GitHub
    /// repositories its `Co-Authored-By` trailers moved out of the body into
    /// the co-authors. Co-authors already in the draft stay when the commit
    /// has none.
    func restoredDraft(for commit: Commit, in repository: RepositoryModel) async -> CommitDraft {
        var restored = CommitDraft(
            summary: commit.summary,
            description: commit.body,
            coAuthors: draft.coAuthors,
            showCoAuthoredBy: draft.showCoAuthoredBy
        )
        // Let's be safe about this since it's untried waters.
        // If we can restore co-authors then that's fantastic
        // but if we can't we shouldn't be throwing an error,
        // let's just fall back to the old way of restoring the
        // entire message
        guard repository.record.gitHubRepository != nil else {
            return restored
        }
        let gitRepository = repository.gitRepository
        let existing = draft.coAuthors
        do {
            let loaded = try await repository.environment.withRuntimes {
                try await loadCommitAndCoAuthors(gitRepository, commit, existingCoAuthors: existing)
            }
            restored.summary = loaded.summary
            restored.description = loaded.description
            if let coAuthors = loaded.coAuthors {
                restored.coAuthors = coAuthors
                if !coAuthors.isEmpty {
                    restored.showCoAuthoredBy = true
                }
            }
        } catch {
            logger.error("Failed to restore commit and co-authors, falling back: \(error.localizedDescription, privacy: .public)")
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

/// `/^co-authored-by(.)\s(.*)/i`
private let coAuthorPattern = JSCompat.regex(
    "(?i)^co-authored-by(\(JSCompat.dot))\(JSCompat.whitespace)(\(JSCompat.dot)*)"
)

/// Attempt to restore both the commit message and any co-authors in it
/// after an undo operation.
///
/// This is a deceivingly simple task which complicated by the us wanting to
/// follow the heuristics of Git when finding, and parsing trailers.
@concurrent
func loadCommitAndCoAuthors(
    _ repository: Repository,
    _ commit: Commit,
    existingCoAuthors: [Author]
) async throws -> RestoredMessage {
    // git-interpret-trailers is really only made for working
    // with full commit messages so let's start with that
    let message = try await formatCommitMessage(repository, CommitContext(summary: commit.summary, description: commit.body))

    // Next we extract any co-authored-by trailers we
    // can find. We use interpret-trailers for this
    let foundTrailers = try await parseTrailers(repository, message)
    var coAuthorTrailers = foundTrailers.filter(isCoAuthoredByTrailer)

    // This is the happy path, nothing more for us to do
    if coAuthorTrailers.isEmpty {
        return RestoredMessage(summary: commit.summary, description: commit.body, coAuthors: nil)
    }

    // call interpret-trailers --unfold so that we can be sure each
    // trailer sits on a single line
    let unfolded = try await mergeTrailers(repository, message, [], unfold: true)
    var lines = JSCompat.split(unfolded, "\n")

    // We don't know (I mean, we're fairly sure) what the separator character
    // used for the trailer is so we call out to git to get all possibilities
    var separators: String?

    // We know that what we've got now is well formed so we can capture the leading
    // token, followed by the separator char and a single space, followed by the
    // value
    var extractedTrailers: [Trailer] = []

    // Iterate backwards from the unfolded message and look for trailers that we've
    // already seen when calling parseTrailers earlier.
    for index in lines.indices.reversed() {
        let line = lines[index]

        // Not a trailer line, we're sure of that
        guard let match = JSCompat.match(line, coAuthorPattern), let separator = match[1] else {
            continue
        }

        // Only shell out for separators if we really need them
        let knownSeparators: String
        if let separators {
            knownSeparators = separators
        } else {
            knownSeparators = try await getTrailerSeparatorCharacters(repository)
            separators = knownSeparators
        }

        if !JSCompat.includes(knownSeparators, separator) {
            continue
        }

        guard let trailer = parseSingleUnfoldedTrailer(line, separator) else {
            continue
        }

        // We already know that the key is Co-Authored-By so we only
        // need to compare by value. Let's see if we can find the thing
        // that we believe to be a trailer among what interpret-trailers
        // --parse told us was a trailer. This step is a bit redundant
        // but it ensure we match exactly with what Git thinks is a trailer
        guard let foundTrailerIndex = coAuthorTrailers.firstIndex(where: { JSCompat.strictEquals($0.value, trailer.value) }) else {
            continue
        }

        // We're running backwards
        extractedTrailers.insert(coAuthorTrailers[foundTrailerIndex], at: 0)

        // Remove the trailer that matched so that we can be sure
        // we're not picking it up again
        coAuthorTrailers.remove(at: foundTrailerIndex)

        // This line was a co-author trailer so we'll remove it to
        // make sure it doesn't end up in the restored commit body
        lines.remove(at: index)
    }

    // Get rid of the summary/title
    lines.removeFirst(min(2, lines.count))

    let newBody = JSCompat.trim(lines.joined(separator: "\n"))

    let extractedAuthors = extractedTrailers.map { GitAuthor.parse($0.value) }
    var newAuthors: [Author] = []

    // Last step, phew! The most likely scenario where we
    // get called is when someone has just made a commit and
    // either forgot to add a co-author or forgot to remove
    // someone so chances are high that we already have a
    // co-author which includes a username. If we don't we'll
    // add it without a username which is fine as well
    for extractedAuthor in extractedAuthors {
        // If GitAuthor failed to parse
        guard let extractedAuthor else {
            continue
        }

        let existing = existingCoAuthors.lazy.compactMap { author -> KnownAuthor? in
            if case .known(let known) = author { known } else { nil }
        }.first { known in
            JSCompat.strictEquals(known.name, extractedAuthor.name)
                && JSCompat.strictEquals(known.email, extractedAuthor.email)
                && known.username != nil
        }
        newAuthors.append(.known(existing ?? KnownAuthor(name: extractedAuthor.name, email: extractedAuthor.email, username: nil)))
    }

    return RestoredMessage(summary: commit.summary, description: newBody, coAuthors: newAuthors)
}
