import GitKit

/// What the repository list shows for a repository: how far its branch is
/// ahead of and behind its upstream, and how many files changed.
public struct RepositoryIndicator: Sendable, Equatable {
    /// Nil when the branch has no upstream (or the tip isn't a branch).
    public var aheadBehind: AheadBehind?
    public var changedFilesCount: Int

    public init(aheadBehind: AheadBehind?, changedFilesCount: Int) {
        self.aheadBehind = aheadBehind
        self.changedFilesCount = changedFilesCount
    }

    /// The indicator for a status result.
    public init(_ status: StatusResult) {
        self.init(aheadBehind: status.branchAheadBehind, changedFilesCount: status.workingDirectory.files.count)
    }
}
