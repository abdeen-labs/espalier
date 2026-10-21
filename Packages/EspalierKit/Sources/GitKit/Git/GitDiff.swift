// Ported from desktop/app/src/lib/git/diff.ts

import EspalierSupport
import Foundation

/// This is a hard limit on how big a buffer can be and still be converted into
/// a string.
let MaxDiffBufferSize = 70_000_000 // 70MB in decimal

/// Where `MaxDiffBufferSize` is a hard limit, this is a suggested limit. Diffs
/// bigger than this _could_ be displayed but it might cause some slowness.
let MaxReasonableDiffSize = MaxDiffBufferSize / 16 // ~4.375MB in decimal

/// The longest line length we should try to display. If a diff has a line longer
/// than this, we probably shouldn't attempt it
let MaxCharactersPerLine = 5000

/// The size limits the diff functions apply. A test can lower them for its
/// task.
enum DiffLimits {
    /// The most bytes of diff output turned into a diff: `MaxDiffBufferSize`
    /// unless a test lowered it. More gives `.unrenderable`.
    @TaskLocal static var maxBufferSize: Int = MaxDiffBufferSize

    /// The most bytes of diff text `getFilesDiffText` returns.
    @TaskLocal static var maxFilesDiffTextSize: Int = 10 * 1024 * 1024
}

/// Utility function to check whether parsing this buffer is going to cause
/// issues at runtime.
///
/// - Parameter buffer: A buffer of binary text from a spawned process
private func isValidBuffer(_ buffer: Data) -> Bool {
    buffer.count <= DiffLimits.maxBufferSize
}

/// Runs a diff command with its output capped one byte past
/// `DiffLimits.maxBufferSize` (stdout and stderr separately), so git stops
/// once its diff is too large to show. Returns nil when the output went past
/// the cap: the callers give `.unrenderable`, as `buildDiff` does for output
/// over the limit.
///
/// - Parameter capsOutput: Whether to cap the output. A submodule's diff is
///   read whole, as `buildSubmoduleDiff` reads one of any size.
private func runDiff(
    _ args: [String],
    _ path: String,
    _ name: String,
    options: GitExecutionOptions = GitExecutionOptions(),
    capsOutput: Bool = true
) async throws -> GitResult? {
    var options = options
    if capsOutput {
        options.maxBuffer = DiffLimits.maxBufferSize + 1
    }
    do {
        return try await git(args, path, name, options: options)
    } catch let error as ExecError where error.isMaxBufferExceeded {
        return nil
    }
}

/// Is the buffer too large for us to reasonably represent?
private func isBufferTooLarge(_ buffer: Data) -> Bool {
    buffer.count >= MaxReasonableDiffSize
}

/// Is the diff too large for us to reasonably represent?
private func isDiffTooLarge(_ diff: RawDiff) -> Bool {
    for hunk in diff.hunks {
        for line in hunk.lines {
            // Lengths count UTF-16 code units, which are never more than the
            // UTF-8 bytes, so only long lines need counting.
            if line.text.utf8.count > MaxCharactersPerLine, line.text.utf16.count > MaxCharactersPerLine {
                return true
            }
        }
    }

    return false
}

/// Defining the list of known extensions we can render inside the app
private let imageFileExtensions: Set<String> = [
    ".png",
    ".jpg",
    ".jpeg",
    ".gif",
    ".ico",
    ".webp",
    ".bmp",
    ".avif",
]

/// The paths to pass git for a file and, for a rename or copy, its old path.
private func pathspecs(for file: some FileChange) -> [String] {
    var paths = [ensureRelativePath(file.path)]
    switch file.status {
    case .renamed(let oldPath, _, _), .copied(let oldPath, _, _):
        paths.append(ensureRelativePath(oldPath))
    case .new, .modified, .deleted, .conflicted, .untracked:
        break
    }
    return paths
}

/// Render the difference between a file in the given commit and its parent
///
/// - Parameter commitish: A commit SHA or some other identifier that ultimately dereferences
///   to a commit.
public func getCommitDiff(
    _ repository: Repository,
    _ file: some FileChange,
    _ commitish: String,
    hideWhitespaceInDiff: Bool = false
) async throws -> Diff {
    let args = [
        "log",
        commitish,
    ] + (hideWhitespaceInDiff ? ["-w"] : []) + [
        "-m",
        "-1",
        "--first-parent",
        "--patch-with-raw",
        "--format=",
        "-z",
        "--no-color",
        "--",
    ] + pathspecs(for: file)

    guard let result = try await runDiff(
        args,
        repository.path,
        "getCommitDiff",
        capsOutput: file.status.submoduleStatus == nil
    ) else {
        return .unrenderable
    }

    return try await buildDiff(result.stdoutData, repository, file, commitish, commitish)
}

/// Render the diff between two branches with --merge-base for a file
/// (Show what would be the result of merge)
public func getBranchMergeBaseDiff(
    _ repository: Repository,
    _ file: some FileChange,
    _ baseBranchName: String,
    _ comparisonBranchName: String,
    hideWhitespaceInDiff: Bool = false,
    latestCommit: String
) async throws -> Diff {
    // `--no-ext-diff`, as everywhere `git diff` runs: a configured
    // `diff.external` program would replace the patch, and the diff couldn't
    // be parsed.
    let args = [
        "diff",
        "--merge-base",
    ] + (hideWhitespaceInDiff ? ["-w"] : []) + [
        "--no-ext-diff",
        "--patch-with-raw",
        "-z",
        "--no-color",
        "--end-of-options",
        baseBranchName,
        comparisonBranchName,
        "--",
    ] + pathspecs(for: file)

    guard let result = try await runDiff(
        args,
        repository.path,
        "getBranchMergeBaseDiff",
        capsOutput: file.status.submoduleStatus == nil
    ) else {
        return .unrenderable
    }

    return try await buildDiff(result.stdoutData, repository, file, latestCommit, latestCommit)
}

/// Render the difference between two commits for a file
public func getCommitRangeDiff(
    _ repository: Repository,
    _ file: some FileChange,
    _ commits: [String],
    hideWhitespaceInDiff: Bool = false,
    useNullTreeSHA: Bool = false
) async throws -> Diff {
    guard let firstCommit = commits.first, let latestCommit = commits.last else {
        throw GitLibError("No commits to diff...")
    }

    // The null tree in the repository's object format: the SHA-1 null tree
    // doesn't exist in SHA-256 repositories.
    var oldestCommit = firstCommit
    var oldestCommitRef = "\(firstCommit)^"
    if useNullTreeSHA {
        oldestCommit = try await getNullTreeSHA(repository)
        oldestCommitRef = oldestCommit
    }
    let args = [
        "diff",
        oldestCommitRef,
        latestCommit,
    ] + (hideWhitespaceInDiff ? ["-w"] : []) + [
        // See `getBranchMergeBaseDiff`.
        "--no-ext-diff",
        "--patch-with-raw",
        "--format=",
        "-z",
        "--no-color",
        "--",
    ] + pathspecs(for: file)

    guard let result = try await runDiff(
        args,
        repository.path,
        "getCommitsDiff",
        options: GitExecutionOptions(expectedErrors: [.badRevision]),
        capsOutput: file.status.submoduleStatus == nil
    ) else {
        return .unrenderable
    }

    // This should only happen if the oldest commit does not have a parent (ex:
    // initial commit of a branch) and therefore `SHA^` is not a valid reference.
    // In which case, we will retry with the null tree sha.
    if result.gitError == .badRevision, !useNullTreeSHA {
        return try await getCommitRangeDiff(
            repository,
            file,
            commits,
            hideWhitespaceInDiff: hideWhitespaceInDiff,
            useNullTreeSHA: true
        )
    }

    return try await buildDiff(result.stdoutData, repository, file, latestCommit, oldestCommit)
}

/// Get the files that were changed for the merge base comparison of two branches.
/// (What would be the result of a merge)
public func getBranchMergeBaseChangedFiles(
    _ repository: Repository,
    _ baseBranchName: String,
    _ comparisonBranchName: String,
    _ latestComparisonBranchCommitRef: String
) async throws -> ChangesetData? {
    let baseArgs = [
        "diff",
        "--merge-base",
        "-C",
        "-M",
        "-z",
        "--raw",
        "--numstat",
        "--end-of-options",
        baseBranchName,
        comparisonBranchName,
        "--",
    ]

    guard let mergeBaseCommit = try await getMergeBase(repository, baseBranchName, comparisonBranchName) else {
        return nil
    }

    let result = try await git(baseArgs, repository.path, "getBranchMergeBaseChangedFiles")

    return try parseRawLogWithNumstat(result.stdout, latestComparisonBranchCommitRef, mergeBaseCommit)
}

public func getCommitRangeChangedFiles(
    _ repository: Repository,
    _ shas: [String],
    useNullTreeSHA: Bool = false
) async throws -> ChangesetData {
    guard let firstSha = shas.first, let latestCommitRef = shas.last else {
        throw GitLibError("No commits to diff...")
    }

    // The null tree in the repository's object format; see
    // `getCommitRangeDiff`.
    var oldestCommitRef = "\(firstSha)^"
    if useNullTreeSHA {
        oldestCommitRef = try await getNullTreeSHA(repository)
    }
    let baseArgs = [
        "diff",
        oldestCommitRef,
        latestCommitRef,
        "-C",
        "-M",
        "-z",
        "--raw",
        "--numstat",
        "--",
    ]

    let result = try await git(
        baseArgs,
        repository.path,
        "getCommitRangeChangedFiles",
        options: GitExecutionOptions(expectedErrors: [.badRevision])
    )

    // This should only happen if the oldest commit does not have a parent (ex:
    // initial commit of a branch) and therefore `SHA^` is not a valid reference.
    // In which case, we will retry with the null tree sha.
    if result.gitError == .badRevision, !useNullTreeSHA {
        return try await getCommitRangeChangedFiles(repository, shas, useNullTreeSHA: true)
    }

    return try parseRawLogWithNumstat(result.stdout, latestCommitRef, oldestCommitRef)
}

/// Render the diff for a file within the repository working directory. The file will be
/// compared against HEAD if it's tracked, if not it'll be compared to an empty file meaning
/// that all content in the file will be treated as additions.
///
/// - Parameter textConv: Whether a `diff` driver's textconv program converts
///   the text, as `git diff` does by default. Patches that stage or discard
///   lines pass false: they must carry the file's own text.
public func getWorkingDirectoryDiff(
    _ repository: Repository,
    _ file: WorkingDirectoryFileChange,
    hideWhitespaceInDiff: Bool = false,
    textConv: Bool = true
) async throws -> Diff {
    // `--no-ext-diff` should be provided wherever we invoke `git diff` so that any
    // diff.external program configured by the user is ignored
    var args = ["diff"] + (hideWhitespaceInDiff ? ["-w"] : []) + (textConv ? [] : ["--no-textconv"]) + [
        "--no-ext-diff",
        "--patch-with-raw",
        "-z",
        "--no-color",
    ]
    var successExitCodes: Set<Int> = [0]
    let isSubmodule = file.status.submoduleStatus != nil

    // For added submodules, we'll use the "default" parameters, which are able
    // to output the submodule commit.
    if !isSubmodule, file.status.kind == .new || file.status.kind == .untracked {
        // `git diff --no-index` seems to emulate the exit codes from `diff` irrespective of
        // whether you set --exit-code
        //
        // this is the behavior:
        // - 0 if no changes found
        // - 1 if changes found
        // -   and error otherwise
        //
        // citation in source:
        // https://github.com/git/git/blob/1f66975deb8402131fbf7c14330d0c7cdebaeaa2/diff-no-index.c#L300
        successExitCodes.insert(1)
        args += ["--no-index", "--", "/dev/null", file.path]
    } else if file.status.kind == .renamed {
        // NB: Technically this is incorrect, the best kind of incorrect.
        // In order to show exactly what will end up in the commit we should
        // perform a diff between the new file and the old file as it appears
        // in HEAD. By diffing against the index we won't show any changes
        // already staged to the renamed file which differs from our other diffs.
        // The closest I got to that was running hash-object and then using
        // git diff <blob> <blob> but that seems a bit excessive.
        args += ["--", ensureRelativePath(file.path)]
    } else {
        args += ["HEAD", "--", ensureRelativePath(file.path)]
    }

    guard let result = try await runDiff(
        args,
        repository.path,
        "getWorkingDirectoryDiff",
        options: GitExecutionOptions(successExitCodes: successExitCodes),
        capsOutput: !isSubmodule
    ) else {
        return .unrenderable
    }
    let lineEndingsChange = parseLineEndingsWarning(result.stderrData)

    return try await buildDiff(result.stdoutData, repository, file, "HEAD", "HEAD", lineEndingsChange)
}

/// The result of `getResolutionDiff`: the computed diff together with the
/// exact old (base) and new (target) content strings it was generated from.
public struct ResolutionDiff: Hashable, Sendable {
    public let diff: Diff
    /// The full content of the base (old) side the diff was generated from.
    public let oldContents: String
    /// The full content of the target (new) side the diff was generated from.
    public let newContents: String

    public init(diff: Diff, oldContents: String, newContents: String) {
        self.diff = diff
        self.oldContents = oldContents
        self.newContents = newContents
    }
}

/// A side of a merge conflict in the index. These always refer to git's
/// definition: `ours` is stage 2 (HEAD at merge time), `theirs` is stage 3
/// (the commit being merged in).
public enum ResolutionStage: String, Hashable, Sendable {
    case ours
    case theirs
}

/// What `getResolutionDiff` compares the working tree file with.
public enum ResolutionDiffOptions: Hashable, Sendable {
    /// Content mode: a string (e.g. the AI's resolved text).
    case content(String)
    /// Stage mode: the content from a merge index stage.
    case stage(ResolutionStage)
}

/// Compute a diff between the working-tree file and either the AI's
/// resolved content string or the content from a specific merge index stage.
///
/// The baseline is always the on-disk file (which still has conflict markers
/// during an active merge). This gives a consistent view across all three
/// resolution options (AI, current, incoming) — the user sees exactly
/// what each choice changes relative to the file's current state.
///
/// Two calling conventions:
///
/// 1. **Content mode** — pass a `content` string (e.g. the AI's resolved
///    text) to diff directly against the working-tree file.
/// 2. **Stage mode** — pass `stage: .ours` or `.theirs` to read from the
///    merge index (`git show :2:<path>` or `git show :3:<path>`).
///    These always refer to git's definition: `ours` = stage 2 (HEAD at
///    merge time), `theirs` = stage 3 (the commit being merged in). Note
///    that during a rebase, git swaps these — the upstream branch is "ours"
///    and the rebased commit is "theirs". The caller is responsible for
///    mapping user-facing labels to the correct git side.
///
/// If the requested stage blob doesn't exist (e.g. file deleted on that
/// side in a modify/delete conflict), the target content is empty, showing
/// the on-disk content as entirely deleted.
///
/// Uses `git diff --no-index` with temp files.
///
/// Returns the computed diff alongside the exact old (base) and new (target)
/// content strings the diff was generated from. Callers can use these to feed
/// syntax highlighting and context expansion, since the diff sides don't
/// correspond to any addressable git revision.
public func getResolutionDiff(
    _ repository: Repository,
    _ filePath: String,
    _ options: ResolutionDiffOptions,
    hideWhitespaceInDiff: Bool = false
) async throws -> ResolutionDiff {
    // Always diff against the working-tree file (which still has conflict
    // markers). This gives a consistent baseline for all three resolution
    // choices (AI, current, incoming) so the user sees exactly what each
    // option changes relative to the file's current state on disk.
    let baseData = try Data(contentsOf: URL(filePath: POSIXPath.join(repository.path, filePath)))
    let baseContent = String(decoding: baseData, as: UTF8.self)
    let targetContent: String

    switch options {
    case .content(let content):
        // Direct content mode (e.g. the AI's resolved text).
        targetContent = content
    case .stage(let stage):
        // Stage mode — read the chosen side from the merge index.
        // If the blob doesn't exist (e.g. file deleted on that side in a
        // modify/delete conflict), use empty content to show full deletion.
        let gitStage = stage == .ours ? ":2" : ":3"
        do {
            let buffer = try await getBlobContents(repository, gitStage, filePath)
            targetContent = String(decoding: buffer, as: UTF8.self)
        } catch {
            targetContent = ""
        }
    }

    let tempBase = getTempFilePath("resolution-diff-base")
    let tempTarget = getTempFilePath("resolution-diff-target")

    defer {
        unlink(tempBase)
        unlink(tempTarget)
    }

    try Data(baseContent.utf8).write(to: URL(filePath: tempBase))
    try Data(targetContent.utf8).write(to: URL(filePath: tempTarget))

    let args = ["diff"] + (hideWhitespaceInDiff ? ["-w"] : []) + [
        "--no-ext-diff",
        "--patch-with-raw",
        "-z",
        "--no-color",
        "--no-index",
        "--",
        tempBase,
        tempTarget,
    ]

    guard let result = try await runDiff(
        args,
        repository.path,
        "getResolutionDiff",
        options: GitExecutionOptions(successExitCodes: [0, 1])
    ), isValidBuffer(result.stdoutData) else {
        return ResolutionDiff(diff: .unrenderable, oldContents: baseContent, newContents: targetContent)
    }
    let stdout = result.stdoutData

    let diff = try diffFromRawDiffOutput(stdout)

    if isDiffTooLarge(diff) {
        return ResolutionDiff(
            diff: .largeText(LargeTextDiff(
                text: diff.contents,
                hunks: diff.hunks,
                maxLineNumber: diff.maxLineNumber,
                hasHiddenBidiChars: diff.hasHiddenBidiChars
            )),
            oldContents: baseContent,
            newContents: targetContent
        )
    }

    return ResolutionDiff(
        diff: .text(TextDiff(
            text: diff.contents,
            hunks: diff.hunks,
            maxLineNumber: diff.maxLineNumber,
            hasHiddenBidiChars: diff.hasHiddenBidiChars
        )),
        oldContents: baseContent,
        newContents: targetContent
    )
}

/// Render the diff for a list of files within the repository working directory.
/// The files will be compared against HEAD if it's tracked, if not it'll be
/// compared to an empty file meaning that all content in the file will be
/// treated as additions.
///
/// Resets the index, stages the files, and diffs, all against a copy of the
/// index (`GIT_INDEX_FILE`), so the repository's own index, with what the
/// user had staged, is never touched. See `withTemporaryIndex`.
///
/// - Parameters:
///   - repository: The repository to get the diff for
///   - files: The list of files to get the diff for
///   - commitish: The commitish to compare against, if not provided it will
///     default to HEAD. Mainly used to get a diff that includes
///     both staged changes and the changes in a commit. For example,
///     when the user is amending a commit and wants to generate
///     a commit message based on both the new changes and the
///     changes in the commit.
public func getFilesDiffText(
    _ repository: Repository,
    _ files: [WorkingDirectoryFileChange],
    _ commitish: String? = nil
) async throws -> String {
    let maxSize = DiffLimits.maxFilesDiffTextSize
    let stdout = try await withTemporaryIndex(repository) { () async throws -> Data? in
        // Clear the staging area, our diffs reflect the difference between the
        // working directory and the last commit (if any) so our commits should
        // do the same thing.
        try await unstageAll(repository)

        try await stageFiles(repository, files)

        // `--no-ext-diff` should be provided wherever we invoke `git diff` so that any
        // diff.external program configured by the user is ignored
        var args = [
            "diff",
            "--no-ext-diff",
            "--patch-with-raw",
            "--no-color",
            "--staged",
        ]
        if let commitish, !commitish.isEmpty {
            args.append(commitish)
        }

        // Output past the limit stops git and gives nil.
        do {
            let result = try await git(
                args,
                repository.path,
                "getFilesDiffText",
                options: GitExecutionOptions(maxBuffer: maxSize + 1, successExitCodes: [0])
            )
            return result.stdoutData
        } catch let error as ExecError where error.isMaxBufferExceeded {
            return nil
        }
    }

    // No more than 10MB
    guard let stdout, stdout.count <= maxSize else {
        throw GitLibError("Diff is too large to render")
    }

    return String(decoding: stdout, as: UTF8.self)
}

/// Runs `operation` with every git command it starts using a temporary copy
/// of `repository`'s index, through `GIT_INDEX_FILE`. The copy is deleted
/// afterwards; the repository's index file is only read.
///
/// The copy starts out byte for byte the same as the real index (a clone on
/// APFS), so commands run against it behave exactly as they would against
/// the real one. Writes go to the copy and its own `.lock` file, so this also
/// works while another git process holds `index.lock`.
func withTemporaryIndex<T: Sendable>(
    _ repository: Repository,
    _ operation: () async throws -> T
) async throws -> T {
    let indexPath = try await getIndexFilePath(repository)
    let temporaryIndexPath = getTempFilePath("espalier-index")

    defer {
        unlink(temporaryIndexPath)
        unlink(temporaryIndexPath + ".lock")
    }

    if copyfile(indexPath, temporaryIndexPath, nil, copyfile_flags_t(COPYFILE_CLONE)) != 0 {
        let code = errno
        // A repository without an index file has nothing staged, which a
        // missing temporary index also means.
        if code != ENOENT {
            throw POSIXError(POSIXErrorCode(rawValue: code) ?? .EIO)
        }
    }

    var runtime = GitRuntime.current
    runtime.processEnvironment["GIT_INDEX_FILE"] = temporaryIndexPath
    return try await GitRuntime.withRuntime(runtime) {
        try await operation()
    }
}

/// The absolute path of the index file git uses for `repository` (in a
/// linked worktree, its own index inside the main repository's git
/// directory).
private func getIndexFilePath(_ repository: Repository) async throws -> String {
    let result = try await git(["rev-parse", "--git-path", "index"], repository.path, "getIndexFilePath")
    var output = result.stdoutData
    if output.last == UInt8(ascii: "\n") {
        output.removeLast()
    }
    // Relative to the working directory, unless it's elsewhere.
    return POSIXPath.resolve(repository.path, String(decoding: output, as: UTF8.self))
}

private func getImageDiff(
    _ repository: Repository,
    _ file: some FileChange,
    _ newestCommitish: String,
    _ oldestCommitish: String
) async throws -> ImageDiff {
    var current: DiffImage?
    var previous: DiffImage?

    // Are we looking at a file in the working directory or a file in a commit?
    if let file = file as? WorkingDirectoryFileChange {
        // No idea what to do about this, a conflicted binary (presumably) file.
        if file.status.kind == .conflicted {
            return ImageDiff()
        }

        // Does it even exist in the working directory?
        if file.status.kind != .deleted {
            current = try await getWorkingDirectoryImage(repository, file)
        }

        if file.status.kind != .new, file.status.kind != .untracked {
            // If we have file.oldPath that means it's a rename so we'll
            // look for that file.
            previous = try await getBlobImage(repository, getOldPathOrDefault(file), "HEAD")
        }
    } else {
        // File status can't be conflicted for a file in a commit
        if file.status.kind != .deleted {
            current = try await getBlobImage(repository, file.path, newestCommitish)
        }

        // File status can't be conflicted for a file in a commit
        if file.status.kind != .new, file.status.kind != .untracked, file.status.kind != .deleted {
            // If we have file.oldPath that means it's a rename so we'll
            // look for that file.
            //
            // A committed file's own parent commitish comes first. For a
            // commit or a range of commits it is `oldestCommitish^`. For the
            // merge-base diff of a pull request preview it is the merge base;
            // the newest commit's parent would show an image changed in an
            // earlier commit of the branch as unchanged.
            let previousCommitish = (file as? CommittedFileChange)?.parentCommitish ?? "\(oldestCommitish)^"
            previous = try await getBlobImage(repository, getOldPathOrDefault(file), previousCommitish)
        }

        if let file = file as? CommittedFileChange, file.status.kind == .deleted {
            previous = try await getBlobImage(repository, getOldPathOrDefault(file), file.parentCommitish)
        }
    }

    return ImageDiff(previous: previous, current: current)
}

public func convertDiff(
    _ repository: Repository,
    _ file: some FileChange,
    _ diff: RawDiff,
    _ newestCommitish: String,
    _ oldestCommitish: String,
    _ lineEndingsChange: LineEndingsChange? = nil
) async throws -> Diff {
    let extensionName = POSIXPath.extname(file.path).lowercased()

    if diff.isBinary {
        // some extension we don't know how to parse, never mind
        if !imageFileExtensions.contains(extensionName) {
            return .binary
        } else {
            return .image(try await getImageDiff(repository, file, newestCommitish, oldestCommitish))
        }
    }

    return .text(TextDiff(
        text: diff.contents,
        hunks: diff.hunks,
        lineEndingsChange: lineEndingsChange,
        maxLineNumber: diff.maxLineNumber,
        hasHiddenBidiChars: diff.hasHiddenBidiChars
    ))
}

/// Map a given file extension to the related data URL media type
///
/// The extension is compared in lowercase, as the check for an image
/// compares it, so `IMAGE.PNG` doesn't get the `text/plain` fallback.
private func getMediaType(_ extensionName: String) -> String {
    switch extensionName.lowercased() {
    case ".png":
        "image/png"
    case ".jpg", ".jpeg":
        "image/jpg"
    case ".gif":
        "image/gif"
    case ".ico":
        "image/x-icon"
    case ".webp":
        "image/webp"
    case ".bmp":
        "image/bmp"
    case ".avif":
        "image/avif"
    case ".dds":
        "image/vnd-ms.dds"
    default:
        // fallback value as per the spec
        "text/plain"
    }
}

/// `git diff` will write out messages about the line ending changes it knows
/// about to `stderr` - this rule here will catch this and also the to/from
/// changes based on what the user has configured.
///
/// `/', (CRLF|CR|LF) will be replaced by (CRLF|CR|LF) the .*/`
private let lineEndingsChangeRegex = JSCompat.regex(
    "', (CRLF|CR|LF) will be replaced by (CRLF|CR|LF) the \(JSCompat.dot)*"
)

/// Utility function for inspecting the stderr output for the line endings
/// warning that Git may report.
///
/// - Parameter error: A buffer of binary text from a spawned process
private func parseLineEndingsWarning(_ error: Data) -> LineEndingsChange? {
    if error.isEmpty {
        return nil
    }

    let errorText = String(decoding: error, as: UTF8.self)
    if let match = JSCompat.match(errorText, lineEndingsChangeRegex),
       let from = match[1].flatMap(parseLineEndingText),
       let to = match[2].flatMap(parseLineEndingText) {
        return LineEndingsChange(from: from, to: to)
    }

    return nil
}

/// Utility function used by get(Commit|WorkingDirectory)Diff.
///
/// Parses the output from a diff-like command that uses `--path-with-raw`
func diffFromRawDiffOutput(_ output: Data) throws -> RawDiff {
    // We assume the diff is UTF-8.
    try output.withUnsafeBytes { raw in
        let bytes = raw.bindMemory(to: UInt8.self)

        // Everything after the last NUL. NUL is a character of its own in
        // UTF-8, so splitting the bytes first gives the same text.
        var start = 0
        if let base = bytes.baseAddress {
            while start < bytes.count, let found = memchr(base + start, 0, bytes.count - start) {
                start = base.distance(to: found.assumingMemoryBound(to: UInt8.self)) + 1
            }
        }

        return try DiffParser().parse(UnsafeBufferPointer(rebasing: bytes[start...]))
    }
}

/// `'Subproject commit ([^-]+)(-dirty)?$'` after `-` (the old SHA) or `\+`
/// (the new SHA). Not anchored at the start.
private let oldSHARegex = JSCompat.regex(#"-Subproject commit ([^-]+)(-dirty)?\z"#)
private let newSHARegex = JSCompat.regex(#"\+Subproject commit ([^-]+)(-dirty)?\z"#)

private func buildSubmoduleDiff(
    _ buffer: Data,
    _ repository: Repository,
    _ file: some FileChange,
    _ status: SubmoduleStatus
) async throws -> Diff {
    let path = file.path
    let fullPath = POSIXPath.join(repository.path, path)
    let url = try await getConfigValue(repository, "submodule.\(path).url", onlyLocal: true)

    var oldSHA: String?
    var newSHA: String?

    if status.commitChanged || file.status.kind == .new || file.status.kind == .deleted {
        let diff = String(decoding: buffer, as: UTF8.self)
        let lines = JSCompat.split(diff, "\n")
        func lineMatch(_ regex: NSRegularExpression) -> String? {
            for line in lines {
                if let match = JSCompat.match(line, regex), let sha = match[1] {
                    return sha
                }
            }
            return nil
        }

        oldSHA = lineMatch(oldSHARegex)
        newSHA = lineMatch(newSHARegex)
    }

    return .submodule(SubmoduleDiff(
        fullPath: fullPath,
        path: path,
        url: url,
        status: status,
        oldSHA: oldSHA,
        newSHA: newSHA
    ))
}

private func buildDiff(
    _ buffer: Data,
    _ repository: Repository,
    _ file: some FileChange,
    _ newestCommitish: String,
    _ oldestCommitish: String,
    _ lineEndingsChange: LineEndingsChange? = nil
) async throws -> Diff {
    if let submoduleStatus = file.status.submoduleStatus {
        return try await buildSubmoduleDiff(buffer, repository, file, submoduleStatus)
    }

    if !isValidBuffer(buffer) {
        // the buffer's diff is too large to be renderable in the UI
        return .unrenderable
    }

    let diff = try diffFromRawDiffOutput(buffer)

    if isBufferTooLarge(buffer) || isDiffTooLarge(diff) {
        // we don't want to render by default
        // but we keep it as an option by
        // passing in text and hunks
        let largeTextDiff = LargeTextDiff(
            text: diff.contents,
            hunks: diff.hunks,
            lineEndingsChange: lineEndingsChange,
            maxLineNumber: diff.maxLineNumber,
            hasHiddenBidiChars: diff.hasHiddenBidiChars
        )

        return .largeText(largeTextDiff)
    }

    return try await convertDiff(repository, file, diff, newestCommitish, oldestCommitish, lineEndingsChange)
}

/// Retrieve the binary contents of a blob from the object database
///
/// Returns an image object containing the raw contents (`DiffImage.contents`
/// computes their base64 encoding, for data URIs).
public func getBlobImage(_ repository: Repository, _ path: String, _ commitish: String) async throws -> DiffImage {
    let extensionName = POSIXPath.extname(path)
    let contents = try await getBlobContents(repository, commitish, path)
    return DiffImage(rawContents: contents, mediaType: getMediaType(extensionName), bytes: contents.count)
}

/// Retrieve the binary contents of a blob from the working directory
///
/// Returns an image object containing the raw contents (`DiffImage.contents`
/// computes their base64 encoding, for data URIs).
public func getWorkingDirectoryImage(_ repository: Repository, _ file: some FileChange) async throws -> DiffImage {
    let contents = try Data(contentsOf: URL(filePath: POSIXPath.join(repository.path, file.path)))
    return DiffImage(rawContents: contents, mediaType: getMediaType(POSIXPath.extname(file.path)), bytes: contents.count)
}

/// List the modified binary files' paths in the given repository
///
/// - Parameters:
///   - repository: to run git operation in
///   - ref: ref (sha, branch, etc) to compare the working index against
///
/// if you're mid-merge pass `'MERGE_HEAD'` to ref to get a diff of `HEAD` vs `MERGE_HEAD`,
/// otherwise you should probably pass `'HEAD'` to get a diff of the working tree vs `HEAD`
public func getBinaryPaths(
    _ repository: Repository,
    _ ref: String,
    _ conflictedFilesInIndex: [StatusEntry]
) async throws -> [String] {
    async let detectedBinaryFiles = getDetectedBinaryFiles(repository, ref)
    async let conflictedFilesUsingBinaryMergeDriver = getFilesUsingBinaryMergeDriver(repository, conflictedFilesInIndex)

    let (detected, usingBinaryMergeDriver) = try await (detectedBinaryFiles, conflictedFilesUsingBinaryMergeDriver)

    // Both lists in order, without duplicates.
    var seen = Set<ExactString>()
    return (detected + usingBinaryMergeDriver).filter { seen.insert(ExactString($0)).inserted }
}

/// Runs diff --numstat to get the list of files that have changed and which
/// Git have detected as binary files
private func getDetectedBinaryFiles(_ repository: Repository, _ ref: String) async throws -> [String] {
    let result = try await git(["diff", "--numstat", "-z", ref], repository.path, "getBinaryPaths")

    return parseBinaryNumstatPaths(result.stdoutData)
}

/// The paths of the binary files in `git diff --numstat -z` output: the
/// entries whose added and deleted counts are both `-`.
///
/// Reads the entries one by one: `<added>\t<deleted>\t<path>\0`, or for a
/// rename or copy `<added>\t<deleted>\t\0<old path>\0<new path>\0`, reporting
/// the new path. A pattern matched across the whole output would let a
/// renamed binary file swallow the entries after it, and count a file whose
/// name contains "-\t-\t" as binary.
func parseBinaryNumstatPaths(_ output: Data) -> [String] {
    let fields = splitBuffer(output, "\0")
    let tab = UInt8(ascii: "\t")
    let dash = Data("-".utf8)

    var paths: [String] = []
    var i = 0
    while i < fields.count {
        let field = fields[i]
        i += 1

        guard let firstTab = field.firstIndex(of: tab),
              let secondTab = field[(firstTab + 1)...].firstIndex(of: tab)
        else {
            continue
        }

        let added = field[field.startIndex..<firstTab]
        let deleted = field[(firstTab + 1)..<secondTab]
        var path = field[(secondTab + 1)...]

        if path.isEmpty {
            // A rename or copy: the old and new paths are the next fields.
            guard i + 1 < fields.count else {
                break
            }
            path = fields[i + 1][...]
            i += 2
        }

        if added.elementsEqual(dash), deleted.elementsEqual(dash) {
            paths.append(String(decoding: path, as: UTF8.self))
        }
    }

    return paths
}

private enum CheckAttrField: Hashable, Sendable {
    case path
    case attr
    case value
}

private func getFilesUsingBinaryMergeDriver(
    _ repository: Repository,
    _ files: [StatusEntry]
) async throws -> [String] {
    let result = try await git(
        ["check-attr", "--stdin", "-z", "merge"],
        repository.path,
        "getConflictedFilesUsingBinaryMergeDriver",
        options: GitExecutionOptions(stdin: files.map(\.path).joined(separator: "\0"))
    )

    return createLogParser([CheckAttrField.path: "", .attr: "", .value: ""])
        .parse(result.stdout)
        .filter { JSCompat.strictEquals($0[.attr], "merge") && JSCompat.strictEquals($0[.value], "binary") }
        .map { $0[.path] }
}

/// Prefix absolute path with `:(top,literal)` to ensure that git treats it as a
/// literal path. This is important for paths that appear to be absolute paths on
/// some platforms and not others. See
/// https://git-scm.com/docs/gitglossary#Documentation/gitglossary.txt-top
///
/// Every other path is a literal pathspec too; as a pattern, the diff of
/// `a*.txt` would also hold ab.txt's changes, which a partial commit or
/// discard would then read as the file's.
private func ensureRelativePath(_ path: String) -> String {
    POSIXPath.isAbsolute(path) ? ":(top,literal)\(path)" : literalPathspec(path)
}

/// Whether git shows `path`'s diff through a textconv program: its `diff`
/// attribute names a driver with `diff.<driver>.textconv` set. Such a diff
/// shows the converted text, which isn't the file's, so no patch can be
/// built from its lines.
public func isTextConverted(_ repository: Repository, _ path: String) async -> Bool {
    guard let result = try? await git(
        ["check-attr", "-z", "diff", "--", path],
        repository.path,
        "isTextConverted"
    ) else {
        return false
    }
    // <path> NUL <attribute> NUL <value> NUL
    let fields = JSCompat.split(result.stdout, "\0")
    guard fields.count >= 3 else {
        return false
    }
    let driver = fields[2]
    if ["unspecified", "unset", "set", ""].contains(driver) {
        return false
    }
    let textconv = try? await getConfigValue(repository, "diff.\(driver).textconv")
    return !(textconv ?? "").isEmpty
}
