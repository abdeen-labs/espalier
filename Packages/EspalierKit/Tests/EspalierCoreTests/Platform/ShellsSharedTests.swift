@testable import EspalierCore
import Foundation
import Testing
import TestSupport

/// No test launches anything: a recording launcher stands in for spawning.
@Suite("Shell lookup and launch")
struct ShellsSharedTests {
    @Test("finds the selected shell, or Terminal")
    func findShellOrDefault() async {
        let terminal = FoundShell(shell: .terminal, path: "/T/Terminal.app", bundleID: "com.apple.Terminal")
        let iTerm = FoundShell(shell: .iTerm2, path: "/T/iTerm.app", bundleID: "com.googlecode.iterm2")
        let lookup = ShellLookup(
            locator: FakeApplicationLocator(["com.apple.Terminal": "/T/Terminal.app", "com.googlecode.iterm2": "/T/iTerm.app"])
        )

        #expect(await lookup.findShellOrDefault(.iTerm2) == iTerm)
        #expect(await lookup.findShellOrDefault(.warp) == terminal)
        #expect(await ShellLookup(locator: FakeApplicationLocator()).findShellOrDefault(.warp) == nil)
    }

    @Test("launches a shell that exists, without detaching it")
    func launches() async throws {
        let directory = try createTempDirectory()
        let kitty = try makeFakeApplication(in: directory, named: "kitty.app", executable: "kitty")
        let launcher = RecordingLauncher()
        let errors = ErrorCollector()

        try await launchShell(
            FoundShell(shell: .kitty, path: "\(kitty)/Contents/MacOS/kitty", bundleID: "net.kovidgoyal.kitty"),
            "/repo",
            onError: errors.onError,
            launcher: launcher
        )

        #expect(launcher.commands == [
            LaunchCommand(
                executable: "\(kitty)/Contents/MacOS/kitty",
                arguments: ["--single-instance", "--directory", "/repo"],
                isDetached: false
            ),
        ])
        #expect(launcher.traced == [true])
        #expect(errors.collected.isEmpty)
    }

    @Test("reports a shell whose executable is missing")
    func missingShell() async throws {
        let directory = try createTempDirectory()
        // Warp is found by its application, but launching needs the
        // executable inside it.
        let warp = try makeFakeApplication(in: directory, named: "Warp.app")
        let launcher = RecordingLauncher()

        await #expect(throws: ShellError.self) {
            try await launchShell(
                FoundShell(shell: .warp, path: "\(warp)/Contents/MacOS/stable", bundleID: "dev.warp.Warp-Stable"),
                "/repo",
                onError: { _ in },
                launcher: launcher
            )
        }
        #expect(launcher.commands.isEmpty)
    }

    @Test("passes a failure to start to onError instead of throwing")
    func spawnFailure() async throws {
        let directory = try createTempDirectory()
        let terminal = try makeFakeApplication(in: directory, named: "Terminal.app")
        let failure = SpawnError(path: "/usr/bin/open", code: "ENOENT")
        let errors = ErrorCollector()

        try await launchShell(
            FoundShell(shell: .terminal, path: terminal, bundleID: "com.apple.Terminal"),
            "/repo",
            onError: errors.onError,
            launcher: RecordingLauncher(failingWith: failure)
        )

        #expect(errors.collected.count == 1)
        #expect(errors.collected.first as? SpawnError == failure)
    }

    @Suite("Custom shell")
    struct CustomShell {
        @Test("launches detached, with tracing")
        func launches() async throws {
            let directory = try createTempDirectory()
            try makeFile("\(directory)/term", permissions: 0o755)
            let app = try makeFakeApplication(in: directory, named: "Term.app", bundleIdentifier: "com.example.term")
            let launcher = RecordingLauncher()

            try await launchCustomShell(
                CustomIntegration(path: "\(directory)/term", arguments: "--cwd %TARGET_PATH%"),
                "/repo",
                onError: { _ in },
                launcher: launcher
            )
            try await launchCustomShell(
                CustomIntegration(path: app, arguments: "%TARGET_PATH%", bundleID: "com.example.term"),
                "/repo",
                onError: { _ in },
                launcher: launcher
            )

            #expect(launcher.commands == [
                LaunchCommand(executable: "\(directory)/term", arguments: ["--cwd", "/repo"], isDetached: true),
                LaunchCommand(executable: "/usr/bin/open", arguments: ["-b", "com.example.term", "/repo"], isDetached: true),
            ])
            #expect(launcher.traced == [true, true])
        }

        @Test("reports a custom shell whose path is missing")
        func missing() async throws {
            let directory = try createTempDirectory()
            let launcher = RecordingLauncher()

            await #expect(throws: ShellError.self) {
                try await launchCustomShell(
                    CustomIntegration(path: "\(directory)/term", arguments: "%TARGET_PATH%"),
                    "/repo",
                    onError: { _ in },
                    launcher: launcher
                )
            }
            #expect(launcher.commands.isEmpty)
        }

        @Test("passes a failure to start to onError")
        func spawnFailure() async throws {
            let directory = try createTempDirectory()
            try makeFile("\(directory)/term", permissions: 0o755)
            let errors = ErrorCollector()

            try await launchCustomShell(
                CustomIntegration(path: "\(directory)/term", arguments: "%TARGET_PATH%"),
                "/repo",
                onError: errors.onError,
                launcher: RecordingLauncher(failingWith: SpawnError(path: "\(directory)/term", code: "EACCES"))
            )

            #expect(errors.collected.first as? SpawnError == SpawnError(path: "\(directory)/term", code: "EACCES"))
        }
    }
}
