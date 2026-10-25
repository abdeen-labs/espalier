// Ported from desktop/app/src/lib/stores/app-store.ts
//
// Commit message generation and conflict resolution, on AIKit with
// bring-your-own-key providers.
//
// - Consent is asked for per feature and provider host; its copy is the
//   disclosure's `reviewAdvice`.
// - "Always use AI when conflicts are detected" starts a round only in the
//   selected repository, once per round of conflicts, when the model
//   resolves and consent exists; otherwise the manual flow shows.
// - Failed and unattempted files can be retried on their own (AIKit keeps
//   the chunks that succeeded).

import AIKit
import EspalierSupport
import Foundation
import GitHubKit
import GitKit
import Observation
import os

private let logger = Log.logger(category: "ai")

/// Generating a commit message.
public enum CommitMessageGenerationState: Sendable, Equatable {
    case idle
    /// A message is being generated; `RepositoryAIModel.cancelGeneration()`
    /// stops it.
    case generating
    /// The last attempt failed: shown under the message fields until the
    /// next attempt (never an alert).
    case failed(OperationError)
}

/// An AI conflict resolution round.
public enum ConflictResolutionState: Sendable, Equatable {
    case idle
    /// A round is running (the loading phase).
    case resolving(ConflictResolutionRound)
    /// A round finished (the results phase), perhaps retrying files.
    case resolved(ConflictResolutionResults)
    /// A round failed.
    case failed(ConflictResolutionFailure)
}

/// AI features in a repository: generating commit messages into the draft,
/// and resolving the operation's conflicts.
@MainActor @Observable
public final class RepositoryAIModel: RepositoryFeature {
    public internal(set) var commitMessageGeneration: CommitMessageGenerationState = .idle
    public internal(set) var conflictResolution: ConflictResolutionState = .idle

    @ObservationIgnored weak var repository: RepositoryModel?

    /// The generation in flight.
    @ObservationIgnored private var generation: (id: UInt64, task: Task<Result<AICommitMessage, OperationError>, Never>)?
    @ObservationIgnored private var generationCount: UInt64 = 0

    /// The round or retry in flight.
    @ObservationIgnored private var activeRound: (id: UInt64, task: Task<Result<Void, OperationError>, Never>)?
    @ObservationIgnored private var roundCount: UInt64 = 0
    /// The conflicts `conflictResolution` is about while it isn't idle.
    @ObservationIgnored private(set) var stateKey: ConflictRoundKey?
    /// The conflicts the last round started for: rounds start by themselves
    /// at most once per round of conflicts.
    @ObservationIgnored private(set) var lastRoundKey: ConflictRoundKey?
    /// The operation the user resolves with AI: its later rounds of
    /// conflicts (a rebase's next commit) start by themselves, until the
    /// user stops a round or goes back to the manual flow.
    @ObservationIgnored private(set) var optedInConflicts: ConflictState?

    init() {}

    func attach(to repository: RepositoryModel) {
        self.repository = repository
    }

    // MARK: Commit messages

    /// Whether there's something to describe: files included in the commit,
    /// or a commit being amended.
    public var hasChangesToDescribe: Bool {
        guard let repository else {
            return false
        }
        return repository.commit.amending != nil
            || repository.changes.workingDirectory.files.contains(where: \.isIncludedInCommit)
    }

    /// Generates a commit message for the included changes (every file
    /// whose selection isn't none; when amending, with the amended commit's
    /// changes) and puts it in the draft, marked `generatedByAI`. Co-authors
    /// stay.
    ///
    /// The diff is made with a temporary index; the repository's commit
    /// message rules and its instructions for AI tools go with it.
    ///
    /// - Throws: `.ai(.disabled)`, `.ai(.noProvider)`,
    ///   `.ai(.modelSelectionRequired)` before anything else;
    ///   `.confirmationRequired(.overwriteCommitMessage)` when the summary or
    ///   description has text and `confirmCommitMessageOverride` is on;
    ///   `.ai(.consentRequired)` before the first request to the provider
    ///   (`app.ai.disclosure(for: .commitMessageGeneration)`); `.busy` while
    ///   generating or committing; `.precondition` without changes, also
    ///   kept in `commitMessageGeneration` as `.failed` when the included
    ///   changes turn out to have no diff;
    ///   `.cancelled(.userCancelled)` after `cancelGeneration()` (or when the
    ///   calling task is cancelled); the provider's failure as `.ai(...)`,
    ///   also kept in `commitMessageGeneration` as `.failed`.
    public func generateCommitMessage(confirmed: Set<ConfirmationKind> = []) async throws(OperationError) {
        guard let repository, let app = repository.app else {
            throw OperationError(.precondition("The repository is no longer in the list."), operation: .generateCommitMessage)
        }
        let id = repository.id
        let ai = app.ai
        func fail(_ reason: OperationError.Reason) -> OperationError {
            OperationError(reason, operation: .generateCommitMessage, repositoryID: id)
        }

        guard ai.isEnabled else {
            throw fail(.ai(.disabled))
        }
        // One at a time, and not while committing.
        if generation != nil {
            throw fail(.busy(.generateCommitMessage))
        }
        if repository.commit.isCommitting {
            throw fail(.busy(.commit))
        }

        let files = repository.changes.workingDirectory.files.filter(\.isIncludedInCommit)
        let amending = repository.commit.amending
        if files.isEmpty, amending == nil {
            throw fail(.precondition("Include at least one file to generate a commit message."))
        }

        let selection = try ai.requireModel(for: .commitMessageGeneration, operation: .generateCommitMessage, repositoryID: id)
        // Overriding the draft is confirmed before consent is asked for.
        let draft = repository.commit.draft
        if !draft.summary.isEmpty || !draft.description.isEmpty, app.preferences.confirmCommitMessageOverride,
           !confirmed.contains(.overwriteCommitMessage) {
            throw fail(.confirmationRequired(.overwriteCommitMessage()))
        }
        try ai.requireConsent(for: .commitMessageGeneration, selection, operation: .generateCommitMessage, repositoryID: id)

        let rules = CommitMessageGenerator.commitMessageRules(repository.gitHub.repoRules)
        let tipSHA = repository.gitState.tip.sha
        let gitRepository = repository.gitRepository
        let environment = repository.environment
        let record = repository.record

        generationCount &+= 1
        let generationID = generationCount
        commitMessageGeneration = .generating
        let task = Task { @MainActor [weak ai] () -> Result<AICommitMessage, OperationError> in
            do {
                let diff = try await environment.withRuntimes {
                    try await CommitMessageGenerator.diff(gitRepository, files: files, amending: amending)
                }
                try Task.checkCancellation()
                if diff.isEmpty {
                    // The included files match HEAD again, or the commit
                    // being amended changed nothing.
                    return .failure(fail(.precondition("There are no changes to describe.")))
                }
                let instructions = await CommitMessageGenerator.readRepositoryInstructions(repositoryPath: gitRepository.path)
                let request = try await CommitMessageGenerator.modelRequest(selection, secrets: environment.secrets)
                // AI may have been turned off, or the consent withdrawn,
                // while the diff was made.
                guard let ai, ai.isEnabled, ai.hasConsent(for: .commitMessageGeneration, selection) else {
                    throw CancellationError()
                }
                try Task.checkCancellation()
                let message = try await AIKit.generateCommitMessage(
                    diff: diff,
                    model: request,
                    commitMessageRules: rules,
                    repositoryInstructions: instructions,
                    session: environment.aiSession
                )
                return .success(message)
            } catch {
                return .failure(await aiOperationError(error, operation: .generateCommitMessage, record: record, cancelled: Task.isCancelled))
            }
        }
        generation = (generationID, task)

        let result = await withTaskCancellationHandler {
            await task.value
        } onCancel: {
            task.cancel()
        }

        let isCurrent = generation?.id == generationID
        if isCurrent {
            generation = nil
        }
        switch result {
        case .success(let message):
            guard isCurrent else {
                // Cancelled as it finished: the user asked for nothing.
                throw fail(.cancelled(.userCancelled))
            }
            // The result replaces the summary and description. One made
            // before HEAD moved (a commit), or for an amend that ended or
            // another commit, describes other changes: it's dropped.
            if repository.commit.amending?.sha == amending?.sha, repository.gitState.tip.sha == tipSHA {
                var draft = repository.commit.draft
                draft.summary = message.title
                draft.description = message.description
                draft.generatedByAI = true
                repository.commit.draft = draft
            }
            commitMessageGeneration = .idle
        case .failure(let error):
            if isCurrent {
                commitMessageGeneration = error.isCancellation ? .idle : .failed(error)
            }
            throw error
        }
    }

    /// Stops generating a commit message. The draft is left as it was.
    public func cancelGeneration() {
        guard let generation else {
            return
        }
        generation.task.cancel()
        self.generation = nil
        if commitMessageGeneration != .idle {
            commitMessageGeneration = .idle
        }
    }

    /// Forgets the last generation's failure.
    public func dismissGenerationFailure() {
        if case .failed = commitMessageGeneration {
            commitMessageGeneration = .idle
        }
    }

    /// Waits for the generation in flight (for tests).
    func generationIdle() async {
        while let task = generation?.task {
            _ = await task.value
            if generation?.task == task {
                return
            }
        }
    }

    // MARK: Conflict resolution

    /// Whether "Resolve with AI" applies: AI is on, the operation waits on
    /// conflicts that still need resolving, and no round runs.
    public var canResolveConflicts: Bool {
        guard let repository, repository.app?.ai.isEnabled == true, repository.operations.conflictState != nil else {
            return false
        }
        if case .resolving = conflictResolution {
            return false
        }
        return !repository.operations.unresolvedFiles.isEmpty
    }

    /// Resolves the operation's conflicted files with AI: gathers the files,
    /// both sides' recent commits, and the pull requests they mention, asks
    /// the model, and shows its resolutions (`conflictResolution`), streaming
    /// progress meanwhile. Nothing is written until `applyResolutions()`.
    /// Returns when the round ends.
    ///
    /// - Throws: `.ai(.disabled)`, `.ai(.noProvider)`,
    ///   `.ai(.modelSelectionRequired)`, `.ai(.consentRequired)` (the
    ///   disclosure is `app.ai.disclosure(for: .conflictResolution)`);
    ///   `.precondition` without conflicts to resolve; `.busy` while a round
    ///   or an operation runs; `.cancelled(.userCancelled)` when stopped; the
    ///   round's failure, also kept in `conflictResolution` as `.failed`.
    public func resolveConflicts() async throws(OperationError) {
        let task = try startRound(automatically: false)
        let result = await withTaskCancellationHandler {
            await task.value
        } onCancel: {
            task.cancel()
        }
        if case .failure(let error) = result {
            throw error
        }
    }

    /// Stops the round in flight and returns to the manual flow, or stops a
    /// retry, keeping the results.
    public func stopResolvingConflicts() {
        switch conflictResolution {
        case .resolving:
            cancelRound()
            setConflictResolution(.idle)
            optedInConflicts = nil
        case .resolved(var results) where results.retry != nil:
            cancelRound()
            results.retry = nil
            setConflictResolution(.resolved(results), key: results.key)
        default:
            break
        }
    }

    /// Goes back to the manual flow, dropping the round's results or
    /// failure. Later rounds of the operation's conflicts don't start by
    /// themselves.
    public func dismissConflictResolution() {
        cancelRound()
        setConflictResolution(.idle)
        optedInConflicts = nil
    }

    /// How a conflicted file is resolved in the results: by the model unless
    /// the user chose a side.
    public func resolutionChoice(forPath path: String) -> ConflictResolutionChoice {
        switch repository?.operations.conflictState?.manualResolutions[path] {
        case .ours?: .ours
        case .theirs?: .theirs
        case nil: .model
        }
    }

    /// Chooses how a conflicted file is resolved: the model's resolution, or
    /// a side (the operation's manual resolution, which continuing applies).
    public func setResolutionChoice(_ choice: ConflictResolutionChoice, forPath path: String) {
        let resolution: ManualConflictResolution? = switch choice {
        case .model: nil
        case .ours: .ours
        case .theirs: .theirs
        }
        repository?.operations.setManualResolution(resolution, forPath: path)
    }

    /// The diff of what a conflicted file would become, against the file on
    /// disk (with its conflict markers), for the results' Changes tab: the
    /// model's resolution, or the side the user chose. Nil when the model has
    /// no resolution for the file and no side is chosen.
    public func resolutionDiff(forPath path: String, hidesWhitespace: Bool = false) async throws(OperationError) -> ResolutionDiff? {
        guard let repository else {
            throw OperationError(.precondition("The repository is no longer in the list."), operation: .resolveConflicts)
        }
        let options: ResolutionDiffOptions
        switch resolutionChoice(forPath: path) {
        case .ours:
            options = .stage(.ours)
        case .theirs:
            options = .stage(.theirs)
        case .model:
            guard case .resolved(let results) = conflictResolution, let resolution = results.resolution(forPath: path),
                  resolution.deleteConflictAction == nil
            else {
                return nil
            }
            options = .content(resolution.resolvedContent)
        }
        let gitRepository = repository.gitRepository
        let record = repository.record
        do {
            return try await repository.environment.withRuntimes {
                try await getResolutionDiff(gitRepository, path, options, hideWhitespaceInDiff: hidesWhitespace)
            }
        } catch {
            throw await aiOperationError(error, operation: .resolveConflicts, record: record, cancelled: Task.isCancelled)
        }
    }

    /// The files of the results that still need the user before the
    /// operation can continue: skipped, failed, and unattempted files with
    /// conflicts left and no side chosen.
    public var filesNeedingResolution: [String] {
        guard case .resolved(let results) = conflictResolution, let repository else {
            return []
        }
        let unresolved = repository.operations.unresolvedFiles.map(\.path).exactSet
        let candidates = results.skippedFiles.map(\.path) + results.failedFiles.map(\.path) + results.notAttemptedFiles
        return candidates.filter { unresolved.contains(ExactString($0)) }
    }

    /// Writes the round's resolutions into the conflicted files and stages
    /// them, before the operation continues; delete-vs-modify choices become
    /// manual resolutions. Files the user chose a side for, resolved
    /// themselves, or changed since the round read them are left alone.
    /// Returns after the status refresh, so `operations.continueOperation()`
    /// can follow.
    ///
    /// - Throws: `.precondition` without results, or when the conflicts
    ///   changed since (the results are dropped); `.busy` while a retry or
    ///   another operation runs; the write's or git's error.
    @discardableResult
    public func applyResolutions() async throws(OperationError) -> AppliedConflictResolutions {
        guard let repository else {
            throw OperationError(.precondition("The repository is no longer in the list."), operation: .applyConflictResolutions)
        }
        let id = repository.id
        guard case .resolved(let results) = conflictResolution else {
            throw OperationError(.precondition("There are no resolutions to apply."), operation: .applyConflictResolutions, repositoryID: id)
        }
        if results.retry != nil {
            throw OperationError(.busy(.resolveConflicts), operation: .applyConflictResolutions, repositoryID: id)
        }
        guard currentRoundKey() == results.key else {
            setConflictResolution(.idle)
            throw OperationError(
                .precondition("The conflicts have changed since the model resolved them."),
                operation: .applyConflictResolutions,
                repositoryID: id
            )
        }

        let descriptor = OperationDescriptor(kind: .applyConflictResolutions, refreshAfter: .status)
        let applied = try await repository.perform(descriptor) { ctx in
            try await self.writeResolutions(results, in: ctx)
        }
        await repository.awaitOperationRefresh(covering: .status)
        if case .resolved(let current) = conflictResolution, current.key == results.key {
            setConflictResolution(.idle)
        }
        return applied
    }

    /// Retries the files the round failed or didn't attempt, together, with
    /// the round's context restricted to them, and merges the retry into
    /// the results. Returns when the retry ends.
    ///
    /// - Throws: `.precondition` without such files, or when the conflicts
    ///   changed since; `.busy` while a retry runs; the gates of
    ///   `resolveConflicts()`; `.cancelled(.userCancelled)` when stopped;
    ///   the retry's failure (its files stay failed, with the new error).
    public func retryFailedFiles() async throws(OperationError) {
        guard let repository, let app = repository.app else {
            throw OperationError(.precondition("The repository is no longer in the list."), operation: .resolveConflicts)
        }
        let id = repository.id
        func fail(_ reason: OperationError.Reason) -> OperationError {
            OperationError(reason, operation: .resolveConflicts, repositoryID: id)
        }
        guard case .resolved(var results) = conflictResolution else {
            throw fail(.precondition("There are no failed files to retry."))
        }
        let paths = results.outcome.failedFiles.map(\.path) + results.outcome.notAttemptedFiles
        guard !paths.isEmpty else {
            throw fail(.precondition("There are no failed files to retry."))
        }
        if results.retry != nil {
            throw fail(.busy(.resolveConflicts))
        }
        guard currentRoundKey() == results.key else {
            setConflictResolution(.idle)
            throw fail(.precondition("The conflicts have changed since the model resolved them."))
        }
        let selection = try app.ai.requireModel(for: .conflictResolution, operation: .resolveConflicts, repositoryID: id)
        try app.ai.requireConsent(for: .conflictResolution, selection, operation: .resolveConflicts, repositoryID: id)

        let context = results.context.restricted(to: paths)
        let key = results.key
        let environment = repository.environment
        let record = repository.record
        let repositoryPath = repository.gitRepository.path

        roundCount &+= 1
        let retryID = roundCount
        results.retry = ConflictResolutionRound(
            operation: results.operation,
            model: AIModel.display(selection),
            files: paths,
            phase: .analyzing,
            startedAutomatically: false
        )
        setConflictResolution(.resolved(results), key: key)

        let task = Task { @MainActor [weak self] () -> Result<Void, OperationError> in
            guard let self else {
                return .failure(OperationError(.cancelled(.userCancelled), operation: .resolveConflicts, repositoryID: id))
            }
            return await self.runRetry(
                id: retryID,
                key: key,
                paths: paths,
                context: context,
                selection: selection,
                environment: environment,
                record: record,
                repositoryPath: repositoryPath
            )
        }
        activeRound = (retryID, task)

        let result = await withTaskCancellationHandler {
            await task.value
        } onCancel: {
            task.cancel()
        }
        if case .failure(let error) = result {
            throw error
        }
    }

    /// Waits for the round or retry in flight (for tests).
    func roundIdle() async {
        while let task = activeRound?.task {
            _ = await task.value
            if activeRound?.task == task {
                return
            }
        }
    }

    // MARK: Rounds

    /// Starts a round for the operation's conflicts.
    private func startRound(automatically: Bool) throws(OperationError) -> Task<Result<Void, OperationError>, Never> {
        guard let repository, let app = repository.app else {
            throw OperationError(.precondition("The repository is no longer in the list."), operation: .resolveConflicts)
        }
        let id = repository.id
        func fail(_ reason: OperationError.Reason) -> OperationError {
            OperationError(reason, operation: .resolveConflicts, repositoryID: id)
        }
        let ai = app.ai
        guard ai.isEnabled else {
            throw fail(.ai(.disabled))
        }
        let operations = repository.operations
        guard let conflictState = operations.conflictState else {
            throw fail(.precondition("There are no conflicts to resolve."))
        }
        if case .resolving = conflictResolution {
            throw fail(.busy(.resolveConflicts))
        }
        if case .resolved(let results) = conflictResolution, results.retry != nil {
            throw fail(.busy(.resolveConflicts))
        }
        if let running = repository.localOperation {
            throw fail(.busy(running.kind))
        }
        let files = operations.unresolvedFiles
        guard !files.isEmpty else {
            throw fail(.precondition("There are no conflicted files to resolve."))
        }
        let selection = try ai.requireModel(for: .conflictResolution, operation: .resolveConflicts, repositoryID: id)
        try ai.requireConsent(for: .conflictResolution, selection, operation: .resolveConflicts, repositoryID: id)

        let record = repository.record
        let environment = repository.environment
        let key = ConflictRoundKey(conflictState, head: repository.gitState.tip.sha)
        let operation = operations.current
        let input = ConflictContextGatherer.Input(
            repository: repository.gitRepository,
            conflictState: conflictState,
            labels: ConflictContextGatherer.labels(conflictState, operation: operation, branches: operations.conflictBranches),
            files: files,
            localCommitSHAs: repository.gitState.localCommitSHAs,
            currentPullRequest: repository.gitHub.currentPullRequest.map {
                ConflictContextPullRequest(number: $0.pullRequestNumber, title: $0.title, body: $0.body)
            },
            isGitHubRepository: isRepositoryWithGitHubRepository(record),
            cachedPullRequests: repository.gitHub.openPullRequests,
            fetchPullRequest: pullRequestFetcher(for: record, app: app, environment: environment)
        )

        roundCount &+= 1
        let roundID = roundCount
        lastRoundKey = key
        let round = ConflictResolutionRound(
            operation: operation?.kind,
            model: AIModel.display(selection),
            files: files.map(\.path),
            phase: .gatheringContext,
            startedAutomatically: automatically
        )
        cancelRound()
        setConflictResolution(.resolving(round), key: key)
        logger.info("Resolving \(files.count) conflicted files with AI")

        let task = Task { @MainActor [weak self] () -> Result<Void, OperationError> in
            guard let self else {
                return .failure(OperationError(.cancelled(.userCancelled), operation: .resolveConflicts, repositoryID: id))
            }
            return await self.runRound(
                id: roundID,
                key: key,
                input: input,
                selection: selection,
                round: round,
                environment: environment,
                record: record
            )
        }
        activeRound = (roundID, task)
        return task
    }

    /// Fetches pull requests the cache lacks, for a GitHub repository with
    /// an account.
    private func pullRequestFetcher(
        for record: RepositoryRecord,
        app: AppModel,
        environment: AppEnvironment
    ) -> (@Sendable (Int) async -> ConflictContextPullRequest?)? {
        guard let gitHubRepository = getNonForkGitHubRepository(record), let account = app.accounts.account(for: record) else {
            return nil
        }
        return ConflictContextGatherer.pullRequestFetcher(account: account, repository: gitHubRepository, runtime: environment.gitHub)
    }

    private func runRound(
        id roundID: UInt64,
        key: ConflictRoundKey,
        input: ConflictContextGatherer.Input,
        selection: ResolvedModelSelection,
        round: ConflictResolutionRound,
        environment: AppEnvironment,
        record: RepositoryRecord
    ) async -> Result<Void, OperationError> {
        let cancelled = OperationError(.cancelled(.userCancelled), operation: .resolveConflicts, repositoryID: record.id)

        let (context, _) = await environment.withRuntimes {
            await ConflictContextGatherer.gather(input)
        }
        guard owns(roundID), !Task.isCancelled else {
            return .failure(cancelled)
        }

        let response: ReassembledConflictResolutionResponse
        do {
            let request: AIModelRequest
            do {
                request = try await CommitMessageGenerator.modelRequest(selection, secrets: environment.secrets)
            } catch {
                throw AIConflictResolutionError(error, stage: .resolveModel)
            }
            let instructions = await CommitMessageGenerator.readRepositoryInstructions(repositoryPath: input.repository.path)
            // AI may have been turned off, or the consent withdrawn, while
            // the context was gathered.
            guard owns(roundID), let ai = repository?.app?.ai, ai.isEnabled, ai.hasConsent(for: .conflictResolution, selection) else {
                throw CancellationError()
            }
            updateRunningRound(roundID) { $0.phase = .analyzing }
            let relay = ConflictResolutionProgressRelay { [weak self] progress in
                self?.applyProgress(progress, to: roundID)
            }
            defer { relay.flush() }
            response = try await AIKit.resolveConflicts(
                context: context,
                model: request,
                repositoryInstructions: instructions,
                session: environment.aiSession,
                onProgress: { relay.send($0) }
            )
        } catch {
            let failure = await aiOperationError(error, operation: .resolveConflicts, record: record, cancelled: Task.isCancelled)
            guard owns(roundID) else {
                return .failure(failure)
            }
            activeRound = nil
            optedInConflicts = nil
            if failure.isCancellation {
                setConflictResolution(.idle)
            } else {
                logger.error("Conflict resolution failed: \(failure.message, privacy: .private)")
                setConflictResolution(.failed(ConflictResolutionFailure(operation: round.operation, model: round.model, error: failure)), key: key)
            }
            return .failure(failure)
        }

        guard owns(roundID), !Task.isCancelled else {
            return .failure(cancelled)
        }
        activeRound = nil
        let results = ConflictResolutionResults(
            operation: round.operation,
            model: round.model,
            retry: nil,
            outcome: makeConflictResolutionOutcome(response, context: context),
            context: context,
            key: key
        )
        setConflictResolution(.resolved(results), key: key)
        // Later rounds of this operation's conflicts start by themselves.
        optedInConflicts = key.conflictState
        return .success(())
    }

    private func runRetry(
        id retryID: UInt64,
        key: ConflictRoundKey,
        paths: [String],
        context: ConflictResolutionContext,
        selection: ResolvedModelSelection,
        environment: AppEnvironment,
        record: RepositoryRecord,
        repositoryPath: String
    ) async -> Result<Void, OperationError> {
        var retryOutcome: ConflictResolutionOutcome
        var failure: OperationError?
        do {
            let request: AIModelRequest
            do {
                request = try await CommitMessageGenerator.modelRequest(selection, secrets: environment.secrets)
            } catch {
                throw AIConflictResolutionError(error, stage: .resolveModel)
            }
            let instructions = await CommitMessageGenerator.readRepositoryInstructions(repositoryPath: repositoryPath)
            guard owns(retryID), let ai = repository?.app?.ai, ai.isEnabled, ai.hasConsent(for: .conflictResolution, selection) else {
                throw CancellationError()
            }
            let relay = ConflictResolutionProgressRelay { [weak self] progress in
                self?.applyProgress(progress, to: retryID)
            }
            defer { relay.flush() }
            let response = try await AIKit.resolveConflicts(
                context: context,
                model: request,
                repositoryInstructions: instructions,
                session: environment.aiSession,
                onProgress: { relay.send($0) }
            )
            retryOutcome = makeConflictResolutionOutcome(response, context: context)
        } catch {
            let operationError = await aiOperationError(error, operation: .resolveConflicts, record: record, cancelled: Task.isCancelled)
            if operationError.isCancellation {
                if owns(retryID), case .resolved(var results) = conflictResolution {
                    activeRound = nil
                    results.retry = nil
                    setConflictResolution(.resolved(results), key: key)
                }
                return .failure(operationError)
            }
            // Every retried file failed, with this error.
            let wrapped = AIConflictResolutionError.wrapping(error, stage: .unknown)
            retryOutcome = ConflictResolutionOutcome(
                resolutions: [],
                summary: AIResolutionSummary(summaries: [], ourLabel: context.ourLabel, theirLabel: context.theirLabel, references: []),
                skippedFiles: [],
                failedFiles: paths.map { AIFailedFile(path: $0, error: wrapped) }
            )
            failure = operationError
        }

        guard owns(retryID), case .resolved(var results) = conflictResolution, results.key == key else {
            return failure.map { .failure($0) } ?? .failure(OperationError(.cancelled(.userCancelled), operation: .resolveConflicts, repositoryID: record.id))
        }
        activeRound = nil
        results.outcome = results.outcome.merging(retryOutcome)
        results.retry = nil
        setConflictResolution(.resolved(results), key: key)
        if let failure {
            return .failure(failure)
        }
        return .success(())
    }

    /// Whether the round or retry `id` is still the one in flight.
    private func owns(_ id: UInt64) -> Bool {
        activeRound?.id == id
    }

    private func cancelRound() {
        activeRound?.task.cancel()
        activeRound = nil
    }

    private func setConflictResolution(_ state: ConflictResolutionState, key: ConflictRoundKey? = nil) {
        stateKey = state == .idle ? nil : key
        if conflictResolution != state {
            conflictResolution = state
        }
    }

    private func updateRunningRound(_ id: UInt64, _ change: (inout ConflictResolutionRound) -> Void) {
        guard owns(id) else {
            return
        }
        switch conflictResolution {
        case .resolving(var round):
            change(&round)
            conflictResolution = .resolving(round)
        case .resolved(var results):
            guard var retry = results.retry else {
                return
            }
            change(&retry)
            results.retry = retry
            conflictResolution = .resolved(results)
        case .idle, .failed:
            break
        }
    }

    private func applyProgress(_ progress: [ConflictResolutionProgress], to id: UInt64) {
        updateRunningRound(id) { $0.apply(progress) }
    }

    /// The conflicts a round would be for now.
    func currentRoundKey() -> ConflictRoundKey? {
        guard let repository, let conflictState = repository.operations.conflictState else {
            return nil
        }
        return ConflictRoundKey(conflictState, head: repository.gitState.tip.sha)
    }

    /// Writes the results' resolutions, in the operation (the local lane is
    /// held), against a fresh status.
    private func writeResolutions(_ results: ConflictResolutionResults, in ctx: OperationContext) async throws -> AppliedConflictResolutions {
        guard let repository else {
            throw CancellationError()
        }
        guard let status = try await getStatus(ctx.repository) else {
            throw OperationError(.missingRepository, operation: .applyConflictResolutions, repositoryID: repository.id)
        }
        var filesByPath: [ExactString: WorkingDirectoryFileChange] = [:]
        for file in status.workingDirectory.files {
            filesByPath[ExactString(file.path)] = file
        }
        var readContents: [ExactString: String] = [:]
        for file in results.context.files {
            if let rawContent = file.rawContent {
                readContents[ExactString(file.path)] = rawContent
            }
        }

        var applied = AppliedConflictResolutions()
        var pending: [ConflictResolutionWriter.PendingWrite] = []
        for resolution in results.resolutions {
            // Respect the sides the user chose in the results.
            if repository.operations.conflictState?.manualResolutions[resolution.path] != nil {
                applied.notWritten.append(.init(path: resolution.path, reason: .userChoseSide))
                continue
            }
            guard let file = filesByPath[ExactString(resolution.path)], case .conflicted(let conflicted) = file.status else {
                applied.notWritten.append(.init(path: resolution.path, reason: .alreadyResolved))
                continue
            }

            // Delete-vs-modify conflicts are resolved by a manual resolution,
            // which continuing applies: keep is the side that didn't delete
            // the file, delete the side that did.
            if let action = resolution.deleteConflictAction {
                guard let deletedSide = ConflictContextGatherer.getDeletedSideFromStatus(file) else {
                    applied.notWritten.append(.init(path: resolution.path, reason: .alreadyResolved))
                    continue
                }
                let side: ManualConflictResolution = switch (action, deletedSide) {
                case (.keep, .ours): .theirs
                case (.keep, .theirs): .ours
                case (.delete, .ours): .ours
                case (.delete, .theirs): .theirs
                }
                repository.operations.setManualResolution(side, forPath: resolution.path)
                applied.sidesChosen.append(resolution.path)
                continue
            }

            // A file the user resolved meanwhile (no markers left) keeps
            // their resolution.
            guard case .conflictsWithMarkers(_, let markerCount, _, _) = conflicted, markerCount > 0 else {
                applied.notWritten.append(.init(path: resolution.path, reason: .alreadyResolved))
                continue
            }
            guard let expected = readContents[ExactString(resolution.path)] else {
                applied.notWritten.append(.init(path: resolution.path, reason: .changedSinceResolution))
                continue
            }
            pending.append(.init(path: resolution.path, content: resolution.resolvedContent, expectedContent: expected))
        }

        let outcomes = try await ConflictResolutionWriter.write(pending, repositoryPath: ctx.repository.path)
        for (write, outcome) in zip(pending, outcomes) {
            switch outcome {
            case .written:
                applied.written.append(write.path)
            case .changedSinceResolution:
                applied.notWritten.append(.init(path: write.path, reason: .changedSinceResolution))
            case .outsideRepository:
                logger.error("An AI resolution was skipped: its path is outside the repository")
                applied.notWritten.append(.init(path: write.path, reason: .outsideRepository))
            }
        }
        try await ConflictResolutionWriter.stage(applied.written, in: ctx.repository)
        logger.info("Applied \(applied.written.count) AI conflict resolutions")
        return applied
    }

    // MARK: Following the repository

    func repositoryDidRefresh(_ update: RefreshUpdate) {
        guard update.applied.contains(.status), let repository else {
            return
        }
        let key = currentRoundKey()

        // A round's work applies only to the conflicts it was for: they're
        // gone, or the operation moved on to its next round.
        if let stateKey, stateKey != key {
            cancelRound()
            setConflictResolution(.idle)
        }
        if key == nil {
            lastRoundKey = nil
        }
        // The opt-in lasts as long as its operation.
        if let optedIn = optedInConflicts {
            if let conflictState = repository.operations.conflictState {
                if !optedIn.isSameOperation(as: conflictState) {
                    optedInConflicts = nil
                }
            } else if repository.operations.current == nil {
                optedInConflicts = nil
            }
        }

        startRoundIfWanted(key)
    }

    /// Starts a round by itself when conflicts appear: "Always use AI when
    /// conflicts are detected" is on (it counts as off while AI is off), or
    /// the user resolved this operation's earlier conflicts with AI; only in
    /// the selected repository, once per round, and only when the model
    /// resolves and consent exists. Otherwise the manual flow shows.
    private func startRoundIfWanted(_ key: ConflictRoundKey?) {
        guard let key, let repository, let app = repository.app, app.ai.isEnabled else {
            return
        }
        guard conflictResolution == .idle, activeRound == nil, key != lastRoundKey else {
            return
        }
        guard app.selection == .repository(repository.id) else {
            return
        }
        if let current = repository.operations.current, current.phase != .conflicted {
            return
        }
        let optedIn = optedInConflicts.map { $0.isSameOperation(as: key.conflictState) } ?? false
        guard app.preferences.alwaysUseAIForConflictResolution || optedIn else {
            return
        }
        guard !repository.operations.unresolvedFiles.isEmpty, case .ready = app.ai.status(for: .conflictResolution) else {
            return
        }
        do {
            _ = try startRound(automatically: true)
        } catch {
            logger.error("Could not start resolving conflicts: \(error.message, privacy: .private)")
        }
    }

    /// AI was turned off: stop and forget everything.
    func aiFeaturesWereTurnedOff() {
        cancelGeneration()
        dismissGenerationFailure()
        dismissConflictResolution()
        lastRoundKey = nil
    }

    func repositoryPathDidChange(keepingSharedState: Bool) {
        cancelGeneration()
        dismissGenerationFailure()
        dismissConflictResolution()
        lastRoundKey = nil
    }
}

extension AIModel {
    /// Whether the user agreed to send `feature`'s data to `selection`'s
    /// provider.
    func hasConsent(for feature: AIFeature, _ selection: ResolvedModelSelection) -> Bool {
        consents.contains(getAIDataDisclosure(for: feature, provider: selection.provider).consentIdentifier)
    }
}
