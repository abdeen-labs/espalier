// The global git configuration's part (the LFS filters) is in
// GlobalGitSettings.swift.

import EspalierSupport
import Foundation
import GitKit
import Observation
import os
import Synchronization

private let logger = Log.logger(category: "integrations")

/// Opening repositories and files in editors, shells, the Finder, and the
/// browser, and the editor and shell settings.
///
/// The settings themselves are `Preferences.integrations`; this model
/// finds what's installed, resolves what to launch, and launches it.
/// Changing the settings through `selectEditor(_:)`, `selectShell(_:)`,
/// `setCustomEditor(path:arguments:)`, and
/// `setCustomShell(path:arguments:)` validates them first.
@MainActor @Observable
public final class IntegrationsModel {
    /// The installed editors, in `darwinExternalEditors`' order. Empty until
    /// the launch lookup finishes (`hasLoadedIntegrations`). Looked up again
    /// when Espalier becomes active, when Settings opens
    /// (`lookUpIntegrationsAgain()`), and when opening in an editor.
    public internal(set) var availableEditors: [FoundEditor] = []

    /// The installed shells, in order (Terminal, Hyper, iTerm2, PowerShell
    /// Core, Ghostty, Kitty, Alacritty, Tabby, WezTerm, Warp). Looked up
    /// again as the editors are, and when opening in a shell.
    public internal(set) var availableShells: [FoundShell] = []

    /// Whether the installed editors and shells have been looked up.
    public internal(set) var hasLoadedIntegrations = false

    /// The global Git LFS filters couldn't be installed at launch: usually
    /// they are already configured with other values
    /// (`.lfsAttributeMismatch`, whose recovery overwrites them). Nil when
    /// they installed.
    public internal(set) var lfsFiltersError: OperationError?

    /// The value `setOpenGitHubDesktopLinks(_:)` is giving GitHub Desktop's
    /// links to, until Launch Services has made the change; nil otherwise.
    public internal(set) var pendingOpenGitHubDesktopLinks: Bool?

    /// The running `reclaimGitHubDesktopLinks()`, if any.
    @ObservationIgnored var gitHubDesktopLinksReclaim: Task<Void, Never>?
    /// Whether a re-claim of GitHub Desktop's links failed or was declined
    /// since launch or the switch's last change; none runs again until one
    /// of those.
    @ObservationIgnored var gitHubDesktopLinksReclaimFailed = false

    @ObservationIgnored let environment: AppEnvironment
    @ObservationIgnored let preferences: Preferences
    /// Runs Espalier's writes of the global git configuration one at a
    /// time (GlobalGitSettings.swift).
    @ObservationIgnored let globalConfigWriter = GlobalConfigWriter()
    @ObservationIgnored private var launchTask: Task<Void, Never>?
    /// The latest lookup started by `lookUpIntegrationsAgain()`.
    @ObservationIgnored private var lookupTask: Task<Void, Never>?
    /// Counts the editor and shell lookups started, so only the latest one
    /// shows its result.
    @ObservationIgnored private var editorLookups = 0
    @ObservationIgnored private var shellLookups = 0

    init(environment: AppEnvironment, preferences: Preferences) {
        self.environment = environment
        self.preferences = preferences
    }

    // MARK: Launch

    /// Launch work: take GitHub Desktop's links back while the setting is
    /// on, look up the installed editors and shells, and install the global
    /// Git LFS filters.
    ///
    /// A selected editor that isn't installed is kept (see `resolvedEditor`),
    /// and when none is selected nothing is written: opening uses the only
    /// installed editor, or asks which one to use when there are several.
    func applicationDidLaunch() {
        guard launchTask == nil else {
            return
        }
        reclaimGitHubDesktopLinks()
        launchTask = Task {
            async let integrations: Void = refreshAvailableIntegrations()
            async let filters: Void = installGlobalLFSFiltersAtLaunch()
            _ = await (integrations, filters)
        }
    }

    /// Espalier became active: takes GitHub Desktop's links back while the
    /// setting is on, and looks up the installed editors and shells again,
    /// as one may have been installed or removed meanwhile.
    func applicationDidBecomeActive() {
        reclaimGitHubDesktopLinks()
        lookUpIntegrationsAgain()
    }

    /// Waits for the launch work, the latest lookup, and a running re-claim
    /// of GitHub Desktop's links, to finish (tests).
    func launchIdle() async {
        await launchTask?.value
        await lookupTask?.value
        await gitHubDesktopLinksReclaimIdle()
    }

    /// Looks up the installed editors and shells again, in the background:
    /// when Espalier becomes active, and when Settings opens.
    public func lookUpIntegrationsAgain() {
        lookupTask = Task {
            await refreshAvailableIntegrations()
        }
    }

    /// Looks up the installed editors and shells again. A lookup started
    /// later shows its result instead, whichever ends first.
    public func refreshAvailableIntegrations() async {
        async let editors = lookUpEditors()
        async let shells = lookUpShells()
        _ = await (editors, shells)
        if !hasLoadedIntegrations {
            hasLoadedIntegrations = true
        }
    }

    /// Looks up the installed editors, and shows them unless another lookup
    /// has started since.
    private func lookUpEditors() async -> [FoundEditor] {
        editorLookups += 1
        let lookup = editorLookups
        let editors = await environment.editors.getAvailableEditors()
        if lookup == editorLookups, availableEditors != editors {
            availableEditors = editors
        }
        return editors
    }

    /// Looks up the installed shells, and shows them unless another lookup
    /// has started since.
    private func lookUpShells() async -> [FoundShell] {
        shellLookups += 1
        let lookup = shellLookups
        let shells = await environment.shells.getAvailableShells()
        if lookup == shellLookups, availableShells != shells {
            availableShells = shells
        }
        return shells
    }

    // MARK: The editor and shell in use

    /// The selected editor's name; nil when none is selected (an empty name
    /// included).
    private var selectedEditorName: String? {
        preferences.integrations.selectedExternalEditor.flatMap { $0.isEmpty ? nil : $0 }
    }

    /// The installed editors behind the editor selection.
    public var editorResolution: ExternalEditorResolution {
        ExternalEditorResolution(selectedEditor: selectedEditorName, installed: availableEditors)
    }

    /// The editor "Open in Editor" launches when no custom editor is in use:
    /// the selected editor, or, when none was selected, the only installed
    /// one. Nil when no editor is installed, when several are and none was
    /// selected (opening asks), or when the selected one isn't installed:
    /// the choice is kept, and opening reports it missing.
    public var resolvedEditor: FoundEditor? {
        let resolution = editorResolution
        return selectedEditorName == nil ? resolution.defaultEditor : resolution.selectedEditor
    }

    /// Whether opening in the editor asks which one to use: no editor is
    /// selected or custom, and several are installed.
    public var asksForEditor: Bool {
        preferences.integrations.activeCustomEditor == nil && selectedEditorName == nil && availableEditors.count > 1
    }

    /// Whether "Open in Editor" has an editor to launch: the custom editor
    /// in use, or `resolvedEditor`, or one to ask for (`asksForEditor`).
    public var isEditorAvailable: Bool {
        preferences.integrations.activeCustomEditor != nil || resolvedEditor != nil || asksForEditor
    }

    /// Whether the selected editor isn't installed, so opening fails until
    /// another one is chosen (Settings shows the choice as unavailable).
    public var isSelectedEditorMissing: Bool {
        hasLoadedIntegrations
            && selectedEditorName != nil
            && editorResolution.selectedEditor == nil
    }

    /// The editor named in "Open in <Editor>": the selected editor, else the
    /// only one installed; nil while the custom editor is in use, or no
    /// editor is selected and there isn't exactly one, which reads "Open in
    /// External Editor".
    public var editorLabel: String? {
        guard preferences.integrations.activeCustomEditor == nil else {
            return nil
        }
        return selectedEditorName ?? editorResolution.defaultEditor?.editor
    }

    /// The shell named in "Open in <Shell>": the selected shell (Terminal
    /// by default), even when it isn't installed and opening reports it
    /// missing; nil while the custom shell is in use, which reads "Open in
    /// Shell".
    public var shellLabel: String? {
        let settings = preferences.integrations
        return settings.activeCustomShell == nil ? settings.selectedShell.rawValue : nil
    }

    // MARK: Settings

    /// Uses `editor`, one of `availableEditors`' names, from now on, instead
    /// of the custom editor. An empty name does nothing.
    public func selectEditor(_ editor: String) {
        guard !editor.isEmpty else {
            return
        }
        var settings = preferences.integrations
        settings.selectedExternalEditor = editor
        settings.useCustomEditor = false
        preferences.integrations = settings
    }

    /// Uses `shell` from now on, instead of the custom shell.
    public func selectShell(_ shell: Shell) {
        var settings = preferences.integrations
        settings.selectedShell = shell
        settings.useCustomShell = false
        preferences.integrations = settings
    }

    /// Checks a custom editor or shell as Settings' form does: the path must
    /// be an executable or an application, and the arguments must include
    /// `%TARGET_PATH%`.
    public func validateCustomIntegration(path: String, arguments: String) async -> CustomIntegrationValidation {
        let pathResult = await validateCustomIntegrationPath(path)
        let hasTargetPath = checkTargetPathArgument(parseCustomIntegrationArguments(arguments))
        return CustomIntegrationValidation(
            path: path,
            arguments: arguments,
            bundleID: pathResult.bundleID,
            isPathValid: pathResult.isValid,
            hasTargetPathArgument: hasTargetPath
        )
    }

    /// Saves a custom editor and uses it from now on, when it is valid. An
    /// invalid one changes nothing.
    ///
    /// - Returns: The validation, with messages for what's wrong.
    @discardableResult
    public func setCustomEditor(path: String, arguments: String) async -> CustomIntegrationValidation {
        let validation = await validateCustomIntegration(path: path, arguments: arguments)
        if let integration = validation.integration {
            var settings = preferences.integrations
            settings.customEditor = integration
            settings.useCustomEditor = true
            preferences.integrations = settings
        }
        return validation
    }

    /// Saves a custom shell and uses it from now on, when it is valid. An
    /// invalid one changes nothing.
    ///
    /// - Returns: The validation, with messages for what's wrong.
    @discardableResult
    public func setCustomShell(path: String, arguments: String) async -> CustomIntegrationValidation {
        let validation = await validateCustomIntegration(path: path, arguments: arguments)
        if let integration = validation.integration {
            var settings = preferences.integrations
            settings.customShell = integration
            settings.useCustomShell = true
            preferences.integrations = settings
        }
        return validation
    }

    // MARK: Opening

    /// Opens a repository, folder, or file in the editor: the custom editor
    /// when it is in use, otherwise the selected editor, or, when none is
    /// selected, the only installed one. The installed editors are looked up
    /// again first.
    ///
    /// - Throws: `.decisionRequired(.externalEditor)` when none is selected
    ///   and several are installed: the answer is saved as the selected
    ///   editor (`selectEditor(_:)`), and opening runs again.
    ///   `.integration(.editor)`: no editor is installed ("Espalier couldn't
    ///   find a supported editor…", recovery "Download Visual Studio Code"),
    ///   the selected one isn't ("Espalier couldn't find <name>…", recovery
    ///   "Open Settings"), or it can't start.
    public func openInEditor(_ path: String) async throws(OperationError) {
        let settings = preferences.integrations
        if let customEditor = settings.activeCustomEditor {
            do {
                try await launchCustomExternalEditor(path, customEditor, launcher: environment.launcher)
            } catch {
                throw await classify(error, as: .openInEditor)
            }
            return
        }
        let editors = await lookUpEditors()
        let selected = selectedEditorName
        if selected == nil, editors.count > 1 {
            throw OperationError(.decisionRequired(.externalEditor(editors: editors.map(\.editor))), operation: .openInEditor)
        }
        do {
            let resolution = ExternalEditorResolution(selectedEditor: selected, installed: editors)
            if let selected, resolution.selectedEditor == nil {
                throw ExternalEditorError.editorNotFound(selected)
            }
            guard let editor = resolution.selectedEditor ?? resolution.defaultEditor else {
                throw ExternalEditorError.noSuitableEditorInstalled
            }
            try await launchExternalEditor(path, editor, launcher: environment.launcher)
        } catch {
            throw await classify(error, as: .openInEditor)
        }
    }

    /// Opens `path` once in `editor`, without changing the settings (Open
    /// With…).
    ///
    /// - Throws: As `openInEditor(_:)`.
    public func openWith(_ path: String, editor: FoundEditor) async throws(OperationError) {
        let editors = await lookUpEditors()
        do {
            guard let found = editors.first(where: { JSCompat.strictEquals($0.editor, editor.editor) }) else {
                throw ExternalEditorError.editorNotFound(editor.editor)
            }
            try await launchExternalEditor(path, found, launcher: environment.launcher)
        } catch {
            throw await classify(error, as: .openInEditor)
        }
    }

    /// Opens `path` once with a custom editor, without saving it (Open With…
    /// with "Configure Custom Editor…"). An editor without a path does
    /// nothing.
    ///
    /// - Throws: As `openInEditor(_:)`.
    public func openWith(_ path: String, customEditor: CustomIntegration) async throws(OperationError) {
        guard !customEditor.path.isEmpty else {
            return
        }
        do {
            try await launchCustomExternalEditor(path, customEditor, launcher: environment.launcher)
        } catch {
            throw await classify(error, as: .openInEditor)
        }
    }

    /// Opens a folder in the shell: the custom shell when it is in use,
    /// otherwise the selected shell. The installed shells are looked up again
    /// first.
    ///
    /// - Throws: `.integration(.shell)` when the shell isn't installed or
    ///   its application or executable is missing (recovery "Open
    ///   Settings"); when it can't start, a generic error (`spawn <path>
    ///   <code>`).
    public func openInShell(_ path: String) async throws(OperationError) {
        let settings = preferences.integrations
        let spawnFailures = SpawnFailures()
        do {
            if let customShell = settings.activeCustomShell {
                try await launchCustomShell(customShell, path, onError: spawnFailures.record, launcher: environment.launcher)
            } else {
                guard let shell = await lookUpShells().first(where: { $0.shell == settings.selectedShell }) else {
                    throw ShellError(
                        "Espalier couldn't find \(settings.selectedShell.rawValue). Choose an available shell in Settings ▸ Integrations."
                    )
                }
                try await launchShell(shell, path, onError: spawnFailures.record, launcher: environment.launcher)
            }
        } catch {
            throw await classify(error, as: .openInShell)
        }
        // A shell that couldn't start is a generic error, not a `ShellError`.
        if let failure = spawnFailures.first {
            throw await classify(failure, as: .openInShell)
        }
    }

    /// Shows `path` in the Finder, selected in its folder ("Show in Finder"
    /// for files).
    public func showInFinder(_ path: String) {
        environment.workspace.revealInFinder(path)
    }

    /// Shows a folder's contents in the Finder: the repository's "Show in
    /// Finder".
    ///
    /// A folder opens in the Finder, unless it looks like an application,
    /// which opening would run: then nothing happens, and the UI asks
    /// before revealing it with `showInFinder(_:)`
    /// (`ShowFolderContentsResult.applicationBundle`). Anything else (a file,
    /// or a path that can't be read) is revealed in its folder.
    @discardableResult
    public func showFolderContents(_ path: String) async -> ShowFolderContentsResult {
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory) else {
            logger.error("Unable to retrieve file information for \(path, privacy: .private)")
            environment.workspace.revealInFinder(path)
            return .revealed
        }
        guard isDirectory.boolValue else {
            logger.error("Trying to get the folder contents of a non-folder at \(path, privacy: .private)")
            environment.workspace.revealInFinder(path)
            return .revealed
        }

        // Warn only when metadata identifies an application bundle; metadata
        // that can't be read counts as "not an application".
        let isBundle: Bool
        do {
            isBundle = try await isApplicationBundle(path)
        } catch {
            logger.error("Failed to load metadata for path \(path, privacy: .private): \(error.localizedDescription, privacy: .public)")
            isBundle = false
        }
        if isBundle {
            logger.info("Preventing direct open of a path identified as an application bundle")
            return .applicationBundle
        }

        if !environment.workspace.open(URL(exactFilePath: path, isDirectory: true)) {
            logger.error("Failed to open directory \(path, privacy: .private)")
        }
        return .opened
    }

    /// Opens a file in the application macOS associates with it ("Open with
    /// Default App" on a changed, conflicted, or committed file). The URL
    /// keeps the path's exact bytes (`URL(exactFilePath:)`).
    ///
    /// - Throws: `.other` when nothing opened it, as when no application
    ///   handles the file's kind.
    public func openWithDefaultApplication(_ path: String) throws(OperationError) {
        guard environment.workspace.open(URL(exactFilePath: path)) else {
            logger.error("Unable to open \(path, privacy: .private) in its default application")
            throw OperationError(
                .other("Couldn't open \(path). Check that an app is set to open this kind of file."),
                operation: .openFile
            )
        }
    }

    /// Opens `url` in the browser when it's a web page (`http` or `https`,
    /// `openWebLink(_:)`): links from GitHub, a remote, or a repository, and
    /// Espalier's own web pages. Anything else doesn't open.
    ///
    /// - Returns: Whether it opened. A failure is only logged.
    @discardableResult
    public func openInBrowser(_ url: URL) -> Bool {
        let opened = environment.workspace.openWebLink(url)
        if !opened {
            logger.error("Call to openExternal failed")
        }
        return opened
    }

    /// Opens a System Settings pane: an `x-apple.systempreferences:` URL
    /// that Espalier builds. Other URLs don't open.
    ///
    /// - Returns: Whether it opened. A failure is only logged.
    @discardableResult
    public func openSystemSettings(_ url: URL) -> Bool {
        guard url.scheme?.lowercased() == "x-apple.systempreferences" else {
            logger.error("Didn't open a System Settings link with the scheme \(url.scheme ?? "(none)", privacy: .public)")
            return false
        }
        let opened = environment.workspace.open(url)
        if !opened {
            logger.error("Could not open System Settings")
        }
        return opened
    }

    /// Opens the global git configuration file in the editor, creating it
    /// when it doesn't exist (Settings ▸ Git's "edit your global Git config
    /// file").
    ///
    /// - Throws: The editor's errors, as `openInEditor(_:)`; also when git
    ///   can't name or create the file.
    public func editGlobalGitConfig() async throws(OperationError) {
        let path: String
        do {
            let environment = environment
            path = try await globalConfigWriter.run {
                try await environment.withRuntimes { try await getGlobalConfigPath() }
            }
        } catch {
            logger.error("Could not open global Git config for editing: \(error.localizedDescription, privacy: .public)")
            throw await classify(error, as: .openInEditor)
        }
        try await openInEditor(path)
    }

    // MARK: Helpers

    /// The error an integration intent throws, classified by `ErrorClassifier`
    /// (a `ShellError`, an `ExternalEditorError`, then the default).
    func classify(_ error: any Error, as kind: OperationKind) async -> OperationError {
        await ErrorClassifier.classify(
            error,
            descriptor: OperationDescriptor(kind: kind, lanes: []),
            record: nil,
            context: ClassificationContext()
        )
    }
}

/// What showing a folder's contents did.
public enum ShowFolderContentsResult: Sendable, Equatable {
    /// The folder opened in the Finder.
    case opened
    /// The path isn't a folder, or couldn't be read: it was selected in its
    /// folder.
    case revealed
    /// The folder looks like an application, which opening would run, so
    /// nothing was done. The UI asks first (`applicationBundleTitle` and the
    /// rest), then calls `IntegrationsModel.showInFinder(_:)`.
    case applicationBundle

    /// The warning before revealing an application-like repository.
    public static let applicationBundleTitle = "Reveal Repository in Finder?"
    public static let applicationBundleMessage = "This repository might be an application."
    public static let applicationBundleDetail =
        "Opening it directly could run software. You can reveal and select it in Finder without opening it."
    /// The button that reveals it (the other is "Cancel").
    public static let applicationBundleConfirmButton = "Reveal in Finder"
}

/// A custom editor or shell, checked as Settings' form checks it.
public struct CustomIntegrationValidation: Sendable, Equatable {
    public let path: String
    public let arguments: String
    /// The bundle ID of the application at `path`, when it is one.
    public let bundleID: String?
    /// Whether `path` is an executable or an application.
    public let isPathValid: Bool
    /// Whether the arguments include `%TARGET_PATH%`.
    public let hasTargetPathArgument: Bool

    public init(path: String, arguments: String, bundleID: String?, isPathValid: Bool, hasTargetPathArgument: Bool) {
        self.path = path
        self.arguments = arguments
        self.bundleID = bundleID
        self.isPathValid = isPathValid
        self.hasTargetPathArgument = hasTargetPathArgument
    }

    /// Whether the integration can be saved.
    public var isValid: Bool {
        isPathValid && hasTargetPathArgument
    }

    /// The integration to save, when it is valid.
    public var integration: CustomIntegration? {
        isValid ? CustomIntegration(path: path, arguments: arguments, bundleID: bundleID) : nil
    }

    /// The message for an invalid path (shown once a path is entered).
    public var pathError: String? {
        isPathValid ? nil : "This path isn't an app or an executable."
    }

    /// The message for arguments without the placeholder.
    public var argumentsError: String? {
        hasTargetPathArgument ? nil : "Arguments must include the target path placeholder (\(TargetPathArgument))."
    }
}

/// Collects the spawn failures a shell launch reports to its `onError`
/// callback.
private final class SpawnFailures: Sendable {
    private let failures = Mutex<[any Error]>([])

    var record: @Sendable (any Error) -> Void {
        { error in self.failures.withLock { $0.append(error) } }
    }

    var first: (any Error)? {
        failures.withLock { $0.first }
    }
}
