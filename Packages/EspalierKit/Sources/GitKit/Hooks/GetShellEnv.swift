// Ported from desktop/app/src/lib/hooks/get-shell-env.ts

import EspalierSupport
import Foundation
import Synchronization

/// The environment of the user's login shell.
public enum ShellEnvResult: Sendable, Equatable {
    case success(env: [String: String])

    /// No shell was found to load the environment with. The login shell
    /// always resolves, so `getShellEnv` throws when the shell can't run
    /// instead; the hooks proxy handles both outcomes.
    case failure
}

/// The login shell's output didn't contain printenvz's output.
public enum ShellEnvError: Error, Equatable, CustomStringConvertible, LocalizedError {
    case missingStartMarker
    case missingEndMarker

    public var description: String {
        switch self {
        case .missingStartMarker: "could not find start marker in shell output"
        case .missingEndMarker: "could not find end marker in shell output"
        }
    }

    public var errorDescription: String? { description }
}

/// The variables of the user's login session that a new terminal window's
/// shell starts with: launchd gives them to every app, Terminal included.
let loginSessionVariables: Set<String> = [
    "HOME", "USER", "LOGNAME", "SHELL", "TMPDIR", "SSH_AUTH_SOCK", "__CF_USER_TEXT_ENCODING",
]

/// The session's language settings, kept too when the app has them.
let localeVariables: Set<String> = [
    "LANG", "LC_ALL", "LC_COLLATE", "LC_CTYPE", "LC_MESSAGES", "LC_MONETARY", "LC_NUMERIC", "LC_TIME",
]

/// launchd's `PATH` for the apps of a login session, which a terminal's
/// login shell starts from before its startup files add to it.
let loginSessionPath = "/usr/bin:/bin:/usr/sbin:/sbin"

/// The environment the login shell for hooks starts with: what a new
/// terminal window's shell starts with, so hooks see what they see when the
/// user commits in a terminal.
///
/// Keeps the session's variables from `environment` (the app's, whose own
/// variables, such as git's and the trampoline's, are left out) and
/// launchd's `PATH`. With an empty environment, hooks would have no `USER`,
/// `TMPDIR`, or `SSH_AUTH_SOCK` (a pre-push hook couldn't reach the SSH
/// agent), and zsh would set `LOGNAME` from `getlogin()`.
///
/// The locale comes from `environmentWithoutShell`, the app's environment
/// without the variables its own login shell loaded: a locale that shell
/// set is the startup files' to set again, and one they set only when
/// `LANG` is unset (macOS's `/etc/zprofile` sets `C.UTF-8`) yields to a
/// terminal window's, as in Terminal. Without a locale (`LANG`, `LC_ALL`,
/// and `LC_CTYPE` all unset or empty, as in an app opened from the Finder),
/// the shell gets the `LANG` a new terminal window gets, `defaultLocale()`:
/// tools in hooks then read and write UTF-8 (Ruby would read files as
/// US-ASCII and fail on the first non-ASCII byte).
func loginShellStartEnvironment(
    _ environment: [String: String],
    environmentWithoutShell: [String: String],
    defaultLocale: () -> String = defaultTerminalLocale
) -> [String: String] {
    var start = environment.filter { loginSessionVariables.contains($0.key) && !$0.value.isEmpty }
    for (name, value) in environmentWithoutShell where localeVariables.contains(name) && !value.isEmpty {
        start[name] = value
    }
    start["PATH"] = loginSessionPath
    if start["LANG"] == nil, start["LC_ALL"] == nil, start["LC_CTYPE"] == nil {
        start["LANG"] = defaultLocale()
    }
    return start
}

/// The `LANG` Terminal gives a new window's shell (its "Set locale
/// environment variables on startup" setting, on by default): the user's
/// language and region as a UTF-8 locale, such as `en_GB.UTF-8`.
public func defaultTerminalLocale() -> String {
    terminalLocale(
        language: Locale.preferredLanguages.first.flatMap { Locale.Language(identifier: $0).languageCode?.identifier },
        region: Locale.current.region?.identifier
    )
}

/// `<language>_<region>.UTF-8`, or `en_US.UTF-8` when the language or region
/// is unknown or the system has no such locale (English with the region
/// set to Germany, `en_DE.UTF-8`, has none).
func terminalLocale(
    language: String?,
    region: String?,
    isAvailable: (String) -> Bool = isLocaleAvailable
) -> String {
    if let language, let region, !language.isEmpty, !region.isEmpty {
        let name = "\(language)_\(region).UTF-8"
        if isAvailable(name) {
            return name
        }
    }
    return "en_US.UTF-8"
}

/// Whether the system has the locale `name`, all of its categories.
func isLocaleAvailable(_ name: String) -> Bool {
    let categories = LC_COLLATE_MASK | LC_CTYPE_MASK | LC_MESSAGES_MASK | LC_MONETARY_MASK | LC_NUMERIC_MASK | LC_TIME_MASK
    guard let locale = newlocale(categories, name, nil) else {
        return false
    }
    freelocale(locale)
    return true
}

/// Loads the environment of the user's login shell, so that hooks find the
/// tools it sets up (nvm, Homebrew, pyenv) even when Espalier was launched
/// from the Finder.
///
/// Runs printenvz in the shell from `getShell()` and parses its output. The
/// shell starts as a terminal's does (`loginShellStartEnvironment`), so
/// everything else in the result comes from the shell and its startup
/// files.
///
/// Throws when the shell can't be launched or its output contains no
/// environment, and `CancellationError` when the task is cancelled. The
/// shell's exit status doesn't matter once the output parses.
///
/// - Parameters:
///   - cwd: The directory to run the shell in, or `nil` for the app's current
///     directory.
///   - printenvzPath: The printenvz program to run. Defaults to
///     `getPrintenvzPath()`.
public func getShellEnv(_ cwd: String? = nil, printenvzPath: String? = nil) async throws -> ShellEnvResult {
    let printenvzPath = try printenvzPath ?? getPrintenvzPath()

    let shellInfo = getShell()
    let runtime = GitRuntime.current

    let child = try ChildProcess(ChildProcess.Configuration(
        executablePath: shellInfo.shell,
        arguments: shellInfo.args + [shellInfo.quoteCommand(printenvzPath)],
        environment: loginShellStartEnvironment(runtime.processEnvironment, environmentWithoutShell: runtime.environmentWithoutShell),
        currentDirectoryPath: cwd
    ))

    let stdout = OutputBuffer()
    child.observeStandardOutput { stdout.append($0) }

    _ = await withTaskCancellationHandler {
        await child.waitUntilExit()
    } onCancel: {
        // Interactive shells ignore SIGTERM.
        child.terminate(signal: SIGKILL)
    }
    try Task.checkCancellation()

    return .success(env: try parsePrintenvzOutput(String(decoding: stdout.data, as: UTF8.self)))
}

/// Parses the output of printenvz run in a login shell: the `KEY=VALUE\0`
/// entries between the first begin marker and the last end marker.
///
/// Not intended to be used directly. Exported only in order to allow for
/// testing.
public func parsePrintenvzOutput(_ stdout: String) throws(ShellEnvError) -> [String: String] {
    // It's possible that the user writes to stdout in their shell init
    // script which would get picked up here so we've added a marker to the
    // output of printenvz so we can be sure we're only parsing its output
    //
    // The regexes match Unicode scalars. Swift's default grapheme semantics
    // would read "\r\n", or an "=" followed by a combining mark, as one
    // character.
    let startRe = /--printenvz--begin\r?\n/.matchingSemantics(.unicodeScalar)
    let endRe = /\r?\n--printenvz--end\r?\n/.matchingSemantics(.unicodeScalar)

    guard let startMatch = stdout.firstMatch(of: startRe) else {
        throw .missingStartMarker
    }

    guard let lastEndMatch = stdout.matches(of: endRe).last else {
        throw .missingEndMarker
    }

    // JavaScript's `substring` swaps its arguments when the start comes after
    // the end. That happens when the environment is empty, because the end
    // marker's leading newline is then the begin marker's trailing one.
    let start = startMatch.range.upperBound
    let end = lastEndMatch.range.lowerBound
    let entries = stdout[min(start, end)..<max(start, end)]

    var env: [String: String] = [:]
    for match in entries.matches(of: /([^=]+)=([^\0]*)\0/.matchingSemantics(.unicodeScalar)) {
        env[String(match.output.1)] = String(match.output.2)
    }
    return env
}

/// Collects a child's standard output from the threads that deliver it.
private final class OutputBuffer: Sendable {
    private let storage = Mutex(Data())

    func append(_ chunk: Data) {
        storage.withLock { $0.append(chunk) }
    }

    var data: Data {
        storage.withLock { $0 }
    }
}
