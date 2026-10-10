// Which commit a stopped rebase or cherry-pick is at ("Stopped at commit 2
// of 4"), as git's own state files say (`getRebaseStep`,
// `getCherryPickStep`).

/// Which step of an operation git stopped at.
public struct OperationStep: Hashable, Sendable {
    /// The step it stopped at, counting from 1.
    public let position: Int
    /// The steps in all.
    public let total: Int

    public init(position: Int, total: Int) {
        self.position = position
        self.total = total
    }
}
