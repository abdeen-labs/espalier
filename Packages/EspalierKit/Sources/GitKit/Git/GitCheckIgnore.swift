import EspalierSupport
import Foundation

/// The variables that change how git reads pathspecs. `check-ignore` takes
/// no pathspec magic, so with any of them set it refuses every path.
private let pathspecVariables: [String: String?] = [
    "GIT_LITERAL_PATHSPECS": nil,
    "GIT_GLOB_PATHSPECS": nil,
    "GIT_NOGLOB_PATHSPECS": nil,
    "GIT_ICASE_PATHSPECS": nil,
]

/// The paths among `paths` that git ignores: an ignore rule (a
/// `.gitignore`, `.git/info/exclude`, `core.excludesFile`) matches them,
/// and they aren't tracked. A tracked file is never ignored, whatever
/// matches it.
///
/// Runs one `git check-ignore --stdin -z`, which needn't find the paths on
/// disk: a deleted file in an ignored directory is still ignored. A
/// deleted directory that only a directory pattern (`build/`) matches isn't,
/// since git can no longer tell it was a directory.
///
/// Git compares the bytes it's given: a path spelled in another Unicode
/// form than the index's isn't found there, so it reads as untracked.
///
/// - Parameter paths: Relative to the repository's working directory, none
///   of them empty. Each goes to git as `./<path>`, so a leading `:` doesn't
///   read as pathspec magic (`check-ignore` refuses `:(literal)`).
/// - Returns: The ignored ones, spelled as given.
/// - Throws: When git fails, as it does for a path inside a submodule,
///   beyond a symbolic link, or outside the working directory.
public func getIgnoredPaths(_ repository: Repository, _ paths: [String]) async throws -> Set<ExactString> {
    guard !paths.isEmpty else {
        return []
    }
    var input = Data()
    for path in paths {
        input.append(contentsOf: "./".utf8)
        input.append(contentsOf: path.utf8)
        input.append(0)
    }
    let result = try await git(
        ["check-ignore", "--stdin", "-z"],
        repository.path,
        "getIgnoredPaths",
        options: GitExecutionOptions(
            env: pathspecVariables,
            stdin: input,
            // 1: none of the paths is ignored.
            successExitCodes: [0, 1]
        )
    )
    var ignored = Set<ExactString>()
    let prefix = Array("./".utf8)
    for record in result.stdoutData.split(separator: 0, omittingEmptySubsequences: true) {
        // Git prints each ignored path as it read it.
        guard record.starts(with: prefix) else {
            continue
        }
        ignored.insert(ExactString(String(decoding: record.dropFirst(prefix.count), as: UTF8.self)))
    }
    return ignored
}

/// The file git reads `core.excludesFile` ignore rules from, resolved as
/// git resolves it: the configured path (`~` expanded, a relative one
/// against the working directory), or else `$XDG_CONFIG_HOME/git/ignore`
/// when that variable isn't empty, or else `$HOME/.config/git/ignore`. Nil
/// when it's configured empty or neither variable is set.
public func getExcludesFile(_ repository: Repository) async throws -> String? {
    let result = try await git(
        ["config", "-z", "--type", "path", "core.excludesFile"],
        repository.path,
        "getExcludesFile",
        // 1: it isn't set.
        options: GitExecutionOptions(successExitCodes: [0, 1])
    )
    if result.exitCode == 0 {
        let configured = JSCompat.split(result.stdout, "\0")[0]
        if configured.isEmpty {
            return nil
        }
        return POSIXPath.resolve(repository.path, configured)
    }
    let environment = GitRuntime.current.processEnvironment
    if let configHome = environment["XDG_CONFIG_HOME"], !configHome.isEmpty {
        return POSIXPath.join(configHome, "git/ignore")
    }
    if let home = environment["HOME"] {
        return home + "/.config/git/ignore"
    }
    return nil
}
