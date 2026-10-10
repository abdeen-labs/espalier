// Ported from desktop/app/src/models/merge.ts

public struct BlobResult: Hashable, Sendable {
    public let mode: String
    public let sha: String
    public let path: String

    public init(mode: String, sha: String, path: String) {
        self.mode = mode
        self.sha = sha
        self.path = path
    }
}

public struct MergeTreeEntry: Hashable, Sendable {
    public let context: String
    public let base: BlobResult?
    public let result: BlobResult?
    public let our: BlobResult?
    public let their: BlobResult?
    public let diff: String
    public let hasConflicts: Bool?

    public init(
        context: String,
        base: BlobResult? = nil,
        result: BlobResult? = nil,
        our: BlobResult? = nil,
        their: BlobResult? = nil,
        diff: String,
        hasConflicts: Bool? = nil
    ) {
        self.context = context
        self.base = base
        self.result = result
        self.our = our
        self.their = their
        self.diff = diff
        self.hasConflicts = hasConflicts
    }
}

/// Whether a merge would be clean. The cases are its `kind`.
public enum MergeTreeResult: Hashable, Sendable {
    /// The merge would be clean.
    case clean
    /// The merge would conflict.
    case conflicts(conflictedFiles: Int)
    /// The merge can't be done.
    case invalid
    /// Still being computed.
    case loading

    public var kind: ComputedAction {
        switch self {
        case .clean: .clean
        case .conflicts: .conflicts
        case .invalid: .invalid
        case .loading: .loading
        }
    }
}
