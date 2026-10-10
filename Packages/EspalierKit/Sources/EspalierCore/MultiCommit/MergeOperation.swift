import EspalierSupport
import Foundation
import GitKit
import os

private let logger = Log.logger(category: "merge")

/// Merges the branch again with the same options.
public struct MergeRetry: RetryableOperation {
    public let repositoryID: RepositoryID
    public let branch: Branch
    public let squash: Bool

    public init(repositoryID: RepositoryID, branch: Branch, squash: Bool) {
        self.repositoryID = repositoryID
        self.branch = branch
        self.squash = squash
    }

    public var kind: OperationKind {
        .merge
    }

    public var displayName: String? {
        branch.name
    }

    @discardableResult
    @MainActor
    public func perform(in app: AppModel) async throws(OperationError) -> OperationOutcome {
        let outcome = try await app.requireRepository(repositoryID, for: kind).operations.merge(branch, squash: squash)
        return .merge(outcome, repositoryID: repositoryID)
    }
}

extension MultiCommitOperationsModel {
    /// Merges `branch` into the current branch, or squash merges it.
    ///
    /// The merge's hooks are intercepted (a failing hook asks whether to abort;
    /// aborting surfaces as `cancelled(.hookAborted)`), a squash merge commits
    /// at once with git's message, and the repository is refreshed before this
    /// returns. Conflicts aren't an error: the merge returns `.conflicted` with
    /// `conflictState` set, and `continueOperation()` or `abortOperation()`
    /// ends it.
    ///
    /// - Returns: `.merged` or `.alreadyUpToDate` with the banner copy in
    ///   `summary`; `.conflicted`.
    /// - Throws: `.precondition` while another operation waits on its
    ///   conflicts, or when HEAD isn't on a branch;
    ///   `.localChangesOverwritten` with "Stash Changes and Continue" when
    ///   local changes are in the way; `cancelled(.hookAborted)` (git leaves
    ///   the merge in progress, so it can be continued or aborted); git's
    ///   other errors.
    public func merge(_ branch: Branch, squash: Bool = false) async throws(OperationError) -> MergeOutcome {
        guard let repository else {
            throw OperationError(.precondition("The repository is no longer in the list."), operation: .merge)
        }
        try requireNoOperationInProgress(.merge)
        guard let currentBranch = repository.gitState.tip.branch else {
            throw OperationError(
                .precondition("You need to be on a branch to merge."),
                operation: .merge,
                repositoryID: repository.id
            )
        }

        let descriptor = OperationDescriptor(
            kind: .merge,
            gitContext: .merge(currentBranch: currentBranch.name, theirBranch: branch.name),
            retry: MergeRetry(repositoryID: repository.id, branch: branch, squash: squash)
        )
        let result: MergeResult
        do {
            result = try await repository.perform(descriptor) { ctx in
                // Set while the lane is held, so no status pass sees the
                // operation before git ran, and only while git has nothing
                // in progress (started since the last refresh): git refuses
                // then, and the operation in progress keeps its state.
                if !(await hasOperationInProgress(ctx.repository)) {
                    self.current = MultiCommitOperation(
                        kind: .merge,
                        detail: .merge(sourceBranch: branch, isSquash: squash),
                        phase: .running(MultiCommitOperationProgress(
                            value: 0,
                            currentCommitSummary: "",
                            position: 1,
                            totalCommitCount: 0
                        )),
                        originalBranchTip: currentBranch.tip.sha,
                        targetBranch: currentBranch,
                        origin: .espalier
                    )
                }
                return try await GitKit.merge(ctx.repository, branch.name, MergeOptions(
                    squash: squash,
                    onHookProgress: ctx.hooks.onHookProgress,
                    onHookFailure: ctx.hooks.onHookFailure,
                    onTerminalOutputAvailable: ctx.hooks.onTerminalOutputAvailable
                ))
            }
        } catch {
            // The refresh ends the operation, unless git left the merge in
            // progress (a hook failed while committing it): then it's
            // waiting to be continued or aborted, still knowing its branch.
            await repository.awaitOperationRefresh(covering: .full)
            throw error
        }

        switch result {
        case .success:
            endOperation()
            await repository.awaitOperationRefresh(covering: .full)
            return .merged(ours: currentBranch.name, theirs: branch.name)
        case .alreadyUpToDate:
            endOperation()
            await repository.awaitOperationRefresh(covering: .full)
            return .alreadyUpToDate(ours: currentBranch.name, theirs: branch.name)
        case .failed:
            // The status pass finds the conflicts and stops the operation on
            // them.
            await repository.awaitOperationRefresh(covering: .full)
            return .conflicted
        }
    }

    /// Commits a merge whose conflicts are resolved: stages the conflicted
    /// files, applying the manual resolutions, and commits
    /// (`createMergeCommit`), intercepting the commit hooks as a commit does.
    ///
    /// The message is `mergeMessage`: git's own (`--no-edit`, its comments
    /// stripped) while it's unchanged or not loaded, otherwise the user's,
    /// formatted as a commit's.
    ///
    /// The conflicted files and their markers come from a fresh status, so a
    /// file still holding conflict markers is never committed (the check
    /// `continueOperation()` makes on the last refresh could be stale). A file
    /// the user chose a side for and then edited by hand keeps the edits.
    /// Success clears the commit message.
    ///
    /// - Throws: `.precondition("Enter a summary to commit")`
    ///   when the user emptied the summary, among the errors
    ///   `continueOperation()` lists.
    func finishMerge() async throws(OperationError) -> MergeOutcome {
        guard let repository else {
            throw OperationError(.precondition("The repository is no longer in the list."), operation: .finishMerge)
        }
        guard case .merge(let ours, _, let resolutions)? = conflictState else {
            throw OperationError(
                .precondition("There's no merge to finish."),
                operation: .finishMerge,
                repositoryID: repository.id
            )
        }
        let theirs = conflictBranches?.theirs
        let id = repository.id
        // The user's message, unless it's git's as loaded.
        let userMessage = mergeMessage.flatMap { $0 == defaultMergeMessage ? nil : $0 }
        if let userMessage, isEmptyOrWhitespace(userMessage.summary) {
            throw OperationError(.precondition("Enter a summary to commit"), operation: .finishMerge, repositoryID: id)
        }

        do {
            try await repository.perform(OperationDescriptor(kind: .finishMerge)) { ctx in
                self.setPhase(.continuing(MultiCommitOperationProgress(
                    value: 0,
                    currentCommitSummary: "",
                    position: 1,
                    totalCommitCount: 0
                )))
                let (status, conflictedFiles) = try await self.resolvedConflictedFiles(resolutions, operation: .finishMerge, in: ctx)
                guard status.mergeHeadFound || (status.squashMsgFound && status.doConflictedFilesExist) else {
                    throw OperationError(.precondition("There's no merge to finish."), operation: .finishMerge, repositoryID: id)
                }

                let message: String? = if let userMessage {
                    try await formatCommitMessage(
                        ctx.repository,
                        CommitContext(summary: userMessage.summary, description: userMessage.description)
                    )
                } else {
                    nil
                }

                // The assumption made here is that all other files that were
                // part of this merge have already been staged by git (or by
                // the user): git stages everything that merged cleanly, so
                // only the conflicted files need staging.
                try await createMergeCommit(
                    ctx.repository,
                    conflictedFiles,
                    effectiveManualResolutions(resolutions, files: conflictedFiles),
                    CreateMergeCommitOptions(
                        message: message,
                        onHookProgress: ctx.hooks.onHookProgress,
                        onHookFailure: ctx.hooks.onHookFailure,
                        onTerminalOutputAvailable: ctx.hooks.onTerminalOutputAvailable
                    )
                )
            }
        } catch {
            // The refresh puts the merge back to waiting on its conflicts.
            await repository.awaitOperationRefresh(covering: .full)
            throw error
        }

        // The refresh finds no merge in progress and ends the operation.
        repository.commit.draft.summary = ""
        repository.commit.draft.description = ""
        repository.commit.draft.generatedByAI = false
        await repository.awaitOperationRefresh(covering: .full)
        return .merged(ours: ours, theirs: theirs)
    }

    /// Aborts the merge in progress, deciding from git's state at the time:
    ///
    /// - `MERGE_HEAD`: `git merge --abort`, whatever `SQUASH_MSG` a squash
    ///   merge left behind.
    /// - No `MERGE_HEAD`, `SQUASH_MSG`, and conflicted files: a squash merge,
    ///   aborted with `git reset --merge`, which is what `git merge --abort`
    ///   runs for a merge. It keeps the local changes the merge didn't touch
    ///   and runs no commit hooks. When the user changed a file the merge
    ///   staged, git refuses rather than discard the change.
    func abortMergeOperation() async throws(OperationError) {
        guard let repository else {
            throw OperationError(.precondition("The repository is no longer in the list."), operation: .abortMerge)
        }
        let id = repository.id
        try await repository.perform(OperationDescriptor(kind: .abortMerge)) { ctx in
            if await isMergeHeadSet(ctx.repository) {
                try await abortMerge(ctx.repository)
                return
            }
            if await isSquashMsgSet(ctx.repository),
               let status = try await getStatus(ctx.repository), status.doConflictedFilesExist {
                try await abortSquashMerge(ctx.repository)
                return
            }
            throw OperationError(
                .precondition("There's no merge to abort."),
                operation: .abortMerge,
                repositoryID: id
            )
        }
        // The refresh finds no merge in progress and ends the operation.
        await repository.awaitOperationRefresh(covering: .full)
    }

    /// The operation ended: nothing is in progress any more.
    private func endOperation() {
        if current != nil {
            current = nil
        }
    }
}

/// A merge commit's message as the user edits it: a summary and a
/// description, as a commit's.
public struct MergeMessage: Sendable, Equatable {
    public var summary: String
    public var description: String

    public init(summary: String = "", description: String = "") {
        self.summary = summary
        self.description = description
    }

    /// `message` split as git splits a commit's message (`%s` and `%b`),
    /// which is how the commit form shows a commit's message: the
    /// first paragraph, its lines joined by spaces, is the summary; what
    /// follows the blank lines after it is the description (without its
    /// final line break).
    public init(splitting message: String) {
        // pretty.c: `skip_blank_lines`, `format_subject`, then the body.
        let lines = message.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        var index = 0
        while index < lines.count, isBlankLine(lines[index]) {
            index += 1
        }
        var subject: [String] = []
        while index < lines.count, !isBlankLine(lines[index]) {
            subject.append(trimmingTrailingSpace(lines[index]))
            index += 1
        }
        while index < lines.count, isBlankLine(lines[index]) {
            index += 1
        }
        var body = lines[index...].joined(separator: "\n")
        while body.hasSuffix("\n") {
            body.removeLast()
        }
        self.init(summary: subject.joined(separator: " "), description: body)
    }
}

/// Whether a line is empty or only C `isspace` characters (git's
/// `is_blank_line`).
private func isBlankLine(_ line: String) -> Bool {
    line.unicodeScalars.allSatisfy(isCSpace)
}

/// `line` without the C `isspace` characters at its end.
private func trimmingTrailingSpace(_ line: String) -> String {
    var scalars = Substring(line).unicodeScalars
    while let last = scalars.last, isCSpace(last) {
        scalars.removeLast()
    }
    return String(scalars)
}

private func isCSpace(_ scalar: Unicode.Scalar) -> Bool {
    switch scalar {
    case " ", "\t", "\n", "\u{0B}", "\u{0C}", "\r": true
    default: false
    }
}

/// The message `git commit` concludes the merge in progress with when it's
/// given none (builtin/commit.c `prepare_to_commit`): `SQUASH_MSG`, then
/// `MERGE_MSG`, either of which may be missing, cleaned up as
/// `--cleanup=strip` cleans it (`git stripspace --strip-comments`, with the
/// repository's comment character). Nil when there's neither file.
@concurrent
func getMergeCommitMessage(_ repository: Repository) async throws -> String? {
    let gitDir = repository.resolvedGitDir
    let squashMessage = FileManager.default.contents(atPath: POSIXPath.join(gitDir, "SQUASH_MSG"))
    let mergeMessage = FileManager.default.contents(atPath: POSIXPath.join(gitDir, "MERGE_MSG"))
    guard squashMessage != nil || mergeMessage != nil else {
        return nil
    }
    let result = try await git(
        ["stripspace", "--strip-comments"],
        repository.path,
        "getMergeCommitMessage",
        options: GitExecutionOptions(stdin: (squashMessage ?? Data()) + (mergeMessage ?? Data()))
    )
    return result.stdout
}

/// Aborts a conflicted squash merge, which has no `MERGE_HEAD` for
/// `git merge --abort` to use: `git reset --merge`, which resets what the
/// merge staged and the conflicted files, keeps local changes the merge
/// didn't touch, and removes the merge state (`SQUASH_MSG`, `MERGE_MSG`).
func abortSquashMerge(_ repository: Repository) async throws {
    try await git(["reset", "--merge"], repository.path, "abortSquashMerge")

    // git removes SQUASH_MSG with the rest of the merge state; a leftover
    // one would make the next regular merge look like a squash merge.
    let squashMessage = POSIXPath.join(repository.resolvedGitDir, "SQUASH_MSG")
    if FileManager.default.fileExists(atPath: squashMessage) {
        do {
            try FileManager.default.removeItem(atPath: squashMessage)
        } catch {
            logger.error("Could not remove SQUASH_MSG after aborting a squash merge: \(error.localizedDescription, privacy: .public)")
        }
    }
}
