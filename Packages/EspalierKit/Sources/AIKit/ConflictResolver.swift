// Ported from desktop/app/src/lib/stores/copilot-store.ts (resolveConflicts) and app-store.ts
//
// - A failed chunk doesn't fail the run: the successful chunks are kept and
//   the failed chunks' files are reported individually (`failedFiles`), to
//   retry on their own with `ConflictResolutionContext.restricted(to:)` and
//   `merging(_:)`. The run only throws when no chunk succeeded.
// - Provider errors (401, 402, 429, ...) are the same `AIProviderError` as
//   in commit message generation, available as `underlyingError`.
// - Every completed round produces a complete `ConflictResolutionOutcome`
//   (empty when there was nothing to resolve), which replaces the previous
//   one as a whole.

import EspalierSupport
import Foundation
import os

/// The per-request timeout (in milliseconds) for each conflict resolution
/// turn when the provider doesn't set one.
public let DefaultConflictResolutionTimeoutMs = 600_000

/// The output token limit for conflict resolution requests (Anthropic
/// requires one). Resolved hunks for many files can be long.
let ConflictResolutionMaxOutputTokens = 64_000

/// Thrown when an in-flight conflict resolution is cancelled by the user
/// (the calling task was cancelled). Distinguished from real failures so it
/// isn't retried and isn't shown as an error.
public struct AIConflictResolutionAbortError: Error, LocalizedError, Sendable, Hashable {
    public init() {}

    public var errorDescription: String? { "Conflict resolution was stopped" }
}

private let log = Log.logger(category: "AIKit")

/// Drives a single streaming turn to completion and returns the final
/// response content.
///
/// The model's live reasoning is reported to `onReasoningSnippet` sentence by
/// sentence. The first response text marks the transition from reasoning to
/// the response (the JSON payload), so any leftover reasoning is flushed
/// then rather than stranded.
///
/// Cancelling the calling task cancels the request immediately and throws
/// `AIConflictResolutionAbortError`.
public func runConflictResolutionTurn(
    provider: any AIProvider,
    request: AIRequest,
    onReasoningSnippet: (@Sendable (String) -> Void)? = nil
) async throws -> String {
    if Task.isCancelled {
        throw AIConflictResolutionAbortError()
    }

    let splitter = Locked(ReasoningSentenceSplitter())
    do {
        let response = try await provider.stream(request) { event in
            let snippets =
                switch event {
                case .reasoning(let text): splitter.withLock { $0.append(text) }
                case .content: splitter.withLock { $0.flush(force: true) }
                }
            for snippet in snippets {
                onReasoningSnippet?(snippet)
            }
        }
        // The complete response is authoritative, not the accumulated
        // increments.
        guard !response.content.isEmpty else {
            throw AIResponseError("No response from the model")
        }
        return response.content
    } catch {
        if error is CancellationError || Task.isCancelled {
            throw AIConflictResolutionAbortError()
        }
        throw error
    }
}

/// What a chunk produced.
private struct ChunkResult: Sendable {
    var resolutions: [FileResolution]
    var summary: String?
    var references: [AIConflictReference]
}

/// The request settings shared by every chunk.
private struct ChunkRequest: Sendable {
    var modelId: String
    var reasoningEffort: ReasoningEffort?
    var timeout: Duration
    var systemPrompt: String
}

/// Resolves conflicts with the selected model.
///
/// Up to `SinglePromptFileLimit` files go in a single prompt. Larger sets
/// are batched into dependency-aware chunks, with up to
/// `MaxConcurrentChunks` requests at a time. Each chunk is retried once when
/// the model's response can't be parsed or validated.
///
/// - Parameters:
///   - context: The files, commits, and pull requests from both sides.
///     Skipped files aren't sent.
///   - model: The model and provider to use (`resolveAIModelRequest`).
///   - repositoryInstructions: The repository's custom instruction files,
///     put at the start of the system prompt.
///   - session: The session for the provider's requests.
///   - onProgress: Called with progress and the model's live reasoning,
///     from any thread.
/// - Returns: The reassembled resolutions, the files of any chunks that
///   failed while others succeeded, and the files of chunks that weren't
///   started after an error that would fail every request.
/// - Throws: `AIConflictResolutionAbortError` when the task is cancelled,
///   otherwise `AIConflictResolutionError` (when no chunk succeeded).
public func resolveConflicts(
    context: ConflictResolutionContext,
    model: AIModelRequest,
    repositoryInstructions: [RepositoryInstructions] = [],
    session: URLSession = defaultAIURLSession,
    onProgress: (@Sendable (ConflictResolutionProgress) -> Void)? = nil
) async throws -> ReassembledConflictResolutionResponse {
    if !context.files.contains(where: \.isResolvable) {
        return ReassembledConflictResolutionResponse(resolutions: [], summary: nil, references: [])
    }
    let provider: any AIProvider
    do {
        provider = try makeAIProvider(model.provider, session: session)
    } catch {
        throw AIConflictResolutionError(error, stage: .createClient)
    }
    return try await resolveConflicts(
        context: context,
        model: model,
        using: provider,
        repositoryInstructions: repositoryInstructions,
        onProgress: onProgress
    )
}

/// Resolves conflicts with the given provider client. See
/// `resolveConflicts(context:model:repositoryInstructions:session:onProgress:)`.
public func resolveConflicts(
    context: ConflictResolutionContext,
    model: AIModelRequest,
    using provider: any AIProvider,
    repositoryInstructions: [RepositoryInstructions] = [],
    onProgress: (@Sendable (ConflictResolutionProgress) -> Void)? = nil
) async throws -> ReassembledConflictResolutionResponse {
    let resolvableFiles = context.files.filter(\.isResolvable)
    let filesTotal = resolvableFiles.count

    if filesTotal == 0 {
        return ReassembledConflictResolutionResponse(resolutions: [], summary: nil, references: [])
    }

    onProgress?(ConflictResolutionProgress(filesResolved: 0, filesTotal: filesTotal))

    var timeout = Duration.milliseconds(DefaultConflictResolutionTimeoutMs)
    if let requested = model.timeout, requested > .zero {
        timeout = clampedRequestTimeout(requested)
    }
    let token = randomHexToken(byteCount: 8)
    let chunkRequest = ChunkRequest(
        modelId: model.modelId,
        reasoningEffort: model.reasoningEffort,
        timeout: timeout,
        systemPrompt: buildRepositoryInstructionsPrompt(
            repositoryInstructions,
            open: "<repository-instructions-\(token)>",
            close: "</repository-instructions-\(token)>"
        ) + ConflictResolutionSystemPrompt
    )

    if filesTotal <= SinglePromptFileLimit {
        var filteredContext = context
        filteredContext.files = resolvableFiles
        let chunk = try await resolveChunk(
            provider: provider,
            prompt: formatConflictContextForPrompt(filteredContext),
            expectedFiles: resolvableFiles,
            request: chunkRequest
        ) { reasoningSnippet in
            onProgress?(ConflictResolutionProgress(filesResolved: 0, filesTotal: filesTotal, reasoningSnippet: reasoningSnippet))
        }
        onProgress?(ConflictResolutionProgress(filesResolved: filesTotal, filesTotal: filesTotal))
        return ReassembledConflictResolutionResponse(
            resolutions: chunk.resolutions,
            summary: chunk.summary,
            references: chunk.references
        )
    }

    // Batch into chunks and resolve concurrently. Smaller chunks at high
    // file counts protect output quality (less truncation, fewer malformed
    // responses).
    let chunkSize = filesTotal > 100 ? 15 : 20
    let chunks = createDependencyAwareChunks(resolvableFiles, chunkSize)
    var allResolutions: [FileResolution] = []
    var failedFiles: [AIFailedFile] = []
    var notAttemptedFiles: [String] = []
    var firstSummary: String?
    var firstReferences: [AIConflictReference] = []
    var firstError: AIConflictResolutionError?
    var succeededChunks = 0
    // An error that would fail every further request (bad credentials, no
    // quota, unreachable provider): later batches aren't started.
    var haltingError: AIConflictResolutionError?
    let filesResolved = Locked(0)

    // Process chunks with bounded concurrency.
    for batchStart in stride(from: 0, to: chunks.count, by: MaxConcurrentChunks) {
        // Stop starting new batches once the user has cancelled. In-flight
        // chunks tear themselves down when the task is cancelled.
        if Task.isCancelled {
            throw AIConflictResolutionAbortError()
        }

        let batch = Array(chunks[batchStart..<min(batchStart + MaxConcurrentChunks, chunks.count)])

        // These files were never sent, so they have no error of their own.
        if haltingError != nil {
            notAttemptedFiles += batch.flatMap { files in files.map(\.path) }
            continue
        }

        let results = await withTaskGroup(of: (Int, Result<ChunkResult, any Error>).self) { group in
            for (index, chunkFiles) in batch.enumerated() {
                var chunkContext = context
                chunkContext.files = chunkFiles
                let prompt = formatConflictContextForPrompt(chunkContext)
                group.addTask {
                    do {
                        let result = try await resolveChunk(
                            provider: provider,
                            prompt: prompt,
                            expectedFiles: chunkFiles,
                            request: chunkRequest
                        ) { reasoningSnippet in
                            onProgress?(
                                ConflictResolutionProgress(
                                    filesResolved: filesResolved.withLock { $0 },
                                    filesTotal: filesTotal,
                                    reasoningSnippet: reasoningSnippet
                                )
                            )
                        }
                        return (index, .success(result))
                    } catch {
                        return (index, .failure(error))
                    }
                }
            }
            var settled = [Result<ChunkResult, any Error>?](repeating: nil, count: batch.count)
            for await (index, result) in group {
                settled[index] = result
            }
            return settled.compactMap { $0 }
        }

        // Collect results in chunk order once the whole batch has settled.
        var aborted = false
        for (index, result) in results.enumerated() {
            switch result {
            case .success(let chunk):
                succeededChunks += 1
                allResolutions += chunk.resolutions
                let resolved = filesResolved.withLock { count in
                    count += chunk.resolutions.count
                    return count
                }
                if firstSummary == nil, let summary = chunk.summary {
                    firstSummary = summary
                }
                if firstReferences.isEmpty, !chunk.references.isEmpty {
                    firstReferences = chunk.references
                }
                onProgress?(ConflictResolutionProgress(filesResolved: resolved, filesTotal: filesTotal))
            case .failure(let error):
                if error is AIConflictResolutionAbortError {
                    aborted = true
                    continue
                }
                let failure = AIConflictResolutionError.wrapping(error, stage: .unknown)
                failedFiles += batch[index].map { AIFailedFile(path: $0.path, error: failure) }
                if firstError == nil {
                    firstError = failure
                }
                if haltingError == nil, (failure.underlyingError as? AIProviderError)?.affectsAllRequests == true {
                    haltingError = failure
                }
            }
        }

        if aborted || Task.isCancelled {
            throw AIConflictResolutionAbortError()
        }
    }

    if succeededChunks == 0, let firstError {
        throw firstError
    }

    onProgress?(ConflictResolutionProgress(filesResolved: filesResolved.withLock { $0 }, filesTotal: filesTotal))
    return ReassembledConflictResolutionResponse(
        resolutions: allResolutions,
        summary: firstSummary,
        references: firstReferences,
        failedFiles: failedFiles,
        notAttemptedFiles: notAttemptedFiles
    )
}

/// Resolves a single chunk of files. Streams the turn with
/// `runConflictResolutionTurn`, then parses, validates, and reassembles the
/// response. Retries once on a parse or validation failure; transport
/// errors (timeouts, authentication) fail fast, and cancellation is never
/// retried.
private func resolveChunk(
    provider: any AIProvider,
    prompt: String,
    expectedFiles: [FileConflictContext],
    request: ChunkRequest,
    onReasoningSnippet: @escaping @Sendable (String) -> Void
) async throws -> ChunkResult {
    var lastError: (any Error)?
    var lastStage = AIConflictResolutionFailureStage.unknown
    var retriedValidation = false

    for attempt in 0..<2 {
        // Don't start (or retry) a turn that's already been cancelled.
        if Task.isCancelled {
            throw AIConflictResolutionAbortError()
        }

        var stage = AIConflictResolutionFailureStage.streamResponse
        do {
            let content = try await runConflictResolutionTurn(
                provider: provider,
                request: AIRequest(
                    model: request.modelId,
                    systemPrompt: request.systemPrompt,
                    userPrompt: prompt,
                    reasoningEffort: request.reasoningEffort,
                    maxOutputTokens: ConflictResolutionMaxOutputTokens,
                    timeout: request.timeout
                ),
                onReasoningSnippet: onReasoningSnippet
            )

            stage = .parseResponse
            let parsed = try parseAIConflictResolution(content)
            stage = .validateResponse
            try validateResolutionPaths(parsed.resolutions, expectedFiles)
            stage = .reassembleResponse
            let resolutions = try reassembleResolutions(parsed.resolutions, expectedFiles)

            return ChunkResult(resolutions: resolutions, summary: parsed.summary, references: parsed.references)
        } catch {
            lastError = error
            lastStage = stage

            // Never retry a user-initiated abort.
            if error is AIConflictResolutionAbortError {
                throw error
            }

            // Only retry on parse or validation failures.
            if !(error is AIValidationError) || attempt > 0 {
                break
            }

            retriedValidation = true
            log.warning("Conflict resolution parse/validation failed, retrying")
        }
    }

    log.warning("Failed to resolve conflicts: \(describeForLog(lastError ?? CancellationError()), privacy: .public)")
    throw AIConflictResolutionError(
        lastError ?? AIResponseError("Conflict resolution failed"),
        stage: lastStage,
        retryState: retriedValidation ? .failedAfterValidationRetry : .notRetried
    )
}

// MARK: Outcome

/// Everything one round of conflict resolution produced, ready to show: the
/// resolutions, the summary card, the files that weren't sent to the model,
/// the files whose chunk failed, and the files whose chunk never started.
///
/// Each completed round produces a complete outcome, even when nothing could
/// be resolved, and it replaces the previous round's outcome as a whole. The
/// state layer must also clear a stored outcome when a round ends without
/// one (the user stopped it, or there was nothing to resolve).
public struct ConflictResolutionOutcome: Sendable {
    public var resolutions: [FileResolution]
    public var summary: AIResolutionSummary
    /// Files that weren't sent to the model, with the reason.
    public var skippedFiles: [AISkippedFile]
    /// Files the model couldn't resolve because their request failed; retry
    /// them with `ConflictResolutionContext.restricted(to:)`.
    public var failedFiles: [AIFailedFile]
    /// Files that weren't attempted because an earlier request failed in a
    /// way that would fail every request (the cause is in `failedFiles`);
    /// retry them like failed files.
    public var notAttemptedFiles: [String]

    public init(
        resolutions: [FileResolution],
        summary: AIResolutionSummary,
        skippedFiles: [AISkippedFile],
        failedFiles: [AIFailedFile],
        notAttemptedFiles: [String] = []
    ) {
        self.resolutions = resolutions
        self.summary = summary
        self.skippedFiles = skippedFiles
        self.failedFiles = failedFiles
        self.notAttemptedFiles = notAttemptedFiles
    }

    /// This outcome with a retry of some of its failed or unattempted files
    /// merged in: the retry's resolutions are added, the retried files' old
    /// entries replaced by the retry's, and the summary kept (or taken from
    /// the retry when this one has none). Paths are compared by code units.
    public func merging(_ retry: ConflictResolutionOutcome) -> ConflictResolutionOutcome {
        let retried = (retry.resolutions.map(\.path) + retry.failedFiles.map(\.path) + retry.notAttemptedFiles).exactSet
        let skipped = skippedFiles.map(\.path).exactSet
        return ConflictResolutionOutcome(
            resolutions: resolutions.filter { !retried.contains(ExactString($0.path)) } + retry.resolutions,
            summary: AIResolutionSummary(
                markdown: summary.markdown ?? retry.summary.markdown,
                ourLabel: summary.ourLabel,
                theirLabel: summary.theirLabel,
                references: summary.references.isEmpty ? retry.summary.references : summary.references
            ),
            skippedFiles: skippedFiles + retry.skippedFiles.filter { !skipped.contains(ExactString($0.path)) },
            failedFiles: failedFiles.filter { !retried.contains(ExactString($0.path)) } + retry.failedFiles,
            notAttemptedFiles: notAttemptedFiles.filter { !retried.contains(ExactString($0)) } + retry.notAttemptedFiles
        )
    }
}

/// Turns a round's response into what the results view shows. The model's
/// cited references are resolved against the gathered context (it can only
/// cite data that was in the prompt); when it cites nothing, the most
/// informative item gathered is shown, so the "Context" list always traces
/// the conflict to at least one source. Files that weren't sent to the
/// model (too large, unreadable, no parseable markers) are listed so the
/// user can resolve them manually.
public func makeConflictResolutionOutcome(
    _ response: ReassembledConflictResolutionResponse,
    context: ConflictResolutionContext
) -> ConflictResolutionOutcome {
    let cited = selectReferencedContext(response.references, context)
    let references = cited.isEmpty ? fallbackReferencedContext(context) : cited
    let skippedFiles = context.files.compactMap { file in
        file.skippedReason.map { AISkippedFile(path: file.path, reason: $0) }
    }
    return ConflictResolutionOutcome(
        resolutions: response.resolutions,
        summary: AIResolutionSummary(
            markdown: response.summary,
            ourLabel: context.ourLabel,
            theirLabel: context.theirLabel,
            references: references
        ),
        skippedFiles: skippedFiles,
        failedFiles: response.failedFiles,
        notAttemptedFiles: response.notAttemptedFiles
    )
}
