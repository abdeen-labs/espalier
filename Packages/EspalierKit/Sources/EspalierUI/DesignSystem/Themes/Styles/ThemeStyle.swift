// What each area of the app draws its own way in a theme: one small struct
// per area, each in its own file here, with a value for Default
// (`.default`) and one for Frost (`.frost`). Views read their area's from
// `Theme.current.style` and never ask which theme is current.

import CoreGraphics

/// What each area of the app draws its own way in a theme.
nonisolated public struct ThemeStyle: Sendable, Equatable {
    public var toolbar: ToolbarThemeStyle
    public var sidebar: SidebarThemeStyle
    public var changes: ChangesThemeStyle
    public var diff: DiffThemeStyle
    public var history: HistoryThemeStyle
    public var controls: ControlsThemeStyle
    public var settings: SettingsThemeStyle
    /// The height of the header row atop a column and atop the diff.
    public var paneHeaderHeight: CGFloat

    /// Default's.
    public static let `default` = ThemeStyle(
        toolbar: .default,
        sidebar: .default,
        changes: .default,
        diff: .default,
        history: .default,
        controls: .default,
        settings: .default,
        paneHeaderHeight: 46
    )

    /// Frost's.
    public static let frost = ThemeStyle(
        toolbar: .frost,
        sidebar: .frost,
        changes: .frost,
        diff: .frost,
        history: .frost,
        controls: .frost,
        settings: .frost,
        paneHeaderHeight: 40
    )
}
