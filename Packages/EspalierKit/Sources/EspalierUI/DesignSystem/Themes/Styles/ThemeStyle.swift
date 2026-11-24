// What each area of the app draws its own way in a theme: one small struct
// per area, each in its own file here, with a value for Default
// (`.default`) and one for Frost (`.frost`). Views read their area's from
// `Theme.current.style` and never ask which theme is current.

/// What each area of the app draws its own way in a theme.
nonisolated public struct ThemeStyle: Sendable, Equatable {
    public var toolbar: ToolbarStyle
    public var sidebar: SidebarStyle
    public var changes: ChangesStyle
    public var diff: DiffStyle
    public var history: HistoryStyle
    public var controls: ControlsStyle
    public var settings: SettingsStyle

    /// Default's.
    public static let `default` = ThemeStyle(
        toolbar: .default,
        sidebar: .default,
        changes: .default,
        diff: .default,
        history: .default,
        controls: .default,
        settings: .default
    )

    /// Frost's.
    public static let frost = ThemeStyle(
        toolbar: .frost,
        sidebar: .frost,
        changes: .frost,
        diff: .frost,
        history: .frost,
        controls: .frost,
        settings: .frost
    )
}
