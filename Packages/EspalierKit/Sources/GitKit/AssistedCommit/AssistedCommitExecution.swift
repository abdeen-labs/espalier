// Ported from desktop/app/src/lib/git/assisted-commit/execute.ts
//
// - The final index keeps the original index's stat data for the entries
//   that didn't change (`read-tree -i -m`), so the next status doesn't read
//   every file again; an index git can't merge that way (a split index) is
//   made from the tree alone, as desktop makes it.
// - Local acceptance (`accept`) checks the result under HEAD's and the
//   branch's locks and then releases rollback; push preparation uses it
//   too, right before the push starts.

import Darwin
import EspalierSupport
import Foundation
import os

private let logger = Log.logger(category: "assisted-commit")

/// The hooks `git commit` runs that go through the hooks proxy.
private let assistedCommitInterceptedHooks = ["pre-commit", "prepare-commit-msg", "commit-msg", "post-commit", "pre-auto-gc"]

extension AssistedCommitSnapshot {
    /// Makes the validated plan's commits and puts them on the branch, one
    /// by one: each commit is made by `git commit` in the private index and
    /// branch (with the request's sign-off, hooks, and trailers), verified
    /// (its full SHA, parent, and tree), and published with a
    /// compare-and-swap of the branch, checked while git holds the branch's
    /// and HEAD's locks. The repository's index is locked throughout and is
    /// replaced by the selected changes' tree only after the last commit.
    /// The working tree is never written.
    ///
    /// Disposes the snapshot. On success the result keeps the ability to
    /// roll back until `AssistedCommitTransaction.accept` or `finalize`.
    ///
    /// - Throws: `AssistedCommitError` with `recovery`: every commit the run
    ///   put on the branch is taken off again and the index put back, unless
    ///   something else changed them, which recovery leaves alone
    ///   (`recoveryFailed`, with a retry). Codes: `cancelled`,
    ///   `hookAborted`, `commitFailed`, `selectionChanged`,
    ///   `repositoryChanged`, `indexChanged`; `invalidPlan` for a plan this
    ///   snapshot didn't validate; `busy` and `disposed`.
    public func execute(
        _ validated: ValidatedAssistedCommitPlan,
        options: AssistedCommitOptions = AssistedCommitOptions()
    ) async throws -> AssistedCommitTransaction {
        try await assistedShielded(options.cancellation) {
            try await self.executeUnshielded(validated, options)
        }
    }

    private func executeUnshielded(
        _ validated: ValidatedAssistedCommitPlan,
        _ options: AssistedCommitOptions
    ) async throws -> AssistedCommitTransaction {
        try requirePhase(.captured)
        guard JSCompat.strictEquals(validated.plan.snapshotID, id), let trees = validatedPlans[validated.token], trees == validated.trees else {
            throw AssistedCommitError(.invalidPlan, "The plan wasn't validated for these changes.")
        }
        phase = .executing
        let run = AssistedExecutionState(expectedTip: originalHead.sha)
        do {
            try await commitAll(validated.plan, trees, options, run)
            let transaction = AssistedCommitTransaction(
                snapshotID: id,
                identity: identity,
                files: files,
                commits: run.created,
                expectedTip: run.expectedTip,
                tree: selectedTree,
                installedIndex: run.installedIndex,
                isRetry: false
            )
            phase = .captured
            do {
                try dispose()
            } catch {
                // The commits stand; only the temporary files stay behind.
                logger.error("Couldn't remove an assisted commit's temporary files: \(error.localizedDescription, privacy: .public)")
            }
            return transaction
        } catch {
            let failure = AssistedCommitError.wrapping(error, .commitFailed, "The assisted commit failed.")
            var outcome = await assistedRecover(
                identity,
                files: files,
                created: run.created,
                published: run.expectedTip != originalHead.sha,
                installedIndex: run.installedIndex,
                heldLock: run.indexLock,
                options: options
            )
            phase = .captured
            do {
                try dispose()
            } catch {
                outcome.errors.append(error)
            }
            let retry = outcome.errors.isEmpty ? nil : AssistedCommitTransaction(
                snapshotID: id,
                identity: identity,
                files: files,
                commits: run.created,
                expectedTip: outcome.observedHead?.sha,
                tree: selectedTree,
                installedIndex: run.installedIndex,
                isRetry: true
            )
            let recovery = outcome.recovery(created: run.created, retry: retry)
            if recovery.needsAttention {
                throw AssistedCommitError(
                    .recoveryFailed,
                    "The assisted commit stopped, and Espalier couldn't undo all of it: something else changed the branch or the index.",
                    underlying: failure,
                    recovery: recovery
                )
            }
            throw failure.with(recovery: recovery)
        }
    }

    private func commitAll(
        _ plan: AssistedCommitPlan,
        _ trees: [String],
        _ options: AssistedCommitOptions,
        _ run: AssistedExecutionState
    ) async throws {
        let identity = identity
        let files = files
        let root = identity.root
        let cancellation = options.cancellation
        let privateRepository = privateRepository

        try cancellation.check()
        try await assistedVerifyHead(identity, run.expectedTip)
        try assistedVerifyIndex(identity)
        try assistedVerifySelectedFiles(root, files)
        try await assistedEnsureNoRepositoryOperation(identity)

        var messages: [String] = []
        for commit in plan.commits {
            try cancellation.check()
            messages.append(try await formatCommitMessage(
                identity.repository,
                CommitContext(summary: commit.title, description: commit.description, trailers: request.trailers)
            ))
        }

        try cancellation.check()
        run.indexLock = try AssistedLockFile.acquire(
            identity.indexPath + ".lock",
            mode: identity.originalIndex.bytes == nil ? 0o644 : identity.originalIndex.mode
        )
        try assistedVerifyIndex(identity)

        let isEmptyCommit = analysis.changes.isEmpty
        let total = plan.commits.count
        for (index, commit) in plan.commits.enumerated() {
            let tree = trees[index]
            await options.report(.committing(index: index, total: total, title: commit.title))
            try cancellation.check()
            try await assistedVerifyHead(identity, run.expectedTip)
            try assistedVerifyIndex(identity)
            try assistedVerifySelectedFiles(root, files)
            try await assistedEnsureNoRepositoryOperation(identity)
            guard try await privateRepository.tip() == run.expectedTip else {
                throw AssistedCommitError(.commitFailed, "The assisted commit's private branch moved.")
            }
            try await privateRepository.readTree(tree, into: privateRepository.indexPath)
            try cancellation.check()

            var args = ["commit", "-F", "-"]
            if request.skipHooks {
                args.append("--no-verify")
            }
            if request.signOff {
                args.append("--signoff")
            }
            if isEmptyCommit {
                args.append("--allow-empty")
            }
            let hookAborted = AssistedFlag()
            let onHookFailure: (@Sendable (String, TerminalOutput) async -> HookFailureResolution)? = options.onHookFailure.map { ask in
                { @Sendable hookName, terminalOutput in
                    // Ignoring continues this commit only; a cancelled run
                    // never continues.
                    if cancellation.isCancelled {
                        hookAborted.set()
                        return .abort
                    }
                    let resolution = await ask(hookName, terminalOutput)
                    if resolution == .abort || cancellation.isCancelled {
                        hookAborted.set()
                        return .abort
                    }
                    return .ignore
                }
            }
            var commitError: (any Error)?
            do {
                try await git(
                    args,
                    root,
                    "assistedCommitCreateCommit",
                    options: GitExecutionOptions(
                        env: privateRepository.environment,
                        stdin: Data(messages[index].utf8),
                        interceptHooks: assistedCommitInterceptedHooks,
                        onHookProgress: options.onHookProgress,
                        onHookFailure: onHookFailure,
                        onTerminalOutputAvailable: options.onTerminalOutputAvailable
                    )
                )
            } catch {
                commitError = error
            }

            // Even a failed commit can have moved the private branch: what
            // it points at now is the outcome, not what git printed.
            let sha = try await privateRepository.tip()
            if let sha, sha != run.expectedTip {
                try await verifyCreatedCommit(sha, parent: run.expectedTip, tree: tree)
                run.created.append(sha)
            }
            try cancellation.check()
            guard commitError == nil, let sha, sha != run.expectedTip else {
                if hookAborted.isSet {
                    throw AssistedCommitError(.hookAborted, "A hook failed, and the assisted commit stopped.", underlying: commitError)
                }
                throw AssistedCommitError(
                    .commitFailed,
                    "Git couldn't make the commit \u{201C}\(commit.title)\u{201D}.",
                    underlying: commitError
                )
            }

            try assistedVerifySelectedFiles(root, files)
            try assistedVerifyIndex(identity)
            let previousTip = run.expectedTip
            let reason = previousTip == nil ? "commit (initial): \(commit.title)" : "commit: \(commit.title)"
            do {
                try await assistedUpdateRef(
                    root,
                    ref: identity.updatedRef,
                    oldValue: previousTip ?? identity.zeroID,
                    newValue: sha,
                    reason: reason
                ) {
                    try await assistedVerifyHead(identity, previousTip)
                    try assistedVerifyIndex(identity)
                    try assistedVerifySelectedFiles(root, files)
                    try cancellation.check()
                }
                run.expectedTip = sha
            } catch {
                // The update may have happened anyway.
                if let observed = try? await assistedReadHead(root, gitDirectory: identity.gitDirectory),
                   observed.ref == identity.originalHead.ref, observed.sha == sha
                {
                    run.expectedTip = sha
                }
                throw error
            }
            try await assistedVerifyHead(identity, run.expectedTip)
            try assistedVerifyIndex(identity)
            try assistedVerifySelectedFiles(root, files)
            await options.report(.committed(index: index, total: total, sha: sha))
            try cancellation.check()
        }

        // The index becomes the selected changes' tree, as an ordinary commit
        // leaves it: other staged changes are cleared.
        let finalIndexPath = POSIXPath.join(privateRepository.directory, "final-index")
        let finalEnv: [String: String?] = ["GIT_INDEX_FILE": finalIndexPath]
        var merged = false
        if let original = identity.originalIndex.bytes {
            try assistedWriteNewFile(finalIndexPath, original)
            do {
                try await privateRepository.run(
                    privateRepository.noHooks + ["read-tree", "-i", "-m", selectedTree],
                    "assistedCommitFinalIndex",
                    env: finalEnv
                )
                merged = true
            } catch {
                _ = unlink(finalIndexPath)
            }
        }
        if !merged {
            try await privateRepository.readTree(selectedTree, into: finalIndexPath)
        }
        let finalTree = try await privateRepository.run(privateRepository.noHooks + ["write-tree"], "assistedCommitCheckFinalIndex", env: finalEnv)
        guard assistedTrimLine(finalTree.stdout) == selectedTree else {
            throw AssistedCommitError(.commitFailed, "The final index doesn't match the selected changes.")
        }
        guard let finalBytes = try assistedReadFile(finalIndexPath), let lock = run.indexLock else {
            throw AssistedCommitError(.commitFailed, "Espalier couldn't read the final index.")
        }
        try await assistedVerifyHead(identity, run.expectedTip)
        try assistedVerifySelectedFiles(root, files)
        try cancellation.check()

        let installed = AssistedIndexState(
            bytes: finalBytes,
            mode: identity.originalIndex.bytes == nil ? 0o644 : identity.originalIndex.mode,
            times: nil
        )
        run.installedIndex = installed
        let tip = run.expectedTip
        try await assistedWithRefLock(identity, expectedValue: tip) {
            try await assistedVerifyHead(identity, tip)
            try assistedVerifySelectedFiles(root, files)
            try cancellation.check()
            try lock.commit(finalBytes, mode: installed.mode, times: nil, to: identity.indexPath) {
                try assistedVerifyIndex(identity)
            }
        }
        try await assistedVerifyHead(identity, run.expectedTip)
        try assistedVerifyIndex(identity, installed)
        try assistedVerifySelectedFiles(root, files)
        try cancellation.check()
        try lock.release()
        run.indexLock = nil
    }

    /// Throws `commitFailed` unless commit `sha` (made by git or a hook) has
    /// exactly `parent` and `tree`, a title, and left the private index at
    /// `tree`.
    private func verifyCreatedCommit(_ sha: String, parent: String?, tree: String) async throws {
        let unexpected = AssistedCommitError(.commitFailed, "Git or a hook made a commit other than the one planned.")
        guard assistedIsFullObjectID(sha) else {
            throw unexpected
        }
        let object = try await privateRepository.run(["cat-file", "commit", sha], "assistedCommitVerifyCommit")
        let text = object.stdout
        guard let separator = text.range(of: "\n\n") else {
            throw unexpected
        }
        let header = text[..<separator.lowerBound].split(separator: "\n", omittingEmptySubsequences: false)
        let message = text[separator.upperBound...]
        guard header.first.map({ $0 == "tree \(tree)" }) == true else {
            throw unexpected
        }
        // Git reads the parents right after the tree, one header each.
        var parents: [String] = []
        var cursor = 1
        while cursor < header.count, header[cursor].hasPrefix("parent ") {
            parents.append(String(header[cursor].dropFirst("parent ".count)))
            cursor += 1
        }
        guard parents == (parent.map { [$0] } ?? []),
              !header[cursor...].contains(where: { $0.hasPrefix("parent ") }),
              let title = message.split(separator: "\n", omittingEmptySubsequences: false).first,
              !title.unicodeScalars.allSatisfy(JSCompat.isWhitespace)
        else {
            throw unexpected
        }
        let indexTree = try await privateRepository.run(privateRepository.noHooks + ["write-tree"], "assistedCommitVerifyHookIndex")
        guard assistedTrimLine(indexTree.stdout) == tree else {
            throw AssistedCommitError(.commitFailed, "A hook staged changes that weren't planned.")
        }
    }
}

/// What a run has done so far, for recovery.
private final class AssistedExecutionState {
    var expectedTip: String?
    var created: [String] = []
    var indexLock: AssistedLockFile?
    var installedIndex: AssistedIndexState?

    init(expectedTip: String?) {
        self.expectedTip = expectedTip
    }
}

/// What recovery did.
struct AssistedRecoveryOutcome: Sendable {
    var history: AssistedCommitRecovery.Outcome = .unchanged
    var index: AssistedCommitRecovery.Outcome = .unchanged
    var observedHead: AssistedCommitHead?
    var errors: [any Error] = []

    func recovery(created: [String], retry: AssistedCommitTransaction?) -> AssistedCommitRecovery {
        AssistedCommitRecovery(
            createdCommits: created,
            observedHead: observedHead,
            history: history,
            index: index,
            errors: errors,
            retry: retry
        )
    }
}

/// Undoes a run: takes the run's commits off the branch, and puts the index
/// back while it holds what the run installed. Only what the run owns is
/// undone: a branch at a commit the run didn't make, or an index something
/// else wrote, is left as it is, as an error. Never resets, checks out, or
/// writes the working tree.
func assistedRecover(
    _ identity: AssistedRepositoryIdentity,
    files: [AssistedFrozenFile],
    created: [String],
    published: Bool,
    installedIndex: AssistedIndexState?,
    heldLock: AssistedLockFile?,
    options: AssistedCommitOptions
) async -> AssistedRecoveryOutcome {
    var outcome = AssistedRecoveryOutcome()
    await options.report(.rollingBack)
    let original = identity.originalHead
    let root = identity.root
    let createdSet = Set(created)

    // History. A branch at one of the run's commits is the run's, even
    // when the update that put it there seemed to fail.
    do {
        let observed = try await assistedReadHead(root, gitDirectory: identity.gitDirectory)
        if observed.ref == original.ref, observed.sha == original.sha {
            outcome.history = .unchanged
        } else if observed.ref == original.ref, let tip = observed.sha, createdSet.contains(tip) {
            try await assistedUpdateRef(
                root,
                ref: identity.updatedRef,
                oldValue: tip,
                newValue: original.sha,
                reason: "rollback: assisted commit stopped"
            ) {
                try await assistedVerifyHead(identity, tip)
            }
            try await assistedVerifyHead(identity, original.sha)
            outcome.history = .restored
        } else if published {
            outcome.history = .interfered
            outcome.errors.append(AssistedCommitError(
                .repositoryChanged,
                "The branch moved to a commit the assisted commit didn't make, so it was left as it is."
            ))
        }
        // Otherwise nothing of the run's is on the branch: whatever moved it
        // isn't the run's to undo.
    } catch {
        if published {
            outcome.errors.append(error)
            if (try? await assistedVerifyHead(identity, original.sha)) != nil {
                outcome.history = .restored
            } else {
                outcome.history = .interfered
            }
        }
    }

    // The index.
    var recoveryLock: AssistedLockFile?
    var attempted = false
    do {
        let current = try assistedReadIndexState(identity.indexPath)
        if !current.matches(identity.originalIndex) {
            if outcome.history == .interfered {
                outcome.index = .interfered
                outcome.errors.append(AssistedCommitError(
                    .indexChanged,
                    "The index wasn't restored because the branch isn't where the assisted commit left it."
                ))
            } else if let installedIndex, current.matches(installedIndex) {
                let lock: AssistedLockFile
                if let heldLock, !heldLock.isConsumed, !heldLock.isReleased {
                    lock = heldLock
                } else {
                    lock = try AssistedLockFile.acquire(identity.indexPath + ".lock", mode: identity.originalIndex.mode)
                    recoveryLock = lock
                }
                attempted = true
                let originalIndex = identity.originalIndex
                try await assistedWithRefLock(identity, expectedValue: original.sha) {
                    try await assistedVerifyHead(identity, original.sha)
                    if let bytes = originalIndex.bytes {
                        try lock.commit(bytes, mode: originalIndex.mode, times: originalIndex.times, to: identity.indexPath) {
                            try assistedVerifyIndex(identity, installedIndex)
                        }
                    } else {
                        try assistedVerifyIndex(identity, installedIndex)
                        guard unlink(identity.indexPath) == 0 || errno == ENOENT else {
                            throw assistedPOSIXError()
                        }
                    }
                }
                outcome.index = .restored
            } else if installedIndex != nil {
                outcome.index = .interfered
                outcome.errors.append(AssistedCommitError(
                    .indexChanged,
                    "Something else changed the index, so the assisted commit left it as it is."
                ))
            }
            // Otherwise the run never wrote the index (it's recorded before
            // the write): whatever changed it isn't the run's to undo.
        }
    } catch {
        outcome.errors.append(error)
        if let current = try? assistedReadIndexState(identity.indexPath), current.matches(identity.originalIndex) {
            outcome.index = attempted ? .restored : .unchanged
        } else {
            outcome.index = .interfered
        }
    }
    for lock in [heldLock, recoveryLock].compactMap({ $0 }) {
        do {
            try lock.release()
        } catch {
            outcome.errors.append(error)
        }
    }
    outcome.observedHead = try? await assistedReadHead(root, gitDirectory: identity.gitDirectory)
    return outcome
}

/// A finished run's commits, which can still be rolled back until they're
/// accepted (`accept`, `finalize`); or, from a failed run's recovery, the
/// recovery to try again (`AssistedCommitRecovery.retry`).
public actor AssistedCommitTransaction {
    public nonisolated let snapshotID: String
    /// The commits the run made, in order.
    public nonisolated let commits: [String]
    /// The branch and its tip after the run.
    public nonisolated let head: AssistedCommitHead
    /// HEAD before the run.
    public nonisolated let originalHead: AssistedCommitHead
    /// The final tree: the selected changes.
    public nonisolated let tree: String

    private let identity: AssistedRepositoryIdentity
    private let files: [AssistedFrozenFile]
    private let installedIndex: AssistedIndexState?
    private let isRetry: Bool

    private enum State {
        case retained
        case working
        case finished
    }

    private var state = State.retained

    init(
        snapshotID: String,
        identity: AssistedRepositoryIdentity,
        files: [AssistedFrozenFile],
        commits: [String],
        expectedTip: String?,
        tree: String,
        installedIndex: AssistedIndexState?,
        isRetry: Bool
    ) {
        self.snapshotID = snapshotID
        self.identity = identity
        self.files = files
        self.commits = commits
        self.head = AssistedCommitHead(ref: identity.originalHead.ref, sha: expectedTip)
        self.originalHead = identity.originalHead
        self.tree = tree
        self.installedIndex = installedIndex
        self.isRetry = isRetry
    }

    /// Whether the commits were accepted or rolled back.
    public var isFinished: Bool {
        state == .finished
    }

    /// Checks the result still stands after the caller's own awaits: the
    /// selected files, HEAD and its tip, and the installed index.
    ///
    /// - Throws: `selectionChanged`, `repositoryChanged`, `indexChanged`,
    ///   `unsafeSelection` (git started a merge or rebase), `cancelled`;
    ///   `disposed` once finished.
    public func verify(cancellation: AssistedCommitCancellation = AssistedCommitCancellation()) async throws {
        try requireRetained()
        try cancellation.check()
        try await check(cancellation)
    }

    /// Accepts the commits: checks them under HEAD's and the branch's locks
    /// (the selected files, the tip, the installed index), then gives up
    /// rolling back. Call it right before the run reports success, or right
    /// before a push starts.
    public func accept(cancellation: AssistedCommitCancellation = AssistedCommitCancellation()) async throws {
        try requireRetained()
        guard !isRetry else {
            throw AssistedCommitError(.disposed, "A failed assisted commit can't be accepted.")
        }
        state = .working
        do {
            let identity = identity
            let files = files
            let installedIndex = installedIndex
            let tip = head.sha
            try await assistedWithRefLock(identity, expectedValue: tip) {
                try await assistedEnsureNoRepositoryOperation(identity)
                try await assistedVerifyHead(identity, tip)
                try assistedVerifyIndex(identity, installedIndex)
                try assistedVerifySelectedFiles(identity.root, files)
                try cancellation.check()
            }
            state = .finished
        } catch {
            state = .retained
            throw error
        }
    }

    /// Gives up rolling back, without any check.
    public func finalize() throws {
        guard state != .working else {
            throw AssistedCommitError(.busy, "The assisted commit is still being checked or rolled back.")
        }
        state = .finished
    }

    /// Takes the run's commits off the branch and puts the index back, while
    /// they're the run's. Leaves the working tree as it is.
    ///
    /// - Returns: What recovery did.
    /// - Throws: `recoveryFailed` with `recovery` when something else
    ///   changed the branch or index (try again once it's resolved);
    ///   `busy`; `disposed` once finished.
    @discardableResult
    public func rollback(options: AssistedCommitOptions = AssistedCommitOptions()) async throws -> AssistedCommitRecovery {
        try requireRetained()
        state = .working
        let identity = identity
        let files = files
        let commits = commits
        let installedIndex = installedIndex
        let outcome = await Task {
            await assistedRecover(
                identity,
                files: files,
                created: commits,
                published: true,
                installedIndex: installedIndex,
                heldLock: nil,
                options: options
            )
        }.value
        let recovery = outcome.recovery(created: commits, retry: outcome.errors.isEmpty ? nil : self)
        if recovery.needsAttention {
            state = .retained
            throw AssistedCommitError(
                .recoveryFailed,
                "Espalier couldn't undo all of the assisted commit: something else changed the branch or the index.",
                recovery: recovery
            )
        }
        state = .finished
        return recovery
    }

    private func requireRetained() throws {
        switch state {
        case .retained:
            return
        case .working:
            throw AssistedCommitError(.busy, "The assisted commit is still being checked or rolled back.")
        case .finished:
            throw AssistedCommitError(.disposed, "The assisted commit was already accepted or rolled back.")
        }
    }

    private func check(_ cancellation: AssistedCommitCancellation) async throws {
        try assistedVerifySelectedFiles(identity.root, files)
        try await assistedEnsureNoRepositoryOperation(identity)
        try await assistedVerifyHead(identity, head.sha)
        try assistedVerifyIndex(identity, installedIndex)
        try cancellation.check()
    }
}
