// Ported from desktop/app/src/models/clone-options.ts

/// Additional arguments to provide when cloning a repository
public struct CloneOptions: Hashable, Sendable {
    /// The branch to checkout after the clone has completed.
    public let branch: String?
    /// The default branch name in case we're cloning an empty repository.
    public let defaultBranch: String?

    public init(branch: String? = nil, defaultBranch: String? = nil) {
        self.branch = branch
        self.defaultBranch = defaultBranch
    }
}
