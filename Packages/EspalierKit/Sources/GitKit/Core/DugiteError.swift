// Ported from dugite/lib/errors.ts, dugite/lib/parse-error.ts, and
// dugite/lib/parse-bad-config-value-error-info.ts

import Foundation

/// The git errors which can be parsed from failed git commands.
///
/// Named `DugiteError` to tell it apart from `GitError`, the error `git()`
/// throws.
public enum DugiteError: String, Sendable, Hashable, CaseIterable {
    case badConfigValue = "BadConfigValue"
    case sshKeyAuditUnverified = "SSHKeyAuditUnverified"
    case sshAuthenticationFailed = "SSHAuthenticationFailed"
    case sshPermissionDenied = "SSHPermissionDenied"
    case httpsAuthenticationFailed = "HTTPSAuthenticationFailed"
    case remoteDisconnection = "RemoteDisconnection"
    case hostDown = "HostDown"
    case rebaseConflicts = "RebaseConflicts"
    case mergeConflicts = "MergeConflicts"
    case httpsRepositoryNotFound = "HTTPSRepositoryNotFound"
    case sshRepositoryNotFound = "SSHRepositoryNotFound"
    case pushNotFastForward = "PushNotFastForward"
    case branchDeletionFailed = "BranchDeletionFailed"
    case defaultBranchDeletionFailed = "DefaultBranchDeletionFailed"
    case revertConflicts = "RevertConflicts"
    case emptyRebasePatch = "EmptyRebasePatch"
    case noMatchingRemoteBranch = "NoMatchingRemoteBranch"
    case noExistingRemoteBranch = "NoExistingRemoteBranch"
    case nothingToCommit = "NothingToCommit"
    case noSubmoduleMapping = "NoSubmoduleMapping"
    case submoduleRepositoryDoesNotExist = "SubmoduleRepositoryDoesNotExist"
    case invalidSubmoduleSHA = "InvalidSubmoduleSHA"
    case localPermissionDenied = "LocalPermissionDenied"
    case invalidMerge = "InvalidMerge"
    case invalidRebase = "InvalidRebase"
    case nonFastForwardMergeIntoEmptyHead = "NonFastForwardMergeIntoEmptyHead"
    case patchDoesNotApply = "PatchDoesNotApply"
    case branchAlreadyExists = "BranchAlreadyExists"
    case badRevision = "BadRevision"
    case notAGitRepository = "NotAGitRepository"
    case cannotMergeUnrelatedHistories = "CannotMergeUnrelatedHistories"
    case lfsAttributeDoesNotMatch = "LFSAttributeDoesNotMatch"
    case branchRenameFailed = "BranchRenameFailed"
    case pathDoesNotExist = "PathDoesNotExist"
    case invalidObjectName = "InvalidObjectName"
    case outsideRepository = "OutsideRepository"
    case lockFileAlreadyExists = "LockFileAlreadyExists"
    case noMergeToAbort = "NoMergeToAbort"
    case localChangesOverwritten = "LocalChangesOverwritten"
    case unresolvedConflicts = "UnresolvedConflicts"
    case gpgFailedToSignData = "GPGFailedToSignData"
    case conflictModifyDeletedInBranch = "ConflictModifyDeletedInBranch"
    // Start of GitHub-specific error codes
    case pushWithFileSizeExceedingLimit = "PushWithFileSizeExceedingLimit"
    case hexBranchNameRejected = "HexBranchNameRejected"
    case forcePushRejected = "ForcePushRejected"
    case invalidRefLength = "InvalidRefLength"
    case protectedBranchRequiresReview = "ProtectedBranchRequiresReview"
    case protectedBranchForcePush = "ProtectedBranchForcePush"
    case protectedBranchDeleteRejected = "ProtectedBranchDeleteRejected"
    case protectedBranchRequiredStatus = "ProtectedBranchRequiredStatus"
    case pushWithPrivateEmail = "PushWithPrivateEmail"
    // End of GitHub-specific error codes
    case configLockFileAlreadyExists = "ConfigLockFileAlreadyExists"
    case remoteAlreadyExists = "RemoteAlreadyExists"
    case tagAlreadyExists = "TagAlreadyExists"
    case mergeWithLocalChanges = "MergeWithLocalChanges"
    case rebaseWithLocalChanges = "RebaseWithLocalChanges"
    case mergeCommitNoMainlineOption = "MergeCommitNoMainlineOption"
    case unsafeDirectory = "UnsafeDirectory"
    case pathExistsButNotInRef = "PathExistsButNotInRef"
    case pushWithSecretDetected = "PushWithSecretDetected"
    /// `git rebase` or `git pull` with rebase refused to start because the
    /// index has staged changes (with or without unstaged ones).
    case rebaseWithStagedChanges = "RebaseWithStagedChanges"
    /// `git rebase` or `git pull` with rebase refused to start because the
    /// git directory already holds a rebase's state (`rebase-merge`, or
    /// `rebase-apply` for git's apply backend).
    case rebaseAlreadyInProgress = "RebaseAlreadyInProgress"
    /// `git rebase` or `git pull` with rebase refused to start because
    /// `git am` is stopped on a patch.
    case applyingPatchesInProgress = "ApplyingPatchesInProgress"
}

extension DugiteError {
    /// A mapping from regexes to the git error they identify. The first
    /// matching regex wins.
    ///
    /// JavaScript and ICU agree on everything the patterns use: without
    /// flags, `.` stops at line breaks and `^` and `$` anchor to the whole
    /// input.
    public static let regexes: [(pattern: String, error: DugiteError)] = [
        (#"fatal: bad (?:numeric|boolean) config value '(.+)' for '(.+)'"#, .badConfigValue),
        (#"ERROR: ([\s\S]+?)\n+\[EPOLICYKEYAGE\]\n+fatal: Could not read from remote repository."#, .sshKeyAuditUnverified),
        (#"fatal: Authentication failed for 'https?://"#, .httpsAuthenticationFailed),
        (#"fatal: Authentication failed"#, .sshAuthenticationFailed),
        (#"fatal: Could not read from remote repository."#, .sshPermissionDenied),
        (#"The requested URL returned error: 403"#, .httpsAuthenticationFailed),
        (#"fatal: [Tt]he remote end hung up unexpectedly"#, .remoteDisconnection),
        (#"fatal: unable to access '(.+)': Failed to connect to (.+): Host is down"#, .hostDown),
        (#"Cloning into '(.+)'...\nfatal: unable to access '(.+)': Could not resolve host: (.+)"#, .hostDown),
        (#"Resolve all conflicts manually, mark them as resolved with"#, .rebaseConflicts),
        // The revert pattern below matches only the hint that old versions
        // of git printed. Git prints this line (followed by a hint, unless
        // advice.mergeConflict is off) only when a revert stops with
        // conflicts. Ahead of the merge conflict pattern so that a reverted
        // commit's summary can't change the error.
        (#"error: could not revert "#, .revertConflicts),
        (#"(Merge conflict|Automatic merge failed; fix conflicts and then commit the result)"#, .mergeConflicts),
        (#"fatal: repository '(.+)' not found"#, .httpsRepositoryNotFound),
        (#"ERROR: Repository not found"#, .sshRepositoryNotFound),
        (#"\((non-fast-forward|fetch first)\)\nerror: failed to push some refs to '.*'"#, .pushNotFastForward),
        (#"error: unable to delete '(.+)': remote ref does not exist"#, .branchDeletionFailed),
        (#"\[remote rejected\] (.+) \(deletion of the current branch prohibited\)"#, .defaultBranchDeletionFailed),
        (#"error: could not revert .*\nhint: after resolving the conflicts, mark the corrected paths\nhint: with 'git add <paths>' or 'git rm <paths>'\nhint: and commit the result with 'git commit'"#, .revertConflicts),
        (#"Applying: .*\nNo changes - did you forget to use 'git add'\?\nIf there is nothing left to stage, chances are that something else\n.*"#, .emptyRebasePatch),
        (#"There are no candidates for (rebasing|merging) among the refs that you just fetched.\nGenerally this means that you provided a wildcard refspec which had no\nmatches on the remote end."#, .noMatchingRemoteBranch),
        (#"Your configuration specifies to merge with the ref '(.+)'\nfrom the remote, but no such ref was fetched."#, .noExistingRemoteBranch),
        (#"nothing to commit"#, .nothingToCommit),
        (#"[Nn]o submodule mapping found in .gitmodules for path '(.+)'"#, .noSubmoduleMapping),
        (#"fatal: repository '(.+)' does not exist\nfatal: clone of '.+' into submodule path '(.+)' failed"#, .submoduleRepositoryDoesNotExist),
        (#"Fetched in submodule path '(.+)', but it did not contain (.+). Direct fetching of that commit failed."#, .invalidSubmoduleSHA),
        (#"fatal: could not create work tree dir '(.+)'.*: Permission denied"#, .localPermissionDenied),
        (#"merge: (.+) - not something we can merge"#, .invalidMerge),
        (#"invalid upstream (.+)"#, .invalidRebase),
        (#"fatal: Non-fast-forward commit does not make sense into an empty head"#, .nonFastForwardMergeIntoEmptyHead),
        (#"error: (.+): (patch does not apply|already exists in working directory)"#, .patchDoesNotApply),
        (#"fatal: [Aa] branch named '(.+)' already exists.?"#, .branchAlreadyExists),
        (#"fatal: bad revision '(.*)'"#, .badRevision),
        (#"fatal: [Nn]ot a git repository \(or any of the parent directories\): (.*)"#, .notAGitRepository),
        (#"fatal: refusing to merge unrelated histories"#, .cannotMergeUnrelatedHistories),
        // Git LFS 3 (bundled) writes "warning: the ... attribute should be
        // ...", in lowercase.
        (#"[Tt]he .+ attribute should be .+ but is .+"#, .lfsAttributeDoesNotMatch),
        (#"fatal: Branch rename failed"#, .branchRenameFailed),
        (#"fatal: path '(.+)' does not exist .+"#, .pathDoesNotExist),
        (#"fatal: invalid object name '(.+)'."#, .invalidObjectName),
        (#"fatal: .+: '(.+)' is outside repository"#, .outsideRepository),
        // Git 2.56 ends the sentence ", or the lock file may be stale";
        // earlier versions go on with ", e.g.".
        (#"Another git process seems to be running in this repository"#, .lockFileAlreadyExists),
        (#"fatal: There is no merge to abort"#, .noMergeToAbort),
        (#"error: (?:Your local changes to the following|The following untracked working tree) files would be overwritten by checkout:"#, .localChangesOverwritten),
        (#"You must edit all merge conflicts and then\nmark them as resolved using git add|fatal: Exiting because of an unresolved conflict"#, .unresolvedConflicts),
        (#"error: gpg failed to sign the data"#, .gpgFailedToSignData),
        (#"CONFLICT \(modify/delete\): (.+) deleted in (.+) and modified in (.+)"#, .conflictModifyDeletedInBranch),
        // GitHub-specific errors
        (#"error: GH001: "#, .pushWithFileSizeExceedingLimit),
        (#"error: GH002: "#, .hexBranchNameRejected),
        (#"error: GH003: Sorry, force-pushing to (.+) is not allowed."#, .forcePushRejected),
        (#"error: GH005: Sorry, refs longer than (.+) bytes are not allowed"#, .invalidRefLength),
        (#"error: GH006: Protected branch update failed for (.+)\nremote: error: At least one approved review is required"#, .protectedBranchRequiresReview),
        (#"error: GH006: Protected branch update failed for (.+)\nremote: error: Cannot force-push to a protected branch"#, .protectedBranchForcePush),
        (#"error: GH006: Protected branch update failed for (.+)\nremote: error: Cannot delete a protected branch"#, .protectedBranchDeleteRejected),
        (#"error: GH006: Protected branch update failed for (.+).\nremote: error: Required status check "(.+)" is expected"#, .protectedBranchRequiredStatus),
        (#"error: GH007: Your push would publish a private email address."#, .pushWithPrivateEmail),
        (#"error: could not lock config file (.+): File exists"#, .configLockFileAlreadyExists),
        (#"error: remote (.+) already exists."#, .remoteAlreadyExists),
        (#"fatal: tag '(.+)' already exists"#, .tagAlreadyExists),
        (#"error: Your local changes to the following files would be overwritten by merge:\n"#, .mergeWithLocalChanges),
        (#"error: cannot (pull with rebase|rebase): You have unstaged changes\.\n\s*error: [Pp]lease commit or stash them\."#, .rebaseWithLocalChanges),
        // Git names unstaged changes first when there are both, and then
        // adds that the index has changes too.
        (#"error: cannot (pull with rebase|rebase): (?:You have unstaged changes\.\n\s*error: additionally, your|Your) index contains uncommitted changes\.\n\s*error: [Pp]lease commit or stash them\."#, .rebaseWithStagedChanges),
        (#"fatal: It seems that there is already a rebase-(?:merge|apply) directory"#, .rebaseAlreadyInProgress),
        (#"fatal: It looks like 'git am' is in progress\. Cannot rebase\."#, .applyingPatchesInProgress),
        (#"error: commit (.+) is a merge but no -m option was given"#, .mergeCommitNoMainlineOption),
        (#"fatal: detected dubious ownership in repository at (.+)"#, .unsafeDirectory),
        (#"fatal: path '(.+)' exists on disk, but not in '(.+)'"#, .pathExistsButNotInRef),
        (#"GITHUB PUSH PROTECTION[.\s\S]+Push cannot contain secrets"#, .pushWithSecretDetected),
    ]

    /// The compiled form of `regexes`, in the same order.
    static let compiled: [(regex: NSRegularExpression, error: DugiteError)] = regexes.map { entry in
        do {
            return (try NSRegularExpression(pattern: entry.pattern), entry.error)
        } catch {
            preconditionFailure("Invalid dugite error pattern for \(entry.error): \(error)")
        }
    }
}

extension Dugite {
    /// Try to parse an error type from stderr.
    public static func parseError(_ stderr: String) -> DugiteError? {
        let range = NSRange(stderr.startIndex..., in: stderr)
        for entry in DugiteError.compiled where entry.regex.firstMatch(in: stderr, range: range) != nil {
            return entry.error
        }
        return nil
    }

    /// The key and value from a "bad config value" error, or `nil` if
    /// `stderr` doesn't contain one.
    public static func parseBadConfigValueErrorInfo(_ stderr: String) -> (key: String, value: String)? {
        guard let entry = DugiteError.compiled.first(where: { $0.error == .badConfigValue }) else {
            return nil
        }

        let range = NSRange(stderr.startIndex..., in: stderr)
        guard let match = entry.regex.firstMatch(in: stderr, range: range),
              let valueRange = Range(match.range(at: 1), in: stderr),
              let keyRange = Range(match.range(at: 2), in: stderr)
        else {
            return nil
        }

        let value = String(stderr[valueRange])
        let key = String(stderr[keyRange])
        guard !value.isEmpty, !key.isEmpty else {
            return nil
        }

        return (key: key, value: value)
    }
}
