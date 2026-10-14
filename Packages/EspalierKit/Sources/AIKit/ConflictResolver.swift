// Ported from desktop/app/src/lib/stores/copilot-store.ts (resolveConflicts) and app-store.ts
//
// - A failed file doesn't fail the run: the resolved files are kept and the
//   failed ones are reported individually (`failedFiles`), to retry on
//   their own with `ConflictResolutionContext.restricted(to:)` and
//   `merging(_:)`. The run only throws when no file was resolved.
// - Chunks are packed by conflict size as well as file count, and a chunk
//   too large for the model is split rather than sent again.
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
/// response, whose content isn't empty.
///
/// The model's live reasoning is reported to `onReasoningSnippet` sentence by
/// sentence. The first response text marks the transition from reasoning to
/// the response (the JSON payload), so any leftover reasoning is flushed
/// then rather than stranded.
///
/// Cancelling the calling task cancels the request immediately and throws
/// `AIConflictResolutionAbortError`. An empty response throws
/// `AIResponseError`, or `AIProviderError` of kind `outputLimitReached` when
/// the output limit cut it off (reasoning can use it all up).
public func runConflictResolutionTurn(
    provider: any AIProvider,
    request: AIRequest,
    onReasoningSnippet: (@Sendable (String) -> Void)? = nil
) async throws -> AIResponse {
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
            throw response.reachedOutputLimit ? outputLimitReachedError() : AIResponseError("No response from the model")
        }
        return response
    } catch {
        if error is CancellationError || Task.isCancelled {
            throw AIConflictResolutionAbortError()
        }
        throw error
    }
}

/// What resolving some files produced.
private struct ChunkResult: Sendable {
    var resolutions: [FileResolution] = []
    /// Each request's summary, covering the files it resolved.
    var summaries: [AIChunkSummary] = []
    var references: [AIConflictReference] = []
    var failedFiles: [AIFailedFile] = []
    /// Files not sent after an error that would fail every request.
    var notAttemptedFiles: [String] = []
    /// That error, when one stopped the chunk.
    var haltingError: AIConflictResolutionError?

    mutating func append(_ other: ChunkResult) {
        resolutions += other.resolutions
        summaries += other.summaries
        references += other.references.filter { !references.contains($0) }
        failedFiles += other.failedFiles
        notAttemptedFiles += other.notAttemptedFiles
        haltingError = haltingError ?? other.haltingError
    }
}

/// The request settings shared by every chunk.
private struct ChunkRequest: Sendable {
    /// The whole context; each request sends some of its files.
    var context: ConflictResolutionContext
    var modelId: String
    var reasoningEffort: ReasoningEffort?
    var timeout: Duration
    var systemPrompt: String
}

/// Resolves conflicts with the selected model.
///
/// Up to `SinglePromptFileLimit` files, with no more conflict content than
/// `MaxChunkConflictContentSize`, go in a single prompt. Larger sets are
/// batched into dependency-aware chunks within both limits, with up to
/// `MaxConcurrentChunks` requests at a time. Each chunk is resolved by
/// `resolveChunk`: asked again once when the response can't be read, its
/// files with unusable resolutions asked about again once on their own, and
/// split in two when it's too large for the model.
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
        return ReassembledConflictResolutionResponse(resolutions: [], summaries: [], references: [])
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
        return ReassembledConflictResolutionResponse(resolutions: [], summaries: [], references: [])
    }

    onProgress?(ConflictResolutionProgress(filesResolved: 0, filesTotal: filesTotal))

    var timeout = Duration.milliseconds(DefaultConflictResolutionTimeoutMs)
    if let requested = model.timeout, requested > .zero {
        timeout = clampedRequestTimeout(requested)
    }
    let token = randomHexToken(byteCount: 8)
    let chunkRequest = ChunkRequest(
        context: context,
        modelId: model.modelId,
        reasoningEffort: model.reasoningEffort,
        timeout: timeout,
        systemPrompt: buildRepositoryInstructionsPrompt(
            repositoryInstructions,
            open: "<repository-instructions-\(token)>",
            close: "</repository-instructions-\(token)>"
        ) + ConflictResolutionSystemPrompt
    )

    // Smaller chunks at high file counts protect output quality (less
    // truncation, fewer malformed responses).
    let chunkSize = filesTotal > 100 ? 15 : SinglePromptFileLimit
    let chunks = createDependencyAwareChunks(resolvableFiles, chunkSize)
    var all = ChunkResult()
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
            all.notAttemptedFiles += batch.flatMap { files in files.map(\.path) }
            continue
        }

        let results = await withTaskGroup(of: (Int, Result<ChunkResult, any Error>).self) { group in
            for (index, chunkFiles) in batch.enumerated() {
                group.addTask {
                    do {
                        let result = try await resolveChunk(chunkFiles, request: chunkRequest, provider: provider) { reasoningSnippet in
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
        for result in results {
            switch result {
            case .success(let chunk):
                all.append(chunk)
                haltingError = haltingError ?? chunk.haltingError
                if !chunk.resolutions.isEmpty {
                    let resolved = filesResolved.withLock { count in
                        count += chunk.resolutions.count
                        return count
                    }
                    onProgress?(ConflictResolutionProgress(filesResolved: resolved, filesTotal: filesTotal))
                }
            case .failure:
                // `resolveChunk` throws only when the task is cancelled.
                aborted = true
            }
        }

        if aborted || Task.isCancelled {
            throw AIConflictResolutionAbortError()
        }
    }

    if all.resolutions.isEmpty, let firstError = all.failedFiles.first?.error {
        throw firstError
    }

    return ReassembledConflictResolutionResponse(
        resolutions: all.resolutions,
        summaries: all.summaries,
        references: all.references,
        failedFiles: all.failedFiles,
        notAttemptedFiles: all.notAttemptedFiles
    )
}

/// Resolves `files` with one request, and then what's left:
///
/// - A response that can't be read is asked for again once.
/// - Files whose resolutions can't be used (`checkResolutions`) are asked
///   about again once, on their own; the rest are kept.
/// - Files too many for one request (the provider calls it too large, or the
///   response is cut off at the output limit) are split in two, each half
///   resolved the same way, one after the other. A single file fails: the
///   same request would fail again.
///
/// Any other failure (timeouts, authentication, ...) fails the files at
/// once. Only cancellation throws (`AIConflictResolutionAbortError`).
///
/// - Parameter retried: Whether the files were already asked about again,
///   so they aren't a third time.
private func resolveChunk(
    _ files: [FileConflictContext],
    request: ChunkRequest,
    provider: any AIProvider,
    retried: Bool = false,
    onReasoningSnippet: @escaping @Sendable (String) -> Void
) async throws -> ChunkResult {
    var retried = retried
    var context = request.context
    context.files = files
    let prompt = formatConflictContextForPrompt(context)

    while true {
        // Don't start (or retry) a turn that's already been cancelled.
        if Task.isCancelled {
            throw AIConflictResolutionAbortError()
        }

        var stage = AIConflictResolutionFailureStage.streamResponse
        do {
            let response = try await runConflictResolutionTurn(
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
            let parsed: AIConflictResolutionResponse
            do {
                parsed = try parseAIConflictResolution(response.content)
            } catch where response.reachedOutputLimit {
                // Cut off, not malformed.
                stage = .streamResponse
                throw outputLimitReachedError()
            }

            stage = .validateResponse
            let checked = checkResolutions(parsed, files)
            var result = ChunkResult()
            if !checked.resolutions.isEmpty {
                result.resolutions = checked.resolutions
                result.summaries = parsed.summary.map { [AIChunkSummary(markdown: $0, paths: checked.resolutions.map(\.path))] } ?? []
                result.references = parsed.references
            }
            if checked.unresolved.isEmpty {
                return result
            }
            if !retried {
                log.warning("Conflict resolution left \(checked.unresolved.count, privacy: .public) file(s) unresolved, retrying them")
                let unresolved = checked.unresolved.map(\.path).exactSet
                let again = files.filter { unresolved.contains(ExactString($0.path)) }
                result.append(
                    try await resolveChunk(again, request: request, provider: provider, retried: true, onReasoningSnippet: onReasoningSnippet)
                )
                return result
            }
            log.warning("Conflict resolution left \(checked.unresolved.count, privacy: .public) file(s) unresolved after a retry")
            result.failedFiles = checked.unresolved.map { file in
                AIFailedFile(
                    path: file.path,
                    error: AIConflictResolutionError(file.error, stage: file.stage, retryState: .failedAfterValidationRetry)
                )
            }
            return result
        } catch {
            // Never retry a user-initiated abort.
            if error is AIConflictResolutionAbortError {
                throw error
            }

            // Ask again for a response that couldn't be read.
            if error is AIValidationError, !retried {
                retried = true
                log.warning("Conflict resolution parse failed, retrying")
                continue
            }

            let kind = (error as? AIProviderError)?.kind
            if files.count > 1, kind == .requestTooLarge || kind == .outputLimitReached {
                log.warning("Conflict resolution request too large for the model, splitting \(files.count, privacy: .public) files")
                let (first, second) = splitInHalf(files)
                var result = try await resolveChunk(first, request: request, provider: provider, retried: retried, onReasoningSnippet: onReasoningSnippet)
                if result.haltingError != nil {
                    result.notAttemptedFiles += second.map(\.path)
                    return result
                }
                result.append(
                    try await resolveChunk(second, request: request, provider: provider, retried: retried, onReasoningSnippet: onReasoningSnippet)
                )
                return result
            }

            log.warning("Failed to resolve conflicts: \(describeForLog(error), privacy: .public)")
            let failure = AIConflictResolutionError(
                error,
                stage: stage,
                retryState: retried ? .failedAfterValidationRetry : .notRetried
            )
            var result = ChunkResult()
            result.failedFiles = files.map { AIFailedFile(path: $0.path, error: failure) }
            if (error as? AIProviderError)?.affectsAllRequests == true {
                result.haltingError = failure
            }
            return result
        }
    }
}

/// `files` in two, in order, with about half the conflict content in each.
private func splitInHalf(_ files: [FileConflictContext]) -> ([FileConflictContext], [FileConflictContext]) {
    let sizes = files.map(conflictContentSize)
    let half = sizes.reduce(0, +) / 2
    var index = 1
    var size = sizes[0]
    while index < files.count - 1, size + sizes[index] <= half {
        size += sizes[index]
        index += 1
    }
    return (Array(files[..<index]), Array(files[index...]))
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
    /// entries replaced by the retry's, and the retry's summaries and the
    /// references not already here added after this outcome's. Paths are
    /// compared by code units.
    public func merging(_ retry: ConflictResolutionOutcome) -> ConflictResolutionOutcome {
        let retried = (retry.resolutions.map(\.path) + retry.failedFiles.map(\.path) + retry.notAttemptedFiles).exactSet
        let skipped = skippedFiles.map(\.path).exactSet
        return ConflictResolutionOutcome(
            resolutions: resolutions.filter { !retried.contains(ExactString($0.path)) } + retry.resolutions,
            summary: AIResolutionSummary(
                summaries: summary.summaries + retry.summary.summaries,
                ourLabel: summary.ourLabel,
                theirLabel: summary.theirLabel,
                references: summary.references + retry.summary.references.filter { !summary.references.contains($0) }
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
            summaries: response.summaries,
            ourLabel: context.ourLabel,
            theirLabel: context.theirLabel,
            references: references
        ),
        skippedFiles: skippedFiles,
        failedFiles: response.failedFiles,
        notAttemptedFiles: response.notAttemptedFiles
    )
}
