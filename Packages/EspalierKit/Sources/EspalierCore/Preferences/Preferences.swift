import EspalierSupport
import Foundation
import GitKit
import Observation

/// The settings' keys, as stored (two of them really end in `Key`).
public enum PreferenceKey {
    // Confirmations.
    public static let confirmRepoRemoval = "confirmRepoRemoval"
    public static let confirmDiscardChanges = "confirmDiscardChanges"
    public static let confirmDiscardChangesPermanently = "confirmDiscardChangesPermanentlyKey"
    public static let confirmDiscardStash = "confirmDiscardStash"
    public static let confirmCheckoutCommit = "confirmCheckoutCommit"
    public static let confirmForcePush = "confirmForcePush"
    public static let confirmUndoCommit = "confirmUndoCommit"
    public static let confirmCommitFilteredChanges = "confirmCommitFilteredChangesKey"
    public static let confirmCommitMessageOverride = "confirmCommitMessageOverride"
    public static let confirmWorktreeRemoval = "confirmWorktreeRemoval"

    // Behavior.
    public static let uncommittedChangesStrategy = "uncommittedChangesStrategyKind"
    public static let showCommitLengthWarning = "showCommitLengthWarning"
    public static let repositoryIndicatorsEnabled = "enable-repository-indicators"
    public static let commitSpellcheckEnabled = "commit-spellcheck-enabled"
    public static let highSignalNotificationsEnabled = "high-signal-notifications-enabled"
    public static let alwaysShowWorktreeList = "always-show-worktree-list"
    public static let askToMoveToApplicationsFolder = "askToMoveToApplicationsFolder"
    public static let hasShownWelcomeFlow = "has-shown-welcome-flow"
    public static let pullRequestSuggestedNextAction = "pull-request-suggested-next-action-key"
    public static let lastCloneLocation = "last-clone-location"
    public static let useExternalCredentialHelper = EspalierCore.useExternalCredentialHelperKey
    public static let hooksEnvEnabled = "git-hooks-env-enabled"
    public static let cacheHooksEnv = "git-cache-hooks-env"

    // Appearance and formatting.
    /// The appearance: System, Light, or Dark (`ApplicationTheme`).
    public static let theme = "theme"
    /// The design theme (`DesignTheme`), Espalier's own.
    public static let designTheme = "design-theme"
    /// The design theme's color, one key per theme
    /// (`design-theme-color-orchard`), so each theme keeps its own.
    public static func designThemeColor(_ theme: DesignTheme) -> String {
        "design-theme-color-\(theme.rawValue)"
    }
    /// The design theme's background tint, one key per theme
    /// (`design-theme-background-orchard`), so each theme keeps its own.
    public static func designThemeBackground(_ theme: DesignTheme) -> String {
        "design-theme-background-\(theme.rawValue)"
    }
    /// The app font (`AppFont`), Espalier's own.
    public static let appFont = "app-font"
    /// The code font (`CodeFont`), Espalier's own.
    public static let codeFont = "code-font"
    public static let underlineLinks = "underline-links"
    public static let preferAbsoluteDates = "preferAbsoluteDates"
    public static let tabSize = "tab-size"
    public static let numberFormat = "numberFormat"
    public static let dateFormat = "dateFormat"
    public static let timeFormat = "timeFormat"

    // Diffs.
    public static let imageDiffType = "image-diff-type"
    public static let hideWhitespaceInChangesDiff = "hide-whitespace-in-changes-diff"
    public static let hideWhitespaceInHistoryDiff = "hide-whitespace-in-diff"
    public static let hideWhitespaceInPullRequestDiff = "hide-whitespace-in-pull-request-diff"
    public static let showSideBySideDiff = "show-side-by-side-diff"
    /// The code text size (a factor of the actual size).
    public static let codeTextSize = "diff-code-text-size"
    /// Wrap long lines in diffs.
    public static let wrapDiffLines = "diff-wrap-lines"

    // History.
    /// Whether History shows the simple list or the graph.
    public static let historyStyle = "history-style"

    // Editor and shell (`IntegrationSettings`).
    public static let externalEditor = "externalEditor"
    public static let shell = "shell"
    public static let useCustomEditor = "use-custom-editor"
    public static let customEditor = "custom-editor"
    public static let useCustomShell = "use-custom-shell"
    public static let customShell = "custom-shell"
    /// Espalier's: whether GitHub's "Open with GitHub Desktop" links open
    /// in Espalier.
    public static let openGitHubDesktopLinks = "open-github-desktop-links"

    // AI (the AI model's).
    /// Whether AI features are on at all.
    public static let aiFeaturesEnabled = "ai-features-enabled"
    public static let alwaysUseAIForConflictResolution = "always-use-copilot-for-conflict-resolution"
    public static let byokProviders = "copilot-byok-providers"
    public static let aiModelSelections = "ai-model-selections"
    public static let aiDataConsents = "ai-data-consents"
}

/// What the pull request button does by default.
public enum PullRequestSuggestedNextAction: String, Sendable, Hashable, CaseIterable {
    case previewPullRequest = "PreviewPullRequest"
    case createPullRequest = "CreatePullRequest"
}

/// The default PR action.
public let defaultPullRequestSuggestedNextAction: PullRequestSuggestedNextAction = .previewPullRequest

/// The app's appearance: the Mac's, or always light or always dark. The raw
/// values are the ones stored.
public enum ApplicationTheme: String, Sendable, Hashable, CaseIterable {
    case system, light, dark
}

/// Espalier's design theme: its colors, shapes, and marks, picked apart from
/// the appearance (`ApplicationTheme`), the app font, and the code font. The
/// raw values are the ones stored.
public enum DesignTheme: String, Sendable, Hashable, CaseIterable {
    /// The look Espalier had before themes, following the Mac's accent
    /// color.
    case classic
    case orchard
    case islands
    case pop

    /// The theme's colors, in the order Settings shows them; none for
    /// Classic, which follows the Mac's accent color.
    public var colors: [DesignThemeColor] {
        switch self {
        case .classic: []
        case .orchard: [.plum, .clay, .ink, .teal, .espresso]
        case .islands: [.berry, .lagoon, .indigo]
        case .pop: [.tangerine, .electric, .magenta]
        }
    }

    /// The color the theme has until the user picks another; nil for
    /// Classic.
    public var defaultColor: DesignThemeColor? {
        switch self {
        case .classic: nil
        case .orchard: .ink
        case .islands: .lagoon
        case .pop: .tangerine
        }
    }
}

/// A design theme's color. Each belongs to one theme (`DesignTheme.colors`).
/// The raw values are the ones stored.
public enum DesignThemeColor: String, Sendable, Hashable, CaseIterable {
    case plum, clay, ink, teal, espresso
    case berry, lagoon, indigo
    case tangerine, electric, magenta
}

/// The tint of a design theme's backgrounds: its panes, sidebar, fields, and
/// lines. The raw values are the ones stored.
public enum BackgroundTint: String, Sendable, Hashable, CaseIterable {
    /// The theme's own backgrounds.
    case own
    case neutral, warm, cool, sage, rose, lavender
}

/// The app font: every piece of the interface's text. The raw values are
/// the ones stored.
public enum AppFont: String, Sendable, Hashable, CaseIterable {
    /// SF Pro, the system's.
    case sf
    /// Fixel Text.
    case fixel
    /// Atkinson Hyperlegible Next.
    case atkinson
    /// Martian Grotesk.
    case martian
}

/// The code font: what's drawn monospaced (commit IDs, counts, ref tags,
/// code, terminal output). The raw values are the ones stored, apart from
/// `AppFont`'s.
public enum CodeFont: String, Sendable, Hashable, CaseIterable {
    /// SF Mono, the system's.
    case sfMono = "sfmono"
    /// Geist Mono.
    case geistMono = "geistmono"
    /// Atkinson Hyperlegible Mono.
    case atkinsonMono = "atkinsonmono"
}

/// The app's settings.
///
/// Each property loads from its key when the model is made and writes its
/// key when it changes; nothing is written until then, so a setting the user
/// never changed follows the default. Values are written as property-list types.
/// Settings that GitKit and the trampoline read themselves (the hooks
/// environment, the external credential helper) go through their own
/// functions, so a change takes effect at the next git command.
@MainActor @Observable
public final class Preferences {
    public let store: PreferenceStore

    /// - Parameters:
    ///   - store: The settings' storage.
    ///   - homeDirectory: The home directory `lastCloneLocation`'s default is in.
    public init(store: PreferenceStore, homeDirectory: String = NSHomeDirectory()) {
        self.store = store
        defaultCloneLocation = POSIXPath.join(homeDirectory, "Developer")

        confirmRepositoryRemoval = store.getBoolean(PreferenceKey.confirmRepoRemoval, true)
        confirmDiscardChanges = store.getBoolean(PreferenceKey.confirmDiscardChanges, true)
        confirmDiscardChangesPermanently = store.getBoolean(PreferenceKey.confirmDiscardChangesPermanently, true)
        confirmDiscardStash = store.getBoolean(PreferenceKey.confirmDiscardStash, true)
        confirmCheckoutCommit = store.getBoolean(PreferenceKey.confirmCheckoutCommit, true)
        confirmForcePush = store.getBoolean(PreferenceKey.confirmForcePush, true)
        confirmUndoCommit = store.getBoolean(PreferenceKey.confirmUndoCommit, true)
        confirmCommitFilteredChanges = store.getBoolean(PreferenceKey.confirmCommitFilteredChanges, true)
        confirmCommitMessageOverride = store.getBoolean(PreferenceKey.confirmCommitMessageOverride, true)
        confirmWorktreeRemoval = store.getBoolean(PreferenceKey.confirmWorktreeRemoval, true)

        uncommittedChangesStrategy = store.getEnum(PreferenceKey.uncommittedChangesStrategy, UncommittedChangesStrategy.self)
            ?? defaultUncommittedChangesStrategy
        showCommitLengthWarning = store.getBoolean(PreferenceKey.showCommitLengthWarning, true)
        repositoryIndicatorsEnabled = store.getBoolean(PreferenceKey.repositoryIndicatorsEnabled, true)
        commitSpellcheckEnabled = store.getBoolean(PreferenceKey.commitSpellcheckEnabled, true)
        highSignalNotificationsEnabled = store.getBoolean(PreferenceKey.highSignalNotificationsEnabled, true)
        alwaysShowWorktreeList = store.getBoolean(PreferenceKey.alwaysShowWorktreeList, false)
        askToMoveToApplicationsFolder = store.getBoolean(PreferenceKey.askToMoveToApplicationsFolder, true)
        hasShownWelcomeFlow = store.getBoolean(PreferenceKey.hasShownWelcomeFlow, false)
        pullRequestSuggestedNextAction = store.getEnum(
            PreferenceKey.pullRequestSuggestedNextAction,
            PullRequestSuggestedNextAction.self
        ) ?? defaultPullRequestSuggestedNextAction
        lastCloneLocation = store.getString(PreferenceKey.lastCloneLocation).flatMap { $0.isEmpty ? nil : $0 }
            ?? defaultCloneLocation
        useExternalCredentialHelper = EspalierCore.useExternalCredentialHelper(defaults: store.defaults)
        hooksEnvEnabled = getHooksEnvEnabled(defaults: store.defaults)
        cacheHooksEnv = getCacheHooksEnv(defaults: store.defaults)

        theme = Self.storedTheme(in: store)
        designTheme = Self.storedDesignTheme(in: store)
        designThemeColors = Self.storedDesignThemeColors(in: store)
        designThemeBackgrounds = Self.storedDesignThemeBackgrounds(in: store)
        appFont = Self.storedAppFont(in: store)
        codeFont = Self.storedCodeFont(in: store)
        underlineLinks = store.getBoolean(PreferenceKey.underlineLinks, true)
        preferAbsoluteDates = store.getBoolean(PreferenceKey.preferAbsoluteDates, false)
        tabSize = store.getNumber(PreferenceKey.tabSize, 4)
        numberFormat = store.getString(PreferenceKey.numberFormat).flatMap { $0.isEmpty ? nil : numberFormatFromKey($0) }
            ?? defaultNumberFormat
        dateFormat = store.getString(PreferenceKey.dateFormat)
        timeFormat = store.getString(PreferenceKey.timeFormat)

        imageDiffType = store.getNumber(PreferenceKey.imageDiffType).flatMap(ImageDiffType.init(rawValue:)) ?? .twoUp
        hideWhitespaceInChangesDiff = store.getBoolean(PreferenceKey.hideWhitespaceInChangesDiff, false)
        hideWhitespaceInHistoryDiff = store.getBoolean(PreferenceKey.hideWhitespaceInHistoryDiff, false)
        hideWhitespaceInPullRequestDiff = store.getBoolean(PreferenceKey.hideWhitespaceInPullRequestDiff, false)
        showSideBySideDiff = store.getBoolean(PreferenceKey.showSideBySideDiff, false)
        codeTextSize = Self.loadCodeTextSize(store)
        wrapDiffLines = store.getBoolean(PreferenceKey.wrapDiffLines, true)

        historyStyle = store.getEnum(PreferenceKey.historyStyle, HistoryStyle.self) ?? .simple

        integrations = Self.loadIntegrations(store)
        openGitHubDesktopLinks = store.getBoolean(PreferenceKey.openGitHubDesktopLinks, false)
        aiFeaturesEnabled = store.getBoolean(PreferenceKey.aiFeaturesEnabled, true)
        alwaysUseAIForConflictResolution = store.getBoolean(PreferenceKey.alwaysUseAIForConflictResolution, false)
    }

    /// `~/Developer`, the clone folder until the user picks another.
    public let defaultCloneLocation: String

    // MARK: Confirmations

    /// Confirm removing a repository from the list (`confirmRepoRemoval`).
    public var confirmRepositoryRemoval: Bool {
        didSet { write(PreferenceKey.confirmRepoRemoval, confirmRepositoryRemoval, oldValue) }
    }

    /// Confirm discarding changes, of files or lines (`confirmDiscardChanges`).
    public var confirmDiscardChanges: Bool {
        didSet { write(PreferenceKey.confirmDiscardChanges, confirmDiscardChanges, oldValue) }
    }

    /// Confirm deleting discarded changes for good when moving them to the
    /// Trash fails (`confirmDiscardChangesPermanentlyKey`).
    public var confirmDiscardChangesPermanently: Bool {
        didSet { write(PreferenceKey.confirmDiscardChangesPermanently, confirmDiscardChangesPermanently, oldValue) }
    }

    /// Confirm dropping a stash (`confirmDiscardStash`).
    public var confirmDiscardStash: Bool {
        didSet { write(PreferenceKey.confirmDiscardStash, confirmDiscardStash, oldValue) }
    }

    /// Confirm checking out a commit, which detaches HEAD (`confirmCheckoutCommit`).
    public var confirmCheckoutCommit: Bool {
        didSet { write(PreferenceKey.confirmCheckoutCommit, confirmCheckoutCommit, oldValue) }
    }

    /// Warn before a force push, and before rebasing, squashing, reordering,
    /// or amending pushed commits (`confirmForcePush`).
    public var confirmForcePush: Bool {
        didSet { write(PreferenceKey.confirmForcePush, confirmForcePush, oldValue) }
    }

    /// Confirm undoing a commit (`confirmUndoCommit`).
    public var confirmUndoCommit: Bool {
        didSet { write(PreferenceKey.confirmUndoCommit, confirmUndoCommit, oldValue) }
    }

    /// Confirm committing while the file filter hides included files
    /// (`confirmCommitFilteredChangesKey`).
    public var confirmCommitFilteredChanges: Bool {
        didSet { write(PreferenceKey.confirmCommitFilteredChanges, confirmCommitFilteredChanges, oldValue) }
    }

    /// Confirm replacing a typed commit message with a generated one
    /// (`confirmCommitMessageOverride`).
    public var confirmCommitMessageOverride: Bool {
        didSet { write(PreferenceKey.confirmCommitMessageOverride, confirmCommitMessageOverride, oldValue) }
    }

    /// Confirm deleting a worktree (`confirmWorktreeRemoval`).
    public var confirmWorktreeRemoval: Bool {
        didSet { write(PreferenceKey.confirmWorktreeRemoval, confirmWorktreeRemoval, oldValue) }
    }

    // MARK: Behavior

    /// What switching branches does with uncommitted changes
    /// (`uncommittedChangesStrategyKind`; ask by default).
    public var uncommittedChangesStrategy: UncommittedChangesStrategy {
        didSet {
            guard uncommittedChangesStrategy != oldValue else { return }
            store.setEnum(PreferenceKey.uncommittedChangesStrategy, uncommittedChangesStrategy)
        }
    }

    /// Warn when the commit summary is long (`showCommitLengthWarning`; on
    /// by default).
    public var showCommitLengthWarning: Bool {
        didSet { write(PreferenceKey.showCommitLengthWarning, showCommitLengthWarning, oldValue) }
    }

    /// Show ahead/behind and change indicators in the repository list, and
    /// fetch in the background for them (`enable-repository-indicators`; on
    /// by default).
    public var repositoryIndicatorsEnabled: Bool {
        didSet { write(PreferenceKey.repositoryIndicatorsEnabled, repositoryIndicatorsEnabled, oldValue) }
    }

    /// Check spelling in the commit fields (`commit-spellcheck-enabled`).
    public var commitSpellcheckEnabled: Bool {
        didSet { write(PreferenceKey.commitSpellcheckEnabled, commitSpellcheckEnabled, oldValue) }
    }

    /// Notify about failed checks and pull request reviews
    /// (`high-signal-notifications-enabled`).
    public var highSignalNotificationsEnabled: Bool {
        didSet { write(PreferenceKey.highSignalNotificationsEnabled, highSignalNotificationsEnabled, oldValue) }
    }

    /// Show the worktree list even without linked worktrees
    /// (`always-show-worktree-list`).
    public var alwaysShowWorktreeList: Bool {
        didSet { write(PreferenceKey.alwaysShowWorktreeList, alwaysShowWorktreeList, oldValue) }
    }

    /// Offer to move the app to the Applications folder at launch
    /// (`askToMoveToApplicationsFolder`).
    public var askToMoveToApplicationsFolder: Bool {
        didSet { write(PreferenceKey.askToMoveToApplicationsFolder, askToMoveToApplicationsFolder, oldValue) }
    }

    /// Whether the welcome flow has been shown (`has-shown-welcome-flow`).
    public var hasShownWelcomeFlow: Bool {
        didSet { write(PreferenceKey.hasShownWelcomeFlow, hasShownWelcomeFlow, oldValue) }
    }

    /// What the pull request button does by default
    /// (`pull-request-suggested-next-action-key`).
    public var pullRequestSuggestedNextAction: PullRequestSuggestedNextAction {
        didSet {
            guard pullRequestSuggestedNextAction != oldValue else { return }
            store.setEnum(PreferenceKey.pullRequestSuggestedNextAction, pullRequestSuggestedNextAction)
        }
    }

    /// The folder clone and create start in (`last-clone-location`):
    /// `defaultCloneLocation` until one is chosen, then the last one used.
    public var lastCloneLocation: String {
        didSet {
            guard !JSCompat.strictEquals(lastCloneLocation, oldValue) else { return }
            store.setString(PreferenceKey.lastCloneLocation, lastCloneLocation)
        }
    }

    /// Use Git Credential Manager for hosts other than GitHub
    /// (`useExternalCredentialHelper`), as the trampoline reads it.
    public var useExternalCredentialHelper: Bool {
        didSet {
            guard useExternalCredentialHelper != oldValue else { return }
            setUseExternalCredentialHelper(useExternalCredentialHelper, defaults: store.defaults)
        }
    }

    /// Run hooks in the user's login shell environment
    /// (`git-hooks-env-enabled`; on by default), as GitKit reads it.
    public var hooksEnvEnabled: Bool {
        didSet {
            guard hooksEnvEnabled != oldValue else { return }
            setHooksEnvEnabled(hooksEnvEnabled, defaults: store.defaults)
        }
    }

    /// Keep the login shell environment between operations
    /// (`git-cache-hooks-env`; on by default), as GitKit reads it.
    public var cacheHooksEnv: Bool {
        didSet {
            guard cacheHooksEnv != oldValue else { return }
            setCacheHooksEnv(cacheHooksEnv, defaults: store.defaults)
        }
    }

    // MARK: Appearance and formatting

    /// The app's appearance (`theme`; System, the Mac's, by default).
    public var theme: ApplicationTheme {
        didSet {
            guard theme != oldValue else { return }
            store.setEnum(PreferenceKey.theme, theme)
        }
    }

    /// The theme stored in `store`: `light` or `dark`, and anything else
    /// System. The app applies it before the model loads, so its first
    /// windows open in it.
    public static func storedTheme(in store: PreferenceStore) -> ApplicationTheme {
        store.getEnum(PreferenceKey.theme, ApplicationTheme.self) ?? .system
    }

    /// The design theme (`design-theme`; Classic by default).
    public var designTheme: DesignTheme {
        didSet {
            guard designTheme != oldValue else { return }
            store.setEnum(PreferenceKey.designTheme, designTheme)
        }
    }

    /// The color each design theme has, its default until the user picks
    /// another (`design-theme-color-<theme>`). Only the themes whose color
    /// changed are written.
    public var designThemeColors: [DesignTheme: DesignThemeColor] {
        didSet {
            for theme in DesignTheme.allCases where designThemeColors[theme] != oldValue[theme] {
                if let color = designThemeColors[theme] {
                    store.setEnum(PreferenceKey.designThemeColor(theme), color)
                }
            }
        }
    }

    /// The current design theme's color; nil for Classic. Setting a color
    /// that isn't one of the theme's does nothing.
    public var designThemeColor: DesignThemeColor? {
        get { designThemeColors[designTheme] }
        set {
            guard let newValue, designTheme.colors.contains(newValue) else { return }
            designThemeColors[designTheme] = newValue
        }
    }

    /// The background tint each design theme has, its own backgrounds
    /// until the user picks another (`design-theme-background-<theme>`).
    /// Only the themes whose tint changed are written.
    public var designThemeBackgrounds: [DesignTheme: BackgroundTint] {
        didSet {
            for theme in DesignTheme.allCases where designThemeBackgrounds[theme] != oldValue[theme] {
                store.setEnum(PreferenceKey.designThemeBackground(theme), designThemeBackgrounds[theme] ?? .own)
            }
        }
    }

    /// The current design theme's background tint.
    public var designThemeBackground: BackgroundTint {
        get { designThemeBackgrounds[designTheme] ?? .own }
        set { designThemeBackgrounds[designTheme] = newValue }
    }

    /// The app font (`app-font`; SF Pro by default).
    public var appFont: AppFont {
        didSet {
            guard appFont != oldValue else { return }
            store.setEnum(PreferenceKey.appFont, appFont)
        }
    }

    /// The code font (`code-font`; SF Mono by default).
    public var codeFont: CodeFont {
        didSet {
            guard codeFont != oldValue else { return }
            store.setEnum(PreferenceKey.codeFont, codeFont)
        }
    }

    /// The design theme stored in `store`; an unknown one is Classic. The
    /// app applies it before the model loads, so its first windows open in
    /// it.
    public static func storedDesignTheme(in store: PreferenceStore) -> DesignTheme {
        store.getEnum(PreferenceKey.designTheme, DesignTheme.self) ?? .classic
    }

    /// Each design theme's color stored in `store`: one that isn't the
    /// theme's, or none, is the theme's default.
    public static func storedDesignThemeColors(in store: PreferenceStore) -> [DesignTheme: DesignThemeColor] {
        var colors: [DesignTheme: DesignThemeColor] = [:]
        for theme in DesignTheme.allCases {
            let stored = store.getEnum(PreferenceKey.designThemeColor(theme), DesignThemeColor.self)
            if let stored, theme.colors.contains(stored) {
                colors[theme] = stored
            } else if let defaultColor = theme.defaultColor {
                colors[theme] = defaultColor
            }
        }
        return colors
    }

    /// Each design theme's background tint stored in `store`: an unknown
    /// one, or none, is the theme's own.
    public static func storedDesignThemeBackgrounds(in store: PreferenceStore) -> [DesignTheme: BackgroundTint] {
        Dictionary(uniqueKeysWithValues: DesignTheme.allCases.map { theme in
            (theme, store.getEnum(PreferenceKey.designThemeBackground(theme), BackgroundTint.self) ?? .own)
        })
    }

    /// The app font stored in `store`; an unknown one is SF Pro.
    public static func storedAppFont(in store: PreferenceStore) -> AppFont {
        store.getEnum(PreferenceKey.appFont, AppFont.self) ?? .sf
    }

    /// The code font stored in `store`; an unknown one is SF Mono.
    public static func storedCodeFont(in store: PreferenceStore) -> CodeFont {
        store.getEnum(PreferenceKey.codeFont, CodeFont.self) ?? .sfMono
    }

    /// Underline links (`underline-links`).
    public var underlineLinks: Bool {
        didSet { write(PreferenceKey.underlineLinks, underlineLinks, oldValue) }
    }

    /// Show absolute dates instead of relative ones in lists
    /// (`preferAbsoluteDates`).
    public var preferAbsoluteDates: Bool {
        didSet { write(PreferenceKey.preferAbsoluteDates, preferAbsoluteDates, oldValue) }
    }

    /// The diff's tab width (`tab-size`; 4).
    public var tabSize: Int {
        didSet {
            guard tabSize != oldValue else { return }
            store.setNumber(PreferenceKey.tabSize, tabSize)
        }
    }

    /// The number format (`numberFormat`, stored as GitKit's
    /// `numberFormatToKey`). GitKit's `getNumberFormatPreference()` reads it
    /// from the standard defaults, which are this store's in the app.
    public var numberFormat: NumberFormat {
        didSet {
            guard numberFormat != oldValue else { return }
            store.setString(PreferenceKey.numberFormat, numberFormatToKey(numberFormat))
        }
    }

    /// The date format pattern (`dateFormat`), or nil for the default. The
    /// formats are the UI's, which checks the pattern.
    public var dateFormat: String? {
        didSet {
            guard dateFormat != oldValue else { return }
            store.setString(PreferenceKey.dateFormat, dateFormat)
        }
    }

    /// The time format pattern (`timeFormat`), or nil for the default; see
    /// `dateFormat`.
    public var timeFormat: String? {
        didSet {
            guard timeFormat != oldValue else { return }
            store.setString(PreferenceKey.timeFormat, timeFormat)
        }
    }

    // MARK: Diffs

    /// How image diffs are shown (`image-diff-type`; two-up). A stored value
    /// that isn't a known type reads as two-up.
    public var imageDiffType: ImageDiffType {
        didSet {
            guard imageDiffType != oldValue else { return }
            store.setNumber(PreferenceKey.imageDiffType, imageDiffType.rawValue)
        }
    }

    /// Hide whitespace changes in the changes diff (`hide-whitespace-in-changes-diff`).
    public var hideWhitespaceInChangesDiff: Bool {
        didSet { write(PreferenceKey.hideWhitespaceInChangesDiff, hideWhitespaceInChangesDiff, oldValue) }
    }

    /// Hide whitespace changes in history diffs (`hide-whitespace-in-diff`).
    public var hideWhitespaceInHistoryDiff: Bool {
        didSet { write(PreferenceKey.hideWhitespaceInHistoryDiff, hideWhitespaceInHistoryDiff, oldValue) }
    }

    /// Hide whitespace changes in pull request diffs
    /// (`hide-whitespace-in-pull-request-diff`).
    public var hideWhitespaceInPullRequestDiff: Bool {
        didSet { write(PreferenceKey.hideWhitespaceInPullRequestDiff, hideWhitespaceInPullRequestDiff, oldValue) }
    }

    /// Show diffs side by side instead of unified (`show-side-by-side-diff`).
    public var showSideBySideDiff: Bool {
        didSet { write(PreferenceKey.showSideBySideDiff, showSideBySideDiff, oldValue) }
    }

    /// The size of code text, in diffs and file contents
    /// (`diff-code-text-size`; actual size by default). View ▸ Bigger,
    /// Smaller, and Actual Size step through `CodeTextSize.factors`.
    public var codeTextSize: CodeTextSize {
        didSet {
            guard codeTextSize != oldValue else { return }
            store.defaults.set(codeTextSize.factor, forKey: PreferenceKey.codeTextSize)
        }
    }

    /// Makes code text the next size larger; nothing at the largest size.
    public func increaseCodeTextSize() {
        codeTextSize = codeTextSize.larger
    }

    /// Makes code text the next size smaller; nothing at the smallest size.
    public func decreaseCodeTextSize() {
        codeTextSize = codeTextSize.smaller
    }

    /// Returns code text to its actual size.
    public func resetCodeTextSize() {
        codeTextSize = .actual
    }

    /// Wrap long lines in diffs (`diff-wrap-lines`; on by default).
    public var wrapDiffLines: Bool {
        didSet { write(PreferenceKey.wrapDiffLines, wrapDiffLines, oldValue) }
    }

    // MARK: History

    /// Whether History shows the current branch simply or every branch as
    /// a graph (`history-style`; simple by default, remembered app-wide).
    /// `HistoryModel.setStyle(_:)` changes it and shows it in every
    /// repository's history.
    public var historyStyle: HistoryStyle {
        didSet {
            guard historyStyle != oldValue else { return }
            store.setEnum(PreferenceKey.historyStyle, historyStyle)
        }
    }

    // MARK: Integrations and AI

    /// The external editor and shell settings, one key per setting
    /// (`externalEditor`, `shell`, `use-custom-editor`, `custom-editor`,
    /// `use-custom-shell`, `custom-shell`). Only the settings that changed
    /// are written.
    public var integrations: IntegrationSettings {
        didSet { writeIntegrations(integrations, oldValue) }
    }

    /// Whether GitHub's "Open with GitHub Desktop" links (`x-github-client`
    /// and `github-mac`) open in Espalier (`open-github-desktop-links`; off
    /// by default). Only the switch changes it, through
    /// `IntegrationsModel.setOpenGitHubDesktopLinks(_:)` once Launch Services
    /// has made the change. While it's on,
    /// `IntegrationsModel.reclaimGitHubDesktopLinks()` takes the links back
    /// from another app that has them, leaving the setting as it is.
    public internal(set) var openGitHubDesktopLinks: Bool {
        didSet { write(PreferenceKey.openGitHubDesktopLinks, openGitHubDesktopLinks, oldValue) }
    }

    /// Whether AI features are on (`ai-features-enabled`; on by default). Off
    /// means no AI anywhere: no sparkle or Generate Commit Message, no AI
    /// conflict resolution (nor its "always" setting), and no request to any
    /// provider. The AI models honor it.
    public var aiFeaturesEnabled: Bool {
        didSet { write(PreferenceKey.aiFeaturesEnabled, aiFeaturesEnabled, oldValue) }
    }

    /// Resolve conflicts with AI without asking each time
    /// (`always-use-copilot-for-conflict-resolution`).
    public var alwaysUseAIForConflictResolution: Bool {
        didSet { write(PreferenceKey.alwaysUseAIForConflictResolution, alwaysUseAIForConflictResolution, oldValue) }
    }

    // MARK: Storage

    private func write(_ key: String, _ value: Bool, _ oldValue: Bool) {
        guard value != oldValue else { return }
        store.setBoolean(key, value)
    }

    /// Reads the code text size leniently: a stored number, or a string
    /// holding one (set by hand with `defaults write`); anything else, or a
    /// value that isn't a positive finite number, is the actual size.
    private static func loadCodeTextSize(_ store: PreferenceStore) -> CodeTextSize {
        let value = store.defaults.object(forKey: PreferenceKey.codeTextSize)
        let factor: Double? = if let string = value as? String {
            Double(JSCompat.trim(string))
        } else if let number = value as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID() {
            number.doubleValue
        } else {
            nil
        }
        guard let factor, factor.isFinite, factor > 0 else {
            return .actual
        }
        return CodeTextSize(factor: factor)
    }

    /// Reads each setting: an empty editor name is none, an empty or unknown
    /// shell is Terminal, and a custom integration in either stored format is
    /// read (`CustomIntegration`'s decoder).
    private static func loadIntegrations(_ store: PreferenceStore) -> IntegrationSettings {
        IntegrationSettings(
            selectedExternalEditor: store.getString(PreferenceKey.externalEditor).flatMap { $0.isEmpty ? nil : $0 },
            selectedShell: store.getString(PreferenceKey.shell).flatMap { $0.isEmpty ? nil : Shell.parse($0) } ?? .default,
            useCustomEditor: store.getBoolean(PreferenceKey.useCustomEditor, false),
            customEditor: store.getObject(PreferenceKey.customEditor, as: CustomIntegration.self),
            useCustomShell: store.getBoolean(PreferenceKey.useCustomShell, false),
            customShell: store.getObject(PreferenceKey.customShell, as: CustomIntegration.self)
        )
    }

    private func writeIntegrations(_ settings: IntegrationSettings, _ old: IntegrationSettings) {
        if settings.selectedExternalEditor != old.selectedExternalEditor {
            store.setString(PreferenceKey.externalEditor, settings.selectedExternalEditor)
        }
        if settings.selectedShell != old.selectedShell {
            store.setString(PreferenceKey.shell, settings.selectedShell.rawValue)
        }
        if settings.useCustomEditor != old.useCustomEditor {
            store.setBoolean(PreferenceKey.useCustomEditor, settings.useCustomEditor)
        }
        if settings.customEditor != old.customEditor {
            store.setObject(PreferenceKey.customEditor, settings.customEditor)
        }
        if settings.useCustomShell != old.useCustomShell {
            store.setBoolean(PreferenceKey.useCustomShell, settings.useCustomShell)
        }
        if settings.customShell != old.customShell {
            store.setObject(PreferenceKey.customShell, settings.customShell)
        }
    }
}

/// How large code text is, relative to its actual size: a factor the UI
/// multiplies the code font's base size by.
public struct CodeTextSize: Sendable, Hashable, Comparable {
    /// The sizes, smallest first.
    public static let factors: [Double] = [0.67, 0.75, 0.8, 0.9, 1, 1.1, 1.25, 1.5, 1.75, 2]

    /// The actual size.
    public static let actual = CodeTextSize(factor: 1)

    /// The factor, between the smallest and the largest of `factors`.
    public let factor: Double

    /// A size, clamped to the supported range; a factor that isn't finite
    /// is the actual size.
    public init(factor: Double) {
        guard factor.isFinite, let smallest = Self.factors.first, let largest = Self.factors.last else {
            self.factor = 1
            return
        }
        self.factor = min(max(factor, smallest), largest)
    }

    /// The next size up: the supported factor closest to this one, then the
    /// next larger one; at the largest, the largest.
    public var larger: CodeTextSize {
        let current = closest(in: Self.factors)
        return CodeTextSize(factor: Self.factors.first { $0 > current } ?? current)
    }

    /// The next size down: the supported factor closest to this one,
    /// searching from the largest, then the next smaller one; at the
    /// smallest, the smallest.
    public var smaller: CodeTextSize {
        let zoomOutFactors = Array(Self.factors.reversed())
        let current = closest(in: zoomOutFactors)
        return CodeTextSize(factor: zoomOutFactors.first { $0 < current } ?? current)
    }

    /// Whether this is the largest size, so code text can't grow.
    public var isLargest: Bool {
        larger == self
    }

    /// Whether this is the smallest size, so code text can't shrink.
    public var isSmallest: Bool {
        smaller == self
    }

    public static func < (lhs: CodeTextSize, rhs: CodeTextSize) -> Bool {
        lhs.factor < rhs.factor
    }

    /// The factor of `factors` nearest this one, the earlier of two equally
    /// near.
    private func closest(in factors: [Double]) -> Double {
        factors.dropFirst().reduce(factors[0]) { previous, current in
            abs(current - factor) < abs(previous - factor) ? current : previous
        }
    }
}
