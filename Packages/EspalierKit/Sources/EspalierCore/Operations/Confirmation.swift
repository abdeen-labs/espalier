import GitKit

/// Something an intent asks the user to confirm before it runs.
///
/// An intent that needs a confirmation the caller didn't pass in
/// `confirmed:` throws `OperationError` with `.confirmationRequired`; the UI
/// asks the user, then calls the intent again with the kind added.
public enum ConfirmationKind: String, Sendable, Hashable, CaseIterable {
    case removeRepository, discardChanges, discardAllChanges, discardLines, discardStash, checkoutCommit, leaveCommitsBehind
    case forcePush, rewritePublishedCommits, undoCommitWithChanges, resetWithChanges, overwriteStash
    case commitFilteredChanges, commitWithUnknownCoAuthors, commitOversizedFiles, commitConflictMarkers
    case overwriteCommitMessage, removeWorktree, abortWithResolvedConflicts, deleteBranch, deleteRemoteBranch, deleteTag
    case replaceCommandLineTool
}

/// A confirmation an intent requires, with its copy.
public struct Confirmation: Sendable, Equatable {
    public let kind: ConfirmationKind
    public let details: Details
    /// The dialog's title.
    public let title: String
    /// The question. Lists (files, authors) are in `details`, for the UI to
    /// show after the message.
    public let message: String
    /// The button that confirms.
    public let confirmButton: String

    public init(kind: ConfirmationKind, details: Details = .none, title: String, message: String, confirmButton: String) {
        self.kind = kind
        self.details = details
        self.title = title
        self.message = message
        self.confirmButton = confirmButton
    }

    /// What the confirmation is about.
    public enum Details: Sendable, Equatable {
        case none
        /// The repository to remove.
        case repository(name: String, path: String)
        /// The files concerned (repository-relative paths).
        case files([String])
        /// The usernames of co-authors who weren't found.
        case authors([String])
        /// A branch name: the remote branch to delete, or the upstream a
        /// force push rewrites.
        case branch(String)
        /// The local branch to delete, and whether its upstream exists on
        /// the remote (the UI then offers to delete it there too).
        case deleteBranch(name: String, existsOnRemote: Bool)
        /// A tag name.
        case tag(String)
        /// A worktree to delete.
        case worktree(name: String, path: String)
        /// The operation's display name ("Rebase", "Squash", "Amend", ...).
        case operation(String)
        /// The branch a checkout goes to after stashing, or nil when only
        /// stashing.
        case overwriteStash(checkingOut: Branch?)
        /// The commit to undo.
        case commit(sha: String, isMergeCommit: Bool)
    }
}

/// The most files or authors a confirmation's message lists.
private let maxItemsToList = 10

extension Confirmation {
    /// Removing a repository from the list.
    public static func removeRepository(name: String, path: String) -> Confirmation {
        Confirmation(
            kind: .removeRepository,
            details: .repository(name: name, path: path),
            title: "Remove Repository?",
            message: "Remove \u{201C}\(name)\u{201D} from Espalier?",
            confirmButton: "Remove"
        )
    }

    /// Discarding the changes to some files.
    public static func discardChanges(_ paths: [String]) -> Confirmation {
        Confirmation(
            kind: .discardChanges,
            details: .files(paths),
            title: "Discard Changes?",
            message: discardMessage(paths),
            confirmButton: "Discard Changes"
        )
    }

    /// Discarding every change ("Discard All Changes…"), which always asks.
    public static func discardAllChanges(_ paths: [String]) -> Confirmation {
        Confirmation(
            kind: .discardAllChanges,
            details: .files(paths),
            title: "Discard All Changes?",
            message: discardMessage(paths),
            confirmButton: "Discard All Changes"
        )
    }

    private static func discardMessage(_ paths: [String]) -> String {
        let question = paths.count > maxItemsToList
            ? "All changes to \(paths.count) files will be discarded."
            : "The changes to these files will be discarded:"
        return "\(question)\n\nYou can get them back from the Trash."
    }

    /// Discarding selected lines of a file.
    public static func discardLines(path: String) -> Confirmation {
        Confirmation(
            kind: .discardLines,
            details: .files([path]),
            title: "Discard Changes?",
            message: "The selected changes to this file will be discarded:",
            confirmButton: "Discard Changes"
        )
    }

    /// Dropping a stash.
    public static func discardStash() -> Confirmation {
        Confirmation(
            kind: .discardStash,
            title: "Discard Stash?",
            message: "Are you sure you want to discard these stashed changes?",
            confirmButton: "Discard"
        )
    }

    /// Checking out a commit.
    public static func checkoutCommit(sha: String) -> Confirmation {
        Confirmation(
            kind: .checkoutCommit,
            details: .commit(sha: sha, isMergeCommit: false),
            title: "Check Out Commit?",
            message: "Checking out a commit puts you on a detached HEAD, so you'll no longer be on any branch.",
            confirmButton: "Check Out"
        )
    }

    /// Leaving a detached HEAD whose commits no branch, tag, or remote
    /// branch has.
    public static func leaveCommitsBehind(count: Int, sha: String) -> Confirmation {
        let one = count == 1
        return Confirmation(
            kind: .leaveCommitsBehind,
            details: .commit(sha: sha, isMergeCommit: false),
            title: one ? "Leave a Commit Behind?" : "Leave \(count) Commits Behind?",
            message: one
                ? "The commit you're on isn't on any branch. If you switch away, it's left behind, and Git eventually deletes it. To keep it, create a branch from it first."
                : "The commit you're on and \(count - 1) before it aren't on any branch. If you switch away, they're left behind, and Git eventually deletes them. To keep them, create a branch from here first.",
            confirmButton: "Switch Anyway"
        )
    }

    /// A force push.
    public static func forcePush(upstreamBranch: String) -> Confirmation {
        Confirmation(
            kind: .forcePush,
            details: .branch(upstreamBranch),
            title: "Force Push?",
            message: "Force pushing rewrites the history of \(upstreamBranch). Anyone working on this branch will need to reset their local branch to match it.",
            confirmButton: "Force Push"
        )
    }

    /// Rewriting commits that were pushed: rebase, squash, reorder, or amend.
    ///
    /// - Parameter operation: The operation's name: "Rebase", "Squash",
    ///   "Reorder", or "Amend".
    public static func rewritePublishedCommits(operation: String) -> Confirmation {
        let lowercased = operation.lowercased()
        // Amending rewrites one commit; the others, several.
        let commits = operation == "Amend" ? "Commit" : "Commits"
        return Confirmation(
            kind: .rewritePublishedCommits,
            details: .operation(operation),
            title: "\(operation) Pushed \(commits)?",
            message: "This branch has already been pushed. After the \(lowercased), you'll need to force push it, which rewrites its history on the remote and may cause problems for others working on it.",
            confirmButton: "\(operation) Anyway"
        )
    }

    /// Undoing a commit while there are changes, or undoing a merge commit.
    public static func undoCommitWithChanges(sha: String, isMergeCommit: Bool, isWorkingDirectoryClean: Bool) -> Confirmation {
        let mergeWarning = "Undoing a merge commit puts its changes back in your working directory, and committing them again makes a new, ordinary commit. The merge commit is lost, so commits from the merged branch could disappear from this branch."
        let message: String
        if !isMergeCommit {
            message = "You have uncommitted changes, and undoing the commit might lose some of them."
        } else if isWorkingDirectoryClean {
            message = mergeWarning
        } else {
            message = "You have uncommitted changes, and undoing the merge commit might lose some of them.\n\n\(mergeWarning)"
        }
        return Confirmation(
            kind: .undoCommitWithChanges,
            details: .commit(sha: sha, isMergeCommit: isMergeCommit),
            title: "Undo Commit?",
            message: message,
            confirmButton: "Undo Anyway"
        )
    }

    /// Resetting to a commit while there are changes.
    public static func resetWithChanges(sha: String) -> Confirmation {
        Confirmation(
            kind: .resetWithChanges,
            details: .commit(sha: sha, isMergeCommit: false),
            title: "Reset to Commit?",
            message: "You have uncommitted changes, and resetting to an earlier commit might lose some of them.",
            confirmButton: "Reset Anyway"
        )
    }

    /// Replacing the current branch's stash with the current changes.
    ///
    /// - Parameter branch: The branch checked out after stashing, or nil when
    ///   only stashing.
    public static func overwriteStash(checkingOut branch: Branch?) -> Confirmation {
        Confirmation(
            kind: .overwriteStash,
            details: .overwriteStash(checkingOut: branch),
            title: "Overwrite Stash?",
            message: "Your current changes will replace the stash already on this branch.",
            confirmButton: "Overwrite"
        )
    }

    /// Committing while the file filter hides included files.
    public static func commitFilteredChanges(hiddenPaths: [String]) -> Confirmation {
        Confirmation(
            kind: .commitFilteredChanges,
            details: .files(hiddenPaths),
            title: "Commit Filtered Changes?",
            message: "A filter is hiding some of the changes that will be committed.",
            confirmButton: "Commit Anyway"
        )
    }

    /// Committing with co-authors who weren't found.
    public static func commitWithUnknownCoAuthors(_ usernames: [String]) -> Confirmation {
        let message = usernames.count > maxItemsToList
            ? "\(usernames.count) users weren't found and won't be added as co-authors."
            : "These users weren't found and won't be added as co-authors:"
        return Confirmation(
            kind: .commitWithUnknownCoAuthors,
            details: .authors(usernames),
            title: "Commit Without Unknown Co-Authors?",
            message: message,
            confirmButton: "Commit Anyway"
        )
    }

    /// Committing files over 100 MB that Git LFS doesn't track.
    public static func commitOversizedFiles(_ paths: [String]) -> Confirmation {
        Confirmation(
            kind: .commitOversizedFiles,
            details: .files(paths),
            title: "Commit Large Files?",
            message: "These files are larger than 100 MB:\n\nIf you commit them, you won't be able to push this repository to GitHub.com. Leave them out of the commit, or store large files with Git LFS.",
            confirmButton: "Commit Anyway"
        )
    }

    /// Committing files that still have conflict markers.
    public static func commitConflictMarkers(_ paths: [String]) -> Confirmation {
        Confirmation(
            kind: .commitConflictMarkers,
            details: .files(paths),
            title: "Commit Conflicted Files?",
            message: "These files still have unresolved conflicts:",
            confirmButton: "Commit Anyway"
        )
    }

    /// Replacing a typed commit message with a generated one.
    public static func overwriteCommitMessage() -> Confirmation {
        Confirmation(
            kind: .overwriteCommitMessage,
            title: "Replace Commit Message?",
            message: "The generated message will replace the one you've typed.",
            confirmButton: "Replace"
        )
    }

    /// Deleting a worktree.
    public static func removeWorktree(name: String, path: String) -> Confirmation {
        Confirmation(
            kind: .removeWorktree,
            details: .worktree(name: name, path: path),
            title: "Delete Worktree?",
            message: "Are you sure you want to delete the worktree \(name)?",
            confirmButton: "Delete"
        )
    }

    /// Aborting a merge, rebase, or cherry-pick after resolving conflicts.
    ///
    /// - Parameter operation: The operation's name: "Merge", "Rebase",
    ///   "Cherry-pick", or "Revert".
    public static func abortWithResolvedConflicts(operation: String) -> Confirmation {
        Confirmation(
            kind: .abortWithResolvedConflicts,
            details: .operation(operation),
            title: "Abort \(operation)?",
            message: "Your branch goes back to how it was before the \(operation.lowercased()), and the conflicts you've resolved are discarded.",
            confirmButton: "Abort \(operation)"
        )
    }

    /// Deleting a local branch.
    ///
    /// - Parameter existsOnRemote: Whether the branch's upstream exists, so
    ///   the UI offers "Delete it on the remote too".
    public static func deleteBranch(_ name: String, existsOnRemote: Bool) -> Confirmation {
        let remote = existsOnRemote
            ? "\n\nThe branch also exists on the remote."
            : ""
        return Confirmation(
            kind: .deleteBranch,
            details: .deleteBranch(name: name, existsOnRemote: existsOnRemote),
            title: "Delete Branch?",
            message: "Delete the branch \(name)?\n\nThis can't be undone.\(remote)",
            confirmButton: "Delete"
        )
    }

    /// Deleting a branch that exists only on the remote.
    public static func deleteRemoteBranch(_ name: String) -> Confirmation {
        Confirmation(
            kind: .deleteRemoteBranch,
            details: .branch(name),
            title: "Delete Remote Branch?",
            message: "Delete the remote branch \(name)?\n\nThis can't be undone. The branch doesn't exist on this Mac, and deleting it may affect others working on it.",
            confirmButton: "Delete"
        )
    }

    /// Deleting a tag.
    public static func deleteTag(_ name: String) -> Confirmation {
        Confirmation(
            kind: .deleteTag,
            details: .tag(name),
            title: "Delete Tag?",
            message: "Are you sure you want to delete the tag \(name)?",
            confirmButton: "Delete"
        )
    }

    /// Installing the command line tool over something else at its path: a
    /// link elsewhere, or a file.
    ///
    /// - Parameters:
    ///   - path: Where the tool goes (`/usr/local/bin/espalier`).
    ///   - linkDestination: Where the link there points; nil for a file.
    public static func replaceCommandLineTool(path: String, linkDestination: String?) -> Confirmation {
        let message = if let linkDestination {
            "\(path) is a link to \(linkDestination), not to Espalier's command line tool. Installing replaces the link."
        } else {
            "\(path) is a file other than Espalier's command line tool. Installing deletes it and puts the tool in its place."
        }
        return Confirmation(
            kind: .replaceCommandLineTool,
            title: "Replace Existing Command?",
            message: message,
            confirmButton: "Replace"
        )
    }
}

// MARK: - Decisions

/// A choice an intent needs before it can run, answered with a
/// `DecisionAnswer`: checkout is called again with an explicit argument
/// (`strategy:`); an editor answer is saved as the editor, and the intent
/// called again.
public enum Decision: Sendable, Equatable {
    /// Switching branches with uncommitted changes and the "ask" strategy:
    /// leave the changes on the current branch (stash them there) or bring
    /// them along.
    ///
    /// - Parameter currentBranchHasStash: Whether leaving the changes would
    ///   replace the current branch's stash (the choice's warning).
    case uncommittedChanges(currentBranch: String, targetBranch: String, currentBranchHasStash: Bool)

    /// Opening in the external editor with no editor chosen and several
    /// installed: which one to use, from now on.
    ///
    /// - Parameter editors: The installed editors' names, in order.
    case externalEditor(editors: [String])

    /// The dialog's title.
    public var title: String {
        switch self {
        case .uncommittedChanges: "Switch Branch"
        case .externalEditor: "Choose an Editor"
        }
    }

    /// The question.
    public var message: String {
        switch self {
        case .uncommittedChanges:
            "You have changes on this branch. What would you like to do with them?"
        case .externalEditor:
            "Espalier found more than one editor on your Mac. Which one should it open repositories and files in?"
        }
    }

    /// The answers to `uncommittedChanges`. Each one's `strategy` is the
    /// argument to pass back. An editor's answers are its `editors`.
    public var choices: [DecisionChoice] {
        switch self {
        case .externalEditor:
            []
        case .uncommittedChanges(let currentBranch, let targetBranch, let hasStash):
            [
                DecisionChoice(
                    strategy: .stashOnCurrentBranch,
                    title: "Leave my changes on \(currentBranch)",
                    description: "Your changes are stashed on this branch, ready for when you come back.",
                    warning: hasStash ? "This replaces the stash already on this branch." : nil
                ),
                DecisionChoice(
                    strategy: .moveToNewBranch,
                    title: "Bring my changes to \(targetBranch)",
                    description: "Your changes come with you to the other branch.",
                    warning: nil
                ),
            ]
        }
    }

    /// The button that commits to the choice.
    public var confirmButton: String {
        switch self {
        case .uncommittedChanges: "Switch Branch"
        case .externalEditor: "Open"
        }
    }

    /// The confirmations answering with `strategy` gives, for the intent's
    /// next call: leaving the changes on a branch that has a stash, which
    /// the choice warns will be overwritten, confirms `.overwriteStash`, so
    /// checking out asks once.
    public func confirmations(answeredBy strategy: UncommittedChangesStrategy) -> Set<ConfirmationKind> {
        switch self {
        case .uncommittedChanges(_, _, let hasStash):
            hasStash && strategy == .stashOnCurrentBranch ? [.overwriteStash] : []
        case .externalEditor:
            []
        }
    }
}

/// The user's answer to a `Decision`.
public enum DecisionAnswer: Sendable, Equatable {
    /// What to do with uncommitted changes (`uncommittedChanges`).
    case strategy(UncommittedChangesStrategy)
    /// The editor to use, by name (`externalEditor`).
    case editor(String)
}

/// One answer to a `Decision`.
public struct DecisionChoice: Sendable, Equatable {
    public let strategy: UncommittedChangesStrategy
    public let title: String
    public let description: String
    /// A warning to show while this choice is selected.
    public let warning: String?
}
