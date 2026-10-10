// Ported from desktop/app/src/models/multi-commit-operation.ts
//
// Only the operation kind, which GitSquash.swift and GitReorder.swift use.

/// Enum of types of multi commit operations
///
/// Note: These are used to output the operation to the user
/// and as such should be capitalized.
public enum MultiCommitOperationKind: String, Hashable, Sendable {
    case rebase = "Rebase"
    case cherryPick = "Cherry-pick"
    case squash = "Squash"
    case merge = "Merge"
    case reorder = "Reorder"
    /// A revert that stopped on conflicts waits for the user like the
    /// others.
    case revert = "Revert"
}
