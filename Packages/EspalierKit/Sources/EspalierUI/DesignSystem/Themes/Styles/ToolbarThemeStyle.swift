/// The main window's toolbar: the location control, the sync button and its
/// label, the Changes / History switcher, and the shelf of work under it.
nonisolated public struct ToolbarThemeStyle: Sendable, Equatable {
    /// The location control's capsule.
    public enum LocationControl: Sendable, Equatable {
        /// A raised pillow on its lip, the repository's name in bold.
        case pillow
        /// A flat quiet capsule of the toolbar's height, its names in the
        /// button font.
        case flat
    }

    /// How the sync button shows its counts ("↑2").
    public enum SyncCounts: Sendable, Equatable {
        /// In a pill of the capsule's own ink.
        case pill
        /// As plain text after the title.
        case text
    }

    /// The Changes / History switcher shown while the sidebar is hidden.
    public enum PlaceSwitcher: Sendable, Equatable {
        /// Two tabs on a hover-wash track, the selected one on the
        /// sidebar's selection.
        case tabs
        /// The capsule segmented control's look: the selected segment
        /// raised off its track.
        case segmented
    }

    /// The shelf's tabs (`WorkShelf`). The open work's tab is raised, as
    /// the capsule segmented control's selected segment, in either.
    public enum ShelfTabs: Sendable, Equatable {
        /// Soft cards on the backdrop, the branch in the text font.
        case cards
        /// Flat, split by hairlines, the branch in the code font.
        case flat
    }

    public var locationControl: LocationControl
    public var syncCounts: SyncCounts
    public var placeSwitcher: PlaceSwitcher
    public var shelfTabs: ShelfTabs

    /// Default's.
    public static let `default` = ToolbarThemeStyle(locationControl: .pillow, syncCounts: .pill, placeSwitcher: .tabs, shelfTabs: .cards)
    /// Frost's.
    public static let frost = ToolbarThemeStyle(locationControl: .flat, syncCounts: .text, placeSwitcher: .segmented, shelfTabs: .flat)
}
