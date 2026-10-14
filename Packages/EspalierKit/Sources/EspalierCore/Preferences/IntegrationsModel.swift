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
    /// The installed editors, in `darwinExternalEditors`' order; the first is
    /// the default. Empty until the launch lookup finishes
    /// (`hasLoadedIntegrations`).
    public internal(set) var availableEditors: [FoundEditor] = []

    /// The installed shells, in order (Terminal, Hyper, iTerm2, PowerShell
    /// Core, Ghostty, Kitty, Alacritty, Tabby, WezTerm, Warp).
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
    /// and when none is selected nothing is written: the default editor is
    /// the first one installed, looked up at each launch.
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

    /// Waits for the launch work, and a running re-claim of GitHub
    /// Desktop's links, to finish (tests).
    func launchIdle() async {
        await launchTask?.value
        await gitHubDesktopLinksReclaimIdle()
    }

    /// Looks up the installed editors and shells again.
    ///
    /// The editor list is kept for the life of the app once it has an editor
    /// (until then each lookup looks again), and the shell list once looked
    /// up.
    public func refreshAvailableIntegrations() async {
        let editors = environment.editors
        let shells = environment.shells
        async let foundEditors = editors.getAvailableEditors()
        async let foundShells = shells.getAvailableShells()
        let (editorList, shellList) = await (foundEditors, foundShells)
        if availableEditors != editorList {
            availableEditors = editorList
        }
        if availableShells != shellList {
            availableShells = shellList
        }
        if !hasLoadedIntegrations {
            hasLoadedIntegrations = true
        }
    }

    // MARK: The editor and shell in use

    /// The installed editors behind the editor selection
    /// (`ExternalEditorLookup.resolveExternalEditor`'s rule over the
    /// installed editors).
    public var editorResolution: ExternalEditorResolution {
        let selected = preferences.integrations.selectedExternalEditor
        return ExternalEditorResolution(
            selectedEditor: selected.flatMap { name in availableEditors.first { JSCompat.strictEquals($0.editor, name) } },
            defaultEditor: availableEditors.first
        )
    }

    /// The editor "Open in Editor" launches when no custom editor is in use:
    /// the selected editor, or, when none was selected, the first installed
    /// one. Nil when no editor is installed, or when the selected one isn't:
    /// the choice is kept, and opening reports it missing.
    public var resolvedEditor: FoundEditor? {
        let resolution = editorResolution
        return preferences.integrations.selectedExternalEditor == nil ? resolution.defaultEditor : resolution.selectedEditor
    }

    /// Whether "Open in Editor" has an editor to launch: the custom editor
    /// in use, or `resolvedEditor`.
    public var isEditorAvailable: Bool {
        preferences.integrations.activeCustomEditor != nil || resolvedEditor != nil
    }

    /// Whether the selected editor isn't installed, so opening fails until
    /// another one is chosen (Settings shows the choice as unavailable).
    public var isSelectedEditorMissing: Bool {
        hasLoadedIntegrations
            && preferences.integrations.selectedExternalEditor != nil
            && editorResolution.selectedEditor == nil
    }

    /// The editor named in "Open in <Editor>": the selected editor, else the
    /// default one; nil while the custom editor is in use or no editor is
    /// known, which reads "Open in External Editor".
    public var editorLabel: String? {
        let settings = preferences.integrations
        guard settings.activeCustomEditor == nil else {
            return nil
        }
        return settings.selectedExternalEditor ?? editorResolution.defaultEditor?.editor
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
    /// when it is in use, otherwise the selected editor, or the first
    /// installed one when none is selected.
    ///
    /// - Throws: `.integration(.editor)`: no editor is installed ("No
    ///   suitable editors installed for Espalier to launch…", recovery
    ///   "Download Visual Studio Code"), the selected one isn't ("The editor
    ///   '<name>' could not be found…", recovery "Open Settings"), or it can't
    ///   start.
    public func openInEditor(_ path: String) async throws(OperationError) {
        let settings = preferences.integrations
        do {
            if let customEditor = settings.activeCustomEditor {
                try await launchCustomExternalEditor(path, customEditor, launcher: environment.launcher)
                return
            }
            let editor = try await findEditorOrRefresh(settings.selectedExternalEditor)
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
        do {
            let found = try await findEditorOrRefresh(editor.editor)
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
    /// otherwise the selected shell.
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
                guard let shell = await environment.shells.findShell(settings.selectedShell) else {
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

    /// Opens `url` in its default app, the browser for web pages.
    ///
    /// - Returns: Whether it opened. A failure is only logged.
    @discardableResult
    public func openInBrowser(_ url: URL) -> Bool {
        let opened = environment.workspace.open(url)
        if !opened {
            logger.error("Call to openExternal failed")
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

    /// `findEditorOrDefault`, reporting "No suitable editors installed" when
    /// there's none. A lookup that finds editors after launch found none
    /// updates `availableEditors`.
    private func findEditorOrRefresh(_ name: String?) async throws(ExternalEditorError) -> FoundEditor {
        let found = try await environment.editors.findEditorOrDefault(name)
        if availableEditors.isEmpty, found != nil {
            await refreshAvailableIntegrations()
        }
        guard let found else {
            throw ExternalEditorError.noSuitableEditorInstalled
        }
        return found
    }

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
