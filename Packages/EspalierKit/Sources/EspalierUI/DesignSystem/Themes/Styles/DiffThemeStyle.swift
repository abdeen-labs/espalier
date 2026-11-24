/// The diff: its lines, gutter, line numbers, hunk headers, and expand buttons.
nonisolated public struct DiffThemeStyle: Sendable, Equatable {
    /// How changed lines' numbers are colored.
    public enum ChangedLineNumbers: Sendable, Equatable {
        /// An added line's in a soft add, a deleted line's in a soft delete.
        case colored
        /// In the same gray as context lines'.
        case gray
    }

    /// How a hunk header's expand buttons are drawn.
    public enum ExpansionButtons: Sendable, Equatable {
        /// Chevrons on capsule pillows, darker under the pointer.
        case pillows
        /// Bare chevrons, a rounded wash under the pointer.
        case bare
    }

    /// How the file header shows the file.
    public enum FileHeader: Sendable, Equatable {
        /// The status tile, then the name as a pane heading and the folder.
        case tile
        /// The name and the folder in row type, the status the path's
        /// tooltip.
        case plain
    }

    /// How changed lines' numbers are colored.
    public var changedLineNumbers: ChangedLineNumbers
    /// How a hunk header's expand buttons are drawn.
    public var expansionButtons: ExpansionButtons
    /// How the file header shows the file.
    public var fileHeader: FileHeader

    /// Default's.
    public static let `default` = DiffThemeStyle(
        changedLineNumbers: .colored,
        expansionButtons: .pillows,
        fileHeader: .tile
    )
    /// Frost's.
    public static let frost = DiffThemeStyle(
        changedLineNumbers: .gray,
        expansionButtons: .bare,
        fileHeader: .plain
    )
}
