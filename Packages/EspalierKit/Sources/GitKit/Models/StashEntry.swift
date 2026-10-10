// Ported from desktop/app/src/models/stash-entry.ts

public struct StashEntry: Hashable, Sendable {
    /// The fully qualified name of the entry i.e., `refs/stash@{0}`
    public let name: String

    /// The name of the branch at the time the entry was created.
    public let branchName: String

    /// The SHA of the commit object created as a result of stashing.
    public let stashSha: String

    /// The list of files this stash touches
    public let files: StashedFileChanges

    public let tree: String
    public let parents: [String]

    public init(
        name: String,
        branchName: String,
        stashSha: String,
        files: StashedFileChanges,
        tree: String,
        parents: [String]
    ) {
        self.name = name
        self.branchName = branchName
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

public typealias StashCallback = @Sendable (StashEntry) async throws -> Void
