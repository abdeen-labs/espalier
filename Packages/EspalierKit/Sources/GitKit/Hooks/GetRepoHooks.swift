// Ported from desktop/app/src/lib/hooks/get-repo-hooks.ts

import EspalierSupport
import Foundation

private let knownHooks: Set<String> = [
    "applypatch-msg",
    "pre-applypatch",
    "post-applypatch",
    "pre-commit",
    "pre-merge-commit",
    "prepare-commit-msg",
    "commit-msg",
    "post-commit",
    "pre-rebase",
    "post-checkout",
    "post-merge",
    "pre-push",
    "pre-receive",
    "update",
    "proc-receive",
    "post-receive",
    "post-update",
    "reference-transaction",
    "push-to-checkout",
    "pre-auto-gc",
    "post-rewrite",
    "sendemail-validate",
    "fsmonitor-watchman",
    "p4-changelist",
    "p4-prepare-changelist",
    "p4-post-changelist",
    "p4-pre-submit",
    "post-index-change",
]

/// A git command that `getRepoHooks` runs exited with a non-zero code.
public struct RepoHooksGitError: Error, CustomStringConvertible, LocalizedError {
    public let exitCode: Int
    public let stderr: String

    public var description: String {
        "Git command failed with exit code \(exitCode): \(stderr)"
    }

    public var errorDescription: String? { description }
}

// getRepoHooks is used by withHooksEnv which is used by git() so we
// have to be careful to not accidentally run into a circular dependency here
// where we invoke git which calls us which calls git which calls us, etc. To
// avoid that we call Dugite directly here.
private func dugiteGit(_ args: [String], _ path: String) async throws -> String {
    let result = try await Dugite.exec(args, path)
    guard result.exitCode == 0 else {
        throw RepoHooksGitError(exitCode: result.exitCode, stderr: String(decoding: result.stderr, as: UTF8.self))
    }
    return String(decoding: result.stdout, as: UTF8.self)
}

private func getHooksPath(_ path: String) async throws -> String {
    let output = try await dugiteGit(["rev-parse", "--git-path", "hooks"], path)
    return POSIXPath.resolve(path, removingTrailingNewline(output))
}

/// Reads a path-valued setting with `--type=path`, so `~/` is expanded, as
/// git expands it when it runs hooks.
private func getPathConfigValue(_ path: String, _ key: String) async throws -> String {
    let output = try await dugiteGit(["config", "-z", "--type=path", "--get", key], path)
    return output.split(separator: "\0", omittingEmptySubsequences: false).first.map(String.init) ?? ""
}

/// Returns the absolute path of the directory git runs the repository's
/// hooks from: `core.hooksPath` (with `~/` expanded, and resolved against
/// `path` when relative), or else the git directory's `hooks` folder.
///
/// `withHooksEnv` needs the directory itself, to expose the hooks it doesn't
/// intercept.
///
/// - Parameter path: The file system path to the Git repository (root of
///   working directory).
public func getRepoHooksPath(_ path: String) async throws -> String {
    do {
        return POSIXPath.resolve(path, try await getPathConfigValue(path, "core.hooksPath"))
    } catch let error as CancellationError {
        throw error
    } catch {
        return POSIXPath.resolve(path, try await getHooksPath(path))
    }
}

/// Returns the names of executable Git hooks found in the given repository.
///
/// - Parameters:
///   - path: The file system path to the Git repository (root of working
///     directory).
///   - filter: An optional array of hook names to filter the results.
///     Including '*' returns none; see the note in the loop.
public func getRepoHooks(_ path: String, filter: [String]? = nil) async throws -> [String] {
    getRepoHooks(inHooksPath: try await getRepoHooksPath(path), filter: filter)
}

/// Returns the names of the executable Git hooks in `hooksPath`, a
/// repository's hooks directory (see `getRepoHooksPath`).
public func getRepoHooks(inHooksPath hooksPath: String, filter: [String]? = nil) -> [String] {
    let files = regularFiles(in: hooksPath)

    let matchAll = filter?.contains("*") ?? false

    var hooks: [String] = []
    for file in files {
        // Git on macOS doesn't run `<hook>.exe`, so the name is used as is.
        let hookName = file

        // This skips every hook when the filter contains '*'. No caller
        // passes '*' (commit, merge, pull, and push all name their hooks).
        if matchAll || filter?.contains(hookName) == false {
            continue
        }

        if !knownHooks.contains(hookName) {
            continue
        }

        if access(POSIXPath.join(hooksPath, file), X_OK) == 0 {
            hooks.append(hookName)
        }
    }
    return hooks
}

/// The names of the regular files in `directory`, or none when it can't be
/// read.
///
/// Follows symbolic links, as git does when it runs hooks. A symlinked hook
/// left out would never be intercepted, and once any other hook is,
/// `core.hooksPath` points at the proxies and git would skip it entirely.
private func regularFiles(in directory: String) -> [String] {
    guard let names = try? FileManager.default.contentsOfDirectory(atPath: directory) else {
        return []
    }
    return names.filter { name in
        var info = stat()
        return stat(POSIXPath.join(directory, name), &info) == 0 && (info.st_mode & S_IFMT) == S_IFREG
    }
}

/// Removes one trailing newline (`\n` or `\r\n`).
private func removingTrailingNewline(_ text: String) -> String {
    var scalars = text.unicodeScalars
    if scalars.last == "\n" {
        scalars.removeLast()
        if scalars.last == "\r" {
            scalars.removeLast()
        }
    }
    return String(scalars)
}
