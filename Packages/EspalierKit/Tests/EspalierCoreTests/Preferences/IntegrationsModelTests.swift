// These drive `IntegrationsModel` with fake applications and a recording
// launcher, so nothing is launched.

@testable import EspalierCore
import EspalierCoreTestSupport
import EspalierSupport
import Foundation
import GitKit
import Testing
import TestSupport

private let vsCode = (name: "Visual Studio Code.app", bundleID: "com.microsoft.VSCode")
private let zed = (name: "Zed.app", bundleID: "dev.zed.Zed")
private let terminal = (name: "Terminal.app", bundleID: "com.apple.Terminal", executable: String?.none)
private let iTerm = (name: "iTerm.app", bundleID: "com.googlecode.iterm2", executable: String?.none)
private let kitty = (name: "kitty.app", bundleID: "net.kovidgoyal.kitty", executable: Optional("kitty"))

@Suite("Integrations model", .offline) @MainActor
struct IntegrationsModelTests {
    // MARK: Resolution

    @Test("looks up the installed editors and shells at launch, and saves no editor choice")
    func launchLookup() async throws {
        let fixture = try await makeIntegrationsFixture(editors: [zed, vsCode], shells: [iTerm, terminal])
        let integrations = fixture.integrations

        #expect(integrations.hasLoadedIntegrations)
        #expect(integrations.availableEditors.map(\.editor) == ["Visual Studio Code", "Zed"])
        #expect(integrations.availableShells.map(\.shell) == [.terminal, .iTerm2])
        // With several installed and none chosen, opening asks; nothing is
        // written.
        #expect(integrations.resolvedEditor == nil)
        #expect(integrations.asksForEditor)
        #expect(integrations.isEditorAvailable)
        #expect(integrations.editorLabel == nil)
        #expect(fixture.app.preferences.integrations.selectedExternalEditor == nil)
        #expect(fixture.harness.defaults.defaults.object(forKey: "externalEditor") == nil)

        // With one installed, it's the editor, and named.
        let one = try await makeIntegrationsFixture(editors: [zed])
        #expect(one.integrations.resolvedEditor?.editor == "Zed")
        #expect(!one.integrations.asksForEditor)
        #expect(one.integrations.editorLabel == "Zed")
    }

    @Test("looks up the installed editors and shells again each time Espalier becomes active, and when asked")
    func looksAgain() async throws {
        let harness = try AppHarness()
        let applications = try createTempDirectory()
        let locator = MutableApplicationLocator()
        var environment = harness.environment
        environment.editors = ExternalEditorLookup(locator: locator)
        environment.shells = ShellLookup(locator: locator)
        let app = AppModel(environment: environment)
        await app.load()
        await app.integrations.launchIdle()
        #expect(app.integrations.availableEditors.isEmpty)
        #expect(app.integrations.availableShells.isEmpty)

        locator.install(zed.bundleID, at: try makeFakeApplication(in: applications, named: zed.name, bundleIdentifier: zed.bundleID))
        locator.install(iTerm.bundleID, at: try makeFakeApplication(in: applications, named: iTerm.name, bundleIdentifier: iTerm.bundleID))
        app.setActive(false)
        app.setActive(true)
        await app.idle()
        #expect(app.integrations.availableEditors.map(\.editor) == ["Zed"])
        #expect(app.integrations.availableShells.map(\.shell) == [.iTerm2])
        #expect(app.integrations.editorLabel == "Zed")

        // Settings opening looks again too.
        locator.remove(zed.bundleID)
        app.integrations.lookUpIntegrationsAgain()
        await app.integrations.launchIdle()
        #expect(app.integrations.availableEditors.isEmpty)
        #expect(app.integrations.editorLabel == nil)
    }

    @Test("resolves the selected editor, and keeps a selected editor that isn't installed")
    func keepsSelection() async throws {
        let fixture = try await makeIntegrationsFixture(editors: [vsCode, zed]) { preferences in
            preferences.integrations.selectedExternalEditor = "Zed"
        }
        let integrations = fixture.integrations
        #expect(integrations.resolvedEditor?.editor == "Zed")
        #expect(!integrations.isSelectedEditorMissing)

        let missing = try await makeIntegrationsFixture(editors: [vsCode]) { preferences in
            preferences.integrations.selectedExternalEditor = "Sublime Text"
        }
        // The missing choice is kept, not replaced with another editor.
        #expect(missing.integrations.resolvedEditor == nil)
        #expect(!missing.integrations.isEditorAvailable)
        #expect(missing.integrations.isSelectedEditorMissing)
        #expect(missing.integrations.editorLabel == "Sublime Text")
        #expect(missing.app.preferences.integrations.selectedExternalEditor == "Sublime Text")
        #expect(missing.harness.defaults.defaults.string(forKey: "externalEditor") == "Sublime Text")
    }

    @Test("names no editor or shell while a custom one is in use, or when none is installed")
    func labels() async throws {
        let none = try await makeIntegrationsFixture()
        #expect(none.integrations.resolvedEditor == nil)
        #expect(!none.integrations.isEditorAvailable)
        #expect(none.integrations.editorLabel == nil)
        #expect(none.integrations.shellLabel == "Terminal")
        #expect(!none.integrations.isSelectedEditorMissing)

        let custom = try await makeIntegrationsFixture(editors: [vsCode]) { preferences in
            preferences.integrations = IntegrationSettings(
                selectedExternalEditor: "Visual Studio Code",
                selectedShell: .iTerm2,
                useCustomEditor: true,
                customEditor: CustomIntegration(path: "/usr/bin/vim", arguments: TargetPathArgument),
                useCustomShell: true,
                customShell: CustomIntegration(path: "/bin/zsh", arguments: TargetPathArgument)
            )
        }
        #expect(custom.integrations.editorLabel == nil)
        #expect(custom.integrations.shellLabel == nil)
        #expect(custom.integrations.isEditorAvailable)

        // Turned on without a saved integration, the built-in ones are used,
        // and named.
        custom.app.preferences.integrations.customEditor = nil
        custom.app.preferences.integrations.customShell = nil
        #expect(custom.integrations.editorLabel == "Visual Studio Code")
        #expect(custom.integrations.shellLabel == "iTerm2")
    }

    @Test("before the launch lookup, no editor is resolved or missing")
    func beforeLookup() async throws {
        let fixture = try await makeIntegrationsFixture(editors: [vsCode], load: false) { preferences in
            preferences.integrations.selectedExternalEditor = "Visual Studio Code"
        }
        #expect(!fixture.integrations.hasLoadedIntegrations)
        #expect(fixture.integrations.resolvedEditor == nil)
        #expect(!fixture.integrations.isSelectedEditorMissing)

        await fixture.integrations.refreshAvailableIntegrations()
        #expect(fixture.integrations.resolvedEditor?.editor == "Visual Studio Code")
    }

    // MARK: Settings

    @Test("choosing an editor or a shell turns the custom one off")
    func selecting() async throws {
        let fixture = try await makeIntegrationsFixture(editors: [vsCode, zed]) { preferences in
            preferences.integrations.useCustomEditor = true
            preferences.integrations.useCustomShell = true
        }
        let integrations = fixture.integrations

        integrations.selectEditor("Zed")
        integrations.selectShell(.ghostty)
        #expect(fixture.app.preferences.integrations.selectedExternalEditor == "Zed")
        #expect(!fixture.app.preferences.integrations.useCustomEditor)
        #expect(fixture.app.preferences.integrations.selectedShell == .ghostty)
        #expect(!fixture.app.preferences.integrations.useCustomShell)
        #expect(fixture.harness.defaults.defaults.string(forKey: "externalEditor") == "Zed")
        #expect(fixture.harness.defaults.defaults.string(forKey: "shell") == "Ghostty")
        #expect(integrations.resolvedEditor?.editor == "Zed")

        integrations.selectEditor("")
        #expect(fixture.app.preferences.integrations.selectedExternalEditor == "Zed")
    }

    @Test("saves a custom editor or shell only when it is valid, with an error for what isn't")
    func customIntegrations() async throws {
        let fixture = try await makeIntegrationsFixture()
        let integrations = fixture.integrations
        let directory = try createTempDirectory()
        let executable = POSIXPath.join(directory, "edit")
        try makeFile(executable, permissions: 0o755)
        let application = try makeFakeApplication(in: directory, named: "Nova.app", bundleIdentifier: "com.panic.Nova")

        let noPlaceholder = await integrations.setCustomEditor(path: executable, arguments: "--wait")
        #expect(!noPlaceholder.isValid)
        #expect(noPlaceholder.pathError == nil)
        #expect(noPlaceholder.argumentsError != nil)
        let badPath = await integrations.setCustomEditor(path: POSIXPath.join(directory, "missing"), arguments: TargetPathArgument)
        #expect(badPath.pathError != nil)
        #expect(badPath.argumentsError == nil)
        #expect(fixture.app.preferences.integrations.customEditor == nil)
        #expect(!fixture.app.preferences.integrations.useCustomEditor)

        let editor = await integrations.setCustomEditor(path: executable, arguments: "--wait %TARGET_PATH%")
        #expect(editor.isValid)
        #expect(fixture.app.preferences.integrations.customEditor == CustomIntegration(path: executable, arguments: "--wait %TARGET_PATH%"))
        #expect(fixture.app.preferences.integrations.useCustomEditor)

        let shell = await integrations.setCustomShell(path: application, arguments: TargetPathArgument)
        #expect(shell.bundleID == "com.panic.Nova")
        #expect(fixture.app.preferences.integrations.customShell == CustomIntegration(
            path: application,
            arguments: TargetPathArgument,
            bundleID: "com.panic.Nova"
        ))
        #expect(fixture.app.preferences.integrations.useCustomShell)
        let stored = try #require(fixture.harness.defaults.defaults.string(forKey: "custom-shell"))
        #expect(stored.contains("\"bundleID\":\"com.panic.Nova\""))

        // An invalid one leaves the saved one in use.
        await integrations.setCustomShell(path: "", arguments: TargetPathArgument)
        #expect(fixture.app.preferences.integrations.customShell?.path == application)
    }

    // MARK: Opening in the editor

    @Test("with no editor chosen, opens a path in the only one installed with open -a, without asking or saving it")
    func opensInOnlyEditor() async throws {
        let fixture = try await makeIntegrationsFixture(editors: [zed])

        try await fixture.integrations.openInEditor("/repo")

        #expect(fixture.launcher.commands == [openApplicationCommand(fixture.applicationPath(zed.name), ["/repo"])])
        #expect(fixture.app.preferences.integrations.selectedExternalEditor == nil)
    }

    @Test("with no editor chosen and several installed, asks which one, then opens in the editor chosen")
    func asksForEditor() async throws {
        let fixture = try await makeIntegrationsFixture(editors: [zed, vsCode])

        let error = await #expect(throws: OperationError.self) {
            try await fixture.integrations.openInEditor("/repo")
        }
        #expect(error?.reason == .decisionRequired(.externalEditor(editors: ["Visual Studio Code", "Zed"])))
        #expect(error?.operation == .openInEditor)
        #expect(fixture.launcher.commands.isEmpty)

        // The answer is saved as the editor, and opening runs again.
        fixture.integrations.selectEditor("Zed")
        try await fixture.integrations.openInEditor("/repo")
        #expect(fixture.launcher.commands == [openApplicationCommand(fixture.applicationPath(zed.name), ["/repo"])])
        #expect(fixture.harness.defaults.defaults.string(forKey: "externalEditor") == "Zed")
    }

    @Test("opens a path in the custom editor, with the path in its arguments")
    func opensInCustomEditor() async throws {
        let directory = try createTempDirectory()
        let executable = POSIXPath.join(directory, "edit")
        try makeFile(executable, permissions: 0o755)
        let fixture = try await makeIntegrationsFixture(editors: [vsCode]) { preferences in
            preferences.integrations.useCustomEditor = true
            preferences.integrations.customEditor = CustomIntegration(path: executable, arguments: "--wait '%TARGET_PATH%' -n")
        }

        try await fixture.integrations.openInEditor("/repo $$ path")

        #expect(fixture.launcher.commands == [
            LaunchCommand(executable: executable, arguments: ["--wait", "/repo $$ path", "-n"], isDetached: true),
        ])
    }

    @Test("reports that no editor is installed, offering desktop's suggested editor")
    func noEditor() async throws {
        let fixture = try await makeIntegrationsFixture()

        let error = await #expect(throws: OperationError.self) {
            try await fixture.integrations.openInEditor("/repo")
        }
        #expect(error?.operation == .openInEditor)
        if case .integration(.editor(message: _, suggestDefaultEditor: true, openPreferences: false))? = error?.reason {} else {
            Issue.record("Unexpected reason \(String(describing: error?.reason))")
        }
        #expect(error?.recoveries.map(\.kind) == [.downloadSuggestedEditor])
        #expect(fixture.launcher.commands.isEmpty)

        // The recovery opens the suggested editor's website.
        let recovery = try #require(error?.recoveries.first)
        try await recovery.perform(in: fixture.app)
        #expect(fixture.harness.workspace.openedURLs == [URL(string: "https://code.visualstudio.com")!])
    }

    @Test("reports a selected editor that isn't installed, offering Settings")
    func missingSelectedEditor() async throws {
        let fixture = try await makeIntegrationsFixture(editors: [vsCode]) { preferences in
            preferences.integrations.selectedExternalEditor = "Xcode"
        }

        let error = await #expect(throws: OperationError.self) {
            try await fixture.integrations.openInEditor("/repo")
        }
        if case .integration(.editor(message: _, suggestDefaultEditor: false, openPreferences: true))? = error?.reason {} else {
            Issue.record("Unexpected reason \(String(describing: error?.reason))")
        }
        #expect(error?.recoveries.map(\.kind) == [.openSettings(.integrations)])
        #expect(fixture.launcher.commands.isEmpty)
    }

    @Test("finds an editor installed after launch found none, and names it")
    func editorInstalledLater() async throws {
        let harness = try AppHarness()
        let applications = try createTempDirectory()
        let locator = MutableApplicationLocator()
        let launcher = RecordingLauncher()
        var environment = harness.environment
        environment.editors = ExternalEditorLookup(locator: locator)
        environment.launcher = launcher
        let app = AppModel(environment: environment)
        await app.load()
        await app.integrations.launchIdle()
        #expect(app.integrations.availableEditors.isEmpty)
        #expect(app.integrations.editorLabel == nil)

        let path = try makeFakeApplication(in: applications, named: zed.name, bundleIdentifier: zed.bundleID)
        locator.install(zed.bundleID, at: path)
        try await app.integrations.openInEditor("/repo")

        #expect(launcher.commands == [openApplicationCommand(path, ["/repo"])])
        #expect(app.integrations.availableEditors.map(\.editor) == ["Zed"])
        #expect(app.integrations.editorLabel == "Zed")
    }

    // MARK: Open With

    @Test("opens a path once in another editor, without changing the settings")
    func openWithEditor() async throws {
        let fixture = try await makeIntegrationsFixture(editors: [vsCode, zed])
        let zedEditor = try #require(fixture.integrations.availableEditors.first { $0.editor == "Zed" })

        try await fixture.integrations.openWith("/repo", editor: zedEditor)

        #expect(fixture.launcher.commands == [openApplicationCommand(fixture.applicationPath(zed.name), ["/repo"])])
        #expect(fixture.app.preferences.integrations == IntegrationSettings())

        // An editor that is gone is reported as missing.
        let gone = FoundEditor(editor: "Xcode", path: "/Applications/Xcode.app")
        let error = await #expect(throws: OperationError.self) {
            try await fixture.integrations.openWith("/repo", editor: gone)
        }
        if case .integration(.editor)? = error?.reason {} else {
            Issue.record("Unexpected reason \(String(describing: error?.reason))")
        }
    }

    @Test("opens a path once with a custom editor, an application through open -a, and nothing without a path")
    func openWithCustomEditor() async throws {
        let fixture = try await makeIntegrationsFixture()
        let directory = try createTempDirectory()
        let application = try makeFakeApplication(in: directory, named: "Nova.app", bundleIdentifier: "com.panic.Nova")

        try await fixture.integrations.openWith(
            "/repo",
            customEditor: CustomIntegration(path: application, arguments: TargetPathArgument, bundleID: "com.panic.Nova")
        )
        try await fixture.integrations.openWith("/repo", customEditor: CustomIntegration(path: "", arguments: TargetPathArgument))

        #expect(fixture.launcher.commands == [openApplicationCommand(application, ["/repo"])])
        #expect(fixture.app.preferences.integrations.customEditor == nil)

        let error = await #expect(throws: OperationError.self) {
            try await fixture.integrations.openWith(
                "/repo",
                customEditor: CustomIntegration(path: POSIXPath.join(directory, "gone"), arguments: TargetPathArgument)
            )
        }
        if case .integration(.editor)? = error?.reason {} else {
            Issue.record("Unexpected reason \(String(describing: error?.reason))")
        }
    }

    // MARK: Opening in the shell

    @Test("opens a folder in Terminal by default, with open -b")
    func opensInTerminal() async throws {
        let fixture = try await makeIntegrationsFixture(shells: [terminal, iTerm])

        try await fixture.integrations.openInShell("/repo")

        #expect(fixture.launcher.commands == [
            LaunchCommand(executable: "/usr/bin/open", arguments: ["-b", "com.apple.Terminal", "/repo"], isDetached: false),
        ])
        #expect(fixture.launcher.traced == [true])
    }

    @Test("opens a folder in the selected shell, its executable for Kitty")
    func opensInSelectedShell() async throws {
        let fixture = try await makeIntegrationsFixture(shells: [terminal, kitty]) { preferences in
            preferences.integrations.selectedShell = .kitty
        }
        try await fixture.integrations.openInShell("/repo")

        #expect(fixture.launcher.commands == [
            LaunchCommand(
                executable: POSIXPath.join(fixture.applicationPath(kitty.name), "Contents/MacOS/kitty"),
                arguments: ["--single-instance", "--directory", "/repo"],
                isDetached: false
            ),
        ])
    }

    @Test("reports a selected shell that isn't installed, offering Settings, and opens nothing else")
    func selectedShellNotInstalled() async throws {
        let fixture = try await makeIntegrationsFixture(shells: [terminal]) { preferences in
            preferences.integrations.selectedShell = .warp
        }

        let error = await #expect(throws: OperationError.self) {
            try await fixture.integrations.openInShell("/repo")
        }
        if case .integration(.shell)? = error?.reason {} else {
            Issue.record("Unexpected reason \(String(describing: error?.reason))")
        }
        #expect(error?.recoveries.map(\.kind) == [.openSettings(.integrations)])
        #expect(fixture.launcher.commands.isEmpty)
        // The choice is kept, and the label names it.
        #expect(fixture.app.preferences.integrations.selectedShell == .warp)
        #expect(fixture.integrations.shellLabel == "Warp")
    }

    @Test("opens a folder in the custom shell")
    func opensInCustomShell() async throws {
        let directory = try createTempDirectory()
        let executable = POSIXPath.join(directory, "term")
        try makeFile(executable, permissions: 0o755)
        let fixture = try await makeIntegrationsFixture(shells: [terminal]) { preferences in
            preferences.integrations.useCustomShell = true
            preferences.integrations.customShell = CustomIntegration(path: executable, arguments: "--cwd=%TARGET_PATH%")
        }

        try await fixture.integrations.openInShell("/repo")

        #expect(fixture.launcher.commands == [
            LaunchCommand(executable: executable, arguments: ["--cwd=/repo"], isDetached: true),
        ])
    }

    @Test("reports a shell whose executable is gone in the shell dialog, offering Settings")
    func missingShellExecutable() async throws {
        // Kitty's application without its executable.
        let fixture = try await makeIntegrationsFixture(shells: [(name: "kitty.app", bundleID: "net.kovidgoyal.kitty", executable: nil)]) { preferences in
            preferences.integrations.selectedShell = .kitty
        }

        let error = await #expect(throws: OperationError.self) {
            try await fixture.integrations.openInShell("/repo")
        }
        #expect(error?.operation == .openInShell)
        if case .integration(.shell)? = error?.reason {} else {
            Issue.record("Unexpected reason \(String(describing: error?.reason))")
        }
        #expect(error?.recoveries.map(\.kind) == [.openSettings(.integrations)])
        #expect(fixture.launcher.commands.isEmpty)
    }

    @Test("reports a shell that can't start in the generic error dialog, as desktop did")
    func shellFailsToStart() async throws {
        let fixture = try await makeIntegrationsFixture(
            shells: [terminal],
            launcherFailure: SpawnError(path: "/usr/bin/open", code: "ENOENT")
        )

        let error = await #expect(throws: OperationError.self) {
            try await fixture.integrations.openInShell("/repo")
        }
        if case .other? = error?.reason {} else {
            Issue.record("Unexpected reason \(String(describing: error?.reason))")
        }
        #expect(error?.recoveries.isEmpty == true)
    }

    @Test("reports that no shell is installed, not even Terminal")
    func noShell() async throws {
        let fixture = try await makeIntegrationsFixture()

        let error = await #expect(throws: OperationError.self) {
            try await fixture.integrations.openInShell("/repo")
        }
        if case .integration(.shell)? = error?.reason {} else {
            Issue.record("Unexpected reason \(String(describing: error?.reason))")
        }
    }

    // MARK: Finder and browser

    @Test("opens a folder in the Finder, and reveals a file or a missing path")
    func showsFolderContents() async throws {
        let fixture = try await makeIntegrationsFixture()
        // A precomposed name, made byte for byte (FileManager would
        // decompose it).
        let folder = POSIXPath.join(try createTempDirectory(), "caf\u{e9}")
        #expect(mkdir(folder, 0o755) == 0)
        let file = POSIXPath.join(folder, "notes.txt")
        try Data("notes\n".utf8).write(to: URL(exactFilePath: file))

        #expect(await fixture.integrations.showFolderContents(folder) == .opened)
        #expect(await fixture.integrations.showFolderContents(file) == .revealed)
        #expect(await fixture.integrations.showFolderContents(POSIXPath.join(folder, "gone")) == .revealed)

        let opened = fixture.harness.workspace.openedURLs
        #expect(opened == [URL(exactFilePath: folder, isDirectory: true)])
        // The folder's name reaches the Finder as it is on disk.
        #expect(opened.first?.withUnsafeFileSystemRepresentation { $0.map { String(cString: $0) } }?.utf8.elementsEqual(folder.utf8) == true)
        #expect(fixture.harness.workspace.revealedPaths == [file, POSIXPath.join(folder, "gone")])
    }

    @Test("opens a file in its default application, by its exact name, and says when nothing could open it")
    func opensWithDefaultApplication() async throws {
        let fixture = try await makeIntegrationsFixture()
        let path = "/repo/R\u{e9}sum\u{e9}.pdf"

        try fixture.integrations.openWithDefaultApplication(path)
        #expect(fixture.harness.workspace.openedURLs == [URL(exactFilePath: path)])
        #expect(fixture.harness.workspace.openedURLs.first?.withUnsafeFileSystemRepresentation { $0.map { String(cString: $0) } }?.utf8.elementsEqual(path.utf8) == true)

        fixture.harness.workspace.opens = false
        let error = #expect(throws: OperationError.self) {
            try fixture.integrations.openWithDefaultApplication("/repo/data.unknown")
        }
        if case .other? = error?.reason {} else {
            Issue.record("Unexpected reason \(String(describing: error?.reason))")
        }
        #expect(error?.operation == .openFile)
        #expect(error?.recoveries.isEmpty == true)
    }

    @Test("never opens a repository that looks like an application, which would run it")
    func applicationLikeFolder() async throws {
        let fixture = try await makeIntegrationsFixture()
        let folder = try createTempDirectory()
        let application = try makeFakeApplication(in: folder, named: "Tool.app", bundleIdentifier: "com.example.tool", executable: "tool")

        #expect(await fixture.integrations.showFolderContents(application) == .applicationBundle)
        #expect(fixture.harness.workspace.openedURLs.isEmpty)
        #expect(fixture.harness.workspace.revealedPaths.isEmpty)
    }

    @Test("the browser opens only web pages, and System Settings only its panes")
    func browserAndSystemSettings() async throws {
        let fixture = try await makeIntegrationsFixture()
        let page = try #require(URL(string: "https://github.com/octocat/hello"))
        let pane = try #require(URL(string: "x-apple.systempreferences:com.apple.Notifications-Settings.extension"))
        // A link from a server could name an app to launch.
        let app = URL(exactFilePath: "/Applications/Calculator.app", isDirectory: true)

        #expect(fixture.integrations.openInBrowser(page))
        #expect(!fixture.integrations.openInBrowser(app))
        #expect(!fixture.integrations.openInBrowser(pane))
        #expect(fixture.integrations.openSystemSettings(pane))
        #expect(!fixture.integrations.openSystemSettings(page))
        #expect(!fixture.integrations.openSystemSettings(app))
        #expect(fixture.harness.workspace.openedURLs == [page, pane])
    }

    // MARK: The global git configuration

    @Test("opens the global git configuration in the editor, creating the file")
    func editsGlobalConfig() async throws {
        try await withIsolatedGitConfig { configPath in
            let fixture = try await makeIntegrationsFixture(editors: [vsCode])
            // (The launch's Git LFS step may have written it.)
            try? FileManager.default.removeItem(atPath: configPath)

            try await fixture.integrations.editGlobalGitConfig()

            #expect(FileManager.default.fileExists(atPath: configPath))
            #expect(fixture.launcher.commands == [openApplicationCommand(fixture.applicationPath(vsCode.name), [configPath])])
        }
    }

    @Test("the Git LFS filters alert's Edit Global Git Config… opens the global configuration in the editor")
    func editGlobalConfigRecovery() async throws {
        try await withIsolatedGitConfig { configPath in
            try await setGlobalConfigValue("filter.lfs.clean", "git-lfs clean --other -- %f")
            let fixture = try await makeIntegrationsFixture(editors: [vsCode])
            let error = try #require(fixture.integrations.lfsFiltersError)
            #expect(error.recoveries.map(\.kind) == [.updateLFSFilters, .editGlobalGitConfig])
            let recovery = error.recoveries[1]
            #expect(recovery.isHeadless)

            try await recovery.perform(in: fixture.app)
            #expect(fixture.launcher.commands == [openApplicationCommand(fixture.applicationPath(vsCode.name), [configPath])])
            // The filters are left to the user.
            #expect(try await getGlobalConfigValue("filter.lfs.clean") == "git-lfs clean --other -- %f")
        }
    }
}
