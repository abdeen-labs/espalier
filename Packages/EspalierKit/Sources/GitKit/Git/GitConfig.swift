// Ported from desktop/app/src/lib/git/config.ts

import EspalierSupport
import Foundation

/// The `--type` values git config canonicalizes values with.
enum ConfigValueType: String {
    case bool
    case int
    case boolOrInt = "bool-or-int"
    case path
    case expiryDate = "expiry-date"
    case color
}

/// Where git runs for global configuration: the bundled git's directory.
func installLocation() -> String {
    GitRuntime.current.gitDirectory.path(percentEncoded: false)
}

/// An optional `env` parameter, as the git execution options take it.
private func executionEnv(_ env: [String: String]?) -> [String: String?]? {
    env?.mapValues { Optional($0) }
}

/// Look up a config value by name in the repository.
///
/// - Parameter onlyLocal: Whether or not the value to be retrieved should stick to
///   the local repository settings. It is false by default. This
///   is equivalent to using the `--local` argument in the
///   `git config` invocation.
public func getConfigValue(
    _ repository: Repository,
    _ name: String,
    onlyLocal: Bool = false
) async throws -> String? {
    try await getConfigValueInPath(name, repository.path, onlyLocal: onlyLocal)
}

/// Look up a global config value by name.
public func getGlobalConfigValue(
    _ name: String,
    env: [String: String]? = nil
) async throws -> String? {
    try await getConfigValueInPath(name, nil, onlyLocal: false, type: nil, env: env)
}

/// Look up a config value by name.
///
/// Treats the returned value as a boolean as per Git's
/// own definition of a boolean configuration value (i.e.
/// 0 -> false, "off" -> false, "yes" -> true etc)
public func getBooleanConfigValue(
    _ repository: Repository,
    _ name: String,
    onlyLocal: Bool = false,
    env: [String: String]? = nil
) async throws -> Bool? {
    let value = try await getConfigValueInPath(name, repository.path, onlyLocal: onlyLocal, type: .bool, env: env)
    return value.map { !JSCompat.strictEquals($0, "false") }
}

/// Look up a global config value by name.
///
/// Treats the returned value as a boolean as per Git's
/// own definition of a boolean configuration value (i.e.
/// 0 -> false, "off" -> false, "yes" -> true etc)
public func getGlobalBooleanConfigValue(
    _ name: String,
    env: [String: String]? = nil
) async throws -> Bool? {
    let value = try await getConfigValueInPath(name, nil, onlyLocal: false, type: .bool, env: env)
    return value.map { !JSCompat.strictEquals($0, "false") }
}

/// Look up a config value by name
///
/// - Parameters:
///   - path: The path to execute the `git` command in. If null
///     we'll use the global configuration (i.e. --global)
///     and execute the Git call from the same location that
///     Espalier is installed in.
///   - onlyLocal: Whether or not the value to be retrieved should stick to
///     the local repository settings (if a path is specified). It
///     is false by default. It is equivalent to using the `--local`
///     argument in the `git config` invocation.
///   - type: Canonicalize configuration values according to the
///     expected type (i.e. 0 -> false, "on" -> true etc).
///     See `--type` documentation in `git config`
private func getConfigValueInPath(
    _ name: String,
    _ path: String?,
    onlyLocal: Bool = false,
    type: ConfigValueType? = nil,
    env: [String: String]? = nil
) async throws -> String? {
    // An empty path means the global configuration.
    let repositoryPath = path.flatMap { $0.isEmpty ? nil : $0 }

    var flags = ["config", "-z"]
    if repositoryPath == nil {
        flags.append("--global")
    } else if onlyLocal {
        flags.append("--local")
    }

    if let type {
        flags.append(contentsOf: ["--type", type.rawValue])
    }

    flags.append(name)

    let result = try await git(
        flags,
        repositoryPath ?? installLocation(),
        "getConfigValueInPath",
        options: GitExecutionOptions(env: executionEnv(env), successExitCodes: [0, 1])
    )

    // Git exits with 1 if the value isn't found. That's OK.
    if result.exitCode == 1 {
        return nil
    }

    let output = result.stdout
    let pieces = JSCompat.split(output, "\0")
    return pieces[0]
}

/// Get the path to the global git config
///
/// Note: this uses git config --edit which will automatically create the global
/// config file if it doesn't exist yet. The primary purpose behind this method
/// is to support opening the global git config for editing.
public func getGlobalConfigPath(env: [String: String]? = nil) async throws -> String {
    var environment = executionEnv(env) ?? [:]
    // We're using printf instead of echo because echo could attempt to decode
    // escape sequences like \n which would be bad in a case like
    // c:\Users\niik\.gitconfig
    //         ^^
    environment["GIT_EDITOR"] = "printf %s"

    let result = try await git(
        ["config", "--edit", "--global"],
        installLocation(),
        "getGlobalConfigPath",
        options: GitExecutionOptions(env: environment)
    )
    return POSIXPath.normalize(result.stdout)
}

/// Set the local config value by name.
public func setConfigValue(
    _ repository: Repository,
    _ name: String,
    _ value: String,
    env: [String: String]? = nil
) async throws {
    try await setConfigValueInPath(name, value, repository.path, env: env)
}

/// Set the global config value by name.
public func setGlobalConfigValue(
    _ name: String,
    _ value: String,
    env: [String: String]? = nil
) async throws {
    try await setConfigValueInPath(name, value, nil, env: env)
}

/// Set the global config value by name.
public func addGlobalConfigValue(_ name: String, _ value: String) async throws {
    try await git(
        ["config", "--global", "--add", name, value],
        installLocation(),
        "addGlobalConfigValue"
    )
}

/// Adds an existing absolute directory to `safe.directory` if it's not already
/// present, allowing Git to use that directory when it belongs to another user.
///
/// Resolves the canonical path and rejects values that Git would interpret as
/// an exception for multiple directories.
///
/// - Throws: `GitLibError` for a relative path or a path denoting a subtree,
///   and `POSIXError` when the directory can't be resolved.
public func addSafeDirectory(_ path: String) async throws {
    if !POSIXPath.isAbsolute(path) {
        throw GitLibError("A directory exception requires an absolute path.")
    }

    let path = try resolveRealPath(path)
    if JSCompat.endsWith(path, "/*") {
        throw GitLibError("A directory exception must refer to a single directory.")
    }

    try await addGlobalConfigValueIfMissing("safe.directory", path)
}

/// Set the global config value by name.
public func addGlobalConfigValueIfMissing(_ name: String, _ value: String) async throws {
    let result = try await git(
        ["config", "--global", "-z", "--fixed-value", "--get-all", name, value],
        installLocation(),
        "addGlobalConfigValue",
        options: GitExecutionOptions(successExitCodes: [0, 1])
    )

    let values = JSCompat.split(result.stdout, "\0")
    if result.exitCode == 1 || !values.contains(where: { JSCompat.strictEquals($0, value) }) {
        try await addGlobalConfigValue(name, value)
    }
}

/// Set config value by name
///
/// - Parameter path: The path to execute the `git` command in. If null
///   we'll use the global configuration (i.e. --global)
///   and execute the Git call from the same location that
///   Espalier is installed in.
private func setConfigValueInPath(
    _ name: String,
    _ value: String,
    _ path: String?,
    env: [String: String]? = nil
) async throws {
    let repositoryPath = path.flatMap { $0.isEmpty ? nil : $0 }

    var flags = ["config"]

    if repositoryPath == nil {
        flags.append("--global")
    }

    flags.append(contentsOf: ["--replace-all", name, value])

    try await git(
        flags,
        repositoryPath ?? installLocation(),
        "setConfigValueInPath",
        options: GitExecutionOptions(env: executionEnv(env))
    )
}

/// Remove the local config value by name.
public func removeConfigValue(
    _ repository: Repository,
    _ name: String,
    env: [String: String]? = nil
) async throws {
    try await removeConfigValueInPath(name, repository.path, env: env)
}

/// Remove config value by name
///
/// - Parameter path: The path to execute the `git` command in. If null
///   we'll use the global configuration (i.e. --global)
///   and execute the Git call from the same location that
///   Espalier is installed in.
private func removeConfigValueInPath(
    _ name: String,
    _ path: String?,
    env: [String: String]? = nil
) async throws {
    let repositoryPath = path.flatMap { $0.isEmpty ? nil : $0 }

    var flags = ["config"]

    if repositoryPath == nil {
        flags.append("--global")
    }

    flags.append(contentsOf: ["--unset-all", name])

    try await git(
        flags,
        repositoryPath ?? installLocation(),
        "removeConfigValueInPath",
        options: GitExecutionOptions(env: executionEnv(env))
    )
}

/// The canonical, absolute path with every symbolic link resolved.
///
/// - Throws: `POSIXError` (for example `ENOENT`) when the path can't be
///   resolved.
func resolveRealPath(_ path: String) throws -> String {
    guard let resolved = realpath(path, nil) else {
        throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
    }
    defer { free(resolved) }
    return String(cString: resolved)
}
