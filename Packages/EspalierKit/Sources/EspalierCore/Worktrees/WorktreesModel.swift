// The operations are in WorktreeOperations.swift and
// WorktreeSwitching.swift.

import EspalierSupport
import GitKit
import Observation

/// Adding a worktree.
///
/// By default the worktree checks out the branch `branchName` names
/// (`WorktreesModel.branchResolution(for:path:)`). Setting `createBranch`
/// or `commitish` asks git for exactly that instead
/// (`git worktree add [-b <createBranch>] -- <path> [<commitish>]`).
public struct AddWorktreeRequest: Sendable, Equatable {
    /// The new worktree's folder, an absolute path: the Local Path joined
    /// with the worktree's name (`worktreePath(in:name:)`).
    public var path: String
    /// The branch to check out: an existing local branch is checked out, a
    /// remote branch (`origin/feature`, or `feature` when exactly one remote
    /// has it) gets a local branch that tracks it (or, when a local branch
    /// tracks it already, that one is checked out), and any other name
    /// becomes a new branch at the current commit. Nil or empty: the folder's
    /// name, as a branch name.
    public var branchName: String?
    /// A branch to create for the worktree (`-b`).
    public var createBranch: String?
    /// What to check out, or where the new branch starts.
    public var commitish: String?

    /// What's wrong with a folder that isn't a full path.
    public static let notFullPathMessage = "Choose the folder for the worktree by its full path."

    public init(path: String, branchName: String? = nil, createBranch: String? = nil, commitish: String? = nil) {
        self.path = path
        self.branchName = branchName
        self.createBranch = createBranch
        self.commitish = commitish
    }

    /// Whether `createBranch` or `commitish` asks for git's arguments
    /// directly.
    var isExplicit: Bool {
        !(createBranch ?? "").isEmpty || !(commitish ?? "").isEmpty
    }
}

/// What a new worktree checks out for a branch name, with its hint.
public enum WorktreeBranchResolution: Sendable, Equatable {
    /// An existing local branch.
    case existing(Branch)
    /// A remote branch, as a new local branch of the same name without the
    /// remote that tracks it.
    case remote(Branch)
    /// A new branch at the current commit.
    case new(name: String)

    /// The local branch the worktree will have checked out.
    public var branchName: String {
        switch self {
        case .existing(let branch): branch.name
        case .remote(let branch): branch.nameWithoutRemote
        case .new(let name): name
        }
    }

    /// The hint under the branch name, nil for a new branch.
    public var hint: String? {
        switch self {
        case .existing(let branch): "Will check out existing branch \(branch.name)."
        case .remote(let branch): "Will check out remote branch \(branch.name)."
        case .new: nil
        }
    }
}

/// The repository's worktrees.
///
/// The list comes from the refresh (`gitState.worktrees`, `git worktree
/// list`), the main worktree first. A worktree is switched to by pointing
/// the repository's record at its folder, which keeps the record, its
/// model, and what worktrees share.
@MainActor @Observable
public final class WorktreesModel: RepositoryFeature {
    @ObservationIgnored weak var repository: RepositoryModel?

    init() {}

    func attach(to repository: RepositoryModel) {
        self.repository = repository
    }

    /// The worktrees, the main one first.
    public var entries: [WorktreeEntry] {
        repository?.gitState.worktrees ?? []
    }

    /// The main worktree.
    public var main: WorktreeEntry? {
        entries.first { $0.type == .main }
    }

    /// The linked worktrees.
    public var linked: [WorktreeEntry] {
        entries.filter { $0.type == .linked }
    }

    /// The worktree the repository is at.
    public var current: WorktreeEntry? {
        guard let repository else {
            return nil
        }
        let path = POSIXPath.normalize(repository.record.path)
        if let entry = entries.first(where: { JSCompat.strictEquals(POSIXPath.normalize($0.path), path) }) {
            return entry
        }
        // Git lists real paths; the refresher resolved the record's.
        guard let realPath = repository.watchedPaths?.workingDirectory else {
            return nil
        }
        return entries.first { JSCompat.strictEquals(POSIXPath.normalize($0.path), realPath) }
    }

    /// Whether the worktree list shows: with more than one worktree, or with
    /// "Always show worktree list" on (`shouldShowWorktreeDropdown`, closed).
    public var isListVisible: Bool {
        shouldShowWorktreeDropdown(entries.count, false, repository?.app?.preferences.alwaysShowWorktreeList ?? false)
    }

    /// Whether the worktree can be renamed or moved: not the main one, and
    /// not locked.
    public func canRename(_ worktree: WorktreeEntry) -> Bool {
        worktree.type == .linked && !worktree.isLocked
    }

    /// Whether the worktree can be deleted: not the main one, and not
    /// locked.
    public func canRemove(_ worktree: WorktreeEntry) -> Bool {
        worktree.type == .linked && !worktree.isLocked
    }

    /// Whether the worktree's folder is gone, looked at now rather than at
    /// the last refresh: git keeps the worktree, and counts its branch as
    /// checked out, until it's removed. A locked worktree isn't missing:
    /// locking keeps one whose folder is on a drive that isn't connected. (A
    /// folder that's there without its `.git` file is one git lists as
    /// prunable too, but won't remove, so it isn't missing here.)
    public nonisolated func isMissing(_ worktree: WorktreeEntry) -> Bool {
        worktree.type == .linked && !worktree.isLocked && !itemExists(atPath: worktree.path)
    }

    // MARK: Adding

    /// The folder new worktrees go in unless the user picks another: the
    /// last folder cloned into, `~/Developer` at first.
    public var defaultDirectory: String? {
        repository?.app?.preferences.lastCloneLocation
    }

    /// The new worktree's folder: `name` in `directory`, a leading `~` in
    /// `directory` as the home folder; nil while either is empty.
    public nonisolated static func worktreePath(in directory: String, name: String) -> String? {
        guard !directory.isEmpty, !JSCompat.trim(name).isEmpty else {
            return nil
        }
        return POSIXPath.join(expandingTilde(directory), name)
    }

    /// The name suggested for a worktree that checks out `branch` ("Check
    /// Out in New Worktree…"): the repository's name and the branch's.
    public func suggestedName(for branch: Branch) -> String {
        "\(repository?.record.name ?? "worktree")-\(branch.nameWithoutRemote)"
    }

    /// The name suggested for a worktree that checks out pull request
    /// `number`.
    public func suggestedName(forPullRequest number: Int) -> String {
        "\(repository?.record.name ?? "worktree")-\(number)"
    }

    /// The branch a worktree at `path` checks out for `branchName` (empty:
    /// the folder's name), from the branches the last refresh loaded; nil
    /// when there's no name to use.
    public func branchResolution(for branchName: String?, path: String) -> WorktreeBranchResolution? {
        guard let name = Self.effectiveBranchName(branchName, path: path) else {
            return nil
        }
        return Self.resolveBranch(name, in: repository?.gitState.branches.all ?? [])
    }

    /// The branch name a new worktree uses: the one given, sanitized as a
    /// ref name, else the folder's name.
    nonisolated static func effectiveBranchName(_ branchName: String?, path: String) -> String? {
        let given = sanitizedRefName(branchName ?? "")
        let name = given.isEmpty ? sanitizedRefName(POSIXPath.basename(path)) : given
        return name.isEmpty ? nil : name
    }

    /// What a worktree checks out for `name`, among `branches` (local
    /// branches and the remote branches no local branch tracks).
    ///
    /// A branch with that name, local or remote, is checked out. Besides:
    /// - A remote branch that a local branch tracks isn't in the list; its
    ///   name (`origin/feature`) checks out the local branch that tracks it
    ///   (the one with the same name first), rather than a new local branch
    ///   named `origin/feature`.
    /// - A name that's no branch's but exactly one remote's branch name
    ///   (`feature` for `origin/feature`) checks that remote branch out, as
    ///   git does for `git worktree add <path> <branch>`, so "Check Out in New
    ///   Worktree…" on a pull request's branch starts from its commit. (A
    ///   remote branch a local branch tracks isn't a candidate: it isn't
    ///   listed.)
    nonisolated static func resolveBranch(_ name: String, in branches: [Branch]) -> WorktreeBranchResolution {
        if let branch = branches.first(where: { JSCompat.strictEquals($0.name, name) }) {
            return branch.type == .remote ? .remote(branch) : .existing(branch)
        }
        let tracking = branches.filter { branch in
            branch.type == .local && branch.upstream.map { JSCompat.strictEquals($0, name) } == true
        }
        if let local = tracking.first(where: { JSCompat.strictEquals($0.name, $0.upstreamWithoutRemote ?? "") }) ?? tracking.first {
            return .existing(local)
        }
        let remotes = branches.filter { $0.type == .remote && JSCompat.strictEquals($0.nameWithoutRemote, name) }
        if remotes.count == 1 {
            return .remote(remotes[0])
        }
        return .new(name: name)
    }
}
