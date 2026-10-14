// Ported from desktop/app/src/lib/ (stores/app-store.ts, copilot-conflict-context.ts, path.ts)
//
// - `resolveWithin` accepts a path only when its real path is the root or
//   inside it, not one that merely starts with the root's (`/src/app-other`
//   for `/src/app`).
// - A conflicted text file that isn't valid UTF-8 (Latin-1, say) is skipped
//   ("File could not be read"): writing the resolution back would replace
//   its other bytes throughout the file.
// - A rebase's conflicts get commit context from the base branch the
//   rebase records.
// - Pull requests missing from the local cache are fetched from the
//   repository pull requests are contributed to, the one the cache is for.
//
// These are namespaced in `ConflictContextGatherer` so they can't collide
// with helpers of the same name elsewhere in the module.

import AIKit
import Darwin
import EspalierSupport
import Foundation
import GitHubKit
import GitKit
import os

private let logger = Log.logger(category: "ai")

/// What a conflict resolution round sends to the model: the conflicted
/// files, the labels of both sides, recent commits from each side, and the
/// pull requests they mention.
enum ConflictContextGatherer {
    /// Display labels for both sides of the conflict, and the git refs to
    /// read each side's commits from (nil when the side isn't a branch).
    struct Labels: Sendable, Equatable {
        var ourLabel: String
        var theirLabel: String
        var ourRef: String?
        var theirRef: String?
    }

    /// At most this many pull request numbers mined from commits are looked
    /// up.
    static let maxPullRequestLookups = 10

    /// How many commits of each side are gathered.
    static let commitLimit = 10

    // MARK: Labels

    /// The labels and refs of both sides, with the branches shown for the
    /// conflicts (`operations.conflictBranches`): a merge's current and
    /// merged branches; a rebase's base branch and the branch being rebased;
    /// a cherry-pick's target and source; a squash's or reorder's branch and
    /// the commit being moved; a revert's branch and the reverted commit.
    /// A side that isn't known gets a generic name ("incoming branch",
    /// "current branch", "cherry-picked commit").
    static func labels(
        _ conflictState: ConflictState,
        operation: MultiCommitOperation?,
        branches: ConflictBranches?
    ) -> Labels {
        switch conflictState {
        case .merge(let currentBranch, _, _):
            let theirBranch = branches?.theirs
            return Labels(
                ourLabel: currentBranch,
                theirLabel: theirBranch ?? "incoming branch",
                ourRef: currentBranch,
                theirRef: theirBranch
            )
        case .rebase(_, let targetBranch, _, _, _, _):
            switch operation?.detail {
            case .squash?, .reorder?:
                // The commits being moved aren't a branch: no commit context.
                return Labels(
                    ourLabel: branches?.ours ?? targetBranch,
                    theirLabel: branches?.theirs ?? "incoming commit",
                    ourRef: nil,
                    theirRef: nil
                )
            default:
                let baseBranch = branches?.ours
                return Labels(
                    ourLabel: baseBranch ?? "current branch",
                    theirLabel: targetBranch,
                    ourRef: baseBranch,
                    theirRef: targetBranch
                )
            }
        case .cherryPick(let targetBranchName, _):
            let sourceBranch = branches?.theirs
            return Labels(
                ourLabel: targetBranchName,
                theirLabel: sourceBranch ?? "cherry-picked commit",
                ourRef: targetBranchName,
                theirRef: sourceBranch
            )
        case .revert(let targetBranchName, _):
            return Labels(ourLabel: targetBranchName, theirLabel: "reverted commit", ourRef: targetBranchName, theirRef: nil)
        }
    }

    /// The branch `MERGE_HEAD` points at when exactly one does, for a merge
    /// whose source branch isn't known yet. Nil for squash merges (no
    /// `MERGE_HEAD`).
    static func mergeHeadBranch(_ repository: Repository) async -> String? {
        guard let names = try? await getBranchesPointedAt(repository, "MERGE_HEAD"), names.count == 1 else {
            return nil
        }
        return names[0]
    }

    // MARK: Files

    /// Which side deleted a file in a delete-vs-modify conflict, or nil.
    static func getDeletedSideFromStatus(_ file: WorkingDirectoryFileChange) -> ConflictSide? {
        guard case .conflicted(let status) = file.status else {
            return nil
        }
        let entry = status.entry
        if entry.us == .deleted, entry.them != .deleted {
            return .ours
        }
        if entry.them == .deleted, entry.us != .deleted {
            return .theirs
        }
        return nil
    }

    /// Reads the conflicted files for AIKit's `buildConflictContext`: a
    /// delete-vs-modify conflict needs no contents; other files must resolve
    /// within the repository (symbolic links included), be at most
    /// `MaxConflictFileReadSize` bytes, and be UTF-8 text.
    @concurrent
    static func readConflictedFiles(repositoryPath: String, files: [WorkingDirectoryFileChange]) async -> [ConflictedFile] {
        files.map { file in
            if let deletedSide = getDeletedSideFromStatus(file) {
                return ConflictedFile(path: file.path, deletedSide: deletedSide)
            }
            let absolutePath: String?
            do {
                absolutePath = try resolveWithin(repositoryPath, file.path)
            } catch {
                return ConflictedFile(path: file.path, contents: .unresolvablePath)
            }
            guard let absolutePath else {
                return ConflictedFile(path: file.path, contents: .outsideRepository)
            }
            return ConflictedFile(path: file.path, contents: readConflictedFileContents(atPath: absolutePath))
        }
    }

    /// Reads a conflicted file: too large (by `stat`, following symbolic
    /// links), unreadable, or its text. A file with conflict markers whose
    /// bytes aren't valid UTF-8 is unreadable: its resolution would be
    /// written back as UTF-8, replacing them throughout the file. Without
    /// markers (a binary file) it's read with those bytes replaced, and
    /// skipped for having no conflict markers.
    static func readConflictedFileContents(atPath absolutePath: String) -> ConflictedFileContents {
        var info = stat()
        guard stat(absolutePath, &info) == 0 else {
            return .unreadable
        }
        if info.st_size > MaxConflictFileReadSize {
            return .tooLarge
        }
        guard let data = FileManager.default.contents(atPath: absolutePath) else {
            return .unreadable
        }
        if let text = decodeUTF8Exactly(data) {
            return .text(text)
        }
        return hasOpeningConflictMarker(data) ? .unreadable : .text(String(decoding: data, as: UTF8.self))
    }

    /// Whether a line of `data` starts with `<<<<<<<`.
    private static func hasOpeningConflictMarker(_ data: Data) -> Bool {
        let marker = Array("<<<<<<<".utf8)
        let bytes = Array(data)
        var lineStart = 0
        while lineStart < bytes.count {
            if bytes[lineStart...].starts(with: marker) {
                return true
            }
            guard let newline = bytes[lineStart...].firstIndex(of: UInt8(ascii: "\n")) else {
                return false
            }
            lineStart = newline + 1
        }
        return false
    }

    /// The text of `data` when it is valid UTF-8 that encodes back to the
    /// same bytes, else nil.
    static func decodeUTF8Exactly(_ data: Data) -> String? {
        guard let text = String(validating: data, as: UTF8.self), Data(text.utf8) == data else {
            return nil
        }
        return text
    }

    /// Resolves path segments under `rootPath`: the absolute path, or nil when
    /// it (after following symbolic links) isn't the root or inside it, or has
    /// a NUL byte.
    ///
    /// - Throws: When the root or the path can't be resolved (for example
    ///   when it doesn't exist).
    static func resolveWithin(_ rootPath: String, _ pathSegments: String...) throws -> String? {
        // An empty root path would let all relative paths through.
        if rootPath.isEmpty {
            return nil
        }

        let normalizedRoot = POSIXPath.normalize(rootPath)
        let normalizedRelative = POSIXPath.normalize(POSIXPath.join(pathSegments))

        // Null bytes have no place in paths.
        if normalizedRoot.utf8.contains(0) || normalizedRelative.utf8.contains(0) {
            return nil
        }

        // Resolve to an absolute path. This will not contain any directory
        // traversal segments.
        let resolved = POSIXPath.resolve(normalizedRoot, normalizedRelative)

        let realRoot = try realPath(normalizedRoot)
        let realResolved = try realPath(resolved)

        return isWithin(realResolved, realRoot) ? resolved : nil
    }

    /// Whether `path` is `root` or inside it, comparing bytes. A plain prefix
    /// check would let `/src/app-other` pass for `/src/app`.
    static func isWithin(_ path: String, _ root: String) -> Bool {
        let path = Array(path.utf8)
        var root = Array(root.utf8)
        if root.count > 1, root.last == UInt8(ascii: "/") {
            root.removeLast()
        }
        guard path.starts(with: root) else {
            return false
        }
        return path.count == root.count || root == [UInt8(ascii: "/")] || path[root.count] == UInt8(ascii: "/")
    }

    /// `realpath(3)`.
    private static func realPath(_ path: String) throws -> String {
        guard let resolved = Darwin.realpath(path, nil) else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
        defer { free(resolved) }
        return String(cString: resolved)
    }

    // MARK: Commits

    /// Gather commit messages from both sides of the merge to provide intent
    /// context for conflict resolution: up to `limit` first-parent commits of
    /// each side since their merge base. Best effort: nil when the merge base
    /// can't be found or git fails.
    static func gatherCommitContext(
        _ repository: Repository,
        _ ourBranch: String,
        _ theirBranch: String,
        limit: Int = commitLimit
    ) async -> (ourCommits: [Commit], theirCommits: [Commit])? {
        do {
            guard let mergeBase = try await getMergeBase(repository, ourBranch, theirBranch) else {
                return nil
            }
            async let ourCommits = getCommits(repository, "\(mergeBase)..\(ourBranch)", limit: limit, additionalArgs: ["--first-parent"])
            async let theirCommits = getCommits(repository, "\(mergeBase)..\(theirBranch)", limit: limit, additionalArgs: ["--first-parent"])
            return try await (ourCommits, theirCommits)
        } catch {
            return nil
        }
    }

    // MARK: Pull requests

    /// Resolve pull request numbers into display-ready context, preferring
    /// the local cache and falling back to the API for any missing (merged
    /// pull requests are no longer in the open pull request cache). Capped
    /// (`maxPullRequestLookups`) and best effort. `seeded` entries are
    /// already resolved and never looked up.
    ///
    /// - Parameters:
    ///   - isGitHubRepository: Whether the repository is on GitHub; when it
    ///     isn't, only the seeded pull requests are returned.
    ///   - fetch: Fetches one pull request from the API; nil without an
    ///     account. Failures return nil.
    static func resolvePullRequestContexts(
        numbers: [Int],
        seeded: [Int: ConflictContextPullRequest],
        isGitHubRepository: Bool,
        cached: [PullRequest],
        fetch: (@Sendable (Int) async -> ConflictContextPullRequest?)?
    ) async -> [Int: ConflictContextPullRequest] {
        var byNumber = seeded

        let lookups = Array(numbers.filter { byNumber[$0] == nil }.prefix(maxPullRequestLookups))
        if lookups.isEmpty || !isGitHubRepository {
            return byNumber
        }

        for pullRequest in findPullRequestsByNumbers(lookups, cached) {
            byNumber[pullRequest.pullRequestNumber] = ConflictContextPullRequest(
                number: pullRequest.pullRequestNumber,
                title: pullRequest.title,
                body: pullRequest.body
            )
        }

        // Fetch anything still missing from the API so merged pull requests
        // (no longer in the open pull request cache) still contribute their
        // title and body.
        let missing = lookups.filter { byNumber[$0] == nil }
        if !missing.isEmpty, let fetch {
            let fetched = await withTaskGroup(of: (Int, ConflictContextPullRequest?).self) { group in
                for number in missing {
                    group.addTask { (number, await fetch(number)) }
                }
                var fetched: [Int: ConflictContextPullRequest] = [:]
                for await (number, pullRequest) in group {
                    fetched[number] = pullRequest
                }
                return fetched
            }
            byNumber.merge(fetched) { existing, _ in existing }
        }

        return byNumber
    }

    // MARK: The context

    /// What gathering needs, captured on the main actor when the round
    /// starts.
    struct Input: Sendable {
        var repository: Repository
        var conflictState: ConflictState
        var labels: Labels
        /// The conflicted files to resolve: no markers removed and no side
        /// chosen yet.
        var files: [WorkingDirectoryFileChange]
        /// The current branch's commits that aren't on a remote.
        var localCommitSHAs: [String]
        /// The current branch's pull request, which may be merged or closed.
        var currentPullRequest: ConflictContextPullRequest?
        var isGitHubRepository: Bool
        /// The pull requests cached for the repository pull requests are
        /// contributed to.
        var cachedPullRequests: [PullRequest]
        var fetchPullRequest: (@Sendable (Int) async -> ConflictContextPullRequest?)?
    }

    /// Gather the full, display-ready context for a conflict resolution in
    /// a single pass: the conflicted file hunks, the recent commits from both
    /// sides, and the pull requests associated with either side. The same
    /// value feeds the prompt and the summary.
    ///
    /// Runs git inside the caller's runtimes.
    static func gather(_ input: Input) async -> (context: ConflictResolutionContext, labels: Labels) {
        var labels = input.labels
        if case .merge = input.conflictState, labels.theirRef == nil, let theirBranch = await mergeHeadBranch(input.repository) {
            labels.theirLabel = theirBranch
            labels.theirRef = theirBranch
        }

        let files = await readConflictedFiles(repositoryPath: input.repository.path, files: input.files)
        let fileContext = await buildContext(ourLabel: labels.ourLabel, theirLabel: labels.theirLabel, files: files)

        // Best-effort enrichment: never blocks resolution.
        var commitContext: (ourCommits: [Commit], theirCommits: [Commit])?
        if let ourRef = labels.ourRef, let theirRef = labels.theirRef {
            commitContext = await gatherCommitContext(input.repository, ourRef, theirRef)
        }

        // A commit is "on the remote" when it isn't one of the current
        // branch's local commits.
        let localSHAs = input.localCommitSHAs.exactSet
        func toContextCommit(_ commit: Commit) -> ConflictContextCommit {
            ConflictContextCommit(
                sha: commit.sha,
                shortSha: commit.shortSha,
                summary: commit.summary,
                isOnRemote: !localSHAs.contains(ExactString(commit.sha))
            )
        }

        // The current branch's pull request is authoritative and may be
        // merged or closed (absent from the open pull request cache), so
        // it's seeded rather than looked up.
        var seeded: [Int: ConflictContextPullRequest] = [:]
        var numbers: [Int] = []
        if let currentPullRequest = input.currentPullRequest {
            seeded[currentPullRequest.number] = currentPullRequest
            numbers.append(currentPullRequest.number)
        }
        // Pull requests are mined from both sides: which side carries them
        // depends on the operation, so the model decides what's material.
        for number in extractPullRequestNumbersFromCommits(commitContext?.ourCommits ?? [])
            + extractPullRequestNumbersFromCommits(commitContext?.theirCommits ?? [])
            where !numbers.contains(number) {
            numbers.append(number)
        }

        let resolved = await resolvePullRequestContexts(
            numbers: numbers,
            seeded: seeded,
            isGitHubRepository: input.isGitHubRepository,
            cached: input.cachedPullRequests,
            fetch: input.fetchPullRequest
        )

        let context = ConflictResolutionContext(
            fileContext,
            pullRequests: numbers.compactMap { resolved[$0] },
            ourCommits: (commitContext?.ourCommits ?? []).map(toContextCommit),
            theirCommits: (commitContext?.theirCommits ?? []).map(toContextCommit)
        )
        return (context, labels)
    }

    /// AIKit's `buildConflictContext`, off the main actor: it scans every
    /// file's lines.
    @concurrent
    private static func buildContext(ourLabel: String, theirLabel: String, files: [ConflictedFile]) async -> AIConflictContext {
        buildConflictContext(ourLabel: ourLabel, theirLabel: theirLabel, files: files)
    }

    /// Fetches a pull request with `account` from the repository pull
    /// requests are contributed to, the one the cache is for.
    static func pullRequestFetcher(
        account: Account,
        repository: GitHubRepository,
        runtime: GitHubRuntime
    ) -> @Sendable (Int) async -> ConflictContextPullRequest? {
        let api = API.fromAccount(account, runtime: runtime)
        let owner = repository.owner.login
        let name = repository.name
        return { number in
            do {
                let pullRequest = try await api.fetchPullRequest(owner: owner, name: name, prNumber: String(number))
                return ConflictContextPullRequest(number: number, title: pullRequest.title, body: pullRequest.body ?? "")
            } catch {
                // Best effort: pull requests that can't be fetched are skipped.
                logger.info("Could not fetch a pull request for conflict context")
                return nil
            }
        }
    }
}
