// Ported from desktop/app/src/models/merge.ts

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
