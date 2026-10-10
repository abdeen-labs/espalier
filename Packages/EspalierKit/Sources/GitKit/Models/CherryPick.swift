// Ported from desktop/app/src/models/cherry-pick.ts

/// Represents a snapshot of the cherry pick state from the Git repository
public struct CherryPickSnapshot: Hashable, Sendable {
    /// The sequence of commits remaining to be cherry picked
    public let remainingCommits: [CommitOneLine]
    /// The sequence of commits being cherry picked
    public let commits: [CommitOneLine]
    /// The progress of the operation
    public let progress: MultiCommitOperationProgress
    /// The sha of the target branch tip before cherry pick initiated.
    public let targetBranchUndoSha: String
    /// The number of commits already cherry-picked
    public let cherryPickedCount: Int

    public init(
        remainingCommits: [CommitOneLine],
        commits: [CommitOneLine],
        progress: MultiCommitOperationProgress,
        targetBranchUndoSha: String,
        cherryPickedCount: Int
    ) {
        self.remainingCommits = remainingCommits
        self.commits = commits
        self.progress = progress
        self.targetBranchUndoSha = targetBranchUndoSha
        self.cherryPickedCount = cherryPickedCount
    }
}
