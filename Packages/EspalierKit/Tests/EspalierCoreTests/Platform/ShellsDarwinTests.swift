@testable import EspalierCore
import Foundation
import Testing
import TestSupport

@Suite("macOS shells")
struct ShellsDarwinTests {
    @Test("parses saved labels, falling back to Terminal")
    func parse() {
        #expect(Shell.parse("iTerm2") == .iTerm2)
        #expect(Shell.parse("PowerShell Core") == .powerShellCore)
        #expect(Shell.parse("iterm2") == .terminal)
        #expect(Shell.parse("Command Prompt") == .terminal)
        #expect(Shell.parse("") == .terminal)
        // Compared by code units: KELVIN SIGN isn't K, though Swift's == says
        // it is.
        #expect(Shell.parse("\u{212A}itty") == .terminal)
    }

    @Test("finds installed shells in desktop's order, with executables for direct launches")
    func detection() async {
        let locator = FakeApplicationLocator([
            "com.apple.Terminal": "/System/Applications/Utilities/Terminal.app",
            "co.zeit.hyper": "/Applications/Hyper.app",
            "com.googlecode.iterm2": "/Applications/iTerm.app",
            "com.microsoft.powershell": "/Applications/PowerShell.app",
            "net.kovidgoyal.kitty": "/Applications/kitty.app",
            "org.alacritty": "/Applications/Alacritty.app",
            "org.tabby": "/Applications/Tabby.app",
            "com.github.wez.wezterm": "/Applications/WezTerm.app",
            "dev.warp.Warp-Stable": "/Applications/Warp.app",
            "com.mitchellh.ghostty": "/Applications/Ghostty.app",
        ])

        #expect(await getAvailableShellsDarwin(locator: locator) == [
            FoundShell(shell: .terminal, path: "/System/Applications/Utilities/Terminal.app", bundleID: "com.apple.Terminal"),
            FoundShell(shell: .hyper, path: "/Applications/Hyper.app", bundleID: "co.zeit.hyper"),
            FoundShell(shell: .iTerm2, path: "/Applications/iTerm.app", bundleID: "com.googlecode.iterm2"),
            FoundShell(shell: .powerShellCore, path: "/Applications/PowerShell.app", bundleID: "com.microsoft.powershell"),
            FoundShell(shell: .ghostty, path: "/Applications/Ghostty.app", bundleID: "com.mitchellh.ghostty"),
            FoundShell(shell: .kitty, path: "/Applications/kitty.app/Contents/MacOS/kitty", bundleID: "net.kovidgoyal.kitty"),
            FoundShell(shell: .alacritty, path: "/Applications/Alacritty.app/Contents/MacOS/alacritty", bundleID: "org.alacritty"),
            FoundShell(shell: .tabby, path: "/Applications/Tabby.app/Contents/MacOS/Tabby", bundleID: "org.tabby"),
            FoundShell(shell: .wezTerm, path: "/Applications/WezTerm.app/Contents/MacOS/wezterm", bundleID: "com.github.wez.wezterm"),
            FoundShell(shell: .warp, path: "/Applications/Warp.app/Contents/MacOS/stable", bundleID: "dev.warp.Warp-Stable"),
        ])
    }

    @Test("uses the first bundle identifier Launch Services knows, without checking the path")
    func firstIdentifierWins() async {
        let both = FakeApplicationLocator(["org.alacritty": "/A/Alacritty.app", "io.alacritty": "/B/Alacritty.app"])
        #expect(await getAvailableShellsDarwin(locator: both) == [
            FoundShell(shell: .alacritty, path: "/A/Alacritty.app/Contents/MacOS/alacritty", bundleID: "org.alacritty"),
        ])

        let second = FakeApplicationLocator(["io.alacritty": "/B/Alacritty.app"])
        #expect(await getAvailableShellsDarwin(locator: second) == [
            FoundShell(shell: .alacritty, path: "/B/Alacritty.app/Contents/MacOS/alacritty", bundleID: "io.alacritty"),
        ])

        #expect(await getAvailableShellsDarwin(locator: FakeApplicationLocator()).isEmpty)
    }

    /// A shell opened by bundle ID, one found by its executable but opened by
    /// bundle ID (Warp), and one run directly, with the command that opens
    /// each at "/my repo".
    static let launchCases: [(Shell, String, String, [String])] = [
        (Shell.terminal, "/T/Terminal.app", "/usr/bin/open", ["-b", "com.apple.Terminal", "/my repo"]),
        (Shell.warp, "/T/Warp.app/Contents/MacOS/stable", "/usr/bin/open", ["-b", "dev.warp.Warp-Stable", "/my repo"]),
        (
            Shell.kitty, "/T/kitty.app/Contents/MacOS/kitty", "/T/kitty.app/Contents/MacOS/kitty",
            ["--single-instance", "--directory", "/my repo"]
        ),
    ]

    @Test("launches a shell by bundle ID or by its executable, as desktop does", arguments: launchCases)
    func launchCommands(shell: Shell, path: String, executable: String, arguments: [String]) throws {
        let launcher = RecordingLauncher()
        let found = FoundShell(shell: shell, path: path, bundleID: getBundleIDs(shell)[0])

        try launchDarwinShell(found, "/my repo", tracing: nil, launcher: launcher)

        #expect(launcher.commands == [LaunchCommand(executable: executable, arguments: arguments, isDetached: false)])
    }

    @Test("launches a custom shell by bundle ID or by path")
    func customShellCommands() throws {
        let launcher = RecordingLauncher()

        try launchDarwinCustomShell(
            CustomIntegration(path: "/Apps/Term.app", arguments: "--cwd=%TARGET_PATH% '%TARGET_PATH%'", bundleID: "com.example.term"),
            "/my repo",
            tracing: nil,
            launcher: launcher
        )
        try launchDarwinCustomShell(
            CustomIntegration(path: "/usr/local/bin/term", arguments: "-d \"%TARGET_PATH%\""),
            "/my repo",
            tracing: nil,
            launcher: launcher
        )
        // An empty bundle ID counts as none.
        try launchDarwinCustomShell(
            CustomIntegration(path: "/usr/local/bin/term", arguments: "%TARGET_PATH%", bundleID: ""),
            "/r",
            tracing: nil,
            launcher: launcher
        )

        #expect(launcher.commands == [
            LaunchCommand(
                executable: "/usr/bin/open",
                arguments: ["-b", "com.example.term", "--cwd=/my repo", "/my repo"],
                isDetached: true
            ),
            LaunchCommand(executable: "/usr/local/bin/term", arguments: ["-d", "/my repo"], isDetached: true),
            LaunchCommand(executable: "/usr/local/bin/term", arguments: ["/r"], isDetached: true),
        ])
    }
}
