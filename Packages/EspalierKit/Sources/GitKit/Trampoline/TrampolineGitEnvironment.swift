// Ported from desktop/app/src/lib/trampoline/trampoline-environment.ts
//
// The parts that don't depend on the app: the credential URL, the user
// agent, the credential helper configuration, and the cancelled
// authentication error. EspalierCore's TrampolineEnvironment has
// `withTrampolineEnv`.

import EspalierSupport
import Foundation
import os

private let logger = Log.logger(category: "trampoline")

/// The first argument espalier-askpass receives when git runs it as a
/// credential helper. The helper's own copy is
/// `TrampolineWire.credentialHelperArgument`.
public let credentialHelperArgument = "--credential-helper"

/// The `credential.helper` value that runs espalier-askpass as git's
/// credential helper: `!'<helper>' --credential-helper`.
///
/// The helper is named by its absolute path, so the bundled git needs no
/// extra files. Git runs a helper that starts with `!` through the shell,
/// appending the action (`get`, `store`, `erase`), so the path is quoted for
/// the shell and may contain spaces and quotes. (A plain absolute path also
/// runs through the shell, but a quoted path no longer starts with `/`, which
/// is how git recognizes one.)
public func credentialHelperConfigValue(helperPath: String) -> String {
    "!\(posixShellQuote(helperPath)) \(credentialHelperArgument)"
}

/// The `GIT_CONFIG_PARAMETERS` value that makes espalier-askpass git's only
/// credential helper, after the `existing` parameters.
///
/// This warrants some explanation. We're configuring the credential helper
/// using environment variables rather than arguments (i.e.
/// `-c credential.helper=`) because we want commands invoked by filters
/// (i.e. Git LFS) to be able to pick up our configuration. Arguments passed
/// to git commands are not passed down to filters.
///
/// We're using the undocumented GIT_CONFIG_PARAMETERS environment variable
/// over the documented GIT_CONFIG_{COUNT,KEY,VALUE} due to an apparent bug
/// either in a Windows Python runtime dependency or in a Python project
/// commonly used to manage hooks which isn't able to handle the blank
/// environment variables we need when using GIT_CONFIG_*.
///
/// See https://github.com/git/git/blob/ed155187b429a/config.c#L664
public func trampolineGitConfigParameters(existing: String, helperPath: String) -> String {
    GitConfigParameters.appending(
        [
            GitConfigParameters.parameter("credential.helper", ""),
            GitConfigParameters.parameter("credential.helper", credentialHelperConfigValue(helperPath: helperPath)),
        ],
        to: existing
    )
}

/// The URL a credential describes: its `url` attribute, or the URL built
/// from `protocol`, `username`, `host`, and `path`.
public func getCredentialUrl(_ cred: GitCredential) throws(JSURLError) -> JSURL {
    if let u = cred["url"], !u.isEmpty {
        return try JSURL(u)
    }

    let proto = cred["protocol"] ?? ""
    let username = cred["username"] ?? ""
    let user = username.isEmpty ? "" : "\(JSURL.encodeURIComponent(username))@"
    let host = cred["host"] ?? ""
    // Git sends the path decoded. WHATWG URLs percent-encode what a path
    // can't hold, and JSURL needs it encoded.
    let path = (cred["path"] ?? "").addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? ""

    return try JSURL("\(proto)://\(user)\(host)/\(path)")
}

/// `git/<git version> (<app>/<app version>; darwin <arch>)`, sent to remotes
/// as git's user agent.
///
/// Callers memoize it.
public func gitUserAgent(appName: String = "Espalier", appVersion: String, runtime: GitRuntime = .current) async -> String {
    var version = "unknown"
    do {
        // Can't use git() as that will call withTrampolineEnv which calls
        // this method
        let result = try await Dugite.exec(["--version"], "/", runtime: runtime)
        // https://github.com/git/git/blob/a9e066fa63149291a55f383cfa113d8bdbdaa6b3/help.c#L733-L739
        if let match = JSCompat.match(String(decoding: result.stdout, as: UTF8.self), gitVersionRe), let parsed = match[1] {
            version = parsed
        }
    } catch is CancellationError {
        // The caller is going away; the result doesn't matter.
    } catch {
        logger.warning("Could not get git version information: \(error.localizedDescription, privacy: .public)")
    }

    #if arch(arm64)
    let arch = "arm64"
    #else
    let arch = "x64"
    #endif
    return "git/\(version) (\(appName)/\(appVersion); darwin \(arch))"
}

private let gitVersionRe = JSCompat.regex("git version (\(JSCompat.dot)*)")

private let fatalPromptsDisabledRe = JSCompat.regex(
    #"^fatal: could not read "# + JSCompat.dot + #"*?: terminal prompts disabled\n\z"#
)

/// When the credential helper provides no credentials, git knows it and,
/// instead of trying to authenticate with an empty string, exits with an
/// error saying that it couldn't read the username since terminal prompts
/// were disabled.
///
/// Returns the user-friendly authentication failed error when `error` is
/// that error, else `nil`. Call it only when the credential helper rejected
/// credentials during the operation.
public func userCancelledAuthenticationError(_ error: any Error) -> GitError? {
    guard let error = error as? GitError, JSCompat.match(error.message, fatalPromptsDisabledRe) != nil else {
        return nil
    }

    let msg = "Authentication failed: user cancelled authentication"
    let gitErrorDescription = getDescriptionForError(.httpsAuthenticationFailed, "") ?? msg
    let result = GitResult(
        stdoutData: error.result.stdoutData,
        stderrData: error.result.stderrData,
        exitCode: error.result.exitCode,
        gitError: error.result.gitError,
        gitErrorDescription: gitErrorDescription,
        path: error.result.path
    )
    return GitError(result: result, args: error.args, terminalOutput: msg)
}

/// Whether `error` is git failing to authenticate over SSH.
public func isSSHAuthFailure(_ error: any Error) -> Bool {
    guard let error = error as? GitError else { return false }
    return error.result.gitError == .sshAuthenticationFailed || error.result.gitError == .sshPermissionDenied
}

/// Whether ssh-keygen, signing a commit or tag for git, rejected the
/// passphrase it was given for the key file.
public func isSigningKeyPassphraseRejected(_ error: any Error) -> Bool {
    guard let error = error as? GitError else { return false }
    return parseSigningFailure(error.result.stderr) == .badPassphrase
}
