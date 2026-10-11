// Settings ▸ Appearance: the theme (System, Light, Dark), the accent color,
// code, dates and numbers, accessibility, and the sidebar. The code text size
// steps through the same sizes as View ▸ Bigger (⌘=) and Smaller (⌘−).

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

/// The Appearance pane: the theme and the accent color, code, dates and
/// numbers, accessibility, and the sidebar.
struct AppearanceForm: View {
    @Bindable var preferences: Preferences
    let openAppearanceSettings: () -> Void

    var body: some View {
        SettingsPage {
            SettingsSection("Theme") {
                SettingsRow("Appearance", labelsControl: true) {
                    CapsuleSegmentedControl("Appearance", selection: $preferences.theme, segments: AppearanceSettings.themes)
                        .fixedSize()
                }
                SettingsRow("Accent color", description: "Espalier follows your Mac's accent color.") {
                    Button("Appearance Settings…", action: openAppearanceSettings)
                        .settingsButton()
                }
            }

            SettingsSection("Code") {
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
                    CapsulePopUp("Date format", selection: dateFormat, title: Self.title(dateFormat.wrappedValue)) {
                        for format in DateFormatPattern.allCases {
                            MenuChoice(Self.title(format), value: format)
                        }
                    }
                    .settingsControlWidth()
                }
                SettingsRow("Time format", labelsControl: true) {
                    CapsulePopUp("Time format", selection: timeFormat, title: Self.title(timeFormat.wrappedValue)) {
                        for format in TimeFormatPattern.allCases {
                            MenuChoice(Self.title(format), value: format)
                        }
                    }
                    .settingsControlWidth()
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
