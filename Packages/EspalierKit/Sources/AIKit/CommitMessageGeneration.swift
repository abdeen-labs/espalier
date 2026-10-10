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
    let userPrompt = buildCommitMessageUserPrompt(diff, tags, cleanedRuleDescriptions)

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
            throw AIResponseError("No response from the model")
        }

        return try parseAICommitMessage(response.content)
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
