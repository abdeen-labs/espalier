// Ported from desktop/app/src/lib/copilot-conflict-resolution.ts

import EspalierSupport
import Foundation

// MARK: Types

/// A conflicted file that the model did not resolve, along with the reason
/// it was skipped (e.g. too large, unreadable, no parseable markers). Shown
/// with the results so the user can resolve it manually.
public struct AISkippedFile: Sendable, Hashable {
    /// Repository-relative file path that was skipped.
    public var path: String
    /// Human-readable reason the file was skipped.
    public var reason: String

    public init(path: String, reason: String) {
        self.path = path
        self.reason = reason
    }
}

/// The model's recommendation for a delete-vs-modify conflict.
public enum DeleteConflictAction: String, Sendable, Hashable, Codable {
    /// Keep the modified file.
    case keep
    /// Accept the deletion.
    case delete
}

/// Resolution suggestion for a single conflicted file.
public struct FileResolution: Sendable, Hashable {
    /// Repository-relative file path that was resolved.
    public var path: String
    /// The fully resolved file content (all conflict markers removed).
    public var resolvedContent: String
    /// Human-readable explanation of how and why conflicts were resolved this way.
    public var reasoning: String
    /// For delete-vs-modify conflicts: the model's recommendation. When
    /// present, `resolvedContent` is not meaningful; the resolution is
    /// applied as a manual conflict resolution (keep = the side that didn't
    /// delete the file, delete = the side that did).
    public var deleteConflictAction: DeleteConflictAction?

    public init(path: String, resolvedContent: String, reasoning: String, deleteConflictAction: DeleteConflictAction? = nil) {
        self.path = path
        self.resolvedContent = resolvedContent
        self.reasoning = reasoning
        self.deleteConflictAction = deleteConflictAction
    }
}

/// Resolution for a single conflict hunk as returned by the model.
public struct HunkResolution: Sendable, Hashable {
    /// The resolved content that replaces the conflict marker block.
    public var resolvedContent: String

    public init(resolvedContent: String) {
        self.resolvedContent = resolvedContent
    }
}

/// Per-file resolution from the model's raw response (before reassembly).
public struct RawFileResolution: Sendable, Hashable {
    /// Repository-relative file path.
    public var path: String
    /// Resolved content for each conflict hunk, in order.
    public var hunks: [HunkResolution]
    /// Human-readable explanation of the resolution strategy for this file.
    public var reasoning: String
    /// For delete-vs-modify conflicts: keep the modified file or accept the
    /// deletion. When present, `hunks` is empty.
    public var action: DeleteConflictAction?

    public init(path: String, hunks: [HunkResolution], reasoning: String, action: DeleteConflictAction? = nil) {
        self.path = path
        self.hunks = hunks
        self.reasoning = reasoning
        self.action = action
    }
}

/// The kind of a reference the model cited.
public enum AIConflictReferenceType: String, Sendable, Hashable {
    case pullRequest
    case commit
}

/// A reference the model considered material to its decision.
public struct AIConflictReference: Sendable, Hashable {
    public var type: AIConflictReferenceType
    /// For pull requests, the decimal pull request number (no leading `#`).
    /// For commits, a short or full SHA in hex.
    public var id: String

    public init(type: AIConflictReferenceType, id: String) {
        self.type = type
        self.id = id
    }
}

/// The model's complete conflict resolution response (raw model output).
public struct AIConflictResolutionResponse: Sendable, Hashable {
    /// Per-file resolution with per-hunk resolved content (before reassembly).
    public var resolutions: [RawFileResolution]
    /// Optional markdown summary of the conflict and the resolution strategy.
    /// The system prompt requires exactly two `###` headings
    /// (`### Conflicting changes` and `### Resolution`), but a missing or
    /// malformed value is *not* treated as a fatal error.
    public var summary: String?
    /// Pull requests and commits the model considered material to its
    /// decision. May be empty when the model omitted the field or none of its
    /// references parse.
    public var references: [AIConflictReference]
}

/// A file that a round of conflict resolution couldn't resolve because the
/// request for its chunk failed. Retry it with
/// `ConflictResolutionContext.restricted(to:)`. (Files whose chunk never
/// started are `notAttemptedFiles`, not failures.)
public struct AIFailedFile: Sendable {
    /// Repository-relative path.
    public var path: String
    /// Why its chunk failed. Show it with `getAIErrorDisplayInfo(for:)`.
    public var error: AIConflictResolutionError

    public init(path: String, error: AIConflictResolutionError) {
        self.path = path
        self.error = error
    }
}

/// The conflict resolution response after reassembly: per-file resolutions
/// contain the complete reassembled file content, and the files that failed
/// or weren't attempted are listed. This is what the rest of the app (UI,
/// write path) consumes.
public struct ReassembledConflictResolutionResponse: Sendable {
    /// Reassembled per-file resolutions with full file content.
    public var resolutions: [FileResolution]
    /// Optional markdown summary (passed through from the model).
    public var summary: String?
    /// Structured references (passed through from the model).
    public var references: [AIConflictReference]
    /// Files in chunks that failed while other chunks succeeded. Empty when
    /// every chunk succeeded. (When every chunk fails, resolution throws.)
    public var failedFiles: [AIFailedFile]
    /// Files that were never sent to the model: their chunks were in batches
    /// that weren't started because an earlier chunk failed with an error
    /// that would fail every request (`AIProviderError.affectsAllRequests`;
    /// that chunk's files and error are in `failedFiles`). Retry them like
    /// failed files.
    public var notAttemptedFiles: [String]

    public init(
        resolutions: [FileResolution],
        summary: String?,
        references: [AIConflictReference],
        failedFiles: [AIFailedFile] = [],
        notAttemptedFiles: [String] = []
    ) {
        self.resolutions = resolutions
        self.summary = summary
        self.references = references
        self.failedFiles = failedFiles
        self.notAttemptedFiles = notAttemptedFiles
    }

    /// This response with the results of retrying some of its failed or
    /// unattempted files (`retry`, from a context restricted to those files)
    /// merged in. The retried files' resolutions are added and their old
    /// entries replaced by the retry's; the summary and references are kept
    /// unless this response had none.
    public func merging(_ retry: ReassembledConflictResolutionResponse) -> ReassembledConflictResolutionResponse {
        let retried = (retry.resolutions.map(\.path) + retry.failedFiles.map(\.path) + retry.notAttemptedFiles).exactSet
        return ReassembledConflictResolutionResponse(
            resolutions: resolutions.filter { !retried.contains(ExactString($0.path)) } + retry.resolutions,
            summary: summary ?? retry.summary,
            references: references.isEmpty ? retry.references : references,
            failedFiles: failedFiles.filter { !retried.contains(ExactString($0.path)) } + retry.failedFiles,
            notAttemptedFiles: notAttemptedFiles.filter { !retried.contains(ExactString($0)) } + retry.notAttemptedFiles
        )
    }
}

/// A reference the model cited, resolved against the gathered context so the
/// result can show a real title and link. Because the model can only ever
/// cite data placed in the prompt (its request has no tools), every
/// reference is one of the entries already gathered.
public enum ConflictContextReference: Sendable, Hashable {
    case pullRequest(ConflictContextPullRequest)
    case commit(ConflictContextCommit)
}

/// The context needed to render the resolution summary card, captured once
/// while the data is fresh.
public struct AIResolutionSummary: Sendable, Hashable {
    /// Markdown text written by the model. `nil` when the model omitted it.
    public var markdown: String?
    /// Display label for the *ours* (current) side.
    public var ourLabel: String
    /// Display label for the *theirs* (incoming) side.
    public var theirLabel: String
    /// Curated list of references the model used when making its decision,
    /// resolved against the gathered context: the "Context" list.
    public var references: [ConflictContextReference]

    public init(markdown: String?, ourLabel: String, theirLabel: String, references: [ConflictContextReference]) {
        self.markdown = markdown
        self.ourLabel = ourLabel
        self.theirLabel = theirLabel
        self.references = references
    }
}

/// Progress reported during conflict resolution.
public struct ConflictResolutionProgress: Sendable, Hashable {
    public var filesResolved: Int
    public var filesTotal: Int
    /// A short snippet of the model's live reasoning, when streaming:
    /// reported sentence by sentence so the user can see what the model is
    /// currently thinking about.
    public var reasoningSnippet: String?

    public init(filesResolved: Int, filesTotal: Int, reasoningSnippet: String? = nil) {
        self.filesResolved = filesResolved
        self.filesTotal = filesTotal
        self.reasoningSnippet = reasoningSnippet
    }
}

// MARK: Error

/// A parse or validation failure of the model's response. Distinguishes
/// retryable errors (bad model output) from transport errors (timeouts,
/// authentication), which fail fast.
public struct AIValidationError: Error, LocalizedError, Sendable, Hashable {
    public let message: String

    public init(_ message: String) {
        self.message = message
    }

    public var errorDescription: String? { message }
}

// MARK: Constants

/// Maximum number of files to resolve in a single prompt. When the total
/// exceeds this threshold, files are batched into parallel chunks.
public let SinglePromptFileLimit = 20

/// Maximum number of chunks to resolve concurrently.
public let MaxConcurrentChunks = 5

/// System prompt for conflict resolution.
let ConflictResolutionSystemPrompt = #"""

    Respond ONLY with valid JSON in the format specified below. Do NOT use tools.

    You are an expert Git conflict resolver. Analyze conflicts from merge, rebase, or cherry-pick operations and produce correct, clean resolutions.

    You will receive:
    - Labels for both sides (branch names or commit refs)
    - Conflict markers from each file (ours, theirs, optionally base)
    - Context lines surrounding each conflict
    - Delete-vs-modify conflicts where one side deleted a file and the other modified it
    - When available: recent commit messages and/or PR title/description for intent

    Your job:
    1. Understand the INTENT behind each side's changes
    2. Resolve each conflict by producing the correct merged content for each conflict hunk
    3. For delete-vs-modify conflicts, recommend whether to keep or delete the file
    4. Explain your reasoning per file \#u{2014} terse but specific enough to verify the decision
    5. Produce a brief markdown summary orienting the user to the conflict and resolution

    Resolution guidelines:
    - Make MINIMAL changes \#u{2014} do not refactor, reformat, or alter code outside conflicted regions
    - When both sides add complementary code (e.g., different imports), combine them
    - When both sides modify the same code differently, use commit messages and PR context to decide
    - When one side deletes code the other modifies, check whether the content was relocated rather than simply removed \#u{2014} accept the deletion only when it was intentional
    - When conflicts involve dependency manifests or lock files, ensure version constraints and entries remain consistent across the resolved file
    - Preserve correctness: imports, types, formatting must remain valid
    - When in doubt, prefer backward compatibility

    Response format:
    {
      "summary": "### Conflicting changes\n<1-2 sentences: what each side did and where they collided, attributing each to its #PR or short SHA>\n\n### Resolution\n<1 sentence: how you resolved it; if a side was dropped, bold that trade-off>",
      "references": [
        { "type": "pullRequest", "id": "1234" },
        { "type": "commit", "id": "abc1234" }
      ],
      "resolutions": [
        {
          "path": "relative/file/path.ts",
          "hunks": [
            { "resolvedContent": "merged content that replaces conflict 1" },
            { "resolvedContent": "merged content that replaces conflict 2" }
          ],
          "reasoning": "What each side changed in this file, what you kept, and what you dropped or overrode."
        },
        {
          "path": "deleted-or-modified/file.ts",
          "action": "keep",
          "hunks": [],
          "reasoning": "The file was modified with important changes; the deletion was part of an incomplete refactor."
        }
      ]
    }

    Field rules:

    hunks: An ordered array with one entry per conflict in the file, matching the "Conflict 1 of N", "Conflict 2 of N" order from the input. Each entry's resolvedContent is ONLY the merged content that replaces that specific conflict marker block (the region between <<<<<<< and >>>>>>>). Do NOT include surrounding non-conflicted code \#u{2014} the application splices each resolution into the original file automatically. If the resolution is to accept one side entirely, return that side's content verbatim. For an intentional deletion, use an empty string. For delete-vs-modify conflicts, hunks must be an empty array.

    action: Only for delete-vs-modify conflicts. Set to "keep" to preserve the modified file, or "delete" to accept the deletion. Use commit messages and PR context to determine intent \#u{2014} if the deletion was part of a refactoring that moved functionality elsewhere, prefer "delete"; if the modifications add important functionality that should be preserved, prefer "keep". Omit this field for regular text conflicts.

    reasoning: Terse, direct prose \#u{2014} enough detail to verify the decision, not a wall of text. State what each side did in this file, what you kept, and any trade-off. Typically 1-4 sentences depending on complexity.

    summary: A markdown banner with exactly two ### headings ("Conflicting changes" then "Resolution"). Write natural prose a developer would say to a teammate. Be brief \#u{2014} per-file detail belongs in reasoning, not here. When many files conflicted, summarize them ("several menu components") rather than listing each. Refer to PRs as "#1234" and commits as short SHAs (no URLs \#u{2014} the app linkifies them). Do not address the user as "you"; write "the current branch". Bold any trade-off where one side's change was dropped.

    references: The PRs and commits a reader would open to understand the conflict. Include every genuinely informative one \#u{2014} skip merge commits, WIP/fixup/squash commits, and low-signal messages. "type" is "pullRequest" or "commit"; "id" is the PR number (no #) or hex SHA. Cite the PR instead of its squash-merge commit when both exist. Return an empty array only when no PRs or commits exist in context.

    """#

// MARK: Parsing

/// Normalizes a file path returned by the model. The model may return
/// Windows-style backslashes (`src\file.ts`), a leading `./`, or redundant
/// separators, all of which would cause validation to reject an otherwise
/// correct resolution.
private func normalizeLLMPath(_ raw: String) -> String {
    var path = JSCompat.trim(raw).replacingOccurrences(of: "\\", with: "/", options: .literal)
    if JSCompat.startsWith(path, "./") {
        path = JSCompat.dropFirst(path, 2)
    }
    return JS.replaceAll(path, repeatedSlashes, with: "/")
}

private let repeatedSlashes = JSCompat.regex("//+")
private let jsonFenceLazy = JSCompat.regex("```json" + JSCompat.whitespace + #"*([\s\S]*?)```"#)
private let anyFenceLazy = JSCompat.regex("```" + JSCompat.whitespace + #"*([\s\S]*?)```"#)
private let jsonFenceGreedy = JSCompat.regex("```json" + JSCompat.whitespace + #"*([\s\S]*)```"#)
private let anyFenceGreedy = JSCompat.regex("```" + JSCompat.whitespace + #"*([\s\S]*)```"#)

/// Parses the model's raw response into a structured conflict resolution
/// response. Handles markdown code-block wrapping (```` ```json ... ``` ````)
/// and validates all required fields.
public func parseAIConflictResolution(_ content: String) throws -> AIConflictResolutionResponse {
    // Build a list of JSON candidates from the response, trying different
    // extraction strategies. Non-greedy handles the common single-block and
    // multi-block cases. Greedy handles triple backticks embedded inside JSON
    // content. Raw content handles responses with no fences at all.
    let nonGreedy = JSCompat.match(content, jsonFenceLazy) ?? JSCompat.match(content, anyFenceLazy)
    let greedy = JSCompat.match(content, jsonFenceGreedy) ?? JSCompat.match(content, anyFenceGreedy)

    var candidates: [String] = []
    let nonGreedyCandidate = nonGreedy.map { JSCompat.trim($0[1] ?? "") }
    if let nonGreedyCandidate {
        candidates.append(nonGreedyCandidate)
    }
    if let greedy {
        let greedyCandidate = JSCompat.trim(greedy[1] ?? "")
        if nonGreedyCandidate.map({ !JSCompat.strictEquals(greedyCandidate, $0) }) ?? true {
            candidates.append(greedyCandidate)
        }
    }
    candidates.append(JSCompat.trim(content))

    guard let parsed = candidates.lazy.compactMap({ try? JSONValue.parse($0) }).first else {
        throw AIValidationError("The model returned invalid JSON for conflict resolution generation")
    }

    guard parsed.isObject else {
        throw AIValidationError("The model returned an invalid conflict resolution payload: expected an object")
    }

    guard let resolutions = parsed["resolutions"]?.arrayValue else {
        throw AIValidationError(
            #"The model returned an invalid conflict resolution payload: "resolutions" must be an array"#
        )
    }

    if resolutions.isEmpty {
        throw AIValidationError(
            #"The model returned an invalid conflict resolution payload: "resolutions" must not be empty"#
        )
    }

    // Soft-fail summary: it's a nice-to-have, not a critical part of the
    // contract. If the model omits it or returns the wrong shape, a usable
    // resolution still ships.
    let summary = parsed["summary"]?.stringValue.flatMap { JSCompat.trim($0).isEmpty ? nil : $0 }

    // Soft-fail references the same way. Drop any entry whose shape isn't
    // recognized; never throw. A curated context list is a polish, not a gate
    // on shipping resolutions.
    var references: [AIConflictReference] = []
    for entry in parsed["references"]?.arrayValue ?? [] {
        guard entry.isObject,
              let type = entry["type"]?.stringValue.flatMap(AIConflictReferenceType.init(rawValue:)),
              let id = entry["id"]?.stringValue, !JSCompat.trim(id).isEmpty
        else {
            continue
        }
        var trimmed = JSCompat.trim(id)
        if JSCompat.startsWith(trimmed, "#") {
            trimmed = JSCompat.dropFirst(trimmed, 1)
        }
        if type == .pullRequest, !isPullRequestNumber(trimmed) {
            continue
        }
        if type == .commit, !isCommitSha(trimmed) {
            continue
        }
        references.append(AIConflictReference(type: type, id: trimmed))
    }

    var validated: [RawFileResolution] = []

    for (i, entry) in resolutions.enumerated() {
        guard entry.isObject else {
            throw AIValidationError(
                "The model returned an invalid conflict resolution payload: resolution at index \(i) must be an object"
            )
        }

        guard let path = entry["path"]?.stringValue, !JSCompat.trim(path).isEmpty else {
            throw AIValidationError(
                #"The model returned an invalid conflict resolution payload: "path" at index \#(i) must be a non-empty string"#
            )
        }

        guard let rawHunks = entry["hunks"]?.arrayValue else {
            throw AIValidationError(
                #"The model returned an invalid conflict resolution payload: "hunks" at index \#(i) must be an array"#
            )
        }

        let reasoning = entry["reasoning"]?.stringValue
        let hasReasoning = reasoning.map { !JSCompat.trim($0).isEmpty } ?? false

        // Delete-vs-modify resolutions use an action instead of hunks.
        if let action = entry["action"]?.stringValue.flatMap(DeleteConflictAction.init(rawValue:)) {
            guard let reasoning, hasReasoning else {
                throw AIValidationError(
                    #"The model returned an invalid conflict resolution payload: "reasoning" at index \#(i) must be a non-empty string"#
                )
            }
            validated.append(RawFileResolution(path: normalizeLLMPath(path), hunks: [], reasoning: reasoning, action: action))
            continue
        }

        if rawHunks.isEmpty {
            throw AIValidationError(
                #"The model returned an invalid conflict resolution payload: "hunks" at index \#(i) must not be empty"#
            )
        }

        var validatedHunks: [HunkResolution] = []
        for (j, hunkEntry) in rawHunks.enumerated() {
            guard hunkEntry.isObject else {
                throw AIValidationError(
                    #"The model returned an invalid conflict resolution payload: hunk at index \#(j) of file "\#(path)" must be an object"#
                )
            }
            guard let resolvedContent = hunkEntry["resolvedContent"]?.stringValue else {
                throw AIValidationError(
                    #"The model returned an invalid conflict resolution payload: "resolvedContent" at hunk \#(j) of file "\#(path)" must be a string"#
                )
            }
            if containsConflictMarkers(resolvedContent) {
                throw AIValidationError(
                    #"The model returned an invalid conflict resolution payload: hunk \#(j) of file "\#(path)" still contains conflict markers"#
                )
            }
            validatedHunks.append(HunkResolution(resolvedContent: resolvedContent))
        }

        guard let reasoning, hasReasoning else {
            throw AIValidationError(
                #"The model returned an invalid conflict resolution payload: "reasoning" at index \#(i) must be a non-empty string"#
            )
        }

        validated.append(RawFileResolution(path: normalizeLLMPath(path), hunks: validatedHunks, reasoning: reasoning))
    }

    return AIConflictResolutionResponse(resolutions: validated, summary: summary, references: references)
}

/// `/^\d{1,9}$/`
private func isPullRequestNumber(_ id: String) -> Bool {
    (1...9).contains(id.unicodeScalars.count) && id.unicodeScalars.allSatisfy(JS.isASCIIDigit)
}

/// `/^[0-9a-f]{4,40}$/i`
private func isCommitSha(_ id: String) -> Bool {
    (4...40).contains(id.unicodeScalars.count)
        && id.unicodeScalars.allSatisfy { JS.isASCIIDigit($0) || ("a"..."f").contains($0) || ("A"..."F").contains($0) }
}

/// JavaScript's `LineTerminator`: where `^` and `$` match in a multiline
/// regular expression.
private func isLineTerminator(_ scalar: Unicode.Scalar) -> Bool {
    JSCompat.isLineTerminator(scalar)
}

/// `/^<{7}\s/m.test(content) && /^={7}$/m.test(content)`: an opening marker
/// and a separator, each at the start of some line.
private func containsConflictMarkers(_ content: String) -> Bool {
    let scalars = Array(content.unicodeScalars)
    var hasOpening = false
    var hasSeparator = false
    for start in scalars.indices where start == 0 || isLineTerminator(scalars[start - 1]) {
        let end = start + 7
        guard end <= scalars.count else {
            continue
        }
        let run = scalars[start..<end]
        if run.allSatisfy({ $0 == "<" }), end < scalars.count, JSCompat.isWhitespace(scalars[end]) {
            hasOpening = true
        }
        if run.allSatisfy({ $0 == "=" }), end == scalars.count || isLineTerminator(scalars[end]) {
            hasSeparator = true
        }
    }
    return hasOpening && hasSeparator
}

/// Validates that a parsed resolution response matches the expected set of
/// file paths and hunk counts. Throws `AIValidationError` on unexpected
/// paths, duplicates, missing files, wrong hunk counts, or an `action` for a
/// file that isn't a delete-vs-modify conflict.
public func validateResolutionPaths(_ resolutions: [RawFileResolution], _ expectedFiles: [FileConflictContext]) throws {
    let expectedPaths = expectedFiles.map(\.path)
    let expectedPathKeys = expectedPaths.exactSet
    var expectedFilesByPath: [ExactString: FileConflictContext] = [:]
    for file in expectedFiles {
        expectedFilesByPath[ExactString(file.path)] = file
    }

    var returnedPathKeys = Set<ExactString>()
    for resolution in resolutions {
        if returnedPathKeys.insert(ExactString(resolution.path)).inserted,
           !expectedPathKeys.contains(ExactString(resolution.path))
        {
            throw AIValidationError("The model returned resolution for unexpected file: \(resolution.path)")
        }
    }

    if returnedPathKeys.count != resolutions.count {
        throw AIValidationError("The model returned duplicate file paths in resolutions")
    }

    var seenMissing = Set<ExactString>()
    let missingPaths = expectedPaths.filter { path in
        let key = ExactString(path)
        return !returnedPathKeys.contains(key) && seenMissing.insert(key).inserted
    }
    if !missingPaths.isEmpty {
        throw AIValidationError("The model did not return resolutions for: \(missingPaths.joined(separator: ", "))")
    }

    for resolution in resolutions {
        let expected = expectedFilesByPath[ExactString(resolution.path)]
        // Delete-vs-modify resolutions use an action instead of hunks; skip
        // the count check. Only those conflicts may have one.
        if resolution.action != nil {
            guard expected?.deletedSide != nil else {
                throw AIValidationError(
                    #"The model returned an action for "\#(resolution.path)", which is not a delete-vs-modify conflict"#
                )
            }
            continue
        }
        let expectedCount = expected?.hunks.count ?? 0
        if resolution.hunks.count != expectedCount {
            throw AIValidationError(
                #"The model returned \#(resolution.hunks.count) hunk(s) for "\#(resolution.path)" but expected \#(expectedCount)"#
            )
        }
    }
}

// MARK: Reassembly

/// Reassembles a fully resolved file by splicing per-hunk resolutions into
/// the original file content (which still has conflict markers on disk).
///
/// Walks the original file line by line. Non-conflicted lines are copied
/// through verbatim. Each conflict marker block (`<<<<<<<` through
/// `>>>>>>>`, with a `=======` separator in between) is replaced with the
/// corresponding entry from `hunkResolutions` (matched by order, not by line
/// number). This guarantees that all non-conflicted code is preserved
/// exactly, and the model's output is only responsible for the small
/// resolved sections.
///
/// A `<<<<<<<` line that is not followed by both a `=======` separator and a
/// closing `>>>>>>>` before the end of the file is treated as regular file
/// content (not a conflict block) and copied through unchanged, to avoid
/// data loss from malformed or stray markers.
///
/// The blocks are the ones `extractConflictHunks` finds (see
/// `findConflictBlocks`), so each resolution replaces exactly the lines its
/// hunk showed the model.
///
/// - Parameters:
///   - rawContent: The full file content on disk, including conflict markers.
///   - hunkResolutions: Per-hunk resolved content, in the order they appear
///     in the file.
/// - Returns: The reassembled file with all conflicts resolved.
public func reassembleResolvedFile(_ rawContent: String, _ hunkResolutions: [HunkResolution]) -> String {
    let eol = containsCRLF(rawContent) ? "\r\n" : "\n"
    let lines = JS.splitLines(rawContent)
    var resultLines: [String] = []
    var next = 0

    for (hunkIndex, block) in findConflictBlocks(lines).enumerated() {
        resultLines.append(contentsOf: lines[next..<block.start])
        // Splice in the resolved content for this hunk.
        if hunkIndex < hunkResolutions.count {
            let resolved = hunkResolutions[hunkIndex].resolvedContent
            if !resolved.isEmpty {
                resultLines.append(contentsOf: JS.splitLines(resolved))
            }
        }
        // Skip through the entire conflict marker block.
        next = block.end + 1
    }
    resultLines.append(contentsOf: lines[next...])

    return resultLines.joined(separator: eol)
}

/// `content.includes('\r\n')`, by scalars.
private func containsCRLF(_ content: String) -> Bool {
    var previous: Unicode.Scalar?
    for scalar in content.unicodeScalars {
        if previous == "\r", scalar == "\n" {
            return true
        }
        previous = scalar
    }
    return false
}

/// Combines the model's raw per-hunk resolutions with the original file
/// contexts to produce the final `FileResolution` array the rest of the app
/// expects (each entry has the complete reassembled file content).
///
/// Throws `AIValidationError` when a reassembled file still has a line that
/// opens or closes a conflict (`<<<<<<<` or `>>>>>>>`), so a file with
/// conflict markers is never reported as resolved, even when the model
/// writes a single marker. (`buildConflictContext` skips files with markers
/// outside their blocks.)
public func reassembleResolutions(
    _ rawResolutions: [RawFileResolution],
    _ fileContexts: [FileConflictContext]
) throws -> [FileResolution] {
    var contextByPath: [ExactString: FileConflictContext] = [:]
    for context in fileContexts {
        contextByPath[ExactString(context.path)] = context
    }

    return try rawResolutions.map { raw in
        // Delete-vs-modify resolutions carry an action, not hunk content.
        // Pass them through without reassembly; the resolution is applied as
        // a manual conflict resolution, not a file write.
        if let action = raw.action {
            return FileResolution(path: raw.path, resolvedContent: "", reasoning: raw.reasoning, deleteConflictAction: action)
        }

        guard let rawContent = contextByPath[ExactString(raw.path)]?.rawContent else {
            throw AIValidationError(
                #"Cannot reassemble resolution for "\#(raw.path)": original file content is unavailable"#
            )
        }

        let resolvedContent = reassembleResolvedFile(rawContent, raw.hunks)
        if containsOpeningOrClosingMarker(resolvedContent) {
            throw AIValidationError(
                #"The resolved content of "\#(raw.path)" still contains conflict markers"#
            )
        }
        return FileResolution(path: raw.path, resolvedContent: resolvedContent, reasoning: raw.reasoning)
    }
}

// MARK: References

private let pullRequestSuffix = JSCompat.regex(#"\(#([0-9]+)\)"# + JSCompat.whitespace + #"*\z"#)

/// Extracts a trailing pull request number from a commit summary, e.g.
/// "Add multilingual greetings (#20)" gives 20. `nil` when no `(#N)` suffix
/// is present.
private func extractPullRequestNumberFromCommitSummary(_ summary: String) -> Int? {
    JSCompat.match(summary, pullRequestSuffix)?[1].flatMap { Int($0) }
}

/// Minimum length required to resolve a commit reference by SHA prefix.
private let MinShaPrefixLength = 7

/// Resolves the model's raw reference list against the gathered context,
/// producing display-ready entries for the result's "Context" list.
///
/// The model's request has no tools, so it can only cite data placed in the
/// prompt; every entry here is therefore one of the pull requests or commits
/// already gathered. References that can't be matched (a hallucinated or
/// mistyped ID) are dropped rather than shown as placeholders.
///
/// When the model cites a commit that is itself a squash or merge of a pull
/// request (detected by a trailing `(#N)` in its summary) and that pull
/// request was gathered, the pull request is shown instead: its title and
/// body carry far more human context than the merge commit. Entries are
/// de-duplicated on their final identity so a pull request and its merge
/// commit collapse into one row.
public func selectReferencedContext(
    _ references: [AIConflictReference],
    _ context: ConflictResolutionContext
) -> [ConflictContextReference] {
    var prByNumber: [Int: ConflictContextPullRequest] = [:]
    for pr in context.pullRequests {
        prByNumber[pr.number] = pr
    }

    var commitBySha: [String: ConflictContextCommit] = [:]
    for commit in context.ourCommits + context.theirCommits {
        commitBySha[commit.sha.lowercased()] = commit
    }

    var selected: [ConflictContextReference] = []
    var seenPrs = Set<Int>()
    var seenCommits = Set<String>()

    func pushPullRequest(_ prNumber: Int) {
        guard !seenPrs.contains(prNumber), let pr = prByNumber[prNumber] else {
            return
        }
        seenPrs.insert(prNumber)
        selected.append(.pullRequest(pr))
    }

    for ref in references {
        if ref.type == .pullRequest {
            if let prNumber = JS.parseInt(ref.id) {
                pushPullRequest(prNumber)
            }
            continue
        }

        guard let matched = findCommitByRef(ref.id, commitBySha) else {
            continue
        }

        // Promote a merge or squash commit to its pull request when gathered.
        if let prFromSummary = extractPullRequestNumberFromCommitSummary(matched.summary),
           prByNumber[prFromSummary] != nil
        {
            pushPullRequest(prFromSummary)
            continue
        }

        if seenCommits.contains(matched.sha) {
            continue
        }
        seenCommits.insert(matched.sha)
        selected.append(.commit(matched))
    }

    return selected
}

/// Commit summaries that carry no human context worth showing:
/// `/^(merge |wip\b|fixup!|squash!|amend\b)/i`.
private func isLowSignalCommitSummary(_ summary: String) -> Bool {
    let scalars = Array(summary.unicodeScalars)
    func hasPrefix(_ prefix: String, wordBoundary: Bool) -> Bool {
        let expected = Array(prefix.unicodeScalars)
        guard scalars.count >= expected.count else {
            return false
        }
        // ASCII case folding only: JavaScript's `i` flag without `u` never
        // matches a non-ASCII character against an ASCII one.
        for (actual, wanted) in zip(scalars, expected) where asciiLowercased(actual) != wanted {
            return false
        }
        if wordBoundary, expected.count < scalars.count {
            return !JS.isWordCharacter(scalars[expected.count])
        }
        return true
    }
    return hasPrefix("merge ", wordBoundary: false)
        || hasPrefix("wip", wordBoundary: true)
        || hasPrefix("fixup!", wordBoundary: false)
        || hasPrefix("squash!", wordBoundary: false)
        || hasPrefix("amend", wordBoundary: true)
}

private func asciiLowercased(_ scalar: Unicode.Scalar) -> Unicode.Scalar {
    ("A"..."Z").contains(scalar) ? Unicode.Scalar(scalar.value + 32)! : scalar
}

private func isMeaningfulCommit(_ commit: ConflictContextCommit) -> Bool {
    let summary = JSCompat.trim(commit.summary)
    return !summary.isEmpty && !isLowSignalCommitSummary(summary)
}

/// Guarantees the "Context" list is never empty when material was gathered.
/// The model curates references, but it occasionally returns none even
/// though a conflict always traces back to at least one commit. This
/// deterministic floor shows the single most informative item available
/// (preferring a pull request, then a commit with a human-readable message,
/// then any commit as a last resort) and favors the incoming (theirs) side,
/// since that is the change being brought in.
///
/// It is only consulted when `selectReferencedContext` yields nothing, so a
/// model that cites real references is never second-guessed.
public func fallbackReferencedContext(_ context: ConflictResolutionContext) -> [ConflictContextReference] {
    if let pr = context.pullRequests.first {
        return [.pullRequest(pr)]
    }

    let commit =
        context.theirCommits.first(where: isMeaningfulCommit)
        ?? context.ourCommits.first(where: isMeaningfulCommit)
        ?? context.theirCommits.first
        ?? context.ourCommits.first
    if let commit {
        return [.commit(commit)]
    }

    return []
}

/// Resolves a commit reference ID (full or abbreviated SHA) against the
/// gathered commits. Prefers an exact match; falls back to a unique prefix
/// match of at least `MinShaPrefixLength` characters. `nil` when nothing
/// matches or a prefix is ambiguous.
private func findCommitByRef(_ id: String, _ commitBySha: [String: ConflictContextCommit]) -> ConflictContextCommit? {
    let lower = id.lowercased()
    if let exact = commitBySha[lower] {
        return exact
    }

    if JS.length(lower) < MinShaPrefixLength {
        return nil
    }

    var match: ConflictContextCommit?
    for (sha, commit) in commitBySha where JSCompat.startsWith(sha, lower) {
        if match != nil {
            // Ambiguous prefix: refuse to guess.
            return nil
        }
        match = commit
    }
    return match
}
