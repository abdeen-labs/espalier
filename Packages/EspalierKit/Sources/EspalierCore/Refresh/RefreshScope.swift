/// What a refresh pass loads:
///
/// | Scope | Loads |
/// |---|---|
/// | `status` | `git status`: the tip, ahead/behind, the operation in progress, the changed files |
/// | `refs` | branches, tags, stashes, and what depends on them |
/// | `remotes` | the remotes, and which is the default, current, and upstream one |
/// | `metadata` | when the repository was last fetched, and the other details of the pass's last steps |
///
/// A pass whose status shows a new tip also loads `refs`.
public struct RefreshScope: OptionSet, Sendable, Hashable {
    public let rawValue: UInt8

    public init(rawValue: UInt8) {
        self.rawValue = rawValue
    }

    public static let status = RefreshScope(rawValue: 1 << 0)
    public static let refs = RefreshScope(rawValue: 1 << 1)
    public static let remotes = RefreshScope(rawValue: 1 << 2)
    public static let metadata = RefreshScope(rawValue: 1 << 3)

    public static let full: RefreshScope = [.status, .refs, .remotes, .metadata]
}

extension RefreshScope: CustomStringConvertible {
    public var description: String {
        if self == .full {
            return "full"
        }
        let names: [(RefreshScope, String)] = [(.status, "status"), (.refs, "refs"), (.remotes, "remotes"), (.metadata, "metadata")]
        let included = names.filter { contains($0.0) }.map(\.1)
        return included.isEmpty ? "none" : included.joined(separator: "+")
    }
}

/// How a refresh pass treats what it loads.
public struct RefreshOptions: OptionSet, Sendable, Hashable {
    public let rawValue: UInt8

    public init(rawValue: UInt8) {
        self.rawValue = rawValue
    }

    /// Drop partial (line) selections when reconciling the changed files, as
    /// after a commit.
    public static let clearPartialSelections = RefreshOptions(rawValue: 1 << 0)
}

/// Why a refresh was requested, for logs and tests.
public enum RefreshReason: Sendable, Hashable {
    /// The repository list loaded at launch.
    case launch
    /// The repository became the selected one.
    case selection
    /// The app became the active app.
    case appActivated
    /// The main window became visible again (the watcher was off).
    case windowBecameVisible
    /// The file system watcher saw a change.
    case fileSystem
    /// An operation ended, successfully or not.
    case operation(OperationKind)
    /// The user asked ("Refresh", "Check again").
    case user
    /// Background work, such as the repository indicator updater.
    case background
}
