/// Changes: the file list's header and rows, the stash row, notes, and the
/// composer with its commit button and last commit row.
nonisolated public struct ChangesThemeStyle: Sendable, Equatable {
    /// Default's.
    public static let `default` = ChangesThemeStyle()
    /// Frost's.
    public static let frost = ChangesThemeStyle()
}
