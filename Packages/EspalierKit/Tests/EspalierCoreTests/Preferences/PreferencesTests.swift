// Reading values as desktop stored them, falling back on unusable ones, and
// write-through.

@testable import EspalierCore
import CoreFoundation
import EspalierSupport
import Foundation
import GitKit
import TestSupport
import Testing

/// The keys stored in the domain.
private func storedKeys(_ temporary: TemporaryDefaults) -> Set<String> {
    Set(temporary.defaults.persistentDomain(forName: temporary.suiteName).map { Array($0.keys) } ?? [])
}

/// Whether `value` is a Core Foundation Boolean rather than a number.
private func isPropertyListBoolean(_ value: Any?) -> Bool {
    guard let value else { return false }
    return CFGetTypeID(value as CFTypeRef) == CFBooleanGetTypeID()
}

@Suite("Preferences") @MainActor
struct PreferencesTests {
    /// Every Boolean setting.
    fileprivate static let booleanSettings: [ReferenceWritableKeyPath<Preferences, Bool>] = [
        \.confirmRepositoryRemoval,
        \.confirmDiscardChanges,
        \.confirmDiscardChangesPermanently,
        \.confirmDiscardStash,
        \.confirmCheckoutCommit,
        \.confirmForcePush,
        \.confirmUndoCommit,
        \.confirmCommitFilteredChanges,
        \.confirmCommitMessageOverride,
        \.confirmWorktreeRemoval,
        \.showCommitLengthWarning,
        \.repositoryIndicatorsEnabled,
        \.commitSpellcheckEnabled,
        \.highSignalNotificationsEnabled,
        \.alwaysShowWorktreeList,
        \.askToMoveToApplicationsFolder,
        \.hasShownWelcomeFlow,
        \.useExternalCredentialHelper,
        \.hooksEnvEnabled,
        \.cacheHooksEnv,
        \.underlineLinks,
        \.preferAbsoluteDates,
        \.hideWhitespaceInChangesDiff,
        \.hideWhitespaceInHistoryDiff,
        \.hideWhitespaceInPullRequestDiff,
        \.showSideBySideDiff,
        \.alwaysUseAIForConflictResolution,
        \.wrapDiffLines,
        \.aiFeaturesEnabled,
        \.openGitHubDesktopLinks,
    ]

    @Test("writes nothing when it loads, leaving what desktop stored as it is")
    func loadingWritesNothing() throws {
        let empty = try TemporaryDefaults()
        defer { empty.remove() }
        _ = Preferences(store: PreferenceStore(empty.defaults))
        #expect(storedKeys(empty).isEmpty)

        let desktop = try TemporaryDefaults()
        defer { desktop.remove() }
        desktop.defaults.set("0", forKey: "confirmForcePush")
        desktop.defaults.set("8", forKey: "tab-size")
        desktop.defaults.set(#"{"path":"/usr/local/bin/vim","arguments":["-g","%TARGET_PATH%"]}"#, forKey: "custom-editor")
        _ = Preferences(store: PreferenceStore(desktop.defaults))
        #expect(storedKeys(desktop) == ["confirmForcePush", "tab-size", "custom-editor"])
        #expect(desktop.defaults.object(forKey: "confirmForcePush") as? String == "0")
        #expect(desktop.defaults.object(forKey: "tab-size") as? String == "8")
        #expect(desktop.defaults.string(forKey: "custom-editor")?.contains(#"["-g","%TARGET_PATH%"]"#) == true)
    }

    @Test("writes only the settings that change, so the others keep following their defaults")
    func writesOnlyChanges() throws {
        let temporary = try TemporaryDefaults()
        defer { temporary.remove() }
        let preferences = Preferences(store: PreferenceStore(temporary.defaults), homeDirectory: "/Users/someone")

        for property in Self.booleanSettings {
            preferences[keyPath: property] = preferences[keyPath: property]
        }
        preferences.uncommittedChangesStrategy = .askForConfirmation
        preferences.pullRequestSuggestedNextAction = .previewPullRequest
        preferences.lastCloneLocation = "/Users/someone/Developer"
        preferences.tabSize = 4
        preferences.imageDiffType = .twoUp
        preferences.dateFormat = nil
        preferences.timeFormat = nil
        preferences.integrations = IntegrationSettings()
        preferences.integrations.selectedShell = .terminal
        preferences.codeTextSize = .actual
        preferences.resetCodeTextSize()
        #expect(storedKeys(temporary).isEmpty)

        preferences.confirmForcePush = false
        preferences.confirmForcePush = true
        #expect(storedKeys(temporary) == ["confirmForcePush"])
    }

    @Test("reads a tab size or image diff type it can't use as the default")
    func unreadableNumbers() throws {
        // "NaN" isn't kept as an image diff type.
        for (tabSize, imageDiffType) in [("", ""), ("wide", "NaN"), ("-", "9"), ("x4", "-1")] {
            let temporary = try TemporaryDefaults()
            defer { temporary.remove() }
            temporary.defaults.set(tabSize, forKey: "tab-size")
            temporary.defaults.set(imageDiffType, forKey: "image-diff-type")

            let preferences = Preferences(store: PreferenceStore(temporary.defaults))
            #expect(preferences.tabSize == 4, "\(tabSize)")
            #expect(preferences.imageDiffType == .twoUp, "\(imageDiffType)")
        }
    }

    @Test("remembers the last clone location; an empty one is the default")
    func cloneLocation() throws {
        let temporary = try TemporaryDefaults()
        defer { temporary.remove() }
        temporary.defaults.set("", forKey: "last-clone-location")
        #expect(Preferences(store: PreferenceStore(temporary.defaults), homeDirectory: "/Users/someone").lastCloneLocation == "/Users/someone/Developer")

        temporary.defaults.set("/Volumes/Work/src", forKey: "last-clone-location")
        let preferences = Preferences(store: PreferenceStore(temporary.defaults), homeDirectory: "/Users/someone")
        #expect(preferences.lastCloneLocation == "/Volumes/Work/src")
        #expect(preferences.defaultCloneLocation == "/Users/someone/Developer")

        preferences.lastCloneLocation = "/Users/someone/Code"
        #expect(temporary.defaults.object(forKey: "last-clone-location") as? String == "/Users/someone/Code")
    }

    @Test("reads and writes the number, date, and time formats in the store it was given")
    func formats() throws {
        let german = Locale(identifier: "de_DE")
        let other = try #require(numberFormats.first { $0 != nearestNumberFormat(to: german) })
        let temporary = try TemporaryDefaults()
        defer { temporary.remove() }
        temporary.defaults.set(numberFormatToKey(other), forKey: "numberFormat")
        temporary.defaults.set("yyyy-MM-dd", forKey: "dateFormat")
        temporary.defaults.set("HH:mm", forKey: "timeFormat")

        let preferences = Preferences(store: PreferenceStore(temporary.defaults), locale: german)
        #expect(preferences.numberFormat == other)
        #expect(preferences.dateFormat == "yyyy-MM-dd")
        #expect(preferences.timeFormat == "HH:mm")

        preferences.numberFormat = nearestNumberFormat(to: german)
        preferences.dateFormat = "d MMM yyyy"
        preferences.timeFormat = nil
        #expect(temporary.defaults.object(forKey: "numberFormat") as? String == numberFormatToKey(nearestNumberFormat(to: german)))
        #expect(temporary.defaults.object(forKey: "dateFormat") as? String == "d MMM yyyy")
        #expect(temporary.defaults.object(forKey: "timeFormat") == nil)

        // An empty or unknown number format is the region's.
        for stored in ["", "x|y"] {
            temporary.defaults.set(stored, forKey: "numberFormat")
            #expect(Preferences(store: PreferenceStore(temporary.defaults), locale: german).numberFormat == nearestNumberFormat(to: german))
        }
    }

    @Test("the number format follows the region until one is picked, and a pick stays, even the region's own")
    func numberFormatFollowsRegion() throws {
        let temporary = try TemporaryDefaults()
        defer { temporary.remove() }
        let periodComma = NumberFormat(thousandsSeparator: .period, decimalSeparator: .comma)
        let spacePeriod = NumberFormat(thousandsSeparator: .space, decimalSeparator: .period)

        let german = Preferences(store: PreferenceStore(temporary.defaults), locale: Locale(identifier: "de_DE"))
        #expect(german.numberFormat == periodComma)
        #expect(Preferences(store: PreferenceStore(temporary.defaults), locale: Locale(identifier: "de_CH")).numberFormat == spacePeriod)
        #expect(temporary.defaults.object(forKey: "numberFormat") == nil)

        // Picking the format already shown keeps it when the region changes.
        german.numberFormat = periodComma
        #expect(temporary.defaults.object(forKey: "numberFormat") as? String == numberFormatToKey(periodComma))
        #expect(Preferences(store: PreferenceStore(temporary.defaults), locale: Locale(identifier: "de_CH")).numberFormat == periodComma)
    }

    @Test("keeps the design theme, the palette and background tint on every theme, the app font, and the code font, and reads unknown ones as the defaults")
    func designTheme() throws {
        let temporary = try TemporaryDefaults()
        defer { temporary.remove() }
        let preferences = Preferences(store: PreferenceStore(temporary.defaults))
        #expect(preferences.designTheme == .classic)
        #expect(preferences.designPalette == .system)
        #expect(preferences.designBackground == .own)
        #expect(preferences.appFont == .geist)
        #expect(preferences.codeFont == .geistMono)

        preferences.designPalette = .tangerine
        preferences.designBackground = .warm
        preferences.designTheme = .frost
        preferences.designTheme = .islands
        // A palette and background chosen on one theme are every theme's.
        #expect(preferences.designPalette == .tangerine)
        #expect(preferences.designThemeBackground == .warm)
        preferences.designBackground = .classic
        preferences.appFont = .atkinson
        preferences.codeFont = .atkinsonMono
        #expect(storedKeys(temporary) == ["design-theme", "design-palette", "design-background", "app-font", "code-font"])

        let reloaded = Preferences(store: PreferenceStore(temporary.defaults))
        #expect(reloaded.designTheme == .islands)
        #expect(reloaded.designPalette == .tangerine)
        #expect(reloaded.designThemeBackground == .classic)
        // Classic draws its own backgrounds for Classic's, and keeps the
        // choice for the other themes.
        reloaded.designTheme = .classic
        #expect(reloaded.designThemeBackground == .own)
        reloaded.designTheme = .pop
        #expect(reloaded.designThemeBackground == .classic)
        #expect(reloaded.appFont == .atkinson)
        #expect(reloaded.codeFont == .atkinsonMono)

        temporary.defaults.set("neon", forKey: "design-theme")
        temporary.defaults.set("chartreuse", forKey: "design-palette")
        temporary.defaults.set("plaid", forKey: "design-background")
        temporary.defaults.set("comic", forKey: "app-font")
        // A font of the other kind isn't one of these.
        temporary.defaults.set("atkinson", forKey: "code-font")
        let unknown = Preferences(store: PreferenceStore(temporary.defaults))
        #expect(unknown.designTheme == .classic)
        #expect(unknown.designPalette == .system)
        #expect(unknown.designBackground == .own)
        #expect(unknown.appFont == .geist)
        #expect(unknown.codeFont == .geistMono)
    }

    @Test("changes the hooks and credential helper settings that GitKit and the trampoline read")
    func liveSettings() throws {
        let temporary = try TemporaryDefaults()
        defer { temporary.remove() }
        let preferences = Preferences(store: PreferenceStore(temporary.defaults))
        #expect(!useExternalCredentialHelper(defaults: temporary.defaults))
        #expect(getHooksEnvEnabled(defaults: temporary.defaults))
        #expect(getCacheHooksEnv(defaults: temporary.defaults))

        preferences.useExternalCredentialHelper = true
        preferences.hooksEnvEnabled = false
        preferences.cacheHooksEnv = false
        #expect(useExternalCredentialHelper(defaults: temporary.defaults))
        #expect(!getHooksEnvEnabled(defaults: temporary.defaults))
        #expect(!getCacheHooksEnv(defaults: temporary.defaults))

        setHooksEnvEnabled(true, defaults: temporary.defaults)
        setUseExternalCredentialHelper(false, defaults: temporary.defaults)
        let reloaded = Preferences(store: PreferenceStore(temporary.defaults))
        #expect(reloaded.hooksEnvEnabled)
        #expect(!reloaded.useExternalCredentialHelper)
        #expect(!reloaded.cacheHooksEnv)
    }

    @Suite("Code text size")
    @MainActor
    struct CodeTextSizeTests {
        @Test("snaps a size between desktop's factors to the closest before stepping")
        func snaps() {
            // Factors stored imprecisely land between the steps.
            #expect(CodeTextSize(factor: 1.04).larger.factor == 1.1)
            #expect(CodeTextSize(factor: 1.04).smaller.factor == 0.9)
            #expect(CodeTextSize(factor: 1.2).larger.factor == 1.5)
            #expect(CodeTextSize(factor: 1.2).smaller.factor == 1.1)
            #expect(CodeTextSize(factor: 1.99).larger.factor == 2)
            #expect(CodeTextSize(factor: 0.68).smaller.factor == 0.67)
        }

        @Test("clamps sizes outside desktop's range, and reads a factor that isn't a number as the actual size")
        func clamps() {
            #expect(CodeTextSize(factor: 5).factor == 2)
            #expect(CodeTextSize(factor: 0.1).factor == 0.67)
            #expect(CodeTextSize(factor: .nan) == .actual)
            #expect(CodeTextSize(factor: .infinity) == .actual)
            #expect(CodeTextSize(factor: 0.8) < .actual)
        }

        @Test("grows, shrinks, and resets the stored size, as a property-list number under Espalier's key")
        func preference() throws {
            let temporary = try TemporaryDefaults()
            defer { temporary.remove() }
            let preferences = Preferences(store: PreferenceStore(temporary.defaults))

            preferences.increaseCodeTextSize()
            preferences.increaseCodeTextSize()
            #expect(preferences.codeTextSize.factor == 1.25)
            let stored = temporary.defaults.object(forKey: "diff-code-text-size")
            #expect(stored as? Double == 1.25)
            #expect(!isPropertyListBoolean(stored))
            #expect(Preferences(store: PreferenceStore(temporary.defaults)).codeTextSize.factor == 1.25)

            preferences.decreaseCodeTextSize()
            #expect(preferences.codeTextSize.factor == 1.1)
            preferences.resetCodeTextSize()
            #expect(preferences.codeTextSize == .actual)
            #expect(temporary.defaults.object(forKey: "diff-code-text-size") as? Double == 1)

            for _ in 0..<20 {
                preferences.decreaseCodeTextSize()
            }
            #expect(preferences.codeTextSize.factor == 0.67)
        }

        @Test("reads a size set by hand, and anything unusable as the actual size")
        func lenientReads() throws {
            let readable: [(Any, Double)] = [("1.5", 1.5), (" 0.8 ", 0.8), (2, 2), (1.75, 1.75), ("9", 2)]
            let unreadable: [Any] = ["", "large", "-1", 0, -2, true, "nan", ["1.5"]]
            for (value, factor) in readable {
                let temporary = try TemporaryDefaults()
                defer { temporary.remove() }
                temporary.defaults.set(value, forKey: "diff-code-text-size")
                #expect(Preferences(store: PreferenceStore(temporary.defaults)).codeTextSize.factor == factor, "\(value)")
            }
            for value in unreadable {
                let temporary = try TemporaryDefaults()
                defer { temporary.remove() }
                temporary.defaults.set(value, forKey: "diff-code-text-size")
                #expect(Preferences(store: PreferenceStore(temporary.defaults)).codeTextSize == .actual, "\(value)")
            }
        }
    }

    @Suite("Integrations")
    @MainActor
    struct Integrations {
        @Test("reads each integration setting from its own key, in desktop's formats")
        func reads() throws {
            let temporary = try TemporaryDefaults()
            defer { temporary.remove() }
            temporary.defaults.set("Visual Studio Code", forKey: "externalEditor")
            temporary.defaults.set("iTerm2", forKey: "shell")
            temporary.defaults.set("1", forKey: "use-custom-editor")
            temporary.defaults.set(#"{"path":"/usr/local/bin/code","arguments":"--wait %TARGET_PATH%"}"#, forKey: "custom-editor")
            temporary.defaults.set(true, forKey: "use-custom-shell")
            temporary.defaults.set(
                #"{"path":"/Applications/Ghostty.app","arguments":["--working-directory=%TARGET_PATH%","--new-window"],"bundleID":"com.mitchellh.ghostty"}"#,
                forKey: "custom-shell"
            )

            let preferences = Preferences(store: PreferenceStore(temporary.defaults))
            #expect(
                preferences.integrations == IntegrationSettings(
                    selectedExternalEditor: "Visual Studio Code",
                    selectedShell: .iTerm2,
                    useCustomEditor: true,
                    customEditor: CustomIntegration(path: "/usr/local/bin/code", arguments: "--wait %TARGET_PATH%"),
                    useCustomShell: true,
                    customShell: CustomIntegration(
                        path: "/Applications/Ghostty.app",
                        arguments: "--working-directory=%TARGET_PATH% --new-window",
                        bundleID: "com.mitchellh.ghostty"
                    )
                )
            )
        }

        @Test("reads an empty editor as none, an empty or unknown shell as Terminal, and unreadable values as the defaults")
        func unreadable() throws {
            let temporary = try TemporaryDefaults()
            defer { temporary.remove() }
            temporary.defaults.set("", forKey: "externalEditor")
            temporary.defaults.set("Command Prompt", forKey: "shell")
            temporary.defaults.set("yes", forKey: "use-custom-editor")
            temporary.defaults.set(#"{"arguments":"%TARGET_PATH%"}"#, forKey: "custom-editor")
            temporary.defaults.set("2", forKey: "use-custom-shell")
            temporary.defaults.set("{corrupt", forKey: "custom-shell")
            #expect(Preferences(store: PreferenceStore(temporary.defaults)).integrations == IntegrationSettings())

            temporary.defaults.set("", forKey: "shell")
            #expect(Preferences(store: PreferenceStore(temporary.defaults)).integrations.selectedShell == .terminal)
        }

        @Test("writes only the integration settings that change, each to its own key")
        func writes() throws {
            let temporary = try TemporaryDefaults()
            defer { temporary.remove() }
            let preferences = Preferences(store: PreferenceStore(temporary.defaults))

            preferences.integrations.selectedShell = .ghostty
            #expect(storedKeys(temporary) == ["shell"])
            #expect(temporary.defaults.object(forKey: "shell") as? String == "Ghostty")

            let editor = CustomIntegration(path: "/usr/local/bin/code", arguments: "--wait %TARGET_PATH%")
            preferences.integrations.customEditor = editor
            preferences.integrations.useCustomEditor = true
            preferences.integrations.selectedExternalEditor = "Zed"
            #expect(storedKeys(temporary) == ["shell", "custom-editor", "use-custom-editor", "externalEditor"])
            #expect(isPropertyListBoolean(temporary.defaults.object(forKey: "use-custom-editor")))
            #expect(temporary.defaults.object(forKey: "externalEditor") as? String == "Zed")
            let stored = try #require(temporary.defaults.object(forKey: "custom-editor") as? String)
            #expect(try JSONDecoder().decode(CustomIntegration.self, from: Data(stored.utf8)) == editor)

            let shell = CustomIntegration(path: "/Applications/Term.app", arguments: "%TARGET_PATH%", bundleID: "com.example.term")
            preferences.integrations = IntegrationSettings(
                selectedExternalEditor: "Zed",
                selectedShell: .ghostty,
                useCustomEditor: true,
                customEditor: editor,
                useCustomShell: true,
                customShell: shell
            )
            #expect(storedKeys(temporary) == ["shell", "custom-editor", "use-custom-editor", "externalEditor", "use-custom-shell", "custom-shell"])
            #expect(Preferences(store: PreferenceStore(temporary.defaults)).integrations == preferences.integrations)

            // Clearing a setting removes its key.
            preferences.integrations.selectedExternalEditor = nil
            preferences.integrations.customShell = nil
            #expect(temporary.defaults.object(forKey: "externalEditor") == nil)
            #expect(temporary.defaults.object(forKey: "custom-shell") == nil)
            #expect(Preferences(store: PreferenceStore(temporary.defaults)).integrations == preferences.integrations)
        }
    }
}
