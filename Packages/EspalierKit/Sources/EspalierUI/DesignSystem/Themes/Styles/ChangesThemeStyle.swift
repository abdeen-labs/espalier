/// Changes: the file list's header and rows, the stash row, notes, and the
/// composer with its commit button and last commit row.
nonisolated public struct ChangesThemeStyle: Sendable, Equatable {
    /// A file's status badge (`StatusGlyph`, and the file rows' twin).
    public enum StatusBadge: Sendable, Equatable {
        /// A 20-point rounded tile of the status's tint, its letter in the
        /// code font.
        case tile
        /// A 17-point square on a faint tint, its letter in the system's
        /// monospaced font; a resolved conflict shows a green check.
        case square
    }

    /// The pieces of the Changes column: the header, the list, the notes
    /// and the Stashed Changes row under it, the composer, and the last
    /// commit row.
    public enum Panes: Sendable, Equatable {
        /// Soft cards stacked under the list, no rules: the hidden-files
        /// note and the warnings as tinted banners, the stash row and the
        /// last commit row as cards, the composer's fields in one note
        /// card, and the pillow commit button with the branch as a pill.
        case cards
        /// Hairlines between the pieces: the header, the list, the stash
        /// row, and the composer; notes and warnings as a symbol and text,
        /// the stash row and the last commit row as plain rows, the
        /// composer's fields split by hairlines, and the prominent capsule
        /// commit button with the branch in bold.
        case hairlines
    }

    /// The line counts on file rows.
    public enum LineCounts: Sendable, Equatable {
        /// "+10" and "−2" on two small tinted pills.
        case pills
        /// "+10 −2" as one run of colored text.
        case text
    }

    /// The file rows' size and the names' weight.
    public enum FileRows: Sendable, Equatable {
        /// 38 at the default text size, names semibold.
        case roomy
        /// 30 at the default text size, names medium.
        case compact
    }

    /// The screen when there's nothing to commit.
    public enum NoChanges: Sendable, Equatable {
        /// "Nothing to Commit" over the check on its tiles, the primary
        /// suggestion as one wide card and the others as square cards.
        case cards
        /// "No Local Changes" under the check in a soft circle, the
        /// suggestions as rows in one card with their descriptions.
        case rows
    }

    public var statusBadge: StatusBadge
    public var panes: Panes
    public var lineCounts: LineCounts
    public var fileRows: FileRows
    public var noChanges: NoChanges

    /// The current theme's.
    public static var current: ChangesThemeStyle {
        Theme.current.style.changes
    }

    /// Default's.
    public static let `default` = ChangesThemeStyle(
        statusBadge: .tile,
        panes: .cards,
        lineCounts: .pills,
        fileRows: .roomy,
        noChanges: .cards
    )
    /// Frost's.
    public static let frost = ChangesThemeStyle(
        statusBadge: .square,
        panes: .hairlines,
        lineCounts: .text,
        fileRows: .compact,
        noChanges: .rows
    )
}
