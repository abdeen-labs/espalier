// Ported from desktop/app/src/lib/shells/darwin.ts

import EspalierSupport
import os

private let logger = Log.logger(category: "integrations")

/// The terminals Espalier can open a repository in.
///
/// The raw value is both the label shown to the user and the value saved for
/// the `shell` setting.
public enum Shell: String, CaseIterable, Sendable {
    case terminal = "Terminal"
    case hyper = "Hyper"
    case iTerm2 = "iTerm2"
    case powerShellCore = "PowerShell Core"
    case kitty = "Kitty"
    case alacritty = "Alacritty"
    case tabby = "Tabby"
    case wezTerm = "WezTerm"
    case warp = "Warp"
    case ghostty = "Ghostty"

    /// The default shell.
    public static let `default`: Shell = .terminal

    /// Parses a saved label, falling back to the default shell when the label
    /// names no shell.
    public static func parse(_ label: String) -> Shell {
        allCases.first { JSCompat.strictEquals($0.rawValue, label) } ?? .default
    }
}

/// The bundle identifiers of a shell, in the order they are looked up.
func getBundleIDs(_ shell: Shell) -> [String] {
    switch shell {
    case .terminal: ["com.apple.Terminal"]
    case .iTerm2: ["com.googlecode.iterm2"]
    case .hyper: ["co.zeit.hyper"]
    case .powerShellCore: ["com.microsoft.powershell"]
    case .kitty: ["net.kovidgoyal.kitty"]
    case .alacritty: ["org.alacritty", "io.alacritty"]
    case .tabby: ["org.tabby"]
    case .wezTerm: ["com.github.wez.wezterm"]
    case .warp: ["dev.warp.Warp-Stable"]
    case .ghostty: ["com.mitchellh.ghostty"]
    }
}

/// The application of the first of the shell's bundle identifiers that Launch
/// Services knows. Unlike an editor's, the path isn't checked here; launching
/// checks it.
func getShellInfo(_ shell: Shell, locator: any ApplicationLocator) -> (path: String, bundleID: String)? {
    for id in getBundleIDs(shell) {
        if let path = locator.appPath(id) {
            return (path, id)
        }

        logger.debug(
            "Unable to locate \(shell.rawValue, privacy: .public) installation with bundle id \(id, privacy: .public)"
        )
    }

    return nil
}

/// The installed shells, in this order: Terminal, Hyper, iTerm2,
/// PowerShell Core, Ghostty, Kitty, Alacritty, Tabby, WezTerm, Warp.
///
/// Kitty, Alacritty, Tabby, WezTerm, and Warp carry the path of the
/// executable inside the application, which is what launching checks for.
@concurrent
func getAvailableShellsDarwin(locator: any ApplicationLocator) async -> [FoundShell] {
    func info(_ shell: Shell) -> (path: String, bundleID: String)? {
        getShellInfo(shell, locator: locator)
    }

    var shells: [FoundShell] = []

    for shell in [Shell.terminal, .hyper, .iTerm2, .powerShellCore, .ghostty] {
        if let found = info(shell) {
            shells.append(FoundShell(shell: shell, path: found.path, bundleID: found.bundleID))
        }
    }

    let executables: [(Shell, String)] = [
        (.kitty, "kitty"),
        (.alacritty, "alacritty"),
        (.tabby, "Tabby"),
        (.wezTerm, "wezterm"),
        (.warp, "stable"),
    ]
    for (shell, executable) in executables {
        if let found = info(shell) {
            shells.append(
                FoundShell(shell: shell, path: "\(found.path)/Contents/MacOS/\(executable)", bundleID: found.bundleID)
            )
        }
    }

    return shells
}

/// Launches a shell at `path`.
func launchDarwinShell(
    _ foundShell: FoundShell,
    _ path: String,
    tracing: LaunchTracing?,
    launcher: any IntegrationLauncher
) throws(SpawnError) {
    let arguments: [String]
    let executable: String

    switch foundShell.shell {
    case .kitty:
        // kitty does not handle arguments as expected when using `open` with
        // an existing session but closed window (it reverts to the previous
        // directory rather than using the new directory directory).
        //
        // This workaround launches the internal `kitty` executable which
        // will open a new window to the desired path.
        executable = foundShell.path
        arguments = ["--single-instance", "--directory", path]
    case .alacritty:
        // Alacritty cannot open files in the folder format.
        //
        // It uses --working-directory command to start the shell
        // in the specified working directory.
        executable = foundShell.path
        arguments = ["--working-directory", path]
    case .tabby:
        // Tabby cannot open files in the folder format.
        //
        // It uses open command to start the shell
        // in the specified working directory.
        executable = foundShell.path
        arguments = ["open", path]
    case .wezTerm:
        // WezTerm, like Alacritty, "cannot open files in the 'folder' format."
        //
        // It uses the subcommand `start`, followed by the option `--cwd` to
        // set the working directory, followed by the path.
        executable = foundShell.path
        arguments = ["start", "--cwd", path]
    case .terminal, .hyper, .iTerm2, .powerShellCore, .warp, .ghostty:
        executable = openCommandPath
        arguments = ["-b", foundShell.bundleID, path]
    }

    try launcher.spawn(LaunchCommand(executable: executable, arguments: arguments, isDetached: false), tracing: tracing)
}

/// Launches a custom shell at `path`: `open -b <bundle ID> <arguments>`
/// for an application, otherwise `<path> <arguments>`, with
/// `%TARGET_PATH%` in the arguments replaced by `path`.
func launchDarwinCustomShell(
    _ customShell: CustomIntegration,
    _ path: String,
    tracing: LaunchTracing?,
    launcher: any IntegrationLauncher
) throws(SpawnError) {
    let argv = parseCustomIntegrationArguments(customShell.arguments)
    let args = expandTargetPathArgument(argv, path)

    // An empty bundle ID runs the path.
    if let bundleID = customShell.bundleID, !bundleID.isEmpty {
        try spawnCustomIntegration(openCommandPath, ["-b", bundleID] + args, tracing: tracing, launcher: launcher)
    } else {
        try spawnCustomIntegration(customShell.path, args, tracing: tracing, launcher: launcher)
    }
}
