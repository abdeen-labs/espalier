// Ported from desktop's assisted commit draft (desktop#22986 and #22991):
// app/src/lib/stores/app-store.ts (_createCopilotAssistedCommits and its
// push), app/src/models/assisted-commit-run.ts, and commit-mode-storage.ts.
//
// - The planner is the commit message feature's model and consent, on the
//   bring-your-own-key providers; there's no separate preference.
// - The run is one commit operation (`perform`), so it holds the local lane
//   from capture to acceptance and nothing else writes the repository
//   meanwhile. Its Stop cancels at the next safe boundary (or aborts a
//   running hook); acceptance can't be stopped.
// - The push after the commits is the ordinary push of the branch, its own
//   operation; a failed one keeps the commits and offers Retry Push.

import AIKit
import EspalierSupport
import Foundation
import GitHubKit
import GitKit
import os

private let logger = Log.logger(category: "assisted-commit")

/// How the next commit is made.
public enum CommitMode: String, Sendable, Hashable, CaseIterable {
    /// From the message the user writes.
    case manual
    /// Planned with AI: the selected changes split into commits, each with
    /// its own message.
    case assisted
}

/// What an assisted commit run is doing.
public enum AssistedCommitPhase: Sendable, Equatable {
    /// Reading the selected changes.
    case preparing
    /// Asking the model for a plan of `changes` units.
    case planning(changes: Int)
    /// Asking the model for one message for everything, after a split that
    /// couldn't be committed in its order.
    case summarizing(changes: Int)
    /// Checking the plan and every commit's tree.
    case validating
    /// Making commit `index` (zero-based) of `total`.
    case committing(index: Int, total: Int, title: String)
    /// Checking the commits and keeping them.
    case finishing
    /// Taking the run's commits back off the branch.
    case rollingBack
    /// Pushing the branch.
    case pushing
}

/// The assisted commit run, as the composer shows it.
public enum AssistedCommitState: Sendable, Equatable {
    case idle
    case running(AssistedCommitPhase)
    /// The last run failed; nothing of it was kept.
    case failed(OperationError)
    /// The last run failed and couldn't undo all of itself, because
    /// something else changed the branch or the index:
    /// `retryAssistedCommitRecovery()` tries again. New assisted commits wait
    /// for it.
    case recoveryNeeded(OperationError)
    /// The commits were made, and pushing them failed:
    /// `retryAssistedCommitPush()` pushes again.
    case pushFailed(OperationError)

    /// Whether a run is going.
    public var isRunning: Bool {
        if case .running = self { true } else { false }
    }
}

/// Assisted commits that were made.
public struct AssistedCommitResult: Sendable, Equatable {
    /// Their full SHAs, oldest first.
    public let commits: [String]
    /// The push after them, when it ran and succeeded.
    public let push: PushOutcome?

    public init(commits: [String], push: PushOutcome?) {
        self.commits = commits
        self.push = push
    }
}

extension CommitModel {
    // MARK: Preferences

    /// The `UserDefaults` key of a repository's commit mode.
    static func commitModeKey(_ id: RepositoryID) -> String {
        "commit-mode-\(id)"
    }

    /// The `UserDefaults` key of whether a repository's assisted commits
    /// are pushed.
    static func assistedCommitPushKey(_ id: RepositoryID) -> String {
        "assisted-commit-push-\(id)"
    }

    func loadAssistedCommitPreferences() {
        guard let repository else {
            return
        }
        let store = PreferenceStore(repository.environment.defaults.defaults)
        mode = (store.defaults.string(forKey: Self.commitModeKey(repository.id))).flatMap(CommitMode.init(rawValue:)) ?? .manual
        pushesAfterAssistedCommits = store.getBoolean(Self.assistedCommitPushKey(repository.id), false)
    }

    /// Chooses how the next commit is made, for this repository from now
    /// on. The draft stays as it is.
    public func setMode(_ mode: CommitMode) {
        guard let repository, mode != self.mode else {
            return
        }
        self.mode = mode
        repository.environment.defaults.defaults.set(mode.rawValue, forKey: Self.commitModeKey(repository.id))
    }

    /// Chooses whether assisted commits are pushed once they're made, for
    /// this repository from now on.
    public func setPushesAfterAssistedCommits(_ pushes: Bool) {
        guard let repository, pushes != pushesAfterAssistedCommits else {
            return
        }
        pushesAfterAssistedCommits = pushes
        PreferenceStore(repository.environment.defaults.defaults).setBoolean(Self.assistedCommitPushKey(repository.id), pushes)
    }

    // MARK: Committing with AI

    /// Splits the included changes (every file whose selection isn't none)
    /// into commits with AI and makes them, then pushes them when
    /// `pushesAfterAssistedCommits` is on.
    ///
    /// The model (the commit message feature's) sees only the frozen
    /// selection: opaque IDs for its hunks and whole changes, and their
    /// diffs. Its plan is checked, and every commit's tree made, before
    /// the first commit; each commit is made with the commit options
    /// (hooks, sign-off) and the co-authors, verified, and put on the
    /// branch with a compare-and-swap. A failure or Stop takes the run's
    /// commits back off and puts the index back; the working tree is never
    /// written. With nothing included and Allow Empty Commit on, it makes
    /// one commit named "Empty commit" without asking a model.
    ///
    /// The draft is never touched. On success Allow Empty Commit resets and
    /// partial line selections drop, as for any commit.
    ///
    /// - Throws: `.busy` while a run, a generation, or another local
    ///   operation runs; `.precondition` while amending, before a rollback
    ///   that needs retrying, with nothing to commit, and for the
    ///   repository's rules; the commit gates' `.confirmationRequired`
    ///   (unknown co-authors, hidden files, large files, conflict markers);
    ///   the AI gates (`.ai(.disabled)`, `.ai(.noProvider)`,
    ///   `.ai(.modelSelectionRequired)`, `.ai(.consentRequired)`);
    ///   `cancelled` when stopped; the run's failure, also kept in
    ///   `assisted`. A failed push doesn't throw: it's kept in `assisted`
    ///   as `.pushFailed`.
    @discardableResult
    public func commitAssisted(confirmed: Set<ConfirmationKind> = []) async throws(OperationError) -> AssistedCommitResult {
        guard let repository, let app = repository.app else {
            throw OperationError(.precondition("The repository is no longer in the list."), operation: .commit)
        }
        let repositoryID = repository.id
        func fail(_ reason: OperationError.Reason) -> OperationError {
            OperationError(reason, operation: .commit, repositoryID: repositoryID, gitContext: .commit)
        }

        switch assisted {
        case .running:
            throw fail(.busy(.commit))
        case .recoveryNeeded:
            throw fail(.precondition("Retry undoing the last assisted commit first."))
        case .idle, .failed, .pushFailed:
            break
        }
        if amending != nil {
            throw fail(.precondition("Stop amending to commit with AI."))
        }
        if repository.ai.commitMessageGeneration == .generating {
            throw fail(.busy(.generateCommitMessage))
        }
        if case .rebase? = repository.gitState.inProgress {
            throw fail(.precondition(repository.operations.current?.conflictsMessage ?? "Resolve conflicts to continue rebasing."))
        }
        if let ruleFailure = await repository.gitHub.repoRuleCommitFailure() {
            throw fail(.precondition(ruleFailure))
        }

        let files = repository.changes.workingDirectory.files.filter(\.isIncludedInCommit)
        let isEmptyCommit = files.isEmpty
        if isEmptyCommit, !options.allowEmpty {
            throw fail(.precondition(
                repository.changes.workingDirectory.files.isEmpty ? "There are no changes to commit." : "Select one or more files to commit"
            ))
        }
        try checkCoAuthorAndFilterGates(in: repository, confirmed: confirmed)
        try await checkFileGates(files, in: repository, confirmed: confirmed)

        // An empty commit asks no model.
        let selection: ResolvedModelSelection?
        if isEmptyCommit {
            selection = nil
        } else {
            let resolved = try app.ai.requireModel(for: .commitMessageGeneration, operation: .commit, repositoryID: repositoryID)
            try app.ai.requireConsent(for: .commitMessageGeneration, resolved, operation: .commit, repositoryID: repositoryID)
            selection = resolved
        }

        let request = AssistedCommitRequest(
            files: files,
            trailers: coAuthorTrailers(in: repository),
            skipHooks: options.skipHooks,
            signOff: options.signOff,
            allowEmpty: isEmptyCommit
        )
        let rules = CommitMessageGenerator.commitMessageRules(repository.gitHub.repoRules)
        let environment = repository.environment
        let record = repository.record
        let pushes = pushesAfterAssistedCommits
        let ai = app.ai

        assistedRunID &+= 1
        let runID = assistedRunID
        assisted = .running(.preparing)
        let descriptor = OperationDescriptor(kind: .commit, gitContext: .commit, refreshOptions: .clearPartialSelections)
        let commits: [String]
        do {
            commits = try await repository.perform(descriptor) { [weak self] ctx in
                do {
                    return try await Self.run(
                        request,
                        selection: selection,
                        rules: rules,
                        environment: environment,
                        in: ctx,
                        onPhase: { phase in self?.setAssistedPhase(phase, runID: runID) },
                        isStillAllowed: { [ai] model in
                            guard let model else {
                                return true
                            }
                            return ai.isEnabled && ai.hasConsent(for: .commitMessageGeneration, model)
                        }
                    )
                } catch {
                    throw await Self.operationError(error, record: record)
                }
            }
        } catch {
            settleFailedRun(error)
            throw error
        }

        options.allowEmpty = false
        await repository.awaitOperationRefresh(covering: .status)

        guard pushes else {
            assisted = .idle
            return AssistedCommitResult(commits: commits, push: nil)
        }
        return AssistedCommitResult(commits: commits, push: await pushAssistedCommits())
    }

    /// Stops the run at its next safe boundary (a hook that's running is
    /// stopped); what it made is undone. Not once it's keeping the commits,
    /// nor while it pushes.
    public func cancelAssistedCommit() {
        guard case .running(let phase) = assisted, phase != .finishing, phase != .pushing, phase != .rollingBack,
              let repository, let operation = repository.localOperation, operation.kind == .commit
        else {
            return
        }
        repository.stopOperation(operation.id)
    }

    /// Tries again to undo the run that couldn't undo all of itself, once
    /// whatever changed the branch or the index is resolved. Never plans,
    /// commits, or pushes.
    public func retryAssistedCommitRecovery() async throws(OperationError) {
        guard case .recoveryNeeded = assisted, let transaction = assistedRecovery, let repository else {
            return
        }
        let record = repository.record
        assisted = .running(.rollingBack)
        do {
            try await repository.perform(OperationDescriptor(kind: .commit, gitContext: .commit)) { _ in
                do {
                    _ = try await transaction.rollback()
                } catch {
                    throw await Self.operationError(error, record: record)
                }
            }
        } catch {
            if let recovery = Self.recovery(in: error), recovery.needsAttention {
                assistedRecovery = recovery.retry ?? transaction
                assisted = .recoveryNeeded(error)
            } else {
                assistedRecovery = nil
                assisted = .failed(error)
            }
            throw error
        }
        assistedRecovery = nil
        assisted = .idle
    }

    /// Pushes the assisted commits again after their push failed. Plans and
    /// commits nothing.
    @discardableResult
    public func retryAssistedCommitPush() async -> PushOutcome? {
        guard case .pushFailed = assisted else {
            return nil
        }
        return await pushAssistedCommits()
    }

    /// Forgets the last run's failure, or its failed push. A rollback that
    /// needs retrying stays.
    public func dismissAssistedCommitFailure() {
        switch assisted {
        case .failed, .pushFailed:
            assisted = .idle
        case .idle, .running, .recoveryNeeded:
            break
        }
    }

    // MARK: The run

    /// The run, inside the commit operation: capture, plan (or the empty
    /// commit's plan), validate, execute, and accept. Cancelled before
    /// acceptance, it rolls back.
    private static func run(
        _ request: AssistedCommitRequest,
        selection: ResolvedModelSelection?,
        rules: [CommitMessageRule],
        environment: AppEnvironment,
        in ctx: OperationContext,
        onPhase: @escaping @MainActor @Sendable (AssistedCommitPhase) -> Void,
        isStillAllowed: @escaping @MainActor @Sendable (ResolvedModelSelection?) -> Bool
    ) async throws -> [String] {
        let cancellation = AssistedCommitCancellation()
        let options = AssistedCommitOptions(
            cancellation: cancellation,
            onProgress: { progress in
                await MainActor.run {
                    switch progress {
                    case .capturing:
                        onPhase(.preparing)
                    case .validating:
                        onPhase(.validating)
                    case .committing(let index, let total, let title):
                        onPhase(.committing(index: index, total: total, title: title))
                    case .committed:
                        break
                    case .rollingBack:
                        onPhase(.rollingBack)
                    }
                }
            },
            onHookProgress: ctx.hooks.onHookProgress,
            onHookFailure: ctx.hooks.onHookFailure,
            onTerminalOutputAvailable: ctx.hooks.onTerminalOutputAvailable
        )

        let snapshot = try await AssistedCommitSnapshot.capture(ctx.repository, request, options: options)
        let transaction: AssistedCommitTransaction
        do {
            let validated: ValidatedAssistedCommitPlan
            if let selection {
                let model = try await CommitMessageGenerator.modelRequest(selection, secrets: environment.secrets)
                let instructions = await CommitMessageGenerator.readRepositoryInstructions(repositoryPath: ctx.repository.path)
                // AI may have been turned off, or the consent withdrawn,
                // while the changes were read.
                guard isStillAllowed(selection) else {
                    throw AssistedCommitError(.cancelled, "AI features were turned off.")
                }
                let session = environment.aiSession
                validated = try await AssistedCommitPlanner.plan(
                    snapshot,
                    options: options,
                    onStep: { step in
                        await MainActor.run {
                            switch step {
                            case .planning(let changes): onPhase(.planning(changes: changes))
                            case .summarizing(let changes): onPhase(.summarizing(changes: changes))
                            }
                        }
                    },
                    propose: { analysis, mode in
                        try await AIKit.proposeAssistedCommitPlan(
                            analysis,
                            mode: mode,
                            model: model,
                            commitMessageRules: rules,
                            repositoryInstructions: instructions,
                            session: session
                        )
                    }
                )
            } else {
                let plan = try await snapshot.singleCommitPlan(reason: .emptySelection, title: "Empty commit")
                validated = try await snapshot.validate(plan, options: options)
            }
            transaction = try await snapshot.execute(validated, options: options)
        } catch {
            try? await snapshot.dispose()
            throw error
        }

        // Keeping the commits can't be stopped part way.
        ctx.stop.setStopper({ false }, canStop: false)
        onPhase(.finishing)
        do {
            if cancellation.isCancelled || Task.isCancelled {
                throw AssistedCommitError(.cancelled, "The assisted commit was cancelled.")
            }
            try await transaction.accept(cancellation: cancellation)
        } catch {
            onPhase(.rollingBack)
            let failure = AssistedCommitError.wrappingForRecovery(error)
            // A rollback something else got in the way of throws its own
            // error, with the recovery to retry.
            let recovery = try await transaction.rollback()
            throw AssistedCommitError(failure.code, failure.message, underlying: failure.underlying, recovery: recovery)
        }
        return transaction.commits
    }

    /// Pushes the branch after assisted commits: the ordinary push, its own
    /// operation. A failure is kept as `.pushFailed`.
    private func pushAssistedCommits() async -> PushOutcome? {
        guard let repository else {
            return nil
        }
        assisted = .running(.pushing)
        do {
            let outcome = try await repository.sync.push()
            if case .publishRepositoryRequired = outcome {
                assisted = .pushFailed(OperationError(
                    .precondition("This repository has no remote to push to. Publish it first."),
                    operation: .push,
                    repositoryID: repository.id
                ))
                return nil
            }
            assisted = .idle
            return outcome
        } catch {
            assisted = error.isCancellation ? .idle : .pushFailed(error)
            return nil
        }
    }

    /// Shows a run's phase, while it's the current run.
    private func setAssistedPhase(_ phase: AssistedCommitPhase, runID: UInt64) {
        guard runID == assistedRunID, assisted.isRunning, assisted != .running(phase) else {
            return
        }
        assisted = .running(phase)
    }

    /// Keeps a failed run's outcome: a recovery to retry, a failure to show,
    /// or nothing for a cancelled or refused run.
    private func settleFailedRun(_ error: OperationError) {
        if let recovery = Self.recovery(in: error), recovery.needsAttention {
            assistedRecovery = recovery.retry
            assisted = .recoveryNeeded(error)
            logger.error("An assisted commit couldn't undo all of itself")
            return
        }
        if error.isCancellation {
            assisted = .idle
            return
        }
        if case .busy = error.reason {
            assisted = .idle
            return
        }
        assisted = .failed(error)
    }

    // MARK: Errors

    /// The recovery an error carries, through its causes.
    static func recovery(in error: any Error) -> AssistedCommitRecovery? {
        var current: (any Error)? = error
        var depth = 0
        while let error = current, depth < 8 {
            if let error = error as? AssistedCommitError {
                if let recovery = error.recovery {
                    return recovery
                }
                current = error.underlying
            } else if let error = error as? OperationError {
                current = error.underlying
            } else {
                return nil
            }
            depth += 1
        }
        return nil
    }

    /// The `OperationError` for what a run threw, keeping the error (with
    /// its recovery) as the underlying one: git's own failure classified as
    /// a commit's, the AI's as an AI failure, the run's checks as what the
    /// user should do.
    static func operationError(_ error: any Error, record: RepositoryRecord) async -> OperationError {
        func make(_ reason: OperationError.Reason, recoveries: [Recovery] = []) -> OperationError {
            OperationError(reason, operation: .commit, repositoryID: record.id, underlying: error, gitContext: .commit, recoveries: recoveries)
        }
        switch error {
        case let error as OperationError:
            return error
        case let error as AssistedCommitError:
            if error.code == .cancelled {
                return make(.cancelled(.userCancelled))
            }
            // Git's own failure (a hook, signing, a filter) says the most.
            if let gitError = error.underlying as? GitError {
                let classified = await ErrorClassifier.classify(
                    gitError,
                    descriptor: OperationDescriptor(kind: .commit, lanes: [], gitContext: .commit),
                    record: record,
                    context: ClassificationContext()
                )
                return make(classified.reason, recoveries: classified.recoveries)
            }
            switch error.code {
            case .cancelled:
                return make(.cancelled(.userCancelled))
            case .commitFailed, .hookAborted:
                return make(.other(error.message))
            case .recoveryFailed, .cleanupFailed:
                return make(.other(error.message))
            case .selectionChanged, .repositoryChanged, .indexChanged, .unsafeSelection, .unsafePlan, .invalidPlan, .busy, .disposed:
                return make(.precondition(error.message))
            }
        case let error as AIAssistedCommitError:
            switch error.code {
            case .cancelled:
                return make(.cancelled(.userCancelled))
            case .emptySelection, .promptTooLarge:
                return make(.precondition(error.message))
            case .invalidResponse:
                return make(.ai(.provider(title: "The Model's Plan Can't Be Used", message: error.message)))
            }
        case let error as AssistedCommitPlanRefused:
            return make(.ai(.provider(title: "The Model Didn't Plan the Commits", message: error.reason)))
        default:
            let classified = await aiOperationError(error, operation: .commit, record: record, cancelled: false)
            return make(classified.reason, recoveries: classified.recoveries)
        }
    }
}

extension AssistedCommitError {
    /// `error` as the run's failure, to carry rollback's outcome.
    static func wrappingForRecovery(_ error: any Error) -> AssistedCommitError {
        if let error = error as? AssistedCommitError {
            return error
        }
        return AssistedCommitError(.commitFailed, "The assisted commits couldn't be kept.", underlying: error)
    }
}
