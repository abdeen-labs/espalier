// Ported from desktop's assisted commit draft (desktop#22976):
// app/src/models/assisted-commit.ts, app/src/lib/git/assisted-commit/error.ts
// and progress.ts.
//
// The snapshot freezes the selected changes; the planner sees only its
// analysis (opaque change IDs and selected-only diffs) and answers with a
// plan of IDs and messages, never paths, patches, or objects. Espalier
// validates the whole plan and every cumulative tree before the first real
// commit, makes each commit in a private index, verifies it, and publishes
// it with a guarded compare-and-swap ref update.

import EspalierSupport
import Foundation
import Synchronization

/// The complete HEAD a run started from: unborn and detached HEADs too.
public struct AssistedCommitHead: Sendable, Hashable {
    /// The fully qualified branch (`refs/heads/<name>`), or nil for a
    /// detached HEAD.
    public let ref: String?
    /// The full commit ID, or nil for an unborn branch.
    public let sha: String?

    public init(ref: String?, sha: String?) {
        self.ref = ref
        self.sha = sha
    }
}

/// Whether a unit is one text hunk or a whole file change.
public enum AssistedCommitChangeKind: String, Sendable, Hashable {
    /// One hunk of a text file's selected changes.
    case textHunk = "text-hunk"
    /// A change that can't be split: a rename or copy, a deletion, a mode
    /// change, a symbolic link, a binary or very large file, an empty file.
    case atomic
}

/// An indivisible unit of the selected changes, valid only in its snapshot.
///
/// The diff is for analysis. A plan names units by ID; it never supplies
/// paths, patches, modes, or object IDs.
public struct AssistedCommitChange: Sendable, Hashable, Identifiable {
    /// An opaque ID, unique within the snapshot.
    public let id: String
    public let kind: AssistedCommitChangeKind
    /// The repository-relative path.
    public let path: String
    /// The original path of a rename or copy.
    public let oldPath: String?
    /// The selected changes with their unchanged context, and nothing that
    /// wasn't selected. A binary change shows git's summary line, not its
    /// bytes.
    public let diff: String

    public init(id: String, kind: AssistedCommitChangeKind, path: String, oldPath: String?, diff: String) {
        self.id = id
        self.kind = kind
        self.path = path
        self.oldPath = oldPath
        self.diff = diff
    }
}

/// What a planner may see of a snapshot: its ID and its units.
public struct AssistedCommitAnalysis: Sendable, Hashable {
    /// The ID a plan must name.
    public let snapshotID: String
    /// Every selected unit, in file order and then hunk order.
    public let changes: [AssistedCommitChange]

    public init(snapshotID: String, changes: [AssistedCommitChange]) {
        self.snapshotID = snapshotID
        self.changes = changes
    }
}

/// The selected changes and the options every planned commit gets.
public struct AssistedCommitRequest: Sendable {
    /// The selected files. Files whose selection is none are left out.
    public var files: [WorkingDirectoryFileChange]
    /// Trailers added to every commit message (co-authors).
    public var trailers: [Trailer]
    /// Skip the pre-commit and commit-msg hooks (`--no-verify`).
    public var skipHooks: Bool
    /// Add a Signed-off-by trailer (`--signoff`).
    public var signOff: Bool
    /// With nothing selected, make one empty commit.
    public var allowEmpty: Bool

    public init(
        files: [WorkingDirectoryFileChange],
        trailers: [Trailer] = [],
        skipHooks: Bool = false,
        signOff: Bool = false,
        allowEmpty: Bool = false
    ) {
        self.files = files
        self.trailers = trailers
        self.skipHooks = skipHooks
        self.signOff = signOff
        self.allowEmpty = allowEmpty
    }
}

/// One proposed commit: a message and the units it owns.
public struct AssistedCommitPlanCommit: Sendable, Hashable {
    /// The title: one line, not blank.
    public let title: String
    /// The description, if any.
    public let description: String?
    /// The units this commit adds, by ID.
    public let changeIDs: [String]

    public init(title: String, description: String?, changeIDs: [String]) {
        self.title = title
        self.description = description
        self.changeIDs = changeIDs
    }
}

/// A complete proposal: ordered commits that together own every unit of
/// the snapshot exactly once.
public struct AssistedCommitPlan: Sendable, Hashable {
    public let snapshotID: String
    public let commits: [AssistedCommitPlanCommit]

    public init(snapshotID: String, commits: [AssistedCommitPlanCommit]) {
        self.snapshotID = snapshotID
        self.commits = commits
    }
}

/// Why a run makes one commit of the whole selection rather than a split.
public enum AssistedCommitSingleCommitReason: String, Sendable, Hashable {
    /// The planner couldn't tell where the boundaries are.
    case uncertainBoundaries = "uncertain-boundaries"
    /// A valid split couldn't be committed in that order (`unsafePlan`).
    case unsafeSplit = "unsafe-split"
    /// Nothing is selected and an empty commit is allowed.
    case emptySelection = "empty-selection"
}

/// A plan Espalier validated against its snapshot, with every cumulative
/// tree made. Only the snapshot that validated it can execute it.
public struct ValidatedAssistedCommitPlan: Sendable {
    public let plan: AssistedCommitPlan
    /// The full tree after each commit, in order.
    public let trees: [String]
    /// The capability the snapshot issued.
    let token: UUID
}

/// The progress of a run, reported at safe boundaries.
public enum AssistedCommitProgress: Sendable, Hashable {
    case capturing
    case validating
    /// Making commit `index` (zero-based) of `total`.
    case committing(index: Int, total: Int, title: String)
    /// Commit `index` is on the branch. Not the end of the run: await the
    /// result.
    case committed(index: Int, total: Int, sha: String)
    case rollingBack
}

/// Cooperative cancellation: checked at safe boundaries, so git that's
/// running finishes and its outcome is recovered.
public final class AssistedCommitCancellation: Sendable {
    private let state = Mutex(false)

    public init() {}

    public func cancel() {
        state.withLock { $0 = true }
    }

    public var isCancelled: Bool {
        state.withLock { $0 }
    }

    /// Throws `cancelled` once cancelled.
    func check() throws(AssistedCommitError) {
        if isCancelled {
            throw AssistedCommitError(.cancelled, "The assisted commit was cancelled.")
        }
    }
}

/// How a run reports and stops.
public struct AssistedCommitOptions: Sendable {
    public var cancellation: AssistedCommitCancellation
    /// Awaited at each boundary.
    public var onProgress: (@Sendable (AssistedCommitProgress) async -> Void)?
    public var onHookProgress: (@Sendable (HookProgress) -> Void)?
    /// Asked whether to abort or ignore a failed hook. Ignoring continues
    /// the commit being made; later commits still run their hooks.
    public var onHookFailure: (@Sendable (_ hookName: String, _ terminalOutput: TerminalOutput) async -> HookFailureResolution)?
    public var onTerminalOutputAvailable: TerminalOutputCallback?

    public init(
        cancellation: AssistedCommitCancellation = AssistedCommitCancellation(),
        onProgress: (@Sendable (AssistedCommitProgress) async -> Void)? = nil,
        onHookProgress: (@Sendable (HookProgress) -> Void)? = nil,
        onHookFailure: (@Sendable (String, TerminalOutput) async -> HookFailureResolution)? = nil,
        onTerminalOutputAvailable: TerminalOutputCallback? = nil
    ) {
        self.cancellation = cancellation
        self.onProgress = onProgress
        self.onHookProgress = onHookProgress
        self.onHookFailure = onHookFailure
        self.onTerminalOutputAvailable = onTerminalOutputAvailable
    }

    func report(_ progress: AssistedCommitProgress) async {
        await onProgress?(progress)
    }
}

/// An assisted commit failed. Never a success-shaped fallback.
public struct AssistedCommitError: Error, LocalizedError, CustomStringConvertible, Sendable {
    public enum Code: String, Sendable, Hashable {
        case cancelled
        /// A selected file changed during the run.
        case selectionChanged = "selection-changed"
        /// HEAD, its branch, or the repository changed during the run.
        case repositoryChanged = "repository-changed"
        /// The repository's index changed during the run.
        case indexChanged = "index-changed"
        /// The plan's shape is wrong: unknown, missing, or repeated IDs,
        /// empty groups, bad titles. Never a reason to fall back.
        case invalidPlan = "invalid-plan"
        /// The selection can't be committed this way.
        case unsafeSelection = "unsafe-selection"
        /// A well-formed plan can't be committed in its order. A fresh
        /// whole-selection message may be used instead.
        case unsafePlan = "unsafe-plan"
        case commitFailed = "commit-failed"
        /// The user aborted a failed hook.
        case hookAborted = "hook-aborted"
        /// Recovery couldn't restore history or the index; see `recovery`.
        case recoveryFailed = "recovery-failed"
        case cleanupFailed = "cleanup-failed"
        case disposed
        case busy
    }

    public let code: Code
    public let message: String
    /// What caused it.
    public let underlying: (any Error)?
    /// What recovery did, for failures while executing.
    public let recovery: AssistedCommitRecovery?

    public init(_ code: Code, _ message: String, underlying: (any Error)? = nil, recovery: AssistedCommitRecovery? = nil) {
        self.code = code
        self.message = message
        self.underlying = underlying
        self.recovery = recovery
    }

    public var errorDescription: String? { message }
    public var description: String { message }

    /// The same error with recovery's outcome.
    func with(recovery: AssistedCommitRecovery) -> AssistedCommitError {
        AssistedCommitError(code, message, underlying: underlying, recovery: recovery)
    }
}

/// What recovery did after a run failed or was cancelled.
public struct AssistedCommitRecovery: Sendable {
    public enum Outcome: String, Sendable, Hashable {
        /// Nothing needed restoring.
        case unchanged
        /// The run's commits were taken off the branch, or the index put
        /// back.
        case restored
        /// Something else changed it, and recovery left it alone.
        case interfered
    }

    /// Every commit the run made and verified, in order.
    public let createdCommits: [String]
    /// HEAD after recovery, or nil when it couldn't be read.
    public let observedHead: AssistedCommitHead?
    public let history: Outcome
    public let index: Outcome
    /// What went wrong while recovering; recovery needs attention when there
    /// are any.
    public let errors: [any Error]
    /// Recovery to try again once the interference is resolved, when it
    /// didn't finish.
    public let retry: AssistedCommitTransaction?

    public var needsAttention: Bool {
        !errors.isEmpty
    }
}

extension AssistedCommitError {
    /// `error` as an assisted commit error: itself, or `code` with it as
    /// the cause.
    static func wrapping(_ error: any Error, _ code: Code, _ message: String) -> AssistedCommitError {
        if let error = error as? AssistedCommitError {
            return error
        }
        return AssistedCommitError(code, message, underlying: error)
    }
}
