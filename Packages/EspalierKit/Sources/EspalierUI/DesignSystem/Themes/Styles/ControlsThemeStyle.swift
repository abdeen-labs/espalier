/// Controls shared across the app: checkboxes, radios, tooltips, menus, toasts,
/// the command palette, and the titles of sheets, alerts, popovers, and
/// empty states.
nonisolated public struct ControlsThemeStyle: Sendable, Equatable {
    /// How checkboxes and radio marks draw.
    public enum Checkbox: Sendable, Equatable {
        /// Chunky, 18 points: an empty box in a rim thicker along its
        /// bottom, a checked one standing on a lip, popping when toggled.
        case key
        /// Flat, 15 points: a 1-point border, or a flat accent fill.
        case flat
    }

    /// A tooltip's card.
    public enum Tooltip: Sendable, Equatable {
        /// A pill while it's one line high, its text in primary color.
        case pill
        /// A small card with the row radius, its text in secondary color.
        case card
    }

    /// A menu's rows, section headers, and dividers.
    public enum Menu: Sendable, Equatable {
        /// 30-point rows, headers as soft titles, rounded rules.
        case roomy
        /// 24-point rows, headers as section labels, plain rules.
        case compact
    }

    /// A toast.
    public enum Toast: Sendable, Equatable {
        /// A pillow with a round badge saying what happened, Undo a quiet
        /// pillow button.
        case pillow
        /// A capsule with a colored symbol, Undo a secondary capsule.
        case capsule
    }

    /// The titles of sheets, alerts, popovers, and empty states.
    public enum Titles: Sendable, Equatable {
        /// The display type, bold and larger.
        case display
        /// The system's sizes, semibold.
        case system
    }

    /// The command palette's search field and rows.
    public enum CommandPalette: Sendable, Equatable {
        /// A large medium-weight field and roomy rows with medium titles.
        case roomy
        /// A 15-point field and list-height rows with regular titles.
        case compact
    }

    public var checkbox: Checkbox
    public var tooltip: Tooltip
    public var menu: Menu
    public var toast: Toast
    public var titles: Titles
    public var commandPalette: CommandPalette

    /// Default's.
    public static let `default` = ControlsThemeStyle(
        checkbox: .key,
        tooltip: .pill,
        menu: .roomy,
        toast: .pillow,
        titles: .display,
        commandPalette: .roomy
    )
    /// Frost's.
    public static let frost = ControlsThemeStyle(
        checkbox: .flat,
        tooltip: .card,
        menu: .compact,
        toast: .capsule,
        titles: .system,
        commandPalette: .compact
    )
}
