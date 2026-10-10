/// Which commits the history shows. Remembered per repository, in its
/// record.
public enum HistoryScope: String, Sendable, Hashable, CaseIterable, Codable {
    /// HEAD's commits.
    case currentBranch
    /// HEAD's commits, every local branch's, and each local branch's
    /// upstream's.
    case localBranches
    /// HEAD's commits and those of every local and remote branch and tag.
    case allBranches

    /// The scope a repository starts with.
    public static let defaultScope = HistoryScope.localBranches

    /// The scope's name in menus.
    public var title: String {
        switch self {
        case .currentBranch: "Current Branch"
        case .localBranches: "Local Branches"
        case .allBranches: "All Branches"
        }
    }
}
