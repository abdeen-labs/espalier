// The gates are in CommitGates.swift; amending, undoing, and resetting in
// UndoAndReset.swift.

import EspalierSupport
import Foundation
import GitKit
import Observation

/// The commit message being written. In memory only, lost on quit.
public struct CommitDraft: Sendable, Equatable {
    public var summary = ""
    public var description = ""
    /// Co-authors, made trailers when the repository is on GitHub.
    public var coAuthors: [Author] = []
    /// Whether the co-author field is showing.
    public var showCoAuthoredBy = false
    /// Whether the message was generated and not edited since.
    public var generatedByAI = false

    public init(
        summary: String = "",
        description: String = "",
        coAuthors: [Author] = [],
        showCoAuthoredBy: Bool = false,
        generatedByAI: Bool = false
    ) {
        self.summary = summary
        self.description = description
        self.coAuthors = coAuthors
        self.showCoAuthoredBy = showCoAuthoredBy
        self.generatedByAI = generatedByAI
    }

    /// Whether the summary or the description has more than whitespace.
    public var hasMessage: Bool {
        !isEmptyOrWhitespace(summary) || !isEmptyOrWhitespace(description)
    }
}

/// Options for the next commit, in memory.
public struct CommitOptions: Sendable, Equatable {
    /// Skip the pre-commit and commit-msg hooks (`--no-verify`).
    public var skipHooks = false
    /// Add a Signed-off-by trailer (`--signoff`).
    public var signOff = false
    /// Allow a commit with no changes (`--allow-empty`); resets after each
    /// commit.
    public var allowEmpty = false

    public init(skipHooks: Bool = false, signOff: Bool = false, allowEmpty: Bool = false) {
        self.skipHooks = skipHooks
        self.signOff = signOff
        self.allowEmpty = allowEmpty
    }
}

/// A commit that was made.
public struct CommitResult: Sendable, Equatable {
    /// The commit's full SHA.
    public let sha: String
    /// Whether it amended the previous tip.
    public let amended: Bool

    public init(sha: String, amended: Bool) {
        self.sha = sha
        self.amended = amended
    }
}

/// The commit message, commit options, amend mode, and committing.
@MainActor @Observable
public final class CommitModel: RepositoryFeature {
    public var draft = CommitDraft()
    public var options = CommitOptions()
    /// The commit being amended, while amending.
    public private(set) var amending: Commit?
    /// The tip of the current branch's upstream when amending started, which
    /// the amend is recorded with for the force push recommendation
    /// (`recordRewrite`).
    @ObservationIgnored private var amendingUpstreamTip: String?
    /// The newest local commit (the first of `gitState.localCommitSHAs`),
    /// loaded for the Changes column's last-commit row and Undo.
    /// MostRecentLocalCommit.swift loads it after refreshes.
    public internal(set) var mostRecentLocalCommit: Commit?

    /// The message the user was writing when amending started, set aside
    /// while the amended commit's message is in the draft; it comes back
    /// when amending stops or the amend is committed.
    private(set) var setAsideDraft: CommitDraft?
    /// The draft as amending loaded it, to tell an edited one apart.
    @ObservationIgnored var draftLoadedForAmend: CommitDraft?

    @ObservationIgnored weak var repository: RepositoryModel?
    /// Loads `mostRecentLocalCommit`, by SHA.
    @ObservationIgnored let mostRecentLocalCommitLoads = LatestTask<String>()

    init() {}

    func attach(to repository: RepositoryModel) {
        self.repository = repository
    }

    /// Whether quitting would lose a commit message the user wrote: the
    /// summary or description has text (unless it's the message amending
    /// loaded, unedited), or a message is set aside while amending. The app
    /// asks before quitting then (`AppModel.repositoriesWithUnfinishedDrafts`).
    public var hasUnfinishedDraft: Bool {
        if setAsideDraft?.hasMessage == true {
            return true
        }
        guard draft.hasMessage else {
            return false
        }
        if amending != nil, let loaded = draftLoadedForAmend, draft == loaded {
            return false
        }
        return true
    }

    // MARK: Committing

    /// Commits the included changes (every file whose selection isn't
    /// none), amending while `amending` is set.
    ///
    /// Runs the gates first, in order: something to commit and a summary (or
    /// the single-file placeholder, "Create/Update/Delete <file>"), unknown
    /// co-authors, included files the filter hides, files over 100 MB that
    /// Git LFS doesn't track, then included files with conflict markers.
    ///
    /// On success: leaves amend mode, clears allow-empty, clears the summary
    /// and description (co-authors stay; a message set aside by amending comes
    /// back), and waits for the status part of the refresh, dropping partial
    /// line selections. An amend that changed the tip records the branch as
    /// rewritten (it needs a force push).
    ///
    /// - Throws: `.precondition` when there's nothing to commit, and while a
    ///   rebase is in progress; `.confirmationRequired` for a gate;
    ///   `busy(.commit)` while another local operation runs;
    ///   `cancelled(.hookAborted)` when the user aborts a failed hook; the
    ///   classified git error otherwise (titled "Commit failed").
    public func commit(confirmed: Set<ConfirmationKind> = []) async throws(OperationError) -> CommitResult {
        guard let repository else {
            throw OperationError(.precondition("The repository is no longer in the list."), operation: .commit)
        }
        // A submodule with only uncommitted changes inside it shows as
        // excluded whatever its selection, and git has nothing to commit for
        // it: committing it would fail with "no changes added to commit".
        let files = repository.changes.workingDirectory.files.filter(\.isIncludedInCommit)
        let context = try await checkGates(files, in: repository, confirmed: confirmed)
        try await checkFileGates(files, in: repository, confirmed: confirmed)

        let options = options
        let amending = amending
        let amendingUpstreamTip = amendingUpstreamTip
        let descriptor = OperationDescriptor(kind: .commit, gitContext: .commit, refreshOptions: .clearPartialSelections)
        let sha = try await repository.perform(descriptor) { ctx in
            let message = try await formatCommitMessage(ctx.repository, context)
            let shortSHA = try await createCommit(ctx.repository, message, files, CreateCommitOptions(
                amend: amending != nil,
                noVerify: options.skipHooks,
                signOff: options.signOff,
                allowEmpty: options.allowEmpty,
                onHookProgress: ctx.hooks.onHookProgress,
                onHookFailure: ctx.hooks.onHookFailure,
                onTerminalOutputAvailable: ctx.hooks.onTerminalOutputAvailable
            ))
            return await resolveCommitSHA(ctx.repository, shortSHA)
        }

        self.amending = nil
        self.amendingUpstreamTip = nil
        self.options.allowEmpty = false
        draft.summary = ""
        draft.description = ""
        draft.generatedByAI = false
        draftLoadedForAmend = nil
        if let setAside = setAsideDraft {
            draft = setAside
            setAsideDraft = nil
        }

        await repository.awaitOperationRefresh(covering: .status)

        // An amend that changed the tip needs a force push.
        if let amended = amending, let branch = repository.gitState.tip.branch,
           !JSCompat.strictEquals(branch.tip.sha, amended.sha) {
            await repository.operations.recordRewrite(of: branch, previousTip: amended.sha, upstreamTip: amendingUpstreamTip)
        }
        return CommitResult(sha: sha, amended: amending != nil)
    }

    // MARK: Amend mode

    /// Leaves amend mode. The amended commit's message stays in the draft,
    /// unless the user had a message of their own when amending started: that
    /// one comes back.
    public func stopAmending() {
        amending = nil
        amendingUpstreamTip = nil
        draftLoadedForAmend = nil
        if let setAside = setAsideDraft {
            draft = setAside
            setAsideDraft = nil
        }
    }

    /// Sets the commit to amend (`startAmending` calls it), noting where the
    /// current branch's upstream is as amending starts.
    func setAmending(_ commit: Commit?) {
        amending = commit
        amendingUpstreamTip = commit == nil ? nil : repository.flatMap { repository in
            repository.gitState.tip.branch.flatMap { repository.operations.upstreamTip(of: $0) }
        }
    }

    /// Sets the user's message aside while amending loads the commit's.
    func setAsideDraftForAmending() {
        if setAsideDraft == nil, amending == nil, draft.hasMessage {
            setAsideDraft = draft
        }
    }

    func repositoryDidRefresh(_ update: RefreshUpdate) {
        if update.applied != .status {
            // The pass's other scopes load the local commits.
            loadMostRecentLocalCommit()
        }
        // Amend mode ends when the tip moves away from the commit being
        // amended.
        guard let amending, update.applied.contains(.status), let repository else {
            return
        }
        if let sha = repository.gitState.tip.sha, !JSCompat.strictEquals(sha, amending.sha) {
            stopAmending()
        }
    }

    func repositoryPathDidChange(keepingSharedState: Bool) {
        mostRecentLocalCommitLoads.cancel()
        mostRecentLocalCommit = nil
    }
}

/// Whether a string is empty or JavaScript whitespace only.
func isEmptyOrWhitespace(_ string: String) -> Bool {
    string.unicodeScalars.allSatisfy(JSCompat.isWhitespace)
}

/// The full SHA of the commit `createCommit` reported (git prints an
/// abbreviated one). Falls back to the abbreviation if git can't resolve it.
@concurrent
func resolveCommitSHA(_ repository: Repository, _ shortSHA: String) async -> String {
    guard !shortSHA.isEmpty else {
        return (try? await getCommit(repository, "HEAD"))?.sha ?? shortSHA
    }
    let result = try? await git(
        ["rev-parse", "--verify", "--quiet", "--end-of-options", "\(shortSHA)^{commit}"],
        repository.path,
        "resolveCommitSHA",
        options: GitExecutionOptions(successExitCodes: [0, 1])
    )
    guard let result, result.exitCode == 0 else {
        return shortSHA
    }
    let sha = JSCompat.trim(result.stdout)
    return sha.isEmpty ? shortSHA : sha
}
