@testable import EspalierCore
import Foundation
import Testing
import TestSupport

/// No test launches anything: a recording launcher stands in for spawning.
@Suite("Editor launch")
struct EditorsLaunchTests {
    @Test("opens a folder with the editor's application")
    func builtInEditor() async throws {
        let directory = try createTempDirectory()
        let app = try makeFakeApplication(in: directory, named: "Visual Studio Code.app")
        let launcher = RecordingLauncher()

        try await launchExternalEditor("/repo path", FoundEditor(editor: "Visual Studio Code", path: app), launcher: launcher)

        #expect(launcher.commands == [
            LaunchCommand(executable: "/usr/bin/open", arguments: ["-a", app, "/repo path"], isDetached: true),
        ])
        #expect(launcher.traced == [false])
    }

    @Test("reports an editor whose application is gone")
    func missingEditor() async throws {
        let directory = try createTempDirectory()
        let launcher = RecordingLauncher()

        let error = await #expect(throws: ExternalEditorError.self) {
            try await launchExternalEditor("/repo", FoundEditor(editor: "Xcode", path: "\(directory)/Xcode.app"), launcher: launcher)
        }
        #expect(
            error == ExternalEditorError(
                "Espalier couldn't find 'Xcode' at path '\(directory)/Xcode.app'. Choose an available editor in Settings ▸ Integrations.",
                metadata: ExternalEditorError.Metadata(openPreferences: true)
            )
        )
        #expect(launcher.commands.isEmpty)
    }

    @Test(
        "reports an editor that can't start",
        arguments: [
            ("EACCES", "Espalier doesn't have permission to open 'Xcode'. Choose another editor in Settings ▸ Integrations."),
            ("ENOENT", "Espalier couldn't open 'Xcode'. Choose another editor in Settings ▸ Integrations."),
        ] as [(String?, String)]
    )
    func spawnFailure(code: String?, message: String) async throws {
        let directory = try createTempDirectory()
        let app = try makeFakeApplication(in: directory, named: "Xcode.app")
        let launcher = RecordingLauncher(failingWith: SpawnError(path: "/usr/bin/open", code: code))

        let error = await #expect(throws: ExternalEditorError.self) {
            try await launchExternalEditor("/repo", FoundEditor(editor: "Xcode", path: app), launcher: launcher)
        }
        #expect(error == ExternalEditorError(message, metadata: ExternalEditorError.Metadata(openPreferences: true)))
    }

    @Suite("Custom editor")
    struct CustomEditor {
        @Test("opens an application with its arguments")
        func application() async throws {
            let directory = try createTempDirectory()
            let app = try makeFakeApplication(in: directory, named: "Editor.app", bundleIdentifier: "com.example.editor")
            let launcher = RecordingLauncher()

            try await launchCustomExternalEditor(
                "/my repo",
                CustomIntegration(path: app, arguments: "--new-window '%TARGET_PATH%'", bundleID: "com.example.editor"),
                launcher: launcher
            )

            #expect(launcher.commands == [
                LaunchCommand(executable: "/usr/bin/open", arguments: ["-a", app, "--new-window", "/my repo"], isDetached: true),
            ])
        }

        @Test("runs an executable with its arguments")
        func executable() async throws {
            let directory = try createTempDirectory()
            try makeFile("\(directory)/edit", permissions: 0o755)
            let launcher = RecordingLauncher()

            try await launchCustomExternalEditor(
                "/my repo",
                CustomIntegration(path: "\(directory)/edit", arguments: "-n --goto=%TARGET_PATH% \"%TARGET_PATH%\""),
                launcher: launcher
            )

            #expect(launcher.commands == [
                LaunchCommand(
                    executable: "\(directory)/edit",
                    arguments: ["-n", "--goto=/my repo", "/my repo"],
                    isDetached: true
                ),
            ])
            #expect(launcher.traced == [false])
        }

        @Test("names a missing custom editor's path once")
        func missing() async throws {
            let directory = try createTempDirectory()
            let launcher = RecordingLauncher()

            let error = await #expect(throws: ExternalEditorError.self) {
                try await launchCustomExternalEditor(
                    "/repo",
                    CustomIntegration(path: "\(directory)/edit", arguments: "%TARGET_PATH%"),
                    launcher: launcher
                )
            }
            #expect(
                error?.message
                    == "Espalier couldn't find custom editor at path '\(directory)/edit'. Choose an available editor in Settings ▸ Integrations."
            )
            #expect(launcher.commands.isEmpty)
        }

        @Test("names the custom editor when it can't start")
        func spawnFailure() async throws {
            let directory = try createTempDirectory()
            try makeFile("\(directory)/edit", permissions: 0o755)
            let launcher = RecordingLauncher(failingWith: SpawnError(path: "\(directory)/edit", code: "EACCES"))

            let error = await #expect(throws: ExternalEditorError.self) {
                try await launchCustomExternalEditor(
                    "/repo",
                    CustomIntegration(path: "\(directory)/edit", arguments: "%TARGET_PATH%"),
                    launcher: launcher
                )
            }
            #expect(
                error?.message
                    == "Espalier doesn't have permission to open custom editor at path '\(directory)/edit'. Choose another editor in Settings ▸ Integrations."
            )
        }
    }
}
