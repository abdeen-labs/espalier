// Settings ▸ Appearance: the theme (Classic, Frost, Islands, Pop) and the
// app font; colors (the palette, System's the Mac's accent color, on any
// theme; the background tint; the appearance, System, Light, or Dark); code
// (the code font, its text size, the diff's tab size), dates and numbers,
// accessibility, and the sidebar (its style, hidden or icons, and the
// worktree list). Each font's name in its pop-up is drawn in that font. The
// code text size steps through the same sizes as View ▸ Bigger (⌘=) and
// Smaller (⌘−).

import EspalierCore
import GitKit
import SwiftUI

/// Settings ▸ Appearance.
public struct AppearancePane: View {
    private let model: AppModel?

    public init(model: AppModel?) {
        self.model = model
    }

    public var body: some View {
        if let model {
            AppearanceForm(preferences: model.preferences)
        } else {
            SettingsPanePlaceholder(tab: .appearance)
        }
    }
}

/// The Appearance pane's values and copy.
enum AppearanceSettings {
    /// The appearance's choices, in order.
    static let themes = ApplicationTheme.allCases.map { CapsuleSegment($0.title, value: $0) }

    /// The sidebar's styles, in order.
    static let sidebarStyles = [
        CapsuleSegment("Hidden", value: SidebarStyle.hidden),
        CapsuleSegment("Icons", value: SidebarStyle.icons),
    ]

    /// What a sidebar style does.
    static func sidebarStyleDescription(_ style: SidebarStyle) -> String {
        switch style {
        case .hidden:
            "Windows open without the sidebar, with Changes and History in the toolbar. View ▸ Show Sidebar shows it."
        case .icons:
            "A narrow bar of icons. Branches, pull requests, tags, and stashes open beside it."
        }
    }

    /// The diff tab sizes; 4 is the default.
    static let tabSizes = [1, 2, 3, 4, 5, 6, 8, 10, 12]
    static let defaultTabSize = 4

    /// The tab sizes to offer: `tabSizes`, plus a stored size that isn't one
    /// of them, so the pop-up always shows the current value.
    static func tabSizes(including current: Int) -> [Int] {
        tabSizes.contains(current) ? tabSizes : (tabSizes + [current]).sorted()
    }

    /// A tab size's title ("4 (default)").
    static func tabSizeTitle(_ size: Int) -> String {
        size == defaultTabSize ? "\(size) (default)" : "\(size)"
    }

    /// The code text size as a percentage of the actual size ("125%").
    static func percentage(_ size: CodeTextSize) -> String {
        "\(Int((size.factor * 100).rounded()))%"
    }

    /// A number format's preview: 1234567.89 formatted.
    static func numberFormatExample(_ format: NumberFormat) -> String {
        formatNumber(1_234_567.89, format)
    }

    /// A date or time format's title: "Oct 19, 2017 (MMM d, yyyy)".
    static func formatTitle(example: String, pattern: String) -> String {
        "\(example) (\(pattern))"
    }
}

/// The Appearance pane: the theme and the app font; the palette, the
/// background tint, and the appearance; code (its font, text size, and tab
/// size), dates and numbers, accessibility, and the sidebar.
struct AppearanceForm: View {
    @Bindable var preferences: Preferences
    @Environment(\.motion) private var motion

    var body: some View {
        SettingsPage {
            SettingsSection("Theme") {
                SettingsRow("Theme") {
                    EmptyView()
                } footer: {
                    ThemeCardPicker(
                        selection: $preferences.designTheme,
                        palette: preferences.designPalette,
                        background: preferences.designBackground
                    )
                    .padding(.vertical, Metrics.FocusRing.outset)
                }
                SettingsRow("Font", labelsControl: true) {
                    CapsulePopUp("Font", selection: $preferences.appFont, title: preferences.appFont.title) {
                        for font in AppFont.allCases {
                            MenuChoice(font.title, value: font)
                                .titleFont(Typography.sans(.body, in: font))
                        }
                    }
                    .fixedSize()
                }
            }

            SettingsSection("Colors") {
                SettingsRow("Palette", description: preferences.designPalette.summary) {
                    SwatchPicker("Palette", values: DesignPalette.allCases, selection: $preferences.designPalette, title: \.title) { palette in
                        Theme.named(preferences.designTheme, palette: palette).accent
                    }
                }
                // The chosen palette's name, and the background's below,
                // crossfade with the swatch's motion.
                .contentTransition(motion.animates ? .opacity : .identity)
                SettingsRow("Background", description: preferences.designThemeBackground.title) {
                    SwatchPicker("Background", values: preferences.designTheme.backgrounds, selection: designBackground, title: \.title) { tint in
                        Theme.named(preferences.designTheme, palette: preferences.designPalette, background: tint).backgroundSwatch
                    }
                }
                .contentTransition(motion.animates ? .opacity : .identity)
                SettingsRow("Appearance", labelsControl: true) {
                    CapsuleSegmentedControl("Appearance", selection: $preferences.theme, segments: AppearanceSettings.themes)
                        .fixedSize()
                }
            }

            SettingsSection("Code") {
                SettingsRow("Font", labelsControl: true) {
                    CapsulePopUp("Code font", selection: $preferences.codeFont, title: preferences.codeFont.title) {
                        for font in CodeFont.allCases {
                            MenuChoice(font.title, value: font)
                                .titleFont(Typography.mono(size: TextStyleSizes.size(of: .body), in: font))
                        }
                    }
                    .fixedSize()
                }
                SettingsRow("Text size", description: "View ▸ Bigger (⌘=) and Smaller (⌘−) change it too.", labelsControl: true) {
                    CapsuleStepper(
                        "Text size",
                        value: AppearanceSettings.percentage(preferences.codeTextSize),
                        canDecrement: !preferences.codeTextSize.isSmallest,
                        canIncrement: !preferences.codeTextSize.isLargest,
                        decrement: { preferences.decreaseCodeTextSize() },
                        increment: { preferences.increaseCodeTextSize() }
                    )
                }
                SettingsRow("Diff tab size", labelsControl: true) {
                    CapsulePopUp("Diff tab size", selection: $preferences.tabSize, title: AppearanceSettings.tabSizeTitle(preferences.tabSize)) {
                        for size in AppearanceSettings.tabSizes(including: preferences.tabSize) {
                            MenuChoice(AppearanceSettings.tabSizeTitle(size), value: size)
                        }
                    }
                    .settingsControlWidth()
                }
            }

            SettingsSection("Dates and numbers") {
                SettingsToggleRow("Prefer absolute dates over relative", isOn: $preferences.preferAbsoluteDates)
                SettingsRow("Date format", labelsControl: true) {
                    CapsulePopUp(
                        "Date format",
                        selection: dateFormat,
                        title: Self.title(dateFormat.wrappedValue),
                        fitting: DateFormatPattern.allCases.map(Self.title)
                    ) {
                        for format in DateFormatPattern.allCases {
                            MenuChoice(Self.title(format), value: format)
                        }
                    }
                    .settingsControlWidthFittingChoices()
                }
                SettingsRow("Time format", labelsControl: true) {
                    CapsulePopUp(
                        "Time format",
                        selection: timeFormat,
                        title: Self.title(timeFormat.wrappedValue),
                        fitting: TimeFormatPattern.allCases.map(Self.title)
                    ) {
                        for format in TimeFormatPattern.allCases {
                            MenuChoice(Self.title(format), value: format)
                        }
                    }
                    .settingsControlWidthFittingChoices()
                }
                SettingsRow("Number format", labelsControl: true) {
                    CapsulePopUp("Number format", selection: $preferences.numberFormat, title: AppearanceSettings.numberFormatExample(preferences.numberFormat)) {
                        for format in numberFormats {
                            MenuChoice(AppearanceSettings.numberFormatExample(format), value: format)
                        }
                    }
                    .settingsControlWidth()
                }
            }

            SettingsSection("Accessibility") {
                SettingsToggleRow(
                    "Underline links",
                    description: "Underlines links in commit messages, comments, and other text, so they're easier to tell apart.",
                    isOn: $preferences.underlineLinks
                )
            }

            SettingsSection("Sidebar") {
                SettingsRow("Style", description: AppearanceSettings.sidebarStyleDescription(preferences.sidebarStyle), labelsControl: true) {
                    CapsuleSegmentedControl("Style", selection: $preferences.sidebarStyle, segments: AppearanceSettings.sidebarStyles)
                        .fixedSize()
                }
                .contentTransition(motion.animates ? .opacity : .identity)
                SettingsToggleRow(
                    "Always show worktree list",
                    description: "Shows Worktrees in the sidebar even when a repository has just one.",
                    isOn: $preferences.alwaysShowWorktreeList
                )
            }
        }
        // What a sidebar style does crossfades to the chosen one's over
        // 0.15 s, the rows below moving with its height.
        .motion(Motion.leave, value: preferences.sidebarStyle)
    }

    private static func title(_ format: DateFormatPattern) -> String {
        AppearanceSettings.formatTitle(example: format.example, pattern: format.rawValue)
    }

    private static func title(_ format: TimeFormatPattern) -> String {
        AppearanceSettings.formatTitle(example: format.example, pattern: format.rawValue)
    }

    /// The background tint: the one the theme draws, setting the one
    /// chosen.
    private var designBackground: Binding<BackgroundTint> {
        Binding {
            preferences.designThemeBackground
        } set: { tint in
            preferences.designBackground = tint
        }
    }

    /// The date format, the default when none (or an unknown one) is
    /// stored.
    private var dateFormat: Binding<DateFormatPattern> {
        Binding {
            preferences.dateFormat.flatMap(DateFormatPattern.init(rawValue:)) ?? .default
        } set: { format in
            preferences.dateFormat = format.rawValue
        }
    }

    /// The time format, the default when none (or an unknown one) is
    /// stored.
    private var timeFormat: Binding<TimeFormatPattern> {
        Binding {
            preferences.timeFormat.flatMap(TimeFormatPattern.init(rawValue:)) ?? .default
        } set: { format in
            preferences.timeFormat = format.rawValue
        }
    }
}
