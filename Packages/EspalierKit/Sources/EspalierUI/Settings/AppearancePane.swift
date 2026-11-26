// Settings ▸ Appearance: the theme (Default or Frost), which sets the
// fonts; colors (the palette, System's the Mac's accent color, on any
// theme; the background tint; the appearance, System, Light, or Dark); code
// (its text size, the diff's tab size), dates and numbers, accessibility,
// Home (opening to it, how the shelf is arranged, the kinds of activity
// that move work up, and what counts as needing the user), and the sidebar
// (its style, hidden or icons, and the worktree list). The
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

    /// How the shelf is arranged, in order.
    static let arrangements = [
        CapsuleSegment("Recent Activity", value: RepositoryArrangement.recentActivity),
        CapsuleSegment("Needs You", value: RepositoryArrangement.needsYou),
    ]

    /// The kinds of activity that move work up, in order.
    static let activityKinds: [(title: String, value: WorktreeActivityKind)] = [
        ("Files change", .files),
        ("A commit or a branch switch", .head),
        ("New commits arrive from the server", .server),
        ("News about its pull request", .pullRequest),
    ]

    /// The reasons that put work in Needs You, in order.
    static let needsYouReasons: [(title: String, value: NeedsYouReason)] = [
        ("Uncommitted changes", .uncommittedChanges),
        ("Commits to push", .commitsToPush),
        ("A rebase or merge that stopped", .stoppedOperation),
        ("Checks failing or a review waiting on its pull request", .pullRequestAttention),
        ("A merged branch to clean up", .mergedReadyToCleanUp),
        ("Commits to pull", .commitsToPull),
        ("A pushed branch with no pull request", .branchWithoutPullRequest),
    ]

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

/// The Appearance pane: the theme; the palette, the background tint, and
/// the appearance; code (its text size and tab size), dates and numbers,
/// accessibility, Home, and the sidebar.
struct AppearanceForm: View {
    @Bindable var preferences: Preferences
    @Environment(\.motion) private var motion

    var body: some View {
        SettingsPage {
            SettingsSection("Look") {
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
            }

            SettingsSection("Colors") {
                SettingsRow("Palette", description: preferences.designPalette.summary) {
                    SwatchPicker("Palette", values: DesignPalette.allCases, selection: $preferences.designPalette, title: \.title) { palette in
                        Theme.named(preferences.designTheme, palette: palette).paletteSwatch
                    }
                }
                // The chosen palette's name, and the background's below,
                // crossfade with the swatch's motion.
                .contentTransition(motion.animates ? .opacity : .identity)
                SettingsRow("Background", description: preferences.designBackground.title) {
                    SwatchPicker("Background", values: BackgroundTint.allCases, selection: $preferences.designBackground, title: \.title) { tint in
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

            SettingsSection("Home") {
                SettingsToggleRow(
                    "Open to Home",
                    description: "Windows open to Home, an overview of the work in your repositories, and the toolbar has a button for it.",
                    isOn: $preferences.showsHome
                )
                SettingsRow("Arrange the shelf by", labelsControl: true) {
                    CapsuleSegmentedControl("Arrange the shelf by", selection: $preferences.repositoryArrangement, segments: AppearanceSettings.arrangements)
                        .fixedSize()
                }
                SettingsRow("Recent Activity moves work up when") {
                    EmptyView()
                } footer: {
                    SettingsChecklist(choices: AppearanceSettings.activityKinds, selection: $preferences.recentActivityKinds)
                }
                SettingsRow("Needs You includes") {
                    EmptyView()
                } footer: {
                    SettingsChecklist(choices: AppearanceSettings.needsYouReasons, selection: $preferences.needsYouReasons)
                }
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

/// A row's checkboxes, one for each choice, on when the choice is in
/// `selection`.
struct SettingsChecklist<Value: Hashable>: View {
    let choices: [(title: String, value: Value)]
    @Binding var selection: Set<Value>

    var body: some View {
        VStack(alignment: .leading, spacing: Metrics.insetSmall) {
            ForEach(choices, id: \.value) { choice in
                Toggle(choice.title, isOn: Binding {
                    selection.contains(choice.value)
                } set: { isOn in
                    if isOn {
                        selection.insert(choice.value)
                    } else {
                        selection.remove(choice.value)
                    }
                })
                .toggleStyle(.checkboxMark)
                .font(Typography.row)
            }
        }
        .padding(.top, Metrics.grid)
        .padding(.vertical, Metrics.FocusRing.outset)
    }
}
