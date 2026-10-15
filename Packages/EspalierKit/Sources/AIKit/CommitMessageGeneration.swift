// Ported from desktop/app/src/lib/stores/copilot-store.ts (generateCommitMessage)

import EspalierSupport
import Foundation
import os

/// Default per-request timeout (in milliseconds) for commit message
/// generation. Providers may override it with `requestTimeoutSeconds`
/// (`AIModelRequest.timeout`).
public let DefaultAIRequestTimeoutMs = 60_000

/// The output token limit for commit message requests. Anthropic requires
/// one; it leaves room for thinking at high effort.
let CommitMessageMaxOutputTokens = 16_000

/// The most of a diff, in bytes of UTF-8, sent to generate a commit message:
/// 128 KB, about 35,000 tokens of code.
let MaxCommitMessageDiffSize = 131_072

/// The least of a file's patch worth sending: about ten lines. When the
/// patches can't all have that much (or all of a shorter one), only the
/// first ones that can are sent.
private let MinCommitMessageDiffShare = 512

/// `diff` cut down to about `limit` bytes of UTF-8 (`MaxCommitMessageDiffSize`)
/// when it's longer, keeping every file in view rather than only the first
/// ones:
///
/// - The list of changed files that `--patch-with-raw` puts first is kept,
///   up to a quarter of the limit.
/// - The rest is shared among the files' patches: smaller patches are sent
///   whole and the largest are cut short, at a line, ending with
///   `[N more lines left out]`. When there are too many files for each to
///   get `MinCommitMessageDiffShare` (or all of a shorter patch), the first
///   files that can are sent and the rest counted at the end.
func limitDiffForCommitMessage(_ diff: String, limit: Int = MaxCommitMessageDiffSize) -> String {
    guard diff.utf8.count > limit else {
        return diff
    }

    // The file list, then each file's patch from its `diff --git` line.
    var header: [Substring] = []
    var files: [[Substring]] = []
    for scalars in diff.unicodeScalars.split(separator: "\n", omittingEmptySubsequences: false) {
        let line = Substring(scalars)
        if line.hasPrefix("diff --git ") {
            files.append([line])
        } else if files.isEmpty {
            header.append(line)
        } else {
            files[files.count - 1].append(line)
        }
    }

    var output = keepLines(header, budget: files.isEmpty ? limit : limit / 4) ?? []
    var remaining = limit - linesSize(output)
    let sizes = files.map(linesSize)
    var sent = 0
    var needed = 0
    while sent < files.count {
        let need = min(sizes[sent], MinCommitMessageDiffShare)
        if sent > 0, needed + need > remaining {
            break
        }
        needed += need
        sent += 1
    }
    var leftOut = files.count - sent

    // Water filling: each patch, smallest first, gets what it needs up to an
    // equal share of what's left.
    var allotments = [Int](repeating: 0, count: sent)
    var sharing = sent
    for index in sizes.indices.prefix(sent).sorted(by: { sizes[$0] < sizes[$1] }) {
        allotments[index] = min(sizes[index], remaining / sharing)
        remaining -= allotments[index]
        sharing -= 1
    }
    for (file, allotment) in zip(files.prefix(sent), allotments) {
        if let kept = keepLines(file, budget: allotment) {
            output += kept
        } else {
            leftOut += 1
        }
    }
    if leftOut > 0 {
        output.append("[The diffs of \(leftOut) more \(leftOut == 1 ? "file" : "files") are left out]")
    }
    return output.joined(separator: "\n")
}

/// The size of lines joined by line breaks, in bytes of UTF-8.
private func linesSize(_ lines: some Collection<Substring>) -> Int {
    lines.reduce(0) { $0 + $1.utf8.count + 1 }
}

/// The lines, or as many of the first ones as fit in `budget` bytes with a
/// last line saying how many were left out; `nil` when none fit.
private func keepLines(_ lines: [Substring], budget: Int) -> [Substring]? {
    if linesSize(lines) <= budget {
        return lines
    }
    // Room for the line saying how many were left out.
    let available = budget - 40
    var kept: [Substring] = []
    var size = 0
    for line in lines {
        let lineSize = line.utf8.count + 1
        guard size + lineSize <= available else {
            break
        }
        kept.append(line)
        size += lineSize
    }
    guard !kept.isEmpty else {
        return nil
    }
    kept.append("[\(lines.count - kept.count) more lines left out]")
    return kept
}

/// Thrown when commit message generation is cancelled by the user (the
/// calling task was cancelled).
public struct CommitMessageGenerationCancelledError: Error, LocalizedError, Sendable, Hashable {
    public init() {}

    public var errorDescription: String? { "Commit message generation was cancelled" }
}

private let log = Log.logger(category: "AIKit")

/// Generates a commit message for the given diff with the selected model.
///
/// - Parameters:
///   - diff: The diff of the changes to be committed, in git format.
///   - model: The model and provider to use (`resolveAIModelRequest`).
///   - commitMessageRules: The repository's commit message rules. The subset
///     the server will evaluate on push is embedded in the user prompt as
///     human-readable constraints so the generated message is more likely to
///     satisfy them. The system prompt is only augmented with a fixed blurb
///     naming the per-request delimiters that wrap those constraints; rule
///     text itself is never embedded in the system channel.
///   - repositoryInstructions: The repository's custom instruction files
///     (`RepositoryInstructionsPaths`), put at the start of the system
///     prompt.
///   - session: The session for the provider's requests.
/// - Returns: The generated title and description.
/// - Throws: `CommitMessageGenerationCancelledError` when the task is
///   cancelled, `AIProviderError` when the provider fails, and
///   `AIResponseError` when the response can't be used.
public func generateCommitMessage(
    diff: String,
    model: AIModelRequest,
    commitMessageRules: [CommitMessageRule] = [],
    repositoryInstructions: [RepositoryInstructions] = [],
    session: URLSession = defaultAIURLSession
) async throws -> AICommitMessage {
    try throwIfCommitMessageGenerationCancelled()
    return try await generateCommitMessage(
        diff: diff,
        model: model,
        using: try makeAIProvider(model.provider, session: session),
        commitMessageRules: commitMessageRules,
        repositoryInstructions: repositoryInstructions
    )
}

/// Generates a commit message with the given provider client. See
/// `generateCommitMessage(diff:model:commitMessageRules:repositoryInstructions:session:)`.
public func generateCommitMessage(
    diff: String,
    model: AIModelRequest,
    using provider: any AIProvider,
    commitMessageRules: [CommitMessageRule] = [],
    repositoryInstructions: [RepositoryInstructions] = []
) async throws -> AICommitMessage {
    try throwIfCommitMessageGenerationCancelled()

    var timeout = Duration.milliseconds(DefaultAIRequestTimeoutMs)
    if let requested = model.timeout, requested > .zero {
        timeout = clampedRequestTimeout(requested)
    }

    let tags = generateCommitMessagePromptTags()
    let cleanedRuleDescriptions = getCleanedEnforcedRuleDescriptions(commitMessageRules)
    let hasRules = !cleanedRuleDescriptions.isEmpty

    // The repository's instructions come first; the commit message prompt
    // follows.
    let systemPrompt =
        buildRepositoryInstructionsPrompt(
            repositoryInstructions,
            open: tags.repositoryInstructionsOpen,
            close: tags.repositoryInstructionsClose
        ) + buildCommitMessageSystemPrompt(hasRules: hasRules, tags: tags)

    // The diff (and any repository rule constraints) are wrapped in
    // per-request tagged blocks so the model can distinguish data from
    // instructions even if either contains literal tag-like text.
    let userPrompt = buildCommitMessageUserPrompt(limitDiffForCommitMessage(diff), tags, cleanedRuleDescriptions)

    do {
        let response = try await provider.complete(
            AIRequest(
                model: model.modelId,
                systemPrompt: systemPrompt,
                userPrompt: userPrompt,
                reasoningEffort: model.reasoningEffort,
                maxOutputTokens: CommitMessageMaxOutputTokens,
                timeout: timeout
            )
        )

        try throwIfCommitMessageGenerationCancelled()

        guard !response.content.isEmpty else {
            throw response.reachedOutputLimit ? outputLimitReachedError() : AIResponseError("No response from the model")
        }

        do {
            return try parseAICommitMessage(response.content)
        } catch where response.reachedOutputLimit {
            // The message was cut off, not malformed.
            throw outputLimitReachedError()
        }
    } catch {
        if error is CommitMessageGenerationCancelledError {
            throw error
        }
        if error is CancellationError || Task.isCancelled {
            throw CommitMessageGenerationCancelledError()
        }
        log.warning("Failed to generate a commit message: \(describeForLog(error), privacy: .public)")
        throw error
    }
}

private func throwIfCommitMessageGenerationCancelled() throws {
    if Task.isCancelled {
        throw CommitMessageGenerationCancelledError()
    }
}

/// An error's type and classification, without its message: provider
/// messages and model output stay out of the log.
func describeForLog(_ error: any Error) -> String {
    switch error {
    case let error as AIProviderError:
        "AIProviderError(\(error.kind.rawValue), status: \(error.statusCode.map(String.init) ?? "none"))"
    case let error as AIConflictResolutionError:
        "AIConflictResolutionError(\(error.stage.rawValue), \(error.retryState.rawValue), \(describeForLog(error.underlyingError)))"
    default:
        String(describing: type(of: error))
    }
}
