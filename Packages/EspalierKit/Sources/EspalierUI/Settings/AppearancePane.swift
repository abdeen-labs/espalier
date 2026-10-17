// Settings ▸ Appearance: the theme (Classic, Orchard, Islands, Pop), its
// color (Classic's is the Mac's accent color), its background tint, the
// appearance (System, Light, Dark), and the app font; code (the code font,
// its text size, the diff's tab size), dates and numbers, accessibility, and
// the sidebar (its style, hidden or icons, and the worktree list). Each font's name in its pop-up is drawn in that font. The
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
            AppearanceForm(preferences: model.preferences, openAppearanceSettings: {
                model.openSystemSettings(AppearanceSettings.systemAppearanceURL)
            })
        } else {
            SettingsPanePlaceholder(tab: .appearance)
        }
    }
}

/// The Appearance pane's values and copy.
enum AppearanceSettings {
    /// System Settings ▸ Appearance.
    static let systemAppearanceURL = "x-apple.systempreferences:com.apple.Appearance-Settings.extension"

    /// The theme's choices, in order.
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

/// The Appearance pane: the theme, its color and background tint, the
/// appearance, and the app font; code (its font, text size, and tab size),
/// dates and numbers, accessibility, and the sidebar.
struct AppearanceForm: View {
    @Bindable var preferences: Preferences
    let openAppearanceSettings: () -> Void

    var body: some View {
        SettingsPage {
            SettingsSection("Theme") {
                SettingsRow("Theme") {
                    EmptyView()
                } footer: {
                    ThemeCardPicker(
                        selection: $preferences.designTheme,
                        colors: preferences.designThemeColors,
                        backgrounds: preferences.designThemeBackgrounds
                    )
                    .padding(.vertical, Metrics.FocusRing.outset)
                }
                if preferences.designTheme == .classic {
                    SettingsRow("Color", description: "Espalier follows your Mac's accent color.") {
                        Button("Appearance Settings…", action: openAppearanceSettings)
                            .settingsButton()
                    }
                } else {
                    SettingsRow("Color", description: preferences.designThemeColor?.title) {
                        SwatchPicker("Color", values: preferences.designTheme.colors, selection: designThemeColor, title: \.title) { color in
                            Theme.named(preferences.designTheme, color: color).accent
                        }
                    }
                }
                SettingsRow("Background", description: preferences.designThemeBackground.title) {
                    SwatchPicker("Background", values: preferences.designTheme.backgrounds, selection: $preferences.designThemeBackground, title: \.title) { tint in
                        Theme.named(preferences.designTheme, color: preferences.designThemeColor, background: tint).backgroundSwatch
                    }
                }
                SettingsRow("Appearance", labelsControl: true) {
                    CapsuleSegmentedControl("Appearance", selection: $preferences.theme, segments: AppearanceSettings.themes)
                        .fixedSize()
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
                SettingsToggleRow(
                    "Always show worktree list",
                    description: "Shows Worktrees in the sidebar even when a repository has just one.",
                    isOn: $preferences.alwaysShowWorktreeList
                )
            }
        }
    }

    private static func title(_ format: DateFormatPattern) -> String {
        AppearanceSettings.formatTitle(example: format.example, pattern: format.rawValue)
    }

    private static func title(_ format: TimeFormatPattern) -> String {
        AppearanceSettings.formatTitle(example: format.example, pattern: format.rawValue)
    }

    /// The current design theme's color.
    private var designThemeColor: Binding<DesignThemeColor> {
        Binding {
            preferences.designThemeColor ?? preferences.designTheme.defaultColor ?? .ink
        } set: { color in
            preferences.designThemeColor = color
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
