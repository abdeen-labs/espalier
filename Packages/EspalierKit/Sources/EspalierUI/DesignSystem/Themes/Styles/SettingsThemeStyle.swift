import CoreGraphics

/// The Settings window: its sidebar, pane titles, and groups.
nonisolated public struct SettingsThemeStyle: Sendable, Equatable {
    /// The sidebar's rows.
    public enum Sidebar: Sendable, Equatable {
        /// Each pane's symbol on its colored tile, in 34-point rows.
        case tiles
        /// Each pane's plain symbol, as the main window's sidebar draws its
        /// rows, at their height.
        case symbols
    }

    /// The panes' groups.
    public enum Groups: Sendable, Equatable {
        /// Cards spaced apart, each under its bold title.
        case cards
        /// Split by hairlines, each under a section label.
        case hairlines
    }

    /// A pane's name in its header band.
    public enum PaneTitle: Sendable, Equatable {
        /// The display type, 22 bold.
        case display
        /// The headline, 13 bold.
        case headline
    }

    public var sidebar: Sidebar
    public var groups: Groups
    public var paneTitle: PaneTitle
    /// The window's width, and its sidebar's.
    public var windowWidth: CGFloat
    public var sidebarWidth: CGFloat

    /// Default's.
    public static let `default` = SettingsThemeStyle(
        sidebar: .tiles,
        groups: .cards,
        paneTitle: .display,
        windowWidth: 760,
        sidebarWidth: 200
    )
    /// Frost's.
    public static let frost = SettingsThemeStyle(
        sidebar: .symbols,
        groups: .hairlines,
        paneTitle: .headline,
        windowWidth: 720,
        sidebarWidth: 180
    )
}
