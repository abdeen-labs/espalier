// Ported from desktop/app/src/lib/git/squash.ts

import EspalierSupport
import Foundation
import os

private let logger = Log.logger(category: "squash")

/// Squashes provided commits by calling interactive rebase.
///
/// Goal is to replay the commits in order from oldest to newest to reduce
/// conflicts with toSquash commits placed in the log at the location of the
/// squashOnto commit.
///
/// Example: A user's history from oldest to newest is A, B, C, D, E and they
/// want to squash A and E (toSquash) onto C. Our goal:  B, A-C-E, D. Thus,
/// maintaining that A came before C and E came after C, placed in history at the
/// the squashOnto of C.
///
/// Also means if the last 2 commits in history are A, B, whether user squashes A
/// onto B or B onto A. It will always perform based on log history, thus, B onto
/// A.
///
/// The squashed commits are replayed with `fixup`, followed by `fixup -C`
/// naming a commit made only to carry the message (it has no changes of its
/// own). The message is cleaned up the way `git commit -F` cleans one, no
/// editor runs, and it survives conflicts without being passed again. An
/// editor replacing the message git proposes would have it cleaned as an
/// edited message, which drops lines that start with `#`: a summary like
/// "#42 Fix the crash" would be lost, and a message made only of such lines
/// would stop the rebase halfway ("Aborting commit due to empty commit
/// message").
///
/// Only the checks of the arguments return `.error`. Git's errors (a failing
/// hook, a commit signing failure, a squash whose changes cancel out) are
/// thrown, after aborting a rebase this call started and git stopped, so the
/// repository is as it was.
///
/// - Parameters:
///   - toSquash: commits to squash onto another commit and does not contain the squashOnto commit
///   - squashOnto: commit to squash the `toSquash` commits onto
///   - lastRetainedCommitRef: sha of commit before commits in squash or nil
///     if commit to be squash is the root (first in history) of the branch
///   - commitMessage: the first line of the string provided will be the
///     summary and rest the body (similar to commit implementation). When
///     blank, the messages of the squashed commits, in the order they're
///     replayed and separated by blank lines.
///   - progressCallback: Called with the progress of the rebase, off the main
///     thread, one call at a time, all before this returns.
public func squash(
    _ repository: Repository,
    _ toSquash: [Commit],
    _ squashOnto: Commit,
    _ lastRetainedCommitRef: String?,
    _ commitMessage: String,
    progressCallback: (@Sendable (MultiCommitOperationProgress) -> Void)? = nil
) async throws -> RebaseResult {
    try await squash(
        repository,
        toSquash,
        squashOnto,
        lastRetainedCommitRef,
        commitMessage,
        progressCallback: progressCallback,
        todoPath: getTempFilePath("squashTodo")
    )
}

/// `squash`, writing its todo list to `todoPath`, which must not exist. The
/// file is removed before this returns or throws.
func squash(
    _ repository: Repository,
    _ toSquash: [Commit],
    _ squashOnto: Commit,
    _ lastRetainedCommitRef: String?,
    _ commitMessage: String,
    progressCallback: (@Sendable (MultiCommitOperationProgress) -> Void)?,
    todoPath: String
) async throws -> RebaseResult {
    let chain: SquashTodo
    do {
        chain = try await planSquash(repository, toSquash, squashOnto, lastRetainedCommitRef)
    } catch let error as GitLibError {
        logger.error("\(error.message, privacy: .public)")
        return .error
    }

    let messageCommit = try await createSquashMessageCommit(
        repository,
        message: JSCompat.trim(commitMessage).isEmpty ? .combined(chain.squashed) : .provided(commitMessage)
    )

    let steps = chain.steps(messageCommit: messageCommit)

    try writeRebaseTemporaryFile(todoPath, steps.map(\.todoLine).joined())
    defer {
        unlink(todoPath)
    }

    return try await runRebaseTodo(
        repository,
        todoPath,
        lastRetainedCommitRef,
        action: MultiCommitOperationKind.squash,
        steps: steps,
        progressCallback: progressCallback
    )
}

/// The todo list of a squash, without the step that applies the message.
private struct SquashTodo {
    /// The picks before the squashed commit.
    var before: [Commit] = []
    /// The commits squashed together, in the order they're replayed: the
    /// first is picked, the others are fixups.
    var squashed: [Commit] = []
    /// The picks after the squashed commit.
    var after: [Commit] = []

    func steps(messageCommit: String) -> [RebaseTodoStep] {
        before.map { RebaseTodoStep(.pick, $0) }
            + squashed.enumerated().map { RebaseTodoStep($0.offset == 0 ? .pick : .fixup, $0.element) }
            + [RebaseTodoStep.message(messageCommit)]
            + after.map { RebaseTodoStep(.pick, $0) }
    }
}

/// The checks of the arguments and the walk through the log, which puts the
/// squashed commits together at the place of `squashOnto`. Throws
/// `GitLibError` where the checks fail.
private func planSquash(
    _ repository: Repository,
    _ toSquash: [Commit],
    _ squashOnto: Commit,
    _ lastRetainedCommitRef: String?
) async throws -> SquashTodo {
    if toSquash.isEmpty {
        throw GitLibError("[squash] No commits provided to squash.")
    }

    let toSquashShas = Set(toSquash.map(\.sha))
    if toSquashShas.contains(squashOnto.sha) {
        throw GitLibError("[squash] The commits to squash cannot contain the commit to squash onto.")
    }

    let commits = try await getCommits(
        repository,
        lastRetainedCommitRef.map { revRange($0, "HEAD") }
    )

    if commits.isEmpty {
        throw GitLibError("[squash] Could not find commits in log for last retained commit ref.")
    }

    try await checkInteractiveRebaseRange(repository, commits, lastRetainedCommitRef, operation: "squash")

    var todo = SquashTodo()
    var foundSquashOntoCommitInLog = false
    var toReplayAtSquash: [Commit] = []

    // Traversed in reverse so we do oldest to newest (replay commits)
    for commit in commits.reversed() {
        if toSquashShas.contains(commit.sha) {
            // If it is toSquash commit and we have found the squashOnto commit, we
            // can go ahead and squash them (as we will hold any picks till after)
            if foundSquashOntoCommitInLog {
                todo.squashed.append(commit)
            } else {
                // However, if we have not found the squashOnto commit yet we want to
                // keep track of them in the order of the log. Thus, we use a new
                // `toReplayAtSquash` array and not trust that what was sent is in the
                // order of the log.
                toReplayAtSquash.append(commit)
            }

            continue
        }

        // If it's the squashOnto commit, replay to the toSquash in the order they
        // appeared on the log to reduce potential conflicts.
        if commit.sha == squashOnto.sha {
            foundSquashOntoCommitInLog = true
            toReplayAtSquash.append(commit)
            todo.squashed.append(contentsOf: toReplayAtSquash)
            continue
        }

        // We can't just replay a pick in case there is a commit from the toSquash
        // commits further up in history that need to be replayed with the
        // squashes. Thus, we will keep track of these and replay after traversing
        // the remainder of the log.
        if foundSquashOntoCommitInLog {
            todo.after.append(commit)
            continue
        }

        // If it is not one toSquash nor the squashOnto and have not found the
        // squashOnto commit, we simply record it is an unchanged pick (before the
        // squash)
        todo.before.append(commit)
    }

    if !foundSquashOntoCommitInLog {
        throw GitLibError(
            "[squash] The commit to squash onto was not in the log. Continuing would result in dropping the commits in the toSquash array."
        )
    }

    // Commits to squash that aren't in the log would be silently left out.
    if todo.squashed.count != toSquashShas.count + 1 {
        throw GitLibError("[squash] A commit to squash was not in the log.")
    }

    return todo
}

/// Where the squashed commit's message comes from.
private enum SquashMessage {
    /// The message the user wrote.
    case provided(String)
    /// The messages of these commits, separated by blank lines, as git
    /// combines them when no message is given.
    case combined([Commit])
}

/// Makes the commit whose message `fixup -C` gives the squashed commit, and
/// returns its ID. It has the tree of its parent, HEAD, so it changes
/// nothing; nothing refers to it once the rebase is done.
///
/// The message is cleaned up as `git commit -F` cleans one (`git
/// stripspace`: trailing whitespace and extra blank lines go, lines starting
/// with `#` stay). The commit isn't signed: it never becomes part of history.
private func createSquashMessageCommit(_ repository: Repository, message: SquashMessage) async throws -> String {
    let text: Data
    switch message {
    case .provided(let message):
        text = Data(message.utf8)
    case .combined(let commits):
        // The raw messages, in the order given.
        let result = try await git(
            ["log", "--no-walk=unsorted", "-z", "--format=%B", "--encoding=UTF-8", "--no-show-signature", "--no-color", "--end-of-options"]
                + commits.map(\.sha) + ["--"],
            repository.path,
            "squashMessages"
        )
        let messages = result.stdoutData.split(separator: 0, omittingEmptySubsequences: false)
            .prefix(commits.count)
        text = Data(messages.joined(separator: Data("\n\n".utf8)))
    }

    let cleaned = try await git(
        ["stripspace"],
        repository.path,
        "squashMessage",
        options: GitExecutionOptions(stdin: text)
    )

    let result = try await git(
        ["commit-tree", "--no-gpg-sign", "-p", "HEAD", "-F", "-", "HEAD^{tree}"],
        repository.path,
        "squashMessageCommit",
        options: GitExecutionOptions(stdin: cleaned.stdoutData)
    )

    return JSCompat.trim(result.stdout)
}
