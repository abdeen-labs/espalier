// `resolveConflicts` with a scripted provider, including partial failures,
// empty rounds, and provider errors.

@testable import AIKit
import Foundation
import Testing
import TestSupport

private func context(_ files: [FileConflictContext]) -> ConflictResolutionContext {
    ConflictResolutionContext(ourLabel: "main", theirLabel: "feature", files: files)
}

private func resolutionError(_ body: () async throws -> Void) async -> AIConflictResolutionError? {
    do {
        try await body()
        Issue.record("Expected an AIConflictResolutionError")
        return nil
    } catch let error as AIConflictResolutionError {
        return error
    } catch {
        Issue.record("Expected an AIConflictResolutionError, got \(error)")
        return nil
    }
}

/// Holds the first requests until `count` of them are in flight together,
/// proving they run concurrently, and records the peak concurrency. A
/// cancelled request (as a test's hang guard cancels it) stops waiting.
private final class StartGate: Sendable {
    private struct State {
        var started = 0
        var inFlight = 0
        var peak = 0
        var waiting: [Int: CheckedContinuation<Void, Never>] = [:]
    }

    private let count: Int
    private let state = Locked(State())

    init(holdingUntil count: Int) {
        self.count = count
    }

    func enter() async {
        let (index, released) = state.withLock { state in
            state.started += 1
            state.inFlight += 1
            state.peak = max(state.peak, state.inFlight)
            guard state.started == count else {
                return (state.started, [CheckedContinuation<Void, Never>]())
            }
            defer { state.waiting = [:] }
            return (state.started, Array(state.waiting.values))
        }
        released.forEach { $0.resume() }
        guard index < count else {
            return
        }
        await withTaskCancellationHandler {
            await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                let open = state.withLock { state in
                    guard state.started < count, !Task.isCancelled else {
                        return true
                    }
                    state.waiting[index] = continuation
                    return false
                }
                if open {
                    continuation.resume()
                }
            }
        } onCancel: {
            state.withLock { $0.waiting.removeValue(forKey: index) }?.resume()
        }
    }

    func leave() {
        state.withLock { $0.inFlight -= 1 }
    }

    var maxInFlight: Int {
        state.withLock { $0.peak }
    }
}

/// Collects progress reports.
private final class ProgressLog: Sendable {
    private let reports = Locked([ConflictResolutionProgress]())

    func record(_ progress: ConflictResolutionProgress) {
        reports.withLock { $0.append(progress) }
    }

    var all: [ConflictResolutionProgress] {
        reports.withLock { $0 }
    }
}

@Suite("Conflict resolution", .hangGuard(minutes: 5))
struct ConflictResolverTests {
    @Test("resolves a small set of files in one prompt, streaming the reasoning as sentences")
    func singlePrompt() async throws {
        let files = [conflictedFile("a.ts"), conflictedFile("b.ts", hunks: 2), FileConflictContext(path: "c.ts", hunks: [], deletedSide: .theirs)]
        let provider = ScriptedProvider { request in
            .content(resolvingEverything(request.userPrompt), reasoning: ["Both sides add ", "imports. Keep both.\nThen", " check b"])
        }
        let progress = ProgressLog()

        let response = try await resolveConflicts(
            context: context(files),
            model: scriptedModel(effort: .medium),
            using: provider,
            onProgress: progress.record
        )

        #expect(response.resolutions.map(\.path) == ["a.ts", "b.ts", "c.ts"])
        #expect(response.resolutions[0].resolvedContent == "line 0\nresolved a.ts 0\nend")
        #expect(response.resolutions[1].resolvedContent == "line 0\nresolved b.ts 0\nline 1\nresolved b.ts 1\nend")
        #expect(response.resolutions[2].deleteConflictAction == .keep)
        #expect(response.summaries == [AIChunkSummary(markdown: "### Conflicting changes\nA.\n\n### Resolution\nB.", paths: ["a.ts", "b.ts", "c.ts"])])
        #expect(response.failedFiles.isEmpty)
        #expect(
            progress.all == [
                ConflictResolutionProgress(filesResolved: 0, filesTotal: 3),
                ConflictResolutionProgress(filesResolved: 0, filesTotal: 3, reasoningSnippet: "Both sides add imports."),
                ConflictResolutionProgress(filesResolved: 0, filesTotal: 3, reasoningSnippet: "Keep both."),
                ConflictResolutionProgress(filesResolved: 0, filesTotal: 3, reasoningSnippet: "Then check b"),
                ConflictResolutionProgress(filesResolved: 3, filesTotal: 3),
            ]
        )

        let request = try #require(provider.requests.first)
        #expect(provider.requests.count == 1)
        #expect(request.model == "scripted-model")
        #expect(request.reasoningEffort == .medium)
        #expect(request.maxOutputTokens == 64_000)
        #expect(request.timeout == .milliseconds(DefaultConflictResolutionTimeoutMs))
        #expect(request.systemPrompt == ConflictResolutionSystemPrompt)
        #expect(request.userPrompt == formatConflictContextForPrompt(context(files)))
    }

    @Test("sends only resolvable files, and returns nothing without asking when none are")
    func skippedFiles() async throws {
        let provider = ScriptedProvider { .content(resolvingEverything($0.userPrompt)) }
        let skipped = FileConflictContext(path: "big.min.js", hunks: [], skippedReason: "Conflict region too large to resolve automatically")

        let response = try await resolveConflicts(
            context: context([skipped, conflictedFile("a.ts")]),
            model: scriptedModel(),
            using: provider
        )
        #expect(response.resolutions.map(\.path) == ["a.ts"])
        #expect(!(provider.requests.first?.userPrompt.contains("big.min.js") ?? true))

        let nothing = try await resolveConflicts(context: context([skipped]), model: scriptedModel(), using: provider)
        #expect(nothing.resolutions.isEmpty)
        #expect(provider.requests.count == 1)
    }

    @Test("puts the repository's instructions ahead of the system prompt and uses the provider's timeout")
    func instructionsAndTimeout() async throws {
        let provider = ScriptedProvider { .content(resolvingEverything($0.userPrompt)) }

        _ = try await resolveConflicts(
            context: context([conflictedFile("a.ts")]),
            model: scriptedModel(timeout: .seconds(45)),
            using: provider,
            repositoryInstructions: [RepositoryInstructions(path: ".github/copilot-instructions.md", content: "Prefer tabs.")]
        )

        let request = try #require(provider.requests.first)
        #expect(request.timeout == .seconds(45))
        #expect(request.systemPrompt.hasSuffix(ConflictResolutionSystemPrompt))
        #expect(request.systemPrompt.contains("Source: .github/copilot-instructions.md\n\nPrefer tabs."))
        #expect(request.systemPrompt.range(of: #"<repository-instructions-[0-9a-f]{16}>"#, options: .regularExpression) != nil)
    }

    @Test("retries once when the response can't be parsed")
    func retriesValidation() async throws {
        let attempts = Locked(0)
        let provider = ScriptedProvider { request in
            let attempt = attempts.withLock { count in
                count += 1
                return count
            }
            return .content(attempt == 1 ? "not json" : resolvingEverything(request.userPrompt))
        }

        let response = try await resolveConflicts(context: context([conflictedFile("a.ts")]), model: scriptedModel(), using: provider)

        #expect(response.resolutions.count == 1)
        #expect(provider.requests.count == 2)
    }

    @Test("fails after the retry when the response is still unusable")
    func failsAfterRetry() async throws {
        let provider = ScriptedProvider { _ in .content(#"{"resolutions":[]}"#) }

        let error = await resolutionError {
            _ = try await resolveConflicts(context: context([conflictedFile("a.ts")]), model: scriptedModel(), using: provider)
        }

        #expect(error?.stage == .parseResponse)
        #expect(error?.retryState == .failedAfterValidationRetry)
        #expect(error?.underlyingError is AIValidationError)
        #expect(provider.requests.count == 2)
    }

    @Test("retries a response that would leave conflict markers or misuse an action, as it retries other invalid ones")
    func retriesUnresolvedResponses() async throws {
        let attempts = Locked(0)
        let provider = ScriptedProvider { request in
            let attempt = attempts.withLock { count in
                count += 1
                return count
            }
            switch attempt {
            case 1:
                // A single marker in the resolved content.
                return .content(resolvingEverything(request.userPrompt).replacingOccurrences(of: "resolved a.ts 0", with: #"merged\n>>>>>>> feature"#))
            default:
                return .content(resolvingEverything(request.userPrompt))
            }
        }

        let response = try await resolveConflicts(context: context([conflictedFile("a.ts")]), model: scriptedModel(), using: provider)

        #expect(response.resolutions.map(\.resolvedContent) == ["line 0\nresolved a.ts 0\nend"])
        #expect(provider.requests.count == 2)

        // An action for a text conflict, twice: the chunk fails validation.
        let actions = ScriptedProvider { _ in
            .content(#"{"resolutions":[{"path":"a.ts","action":"delete","hunks":[],"reasoning":"Gone."}]}"#)
        }
        let error = await resolutionError {
            _ = try await resolveConflicts(context: context([conflictedFile("a.ts")]), model: scriptedModel(), using: actions)
        }
        #expect(error?.stage == .validateResponse)
        #expect(error?.retryState == .failedAfterValidationRetry)
        #expect(actions.requests.count == 2)
    }

    @Test("fails on a response for the wrong files, at the validation stage")
    func validationStage() async throws {
        let provider = ScriptedProvider { _ in .content(resolvingEverything("## File: other.ts\n### Conflict 1 of 1")) }

        let error = await resolutionError {
            _ = try await resolveConflicts(context: context([conflictedFile("a.ts")]), model: scriptedModel(), using: provider)
        }

        #expect(error?.stage == .validateResponse)
        #expect(error?.retryState == .failedAfterValidationRetry)
    }

    @Test("fails fast, without retrying, on an empty response")
    func emptyResponse() async throws {
        let provider = ScriptedProvider { _ in ScriptedTurn(response: AIResponse(content: "")) }

        let error = await resolutionError {
            _ = try await resolveConflicts(context: context([conflictedFile("a.ts")]), model: scriptedModel(), using: provider)
        }

        #expect(error?.stage == .streamResponse)
        #expect(error?.retryState == .notRetried)
        #expect(error?.underlyingError is AIResponseError)
        #expect(provider.requests.count == 1)
    }

    // Provider failures are the same errors as in commit message generation.
    @Test("surfaces provider errors with their display info")
    func providerErrors() async throws {
        let providerError = parseProviderErrorResponse(statusCode: 429, responseText: #"{"error":{"message":"Nope"}}"#, retryAfter: "5")
        let provider = ScriptedProvider { _ in throw providerError }

        let error = await resolutionError {
            _ = try await resolveConflicts(context: context([conflictedFile("a.ts")]), model: scriptedModel(), using: provider)
        }

        #expect(error?.stage == .streamResponse)
        #expect(error?.retryState == .notRetried)
        #expect(error?.underlyingError as? AIProviderError == providerError)
        let displayInfo = try #require(error.flatMap { getAIErrorDisplayInfo(for: $0) })
        #expect(displayInfo.message == "Nope")
        #expect(provider.requests.count == 1)
    }

    @Test("resolves larger sets in concurrent chunks and merges them in order, with each chunk's summary and references")
    func chunks() async throws {
        let files = (0..<25).map { conflictedFile("file\($0).ts") }
        let gate = StartGate(holdingUntil: 2)
        let commit = AIConflictReference(type: .commit, id: "abc1234")
        let pullRequest = AIConflictReference(type: .pullRequest, id: "7")
        let provider = ScriptedProvider { request in
            await gate.enter()
            defer { gate.leave() }
            let first = promptFiles(request.userPrompt).first?.path ?? ""
            return .content(
                resolvingEverything(
                    request.userPrompt,
                    summary: "From \(first)",
                    references: first == "file0.ts" ? [commit] : [commit, pullRequest]
                )
            )
        }
        let progress = ProgressLog()

        let response = try await resolveConflicts(context: context(files), model: scriptedModel(), using: provider, onProgress: progress.record)

        #expect(provider.requests.count == 2)
        #expect(gate.maxInFlight == 2)
        #expect(response.resolutions.map(\.path) == files.map(\.path))
        #expect(response.failedFiles.isEmpty)
        #expect(
            response.summaries == [
                AIChunkSummary(markdown: "From file0.ts", paths: files.prefix(20).map(\.path)),
                AIChunkSummary(markdown: "From file20.ts", paths: files.suffix(5).map(\.path)),
            ]
        )
        #expect(response.references == [commit, pullRequest])
        #expect(
            progress.all == [
                ConflictResolutionProgress(filesResolved: 0, filesTotal: 25),
                ConflictResolutionProgress(filesResolved: 20, filesTotal: 25),
                ConflictResolutionProgress(filesResolved: 25, filesTotal: 25),
                ConflictResolutionProgress(filesResolved: 25, filesTotal: 25),
            ]
        )
    }

    @Test("runs at most five chunks at a time")
    func boundedConcurrency() async throws {
        // 120 files: chunks of 15, so 8 chunks in batches of 5 and 3.
        let files = (0..<120).map { conflictedFile("file\($0).ts") }
        let gate = StartGate(holdingUntil: MaxConcurrentChunks)
        let provider = ScriptedProvider { request in
            await gate.enter()
            defer { gate.leave() }
            return .content(resolvingEverything(request.userPrompt))
        }

        let response = try await resolveConflicts(context: context(files), model: scriptedModel(), using: provider)

        #expect(provider.requests.count == 8)
        #expect(gate.maxInFlight == MaxConcurrentChunks)
        #expect(response.resolutions.count == 120)
        #expect(promptFiles(provider.requests[0].userPrompt).count == 15)
    }

    @Test("keeps successful chunks and reports the failed chunk's files, which can be retried")
    func partialFailure() async throws {
        let files = (0..<25).map { conflictedFile("file\($0).ts") }
        let failing = Locked(true)
        let provider = ScriptedProvider { request in
            if failing.withLock({ $0 }), request.userPrompt.contains("## File: file24.ts") {
                throw AIProviderError(kind: .server, message: "Overloaded", statusCode: 529)
            }
            return .content(resolvingEverything(request.userPrompt))
        }
        let resolutionContext = context(files)

        let response = try await resolveConflicts(context: resolutionContext, model: scriptedModel(), using: provider)

        #expect(response.resolutions.map(\.path) == files.prefix(20).map(\.path))
        #expect(response.failedFiles.map(\.path) == files.suffix(5).map(\.path))
        let failure = try #require(response.failedFiles.first?.error)
        #expect(failure.stage == .streamResponse)
        #expect((failure.underlyingError as? AIProviderError)?.kind == .server)
        #expect(response.summaries.map(\.paths) == [files.prefix(20).map(\.path)])

        // Retry just the failed files and merge the results in.
        failing.withLock { $0 = false }
        let retry = try await resolveConflicts(
            context: resolutionContext.restricted(to: response.failedFiles.map(\.path)),
            model: scriptedModel(),
            using: provider
        )
        #expect(promptFiles(try #require(provider.requests.last).userPrompt).map(\.path) == files.suffix(5).map(\.path))
        let merged = response.merging(retry)
        #expect(Set(merged.resolutions.map(\.path)) == Set(files.map(\.path)))
        #expect(merged.failedFiles.isEmpty)
        #expect(merged.summaries.map(\.paths) == [files.prefix(20).map(\.path), files.suffix(5).map(\.path)])
    }

    @Test("stops starting chunks after an error that would fail them all")
    func haltsOnGlobalErrors() async throws {
        let files = (0..<120).map { conflictedFile("file\($0).ts") }
        let failing = Locked(true)
        let provider = ScriptedProvider { request in
            if failing.withLock({ $0 }), request.userPrompt.contains("## File: file0.ts") {
                throw AIProviderError(kind: .authentication, message: "Invalid API key", statusCode: 401)
            }
            return .content(resolvingEverything(request.userPrompt))
        }

        let response = try await resolveConflicts(context: context(files), model: scriptedModel(), using: provider)

        // The first batch of 5 chunks ran; the second batch never started.
        #expect(provider.requests.count == 5)
        #expect(response.resolutions.count == 60)
        // Only the chunk that failed has an error. The 45 files of the
        // batch that never started aren't reported with that chunk's error,
        // as if they had failed the same way.
        #expect(response.failedFiles.map(\.path) == (0..<15).map { "file\($0).ts" })
        #expect(response.failedFiles.allSatisfy { ($0.error.underlyingError as? AIProviderError)?.kind == .authentication })
        #expect(response.notAttemptedFiles == (75..<120).map { "file\($0).ts" })
        #expect(Set(response.resolutions.map(\.path) + response.failedFiles.map(\.path) + response.notAttemptedFiles).count == 120)

        let outcome = makeConflictResolutionOutcome(response, context: context(files))
        #expect(outcome.notAttemptedFiles == response.notAttemptedFiles)

        // Retry the failed and unattempted files together.
        failing.withLock { $0 = false }
        let retry = try await resolveConflicts(
            context: context(files).restricted(to: response.failedFiles.map(\.path) + response.notAttemptedFiles),
            model: scriptedModel(),
            using: provider
        )
        let merged = response.merging(retry)
        #expect(Set(merged.resolutions.map(\.path)) == Set(files.map(\.path)))
        #expect(merged.failedFiles.isEmpty)
        #expect(merged.notAttemptedFiles.isEmpty)
    }

    @Test("throws the first failure when every chunk fails")
    func allChunksFail() async throws {
        let files = (0..<25).map { conflictedFile("file\($0).ts") }
        let provider = ScriptedProvider { _ in throw AIProviderError(kind: .server, message: "Down", statusCode: 500) }

        let error = await resolutionError {
            _ = try await resolveConflicts(context: context(files), model: scriptedModel(), using: provider)
        }

        #expect((error?.underlyingError as? AIProviderError)?.message == "Down")
    }

    @Test("stops when the task is cancelled, without retrying", arguments: [3, 25])
    func cancellation(fileCount: Int) async throws {
        let files = (0..<fileCount).map { conflictedFile("file\($0).ts") }
        let (started, startedContinuation) = AsyncStream.makeStream(of: Void.self)
        let provider = ScriptedProvider { _ in
            startedContinuation.yield()
            try await Task.sleep(for: .seconds(60))
            throw AIProviderError(kind: .server, message: "unreachable")
        }

        let task = Task {
            try await resolveConflicts(context: context(files), model: scriptedModel(), using: provider)
        }
        // Wait until every chunk's request is in flight.
        var waiting = fileCount > SinglePromptFileLimit ? 2 : 1
        for await _ in started {
            waiting -= 1
            if waiting == 0 {
                break
            }
        }
        task.cancel()

        await #expect(throws: AIConflictResolutionAbortError.self) {
            _ = try await task.value
        }
        #expect(provider.requests.count == (fileCount > SinglePromptFileLimit ? 2 : 1))
    }

    @Test("wraps invalid provider settings at the create-client stage")
    func invalidConfiguration() async throws {
        var model = scriptedModel()
        model.provider.baseUrl = "http://example.com/v1"

        let error = await resolutionError {
            _ = try await resolveConflicts(context: context([conflictedFile("a.ts")]), model: model)
        }

        #expect(error?.stage == .createClient)
        #expect((error?.underlyingError as? AIProviderError)?.kind == .invalidConfiguration)
    }
}

@Suite("Conflict resolution turn")
struct ConflictResolutionTurnTests {
    @Test("splits reasoning into sentences and flushes it when the response starts")
    func sentences() async throws {
        let provider = ScriptedProvider { _ in
            ScriptedTurn(
                events: [
                    .reasoning("Step 1. Look at"), .reasoning(" the imports! Both"), .reasoning(" sides\n\nadd lines"),
                    .content("{"), .reasoning("Late thought."), .content("}"),
                ],
                response: AIResponse(content: "{}")
            )
        }
        let snippets = Locked([String]())

        let content = try await runConflictResolutionTurn(provider: provider, request: testRequest()) { snippet in
            snippets.withLock { $0.append(snippet) }
        }

        #expect(content == "{}")
        #expect(snippets.withLock { $0 } == ["Step 1. Look at the imports!", "Both sides", "add lines", "Late thought."])
    }
}

@Suite("Conflict resolution outcome")
struct ConflictResolutionOutcomeTests {
    private let commit = ConflictContextCommit(sha: "abc1234".padding(toLength: 40, withPad: "0", startingAt: 0), shortSha: "abc1234", summary: "Add greetings", isOnRemote: true)

    @Test("resolves cited references, falls back when none are cited, and lists skipped files")
    func outcome() {
        let resolutionContext = ConflictResolutionContext(
            ourLabel: "main",
            theirLabel: "feature",
            files: [
                FileConflictContext(path: "a.ts", hunks: []),
                FileConflictContext(path: "big.js", hunks: [], skippedReason: "File too large to resolve automatically"),
            ],
            theirCommits: [commit]
        )
        let resolution = FileResolution(path: "a.ts", resolvedContent: "x", reasoning: "r")

        let cited = makeConflictResolutionOutcome(
            ReassembledConflictResolutionResponse(
                resolutions: [resolution],
                summaries: [AIChunkSummary(markdown: "S", paths: ["a.ts"])],
                references: [AIConflictReference(type: .commit, id: "abc1234")]
            ),
            context: resolutionContext
        )
        #expect(cited.resolutions == [resolution])
        #expect(
            cited.summary
                == AIResolutionSummary(
                    summaries: [AIChunkSummary(markdown: "S", paths: ["a.ts"])],
                    ourLabel: "main",
                    theirLabel: "feature",
                    references: [.commit(commit)]
                )
        )
        #expect(cited.skippedFiles == [AISkippedFile(path: "big.js", reason: "File too large to resolve automatically")])
        #expect(cited.failedFiles.isEmpty)

        let uncited = makeConflictResolutionOutcome(
            ReassembledConflictResolutionResponse(resolutions: [resolution], summaries: [], references: []),
            context: resolutionContext
        )
        #expect(uncited.summary.references == [.commit(commit)])
        #expect(uncited.summary.summaries.isEmpty)
    }

    @Test("produces a complete, empty outcome for a round with nothing to resolve")
    func emptyRound() async throws {
        let skippedOnly = ConflictResolutionContext(
            ourLabel: "main",
            theirLabel: "feature",
            files: [FileConflictContext(path: "big.js", hunks: [], skippedReason: "File could not be read")]
        )
        let provider = ScriptedProvider { _ in throw AIProviderError(kind: .server, message: "unused") }

        let response = try await resolveConflicts(context: skippedOnly, model: scriptedModel(), using: provider)
        let outcome = makeConflictResolutionOutcome(response, context: skippedOnly)

        #expect(outcome.resolutions.isEmpty)
        #expect(outcome.failedFiles.isEmpty)
        #expect(outcome.summary.summaries.isEmpty)
        #expect(outcome.summary.references.isEmpty)
        #expect(outcome.skippedFiles == [AISkippedFile(path: "big.js", reason: "File could not be read")])
        #expect(provider.requests.isEmpty)
    }

    @Test("merges a retry of failed files, adding its summary and the references it adds")
    func merging() {
        let failure = AIConflictResolutionError(AIProviderError(kind: .server, message: "Down"), stage: .streamResponse)
        let pullRequest = ConflictContextPullRequest(number: 7, title: "Greet in French", body: "")
        let first = ConflictResolutionOutcome(
            resolutions: [FileResolution(path: "a.ts", resolvedContent: "a", reasoning: "r")],
            summary: AIResolutionSummary(
                summaries: [AIChunkSummary(markdown: "A", paths: ["a.ts"])],
                ourLabel: "main",
                theirLabel: "feature",
                references: [.commit(commit)]
            ),
            skippedFiles: [AISkippedFile(path: "big.js", reason: "too large")],
            failedFiles: [AIFailedFile(path: "b.ts", error: failure), AIFailedFile(path: "c.ts", error: failure)]
        )
        let retry = ConflictResolutionOutcome(
            resolutions: [FileResolution(path: "b.ts", resolvedContent: "b", reasoning: "r")],
            summary: AIResolutionSummary(
                summaries: [AIChunkSummary(markdown: "B", paths: ["b.ts"])],
                ourLabel: "main",
                theirLabel: "feature",
                references: [.pullRequest(pullRequest), .commit(commit)]
            ),
            skippedFiles: [],
            failedFiles: [AIFailedFile(path: "c.ts", error: failure)]
        )

        let merged = first.merging(retry)

        #expect(merged.resolutions.map(\.path) == ["a.ts", "b.ts"])
        #expect(merged.failedFiles.map(\.path) == ["c.ts"])
        #expect(merged.skippedFiles.map(\.path) == ["big.js"])
        #expect(merged.summary.summaries == [AIChunkSummary(markdown: "A", paths: ["a.ts"]), AIChunkSummary(markdown: "B", paths: ["b.ts"])])
        #expect(merged.summary.references == [.commit(commit), .pullRequest(pullRequest)])
    }

    @Test("merges a retry of unattempted files, comparing paths by code units")
    func mergingNotAttempted() {
        let failure = AIConflictResolutionError(AIProviderError(kind: .authentication, message: "Bad key"), stage: .streamResponse)
        let summary = AIResolutionSummary(summaries: [], ourLabel: "main", theirLabel: "feature", references: [])
        let first = ConflictResolutionOutcome(
            resolutions: [FileResolution(path: "a.ts", resolvedContent: "a", reasoning: "r")],
            summary: summary,
            skippedFiles: [],
            failedFiles: [AIFailedFile(path: "b.ts", error: failure)],
            notAttemptedFiles: ["c.ts", "caf\u{E9}.ts"]
        )
        let retry = ConflictResolutionOutcome(
            resolutions: [
                FileResolution(path: "b.ts", resolvedContent: "b", reasoning: "r"),
                FileResolution(path: "c.ts", resolvedContent: "c", reasoning: "r"),
            ],
            summary: summary,
            skippedFiles: [],
            failedFiles: [],
            notAttemptedFiles: ["cafe\u{301}.ts"]
        )

        let merged = first.merging(retry)

        #expect(merged.resolutions.map(\.path) == ["a.ts", "b.ts", "c.ts"])
        #expect(merged.failedFiles.isEmpty)
        // Two different paths, as in JavaScript; neither replaces the other.
        #expect(merged.notAttemptedFiles.map { Array($0.unicodeScalars) } == [Array("caf\u{E9}.ts".unicodeScalars), Array("cafe\u{301}.ts".unicodeScalars)])
    }
}
