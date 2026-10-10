// Ported from desktop/app/src/lib/git/log.ts

import EspalierSupport
import Foundation

// File mode 160000 is used by git specifically for submodules:
// https://github.com/git/git/blob/v2.37.3/cache.h#L62-L69
private let submoduleFileMode = "160000"

private func mapSubmoduleStatusFileModes(
    _ status: String,
    _ srcMode: String,
    _ dstMode: String
) -> SubmoduleStatus? {
    if srcMode == submoduleFileMode && dstMode == submoduleFileMode && status == "M" {
        return SubmoduleStatus(commitChanged: true, modifiedChanges: false, untrackedChanges: false)
    }
    if (srcMode == submoduleFileMode && status == "D") || (dstMode == submoduleFileMode && status == "A") {
        return SubmoduleStatus(commitChanged: false, modifiedChanges: false, untrackedChanges: false)
    }
    return nil
}

/// `/R[0-9]+/` and `/C[0-9]+/`, unanchored.
private let renameScorePattern = JSCompat.regex("R[0-9]+")
private let copyScorePattern = JSCompat.regex("C[0-9]+")

/// Map the raw status text from Git to an app-friendly value
private func mapStatus(
    _ rawStatus: String,
    _ oldPath: String?,
    _ srcMode: String,
    _ dstMode: String
) -> AppFileStatus {
    let status = JSCompat.trim(rawStatus)
    let submoduleStatus = mapSubmoduleStatusFileModes(status, srcMode, dstMode)

    if status == "M" {
        return .modified(submoduleStatus: submoduleStatus)
    } // modified
    if status == "A" {
        return .new(submoduleStatus: submoduleStatus)
    } // added
    if status == "?" {
        return .untracked(submoduleStatus: submoduleStatus)
    } // untracked
    if status == "D" {
        return .deleted(submoduleStatus: submoduleStatus)
    } // deleted
    if status == "R", let oldPath {
        return .renamed(oldPath: oldPath, renameIncludesModifications: false, submoduleStatus: submoduleStatus)
    } // renamed
    if status == "C", let oldPath {
        return .copied(oldPath: oldPath, renameIncludesModifications: false, submoduleStatus: submoduleStatus)
    } // copied

    // git log -M --name-status will return a RXXX - where XXX is a percentage
    if JSCompat.match(status, renameScorePattern) != nil, let oldPath {
        return .renamed(
            oldPath: oldPath,
            renameIncludesModifications: status != "R100",
            submoduleStatus: submoduleStatus
        )
    }

    // git log -C --name-status will return a CXXX - where XXX is a percentage
    if JSCompat.match(status, copyScorePattern) != nil, let oldPath {
        return .copied(oldPath: oldPath, renameIncludesModifications: false, submoduleStatus: submoduleStatus)
    }

    return .modified(submoduleStatus: submoduleStatus)
}

private func isCopyOrRename(_ status: AppFileStatus) -> Bool {
    status.kind == .copied || status.kind == .renamed
}

/// The fields `getCommits` reads for each commit.
private enum CommitField: Hashable, Sendable {
    case sha, shortSha, summary, body, author, committer, parents, trailers, refs
}

/// The most bytes of a summary or body that `getCommits` keeps.
private let maximumMessageBytes = 100 * 1024

/// Get the repository's commits using `revisionRange` and limited to `limit`
///
/// - Parameters:
///   - revisionRange: The revision (or range) to log, or nil for git's
///     default.
///   - limit: The maximum number of commits to return.
///   - skip: The number of commits to skip before returning any.
///   - additionalArgs: Extra arguments for `git log`, placed before the
///     revision.
///
/// - Returns: The commits, newest first, or an empty list when HEAD is
///   unborn.
public func getCommits(
    _ repository: Repository,
    _ revisionRange: String? = nil,
    limit: Int? = nil,
    skip: Int? = nil,
    additionalArgs: [String] = []
) async throws -> [Commit] {
    var args = commitLogArgs(limit: limit, skip: skip)
    args.append(contentsOf: additionalArgs)

    // The explicit revision comes after additionalArgs, so it must not
    // inherit an exclusion toggle left active by options such as --not --remotes.
    if let revisionRange {
        let isExcludingRevisions = additionalArgs.filter { $0 == "--not" }.count % 2 == 1
        if isExcludingRevisions {
            args.append("--not")
        }

        args.append(contentsOf: ["--end-of-options", revisionRange])
    }

    args.append("--")
    let result = try await git(args, repository.path, "getCommits", options: GitExecutionOptions(
        successExitCodes: [0, 128]
    ))

    // if the repository has an unborn HEAD, return an empty history of commits
    if result.exitCode == 128 {
        return []
    }

    return try parseCommits(result.stdoutData)
}

/// Get the commits reachable from any of `revisions`, newest first (or in
/// the order `additionalArgs` asks for), limited to `limit` after skipping
/// `skip`.
///
/// The revisions are read from standard input (`git log --stdin`), so any
/// number of them fits; git peels tags and ignores revisions that name trees
/// or blobs. Unlike `getCommits(_:_:limit:skip:additionalArgs:)`, an empty
/// list means no history rather than HEAD's.
///
/// - Returns: The commits, or an empty list when `revisions` is empty.
/// - Throws: `GitError` when git fails, such as for a revision that names no
///   object (HEAD isn't involved, so exit code 128 isn't an unborn branch).
public func getCommits(
    _ repository: Repository,
    revisions: [String],
    limit: Int? = nil,
    skip: Int? = nil,
    additionalArgs: [String] = []
) async throws -> [Commit] {
    // `git log --stdin` with nothing on standard input logs HEAD.
    if revisions.isEmpty {
        return []
    }

    var args = commitLogArgs(limit: limit, skip: skip)
    args.append(contentsOf: additionalArgs)
    args.append(contentsOf: ["--stdin", "--"])

    let input = revisions.map { "\($0)\n" }.joined()
    let result = try await git(
        args,
        repository.path,
        "getCommitsFromRevisions",
        options: GitExecutionOptions(stdin: Data(input.utf8))
    )

    return try parseCommits(result.stdoutData)
}

/// A commit and the number of files it changed.
public struct CommitWithChangedFileCount: Hashable, Sendable {
    public let commit: Commit
    /// The files the commit changed against its first parent (a root
    /// commit against the empty tree), a rename counting once, as the
    /// commit's changed files list them (`getChangedFiles`).
    public let changedFileCount: Int

    public init(commit: Commit, changedFileCount: Int) {
        self.commit = commit
        self.changedFileCount = changedFileCount
    }
}

/// Get the commits reachable from any of `revisions`, with the number of
/// files each changed, newest first (or in the order `additionalArgs` asks
/// for), limited to `limit`.
///
/// History's simple mode shows each commit's file count.
/// The counts come from the same `git log` as the commits (`--raw`, a tree
/// comparison that reads no file contents, with renames detected), so they
/// cost little more than the log itself; a merge counts against its first
/// parent, as its changed files are listed. The revisions are read from
/// standard input, as for `getCommits(_:revisions:limit:skip:additionalArgs:)`,
/// so `^<sha>` excludes a commit's history.
///
/// - Returns: The commits, or an empty list when `revisions` is empty.
/// - Throws: `GitError` when git fails, such as for a revision that names no
///   object.
public func getCommitsWithChangedFileCounts(
    _ repository: Repository,
    revisions: [String],
    limit: Int? = nil,
    additionalArgs: [String] = []
) async throws -> [CommitWithChangedFileCount] {
    // `git log --stdin` with nothing on standard input logs HEAD.
    if revisions.isEmpty {
        return []
    }

    var args = commitLogArgs(limit: limit, skip: nil)
    // `--root` and `--diff-merges` are explicit so `log.showRoot` and
    // `log.diffMerges` can't change the counts.
    args.append(contentsOf: ["--raw", "-M", "--root", "--diff-merges=first-parent"])
    args.append(contentsOf: additionalArgs)
    args.append(contentsOf: ["--stdin", "--"])

    let input = revisions.map { "\($0)\n" }.joined()
    let result = try await git(
        args,
        repository.path,
        "getCommitsWithChangedFileCounts",
        options: GitExecutionOptions(stdin: Data(input.utf8))
    )

    return try parseCommitsWithRawEntries(result.stdoutData)
}

/// Parses `git log` output in `commitLogParser`'s format followed, for each
/// commit with changes, by its `--raw -z` entries:
///
///     <field>\0<field>\0...<field>\0
///     \n:100644 100644 5716ca5 db3c77d M\0path\0
///     :100644 100644 0835e4f 28096ea R100\0old path\0new path\0
///     <the next commit's fields>...
///
/// A commit without changes is followed by the next commit's fields at once.
private func parseCommitsWithRawEntries(_ stdout: Data) throws -> [CommitWithChangedFileCount] {
    let tokens = splitBuffer(stdout, "\0")
    let fieldCount = commitLogParser.fieldCount
    let colon = UInt8(ascii: ":")
    let newline = UInt8(ascii: "\n")

    /// The status of a raw entry (`R100` in `:100644 100644 a b R100`), if
    /// `token` is one.
    func rawStatus(_ token: Data) -> Data? {
        guard let start = token.firstIndex(where: { $0 != newline }), token[start] == colon,
              let space = token.lastIndex(of: UInt8(ascii: " "))
        else {
            return nil
        }
        return token[token.index(after: space)...]
    }

    var commits: [CommitWithChangedFileCount] = []
    var index = 0
    // The output ends with a NUL, so the last token is empty.
    while index + fieldCount <= tokens.count {
        let record = commitLogParser.record(tokens[index..<(index + fieldCount)])
        index += fieldCount
        var count = 0
        while index < tokens.count, let status = rawStatus(tokens[index]) {
            // A rename or copy has the old and the new path.
            let first = status.first
            let paths = first == UInt8(ascii: "R") || first == UInt8(ascii: "C") ? 2 : 1
            guard index + paths < tokens.count else {
                throw GitLibError("Invalid log output (missing path)")
            }
            index += 1 + paths
            count += 1
        }
        commits.append(CommitWithChangedFileCount(commit: try parseCommit(record), changedFileCount: count))
    }
    return commits
}

/// The fields `getCommits` reads, in `git log --format` syntax.
private let commitLogParser = createLogParser([
    CommitField.sha: "%H", // SHA
    .shortSha: "%h", // short SHA
    .summary: "%s", // summary
    .body: "%b", // body
    // author identity string, matching format of GIT_AUTHOR_IDENT.
    //   author name <author email> <author date>
    // author date format dependent on --date arg, should be raw
    .author: "%an <%ae> %ad",
    .committer: "%cn <%ce> %cd",
    .parents: "%P", // parent SHAs,
    .trailers: "%(trailers:unfold,only)",
    .refs: "%D",
])

/// `git log` with `getCommits`' format, limit, and skip, before any other
/// arguments.
private func commitLogArgs(limit: Int?, skip: Int?) -> [String] {
    var args = ["log", "--date=raw"]

    if let limit {
        args.append("--max-count=\(limit)")
    }

    if let skip {
        args.append("--skip=\(skip)")
    }

    args.append(contentsOf: commitLogParser.formatArgs)
    // Messages and names come out as UTF-8 whatever
    // `i18n.logOutputEncoding` (which defaults to `i18n.commitEncoding`)
    // says, so a repository committing in Latin-1 doesn't show U+FFFD for
    // its accents.
    args.append(contentsOf: ["--encoding=UTF-8", "--no-show-signature", "--no-color"])
    return args
}

/// Parses `git log` output in `commitLogParser`'s format.
private func parseCommits(_ stdout: Data) throws -> [Commit] {
    try commitLogParser.parse(stdout).map(parseCommit)
}

/// A commit from one record of `commitLogParser`'s format.
private func parseCommit(_ commit: DelimitedRecord<CommitField, Data>) throws -> Commit {
    // Ref is of the format: (HEAD -> master, tag: some-tag-name, tag: some-other-tag,with-a-comma, origin/master, origin/HEAD)
    // Refs are comma separated, but some like tags can also contain commas in the name, so we split on the pattern ", " and then
    // check each ref for the tag prefix. A regex like /tag: ([^\s,]+)/g would clip a tag with a comma short.
    let tags = JSCompat.split(utf8(commit[.refs]), ", ").compactMap { ref in
        JSCompat.startsWith(ref, "tag: ") ? JSCompat.dropFirst(ref, 5) : nil
    }

    let parents = commit[.parents]

    return Commit(
        sha: utf8(commit[.sha]),
        shortSha: utf8(commit[.shortSha]),
        summary: utf8(commit[.summary].prefix(maximumMessageBytes)),
        body: utf8(commit[.body].prefix(maximumMessageBytes)),
        author: try CommitIdentity.parseIdentity(utf8(commit[.author])),
        committer: try CommitIdentity.parseIdentity(utf8(commit[.committer])),
        parentSHAs: parents.isEmpty ? [] : JSCompat.split(utf8(parents), " "),
        // We know for sure that the trailer separator will be ':' since we got
        // them from %(trailers:unfold) above, see `git help log`:
        //
        //   "key_value_separator=<SEP>: specify a separator inserted between
        //    trailer lines. When this option is not given each trailer key-value
        //    pair is separated by ": ". Otherwise it shares the same semantics as
        //    separator=<SEP> above."
        trailers: parseRawUnfoldedTrailers(utf8(commit[.trailers]), ":"),
        tags: tags
    )
}

/// UTF-8, with U+FFFD for invalid sequences.
private func utf8(_ data: Data) -> String {
    String(decoding: data, as: UTF8.self)
}

/// This interface contains information of a changeset.
public struct ChangesetData: Hashable, Sendable {
    /// Files changed in the changeset.
    public let files: [CommittedFileChange]

    /// Number of lines added in the changeset.
    public let linesAdded: Int

    /// Number of lines deleted in the changeset.
    public let linesDeleted: Int

    /// Each file's lines added and deleted, by the file's ID. A binary file
    /// has nil counts (`-` in `--numstat`).
    public let lineCounts: [String: FileLineCount]

    public init(files: [CommittedFileChange], linesAdded: Int, linesDeleted: Int, lineCounts: [String: FileLineCount] = [:]) {
        self.files = files
        self.linesAdded = linesAdded
        self.linesDeleted = linesDeleted
        self.lineCounts = lineCounts
    }
}

/// A file's lines added and deleted in a changeset; nil for a binary file.
public struct FileLineCount: Hashable, Sendable {
    public let added: Int?
    public let deleted: Int?

    public init(added: Int?, deleted: Int?) {
        self.added = added
        self.deleted = deleted
    }
}

/// Get the files that were changed in the given commit.
public func getChangedFiles(_ repository: Repository, _ sha: String) async throws -> ChangesetData {
    // opt-in for rename detection (-M) and copies detection (-C)
    // this is equivalent to the user configuring 'diff.renames' to 'copies'
    // NOTE: order here matters - doing -M before -C means copies aren't detected
    let args = [
        "log",
        sha,
        "-C",
        "-M",
        "-m",
        "-1",
        "--no-show-signature",
        "--first-parent",
        "--raw",
        "--format=format:",
        "--numstat",
        "-z",
        "--",
    ]

    let result = try await git(args, repository.path, "getChangesFiles")
    return try parseRawLogWithNumstat(result.stdout, sha, "\(sha)^")
}

/// `/^(\d+|-)\t(\d+|-)\t/`
private let numstatPattern = JSCompat.regex("^([0-9]+|-)\\t([0-9]+|-)\\t")

/// Parses output of diff flags -z --raw --numstat.
///
/// Given the -z flag the new lines are separated by \0 character (left them as
/// new lines below for ease of reading)
///
/// For modified, added, deleted, untracked:
///
///     100644 100644 5716ca5 db3c77d M
///     file_one_path
///     :100644 100644 0835e4f 28096ea M
///     file_two_path
///     1    0       file_one_path
///     1    0       file_two_path
///
/// For copied or renamed:
///
///     100644 100644 5716ca5 db3c77d M
///     file_one_original_path
///     file_one_new_path
///     :100644 100644 0835e4f 28096ea M
///     file_two_original_path
///     file_two_new_path
///     1    0
///     file_one_original_path
///     file_one_new_path
///     1    0
///     file_two_original_path
///     file_two_new_path
public func parseRawLogWithNumstat(
    _ stdout: String,
    _ sha: String,
    _ parentCommitish: String
) throws -> ChangesetData {
    var files: [CommittedFileChange] = []
    var linesAdded = 0
    var linesDeleted = 0
    var lineCounts: [String: FileLineCount] = [:]
    var numStatCount = 0
    let lines = JSCompat.split(stdout, "\0")

    /// The line at `i`, or nil past the end.
    func lineAt(_ i: Int) -> String? {
        lines.indices.contains(i) ? lines[i] : nil
    }

    var i = 0
    while i < lines.count - 1 {
        defer { i += 1 }
        let line = lines[i]

        if JSCompat.startsWith(line, ":") {
            let lineComponents = JSCompat.split(line, " ")
            let srcMode = try forceUnwrap(
                "Invalid log output (srcMode)",
                lineComponents.first.map { JSCompat.replaceFirst($0, ":", with: "") }
            )
            let dstMode = try forceUnwrap(
                "Invalid log output (dstMode)",
                lineComponents.count > 1 ? lineComponents[1] : nil
            )
            let status = try forceUnwrap("Invalid log output (status)", lineComponents.last)

            // `/^R|C/`: a status starting with R, or containing C.
            var oldPath: String?
            if JSCompat.startsWith(status, "R") || JSCompat.includes(status, "C") {
                i += 1
                oldPath = try forceUnwrap("Missing old path", lineAt(i))
            }

            i += 1
            let path = try forceUnwrap("Missing path", lineAt(i))

            files.append(CommittedFileChange(
                path: path,
                status: mapStatus(status, oldPath, srcMode, dstMode),
                commitish: sha,
                parentCommitish: parentCommitish
            ))
        } else {
            let match = try forceUnwrap("Invalid numstat line", JSCompat.match(line, numstatPattern))
            let added = match[1] ?? ""
            let deleted = match[2] ?? ""
            linesAdded += added == "-" ? 0 : JSCompat.parseInt(added) ?? 0
            linesDeleted += deleted == "-" ? 0 : JSCompat.parseInt(deleted) ?? 0

            // If this entry denotes a rename or copy the old and new paths are on
            // two separate fields (separated by \0). Otherwise they're on the same
            // line as the added and deleted lines.
            guard files.indices.contains(numStatCount) else {
                throw GitLibError("Invalid numstat line: no file for entry \(numStatCount)")
            }
            lineCounts[files[numStatCount].id] = FileLineCount(
                added: added == "-" ? nil : JSCompat.parseInt(added) ?? 0,
                deleted: deleted == "-" ? nil : JSCompat.parseInt(deleted) ?? 0
            )
            if isCopyOrRename(files[numStatCount].status) {
                i += 2
            }
            numStatCount += 1
        }
    }

    return ChangesetData(files: files, linesAdded: linesAdded, linesDeleted: linesDeleted, lineCounts: lineCounts)
}

/// Get the commit for the given ref.
public func getCommit(_ repository: Repository, _ ref: String) async throws -> Commit? {
    let commits = try await getCommits(repository, ref, limit: 1)
    return commits.first
}

/// Get the author identity for the given shas
public func getAuthors(_ repository: Repository, _ shas: [String]) async throws -> [CommitIdentity] {
    if shas.isEmpty {
        return []
    }

    let result = try await git(
        [
            "log",
            "--format=format:%an <%ae> %ad",
            "--encoding=UTF-8",
            "--no-walk=unsorted",
            "--date=raw",
            "-z",
            "--stdin",
        ],
        repository.path,
        "getAuthors",
        options: GitExecutionOptions(stdin: shas.joined(separator: "\n"))
    )

    let authors = try JSCompat.split(result.stdout, "\0").map(CommitIdentity.parseIdentity)

    // This can happen if there are duplicate shas in the input, git log will only
    // return the author once for each sha.
    guard authors.count == shas.count else {
        throw GitLibError("Commit to author mismatch")
    }

    return authors
}
