// Ported from desktop/app/src/lib/copilot-conflict-context.ts
//
// AIKit doesn't depend on GitKit, so EspalierCore runs git and resolves
// paths: it supplies the commits (`ConflictContextCommit`) and each file's
// read result (`ConflictedFileContents`), and `buildConflictContext` turns
// them into the context.

import EspalierSupport
import Foundation

/// A single conflict hunk extracted from a file with conflict markers.
public struct ConflictHunk: Sendable, Hashable {
    /// Content from the current branch (between `<<<<<<<` and `=======`).
    public var oursContent: String
    /// Content from the incoming branch (between `=======` and `>>>>>>>`).
    public var theirsContent: String
    /// Base content if diff3 markers are present (between `|||||||` and
    /// `=======`), `nil` otherwise.
    public var baseContent: String?
    /// Lines of unchanged content before the conflict marker.
    public var contextBefore: String
    /// Lines of unchanged content after the conflict marker.
    public var contextAfter: String

    public init(
        oursContent: String,
        theirsContent: String,
        baseContent: String?,
        contextBefore: String,
        contextAfter: String
    ) {
        self.oursContent = oursContent
        self.theirsContent = theirsContent
        self.baseContent = baseContent
        self.contextBefore = contextBefore
        self.contextAfter = contextAfter
    }
}

/// A side of a conflict.
public enum ConflictSide: String, Sendable, Hashable, Codable {
    case ours
    case theirs
}

/// Conflict context for a single file.
public struct FileConflictContext: Sendable, Hashable {
    /// Repository-relative file path.
    public var path: String
    /// All conflict hunks in the file (empty if skipped or delete-vs-modify).
    public var hunks: [ConflictHunk]
    /// If the file was skipped, the reason why.
    public var skippedReason: String?
    /// The full file content on disk (including conflict markers). Used after
    /// the model responds to reassemble the resolved file by splicing
    /// per-hunk resolutions into the original content. `nil` when the file is
    /// skipped.
    public var rawContent: String?
    /// Which side deleted the file, when this is a delete-vs-modify conflict
    /// (no text markers). The model responds with `"action": "keep"` or
    /// `"action": "delete"` instead of per-hunk resolutions.
    public var deletedSide: ConflictSide?

    public init(
        path: String,
        hunks: [ConflictHunk],
        skippedReason: String? = nil,
        rawContent: String? = nil,
        deletedSide: ConflictSide? = nil
    ) {
        self.path = path
        self.hunks = hunks
        self.skippedReason = skippedReason
        self.rawContent = rawContent
        self.deletedSide = deletedSide
    }

    /// Whether the file is sent to the model: it has no skip reason. (An
    /// empty reason doesn't count.)
    var isResolvable: Bool {
        skippedReason?.isEmpty ?? true
    }
}

/// The files of a conflict and the labels of both sides.
///
/// Labels are used instead of branch names because for rebase and
/// cherry-pick the "theirs" side is a specific commit, not a branch.
public struct AIConflictContext: Sendable, Hashable {
    /// Label for the current side (e.g., branch name or "main (rebase target)").
    public var ourLabel: String
    /// Label for the incoming side (e.g., branch name or "abc1234: Add UUID support").
    public var theirLabel: String
    /// All conflicted files with their conflict data.
    public var files: [FileConflictContext]

    public init(ourLabel: String, theirLabel: String, files: [FileConflictContext]) {
        self.ourLabel = ourLabel
        self.theirLabel = theirLabel
        self.files = files
    }
}

/// A pull request gathered as conflict context, in display-ready form.
///
/// Captured once while the data is fresh so the same value can be fed to the
/// prompt *and* rendered in the result's "Context" list.
public struct ConflictContextPullRequest: Sendable, Hashable {
    /// The pull request number (no leading `#`).
    public var number: Int
    public var title: String
    /// The pull request body (may be empty).
    public var body: String

    public init(number: Int, title: String, body: String) {
        self.number = number
        self.title = title
        self.body = body
    }
}

/// A commit gathered as conflict context, in display-ready form.
public struct ConflictContextCommit: Sendable, Hashable {
    /// Full commit SHA.
    public var sha: String
    /// Abbreviated commit SHA for display.
    public var shortSha: String
    /// First line of the commit message.
    public var summary: String
    /// Whether the commit is reachable from a remote (i.e. pushed).
    public var isOnRemote: Bool

    public init(sha: String, shortSha: String, summary: String, isOnRemote: Bool) {
        self.sha = sha
        self.shortSha = shortSha
        self.summary = summary
        self.isOnRemote = isOnRemote
    }
}

/// The full, display-ready context gathered for a conflict resolution: the
/// files plus the pull requests and commits from both sides. This single
/// value is the source of truth for both the prompt and the result's summary
/// card, so the data is gathered exactly once.
public struct ConflictResolutionContext: Sendable, Hashable {
    public var ourLabel: String
    public var theirLabel: String
    public var files: [FileConflictContext]
    /// All pull requests referenced in either side's commit history. The
    /// model infers which pull requests relate to which side from the commit
    /// context.
    public var pullRequests: [ConflictContextPullRequest]
    /// Recent commits on the *ours* (current) side.
    public var ourCommits: [ConflictContextCommit]
    /// Recent commits on the *theirs* (incoming) side.
    public var theirCommits: [ConflictContextCommit]

    public init(
        ourLabel: String,
        theirLabel: String,
        files: [FileConflictContext],
        pullRequests: [ConflictContextPullRequest] = [],
        ourCommits: [ConflictContextCommit] = [],
        theirCommits: [ConflictContextCommit] = []
    ) {
        self.ourLabel = ourLabel
        self.theirLabel = theirLabel
        self.files = files
        self.pullRequests = pullRequests
        self.ourCommits = ourCommits
        self.theirCommits = theirCommits
    }

    /// The file context with pull requests and commits.
    public init(
        _ context: AIConflictContext,
        pullRequests: [ConflictContextPullRequest] = [],
        ourCommits: [ConflictContextCommit] = [],
        theirCommits: [ConflictContextCommit] = []
    ) {
        self.init(
            ourLabel: context.ourLabel,
            theirLabel: context.theirLabel,
            files: context.files,
            pullRequests: pullRequests,
            ourCommits: ourCommits,
            theirCommits: theirCommits
        )
    }

    /// The same context with only the files at `paths`, for retrying the
    /// files a round couldn't resolve (`ConflictResolutionOutcome.failedFiles`
    /// and `notAttemptedFiles`). Paths are compared by code units.
    public func restricted(to paths: some Collection<String>) -> ConflictResolutionContext {
        let keep = paths.exactSet
        var context = self
        context.files = files.filter { keep.contains(ExactString($0.path)) }
        return context
    }
}

// MARK: Parsing conflict markers

/// Whether a line starts with exactly `count` of `marker` followed by
/// JavaScript whitespace or the end of the line: `/^<{7}(?:\s|$)/`.
private func startsWithMarker(_ line: String, _ marker: Unicode.Scalar) -> Bool {
    let scalars = line.unicodeScalars
    var index = scalars.startIndex
    for _ in 0..<7 {
        guard index < scalars.endIndex, scalars[index] == marker else {
            return false
        }
        index = scalars.index(after: index)
    }
    return index == scalars.endIndex || JSCompat.isWhitespace(scalars[index])
}

func isOursMarker(_ line: String) -> Bool {
    startsWithMarker(line, "<")
}

private func isBaseMarker(_ line: String) -> Bool {
    startsWithMarker(line, "|")
}

/// `/^={7}$/`: exactly seven equals signs.
func isSeparatorMarker(_ line: String) -> Bool {
    line.unicodeScalars.count == 7 && line.unicodeScalars.allSatisfy { $0 == "=" }
}

func isTheirsMarker(_ line: String) -> Bool {
    startsWithMarker(line, ">")
}

/// Absolute upper bound (in bytes) on a conflicted file read into memory.
///
/// This is a memory-safety guard only, not a resolvability heuristic: only
/// the *conflict hunks* are ever sent to the model, never the whole file, so
/// a large file with a small conflict is still perfectly resolvable. Files
/// above this size are skipped before reading to avoid loading pathological
/// blobs (e.g. a multi-megabyte generated lockfile) into a string.
public let MaxConflictFileReadSize = 10_485_760  // 10MB

/// Maximum length (in UTF-16 code units) of any single line within a
/// conflict hunk.
///
/// Mirrors the diff renderer's `MaxCharactersPerLine`. Conflicts containing a
/// line longer than this are almost always minified or generated content
/// where a line-oriented resolution is meaningless, so they're skipped rather
/// than sending an enormous single line to the model.
let MaxConflictLineLength = 5000

/// Maximum combined size (in UTF-16 code units) of the actual conflict
/// content in a single file: the sum of the ours/base/theirs text across
/// every hunk.
///
/// Unlike a whole-file cap, this measures what is actually sent to the
/// model, so it protects prompt size and output quality (truncation,
/// malformed JSON) without penalizing large files whose conflicts are small.
let MaxConflictContentSize = 262_144  // 256KB

private func isConflictMarker(_ line: String) -> Bool {
    isOursMarker(line) || isBaseMarker(line) || isSeparatorMarker(line) || isTheirsMarker(line)
}

/// A conflict block in a file's lines: the `<<<<<<<` line through the
/// `>>>>>>>` line that closes it, and the sections in between.
struct ConflictBlock {
    /// The index of the `<<<<<<<` line.
    let start: Int
    /// The index of the closing `>>>>>>>` line.
    let end: Int
    let ours: Range<Int>
    /// The diff3 base section, between `|||||||` and `=======`.
    let base: Range<Int>?
    let theirs: Range<Int>
}

/// Finds the conflict blocks in a file's lines: after a `<<<<<<<` line, the
/// ours section runs to a `|||||||` or `=======` line, the base section
/// (diff3) to `=======`, and the theirs section to `>>>>>>>`. Other marker
/// lines inside a section are its content. A block that never closes ends
/// the scan (no later block could close either).
///
/// Both `extractConflictHunks` and `reassembleResolvedFile` use these
/// blocks, so the lines a resolution replaces are exactly the lines the
/// model was shown.
func findConflictBlocks(_ lines: [String]) -> [ConflictBlock] {
    var blocks: [ConflictBlock] = []
    var i = 0
    while i < lines.count {
        if !isOursMarker(lines[i]) {
            i += 1
            continue
        }

        let start = i
        i += 1

        // Ours, up to the base marker or the separator.
        let oursStart = i
        var hasBase = false
        while i < lines.count, !isBaseMarker(lines[i]), !isSeparatorMarker(lines[i]) {
            i += 1
        }
        let ours = oursStart..<i
        if i < lines.count {
            hasBase = isBaseMarker(lines[i])
            i += 1
        }

        // If diff3, the base, up to the separator.
        var base: Range<Int>?
        if hasBase {
            let baseStart = i
            while i < lines.count, !isSeparatorMarker(lines[i]) {
                i += 1
            }
            base = baseStart..<i
            if i < lines.count {
                i += 1
            }
        }

        // Theirs, up to the closing marker.
        let theirsStart = i
        while i < lines.count, !isTheirsMarker(lines[i]) {
            i += 1
        }
        guard i < lines.count else {
            // The closing marker never came: a malformed block.
            break
        }
        blocks.append(ConflictBlock(start: start, end: i, ours: ours, base: base, theirs: theirsStart..<i))
        i += 1
    }
    return blocks
}

/// Whether a file has a `<<<<<<<` or `>>>>>>>` marker outside its conflict
/// blocks: one that doesn't open or close a block, or one after a block that
/// never closed. A resolution would leave it in the file. `=======` and
/// `|||||||` lines don't count; they're common in ordinary text (Markdown
/// headings and tables).
func hasUnmatchedConflictMarkers(_ lines: [String], _ blocks: [ConflictBlock]) -> Bool {
    var next = 0
    for block in blocks {
        if lines[next..<block.start].contains(where: isOpeningOrClosingMarker) {
            return true
        }
        next = block.end + 1
    }
    return lines[next...].contains(where: isOpeningOrClosingMarker)
}

/// Whether text has a line that would open or close a conflict block, so a
/// file with it can't count as resolved.
func containsOpeningOrClosingMarker(_ content: String) -> Bool {
    JS.splitLines(content).contains(where: isOpeningOrClosingMarker)
}

private func isOpeningOrClosingMarker(_ line: String) -> Bool {
    isOursMarker(line) || isTheirsMarker(line)
}

/// Parses a file's text content and extracts all conflict hunks.
///
/// Handles both standard two-way conflict markers (`<<<<<<<`, `=======`,
/// `>>>>>>>`) and diff3 three-way markers that also include a `|||||||`
/// section for the merge base content.
///
/// - Parameters:
///   - fileContent: The full text content of the conflicted file.
///   - contextLines: Number of surrounding unchanged lines to include around
///     each hunk.
/// - Returns: The extracted conflict hunks, empty if no markers are found.
public func extractConflictHunks(_ fileContent: String, contextLines: Int = 3) -> [ConflictHunk] {
    let lines = JS.splitLines(fileContent)
    return conflictHunks(lines, findConflictBlocks(lines), contextLines: contextLines)
}

/// The hunks of the given blocks, with up to `contextLines` lines of context
/// on each side.
private func conflictHunks(_ lines: [String], _ blocks: [ConflictBlock], contextLines: Int) -> [ConflictHunk] {
    blocks.map { block in
        let contextStart = max(0, block.start - contextLines)
        let contextEnd = min(lines.count - 1, block.end + contextLines)

        // Clamp context to not include conflict markers from adjacent hunks.
        var contextBeforeLines: [String] = []
        var j = block.start - 1
        while j >= contextStart {
            if isConflictMarker(lines[j]) {
                break
            }
            contextBeforeLines.insert(lines[j], at: 0)
            j -= 1
        }

        var contextAfterLines: [String] = []
        j = block.end + 1
        while j <= contextEnd {
            if isConflictMarker(lines[j]) {
                break
            }
            contextAfterLines.append(lines[j])
            j += 1
        }

        return ConflictHunk(
            oursContent: lines[block.ours].joined(separator: "\n"),
            theirsContent: lines[block.theirs].joined(separator: "\n"),
            baseContent: block.base.map { lines[$0].joined(separator: "\n") },
            contextBefore: contextBeforeLines.joined(separator: "\n"),
            contextAfter: contextAfterLines.joined(separator: "\n")
        )
    }
}

/// Determines whether a file's conflict hunks are too large or too unwieldy
/// to send to the model, returning a human-readable skip reason or `nil`
/// when the conflict is resolvable.
///
/// Gates on the size of the conflict content itself (what is actually sent)
/// rather than the whole-file size, so a large file with a small conflict is
/// still resolved. Two conditions trigger a skip:
///   1. Any single conflict line exceeds `MaxConflictLineLength` (minified or
///      generated content where a line-oriented resolution is meaningless).
///   2. The combined ours/base/theirs content exceeds
///      `MaxConflictContentSize` (protects prompt size and output quality).
public func getHunkSkipReason(_ hunks: [ConflictHunk]) -> String? {
    var totalContent = 0

    for hunk in hunks {
        for side in [hunk.oursContent, hunk.theirsContent, hunk.baseContent ?? ""] {
            totalContent += JS.length(side)
            // `side.split('\n')`, on scalars so a CR before the LF stays in
            // the line as it does in JavaScript.
            for line in side.unicodeScalars.split(separator: "\n", omittingEmptySubsequences: false)
            where line.reduce(0, { $0 + $1.utf16.count }) > MaxConflictLineLength {
                return "Conflict contains lines too long to resolve automatically"
            }
        }
        if totalContent > MaxConflictContentSize {
            return "Conflict region too large to resolve automatically"
        }
    }

    return nil
}

// MARK: Building the context

/// What the glue found when it looked for a conflicted file in the working
/// directory. Each failure maps to a skip reason.
public enum ConflictedFileContents: Sendable, Hashable {
    /// The file's text, decoded as UTF-8 with invalid bytes replaced (Node's
    /// `readFile(path, 'utf8')`).
    case text(String)
    /// `resolveWithin` threw: "File path could not be resolved safely".
    case unresolvablePath
    /// `resolveWithin` returned no path: "File path is outside the repository".
    case outsideRepository
    /// Larger than `MaxConflictFileReadSize`: "File too large to resolve
    /// automatically".
    case tooLarge
    /// The file couldn't be examined or read: "File could not be read".
    case unreadable
}

/// A conflicted file, as the glue supplies it to `buildConflictContext`.
public struct ConflictedFile: Sendable, Hashable {
    /// Repository-relative path.
    public var path: String
    /// Which side deleted the file, for delete-vs-modify conflicts. Their
    /// contents aren't needed.
    public var deletedSide: ConflictSide?
    /// The file's contents, or why they couldn't be read. Unused for
    /// delete-vs-modify conflicts.
    public var contents: ConflictedFileContents?

    /// A text conflict, with what reading the file produced.
    public init(path: String, contents: ConflictedFileContents) {
        self.path = path
        self.deletedSide = nil
        self.contents = contents
    }

    /// A delete-vs-modify conflict.
    public init(path: String, deletedSide: ConflictSide) {
        self.path = path
        self.deletedSide = deletedSide
        self.contents = nil
    }
}

/// The skip reason for a file with a `<<<<<<<` or `>>>>>>>` marker outside
/// its conflict blocks (see `hasUnmatchedConflictMarkers`). The model could
/// resolve the blocks, but the file would still have a conflict marker.
public let UnmatchedConflictMarkersReason = "Unmatched conflict markers found"

/// Builds the file context for a merge, rebase, or cherry-pick from the
/// conflicted files the glue read: extracts each file's conflict hunks, and
/// records why a file was skipped when it can't be resolved.
///
/// - Parameters:
///   - ourLabel: Label for the current side (e.g., branch name).
///   - theirLabel: Label for the incoming side (e.g., branch name, or commit
///     summary for rebase and cherry-pick).
///   - files: The conflicted files, in order.
public func buildConflictContext(ourLabel: String, theirLabel: String, files: [ConflictedFile]) -> AIConflictContext {
    let results = files.map { file -> FileConflictContext in
        // Delete-vs-modify conflicts have no text markers on disk. Include
        // them in the context with metadata so the model can recommend keep
        // or delete; no file content is needed.
        if let deletedSide = file.deletedSide {
            return FileConflictContext(path: file.path, hunks: [], deletedSide: deletedSide)
        }

        let skippedReason: String
        switch file.contents {
        case .text(let content):
            let lines = JS.splitLines(content)
            let blocks = findConflictBlocks(lines)
            let hunks = conflictHunks(lines, blocks, contextLines: 3)
            if hunks.isEmpty {
                skippedReason = "No conflict markers found"
            } else if let hunkSkipReason = getHunkSkipReason(hunks) {
                // Gate on the size of the conflict content that would actually
                // be sent to the model, not the whole-file size.
                skippedReason = hunkSkipReason
            } else if hasUnmatchedConflictMarkers(lines, blocks) {
                // Resolving the blocks would still leave a marker in the
                // file.
                skippedReason = UnmatchedConflictMarkersReason
            } else {
                return FileConflictContext(path: file.path, hunks: hunks, rawContent: content)
            }
        case .unresolvablePath:
            skippedReason = "File path could not be resolved safely"
        case .outsideRepository:
            skippedReason = "File path is outside the repository"
        case .tooLarge:
            skippedReason = "File too large to resolve automatically"
        case .unreadable, nil:
            skippedReason = "File could not be read"
        }
        return FileConflictContext(path: file.path, hunks: [], skippedReason: skippedReason)
    }

    return AIConflictContext(ourLabel: ourLabel, theirLabel: theirLabel, files: results)
}

// MARK: The prompt

/// Converts a conflict resolution context into a human-readable prompt
/// suitable for sending to the model as the user message.
///
/// Reads the pull requests and commits straight off the context so the
/// prompt and the result's summary are built from the exact same gathered
/// data.
public func formatConflictContextForPrompt(_ context: ConflictResolutionContext) -> String {
    var parts: [String] = []

    parts.append(#"Merge conflict between "\#(context.ourLabel)" (ours) and "\#(context.theirLabel)" (theirs)."#)
    parts.append("")

    if !context.pullRequests.isEmpty {
        parts.append("## Pull Request Context")
        parts.append(
            "These pull requests were referenced in the commit history and may explain the intent behind either side:"
        )
        parts.append("")
        for pr in context.pullRequests {
            appendPullRequest(&parts, pr)
        }
    }

    if !context.ourCommits.isEmpty || !context.theirCommits.isEmpty {
        parts.append("## Recent Commits")
        parts.append("")

        if !context.ourCommits.isEmpty {
            parts.append("### Ours (\(context.ourLabel)) commits:")
            for commit in context.ourCommits {
                parts.append("- \(commit.shortSha): \(commit.summary)")
            }
            parts.append("")
        }

        if !context.theirCommits.isEmpty {
            parts.append("### Theirs (\(context.theirLabel)) commits:")
            for commit in context.theirCommits {
                parts.append("- \(commit.shortSha): \(commit.summary)")
            }
            parts.append("")
        }
    }

    for file in context.files {
        let safePath = sanitizeForMarkdown(file.path)

        if let deletedSide = file.deletedSide {
            let deletedLabel = deletedSide == .ours ? context.ourLabel : context.theirLabel
            let modifiedLabel = deletedSide == .ours ? context.theirLabel : context.ourLabel
            let modifiedSide = deletedSide == .ours ? "theirs" : "ours"

            parts.append("## File: \(safePath) (delete-vs-modify conflict)")
            parts.append("")
            parts.append(
                #"Deleted on "\#(deletedLabel)" (\#(deletedSide.rawValue)), modified on "\#(modifiedLabel)" (\#(modifiedSide))."#
            )
            parts.append("")
            parts.append(
                #"Respond with `"action": "keep"` to preserve the modified file, or `"action": "delete"` to accept the deletion."#
            )
            parts.append("")
            continue
        }

        parts.append("## File: \(safePath)")
        parts.append("")

        if let skippedReason = file.skippedReason, !skippedReason.isEmpty {
            parts.append("> \u{26A0}\u{FE0F} Skipped: \(skippedReason)")
            parts.append("")
            continue
        }

        let lang = getLangFromPath(file.path)

        for (i, hunk) in file.hunks.enumerated() {
            parts.append("### Conflict \(i + 1) of \(file.hunks.count)")
            parts.append("")

            if !hunk.contextBefore.isEmpty {
                parts.append("Context before:")
                parts.append(makeFencedBlock(hunk.contextBefore, lang))
                parts.append("")
            }

            parts.append("Ours (current branch):")
            parts.append(makeFencedBlock(hunk.oursContent, lang))
            parts.append("")

            if let baseContent = hunk.baseContent {
                parts.append("Base (common ancestor):")
                parts.append(makeFencedBlock(baseContent, lang))
                parts.append("")
            }

            parts.append("Theirs (incoming branch):")
            parts.append(makeFencedBlock(hunk.theirsContent, lang))
            parts.append("")

            if !hunk.contextAfter.isEmpty {
                parts.append("Context after:")
                parts.append(makeFencedBlock(hunk.contextAfter, lang))
                parts.append("")
            }
        }
    }

    return parts.joined(separator: "\n")
}

/// Maximum number of characters (UTF-16 code units) of a pull request body
/// to include in the prompt.
let MaxPullRequestBodyLength = 4000

/// Appends a single pull request's title and (truncated) body to the prompt.
private func appendPullRequest(_ parts: inout [String], _ pr: ConflictContextPullRequest) {
    parts.append("PR #\(pr.number): \(pr.title)")
    if !pr.body.isEmpty {
        parts.append("Description:")
        parts.append(makeFencedBlock(truncateBody(pr.body)))
    }
    parts.append("")
}

/// Truncates an over-long pull request body so a single pull request can't
/// dominate the prompt.
private func truncateBody(_ body: String) -> String {
    if JS.length(body) <= MaxPullRequestBodyLength {
        return body
    }
    return "\(JS.prefix(body, utf16Count: MaxPullRequestBodyLength))\n\u{2026}(truncated)"
}

private let alphanumeric = JSCompat.regex(#"^[a-zA-Z0-9]+\z"#)

/// Extracts a language identifier from a file path for use in code fences.
private func getLangFromPath(_ filePath: String) -> String {
    let ext = POSIXPath.extname(filePath)
    let lang = ext.hasPrefix(".") ? String(ext.dropFirst()) : ""
    // Only allow safe alphanumeric language tags.
    return JS.test(alphanumeric, lang) ? lang : ""
}

/// Wraps content in a fenced code block using a delimiter long enough to
/// avoid breaking if the content itself contains backticks.
private func makeFencedBlock(_ content: String, _ lang: String = "") -> String {
    var maxRun = 2
    var run = 0
    for scalar in content.unicodeScalars {
        if scalar == "`" {
            run += 1
            maxRun = max(maxRun, run)
        } else {
            run = 0
        }
    }
    let fence = String(repeating: "`", count: max(3, maxRun + 1))
    return "\(fence)\(lang)\n\(content)\n\(fence)"
}

/// Strips characters that could break markdown structure when used in
/// headings and labels.
private func sanitizeForMarkdown(_ text: String) -> String {
    String(String.UnicodeScalarView(text.unicodeScalars.filter { $0 != "\r" && $0 != "\n" && $0 != "`" }))
}
