// Ported from desktop/app/src/models/stash-entry.ts

public struct StashEntry: Hashable, Sendable {
    /// The fully qualified name of the entry when it was listed, i.e.
    /// `refs/stash@{0}`. Indices shift as entries are pushed and dropped, so
    /// commands find the entry by `stashSha` when they run.
    public let name: String

    /// The branch in the entry's marker (`!!Espalier<branch>` or
    /// `!!GitHub_Desktop<branch>`): the branch it was created for. Nil for
    /// an entry made outside the app.
    public let branchName: String?

    /// Git's message for the entry, as `git stash list` shows it: "On main:
    /// fix login", "WIP on main: a1b2c3d Subject".
    public let message: String

    /// The SHA of the commit object created as a result of stashing.
    public let stashSha: String

    /// The list of files this stash touches
    public let files: StashedFileChanges

    public let tree: String
    public let parents: [String]

    public init(
        name: String,
        branchName: String?,
        message: String,
        stashSha: String,
        files: StashedFileChanges,
        tree: String,
        parents: [String]
    ) {
        self.name = name
        self.branchName = branchName
        self.message = message
        self.stashSha = stashSha
        self.files = files
        self.tree = tree
        self.parents = parents
    }
}

/// Whether file changes for a stash entry are loaded or not
public enum StashedChangesLoadStates: String, Hashable, Sendable {
    case notLoaded = "NotLoaded"
    case loading = "Loading"
    case loaded = "Loaded"
}

/// The status of stashed file changes
///
/// When the status us `Loaded` all the files associated
/// with the stash are made available.
public enum StashedFileChanges: Hashable, Sendable {
    case notLoaded
    case loading
    case loaded(files: [CommittedFileChange])

    public var kind: StashedChangesLoadStates {
        switch self {
        case .notLoaded: .notLoaded
        case .loading: .loading
        case .loaded: .loaded
        }
    }
}
