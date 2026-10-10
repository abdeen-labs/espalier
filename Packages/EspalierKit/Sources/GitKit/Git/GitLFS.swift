// Ported from desktop/app/src/lib/git/lfs.ts

import EspalierSupport
import Foundation

/// Install the global LFS filters.
public func installGlobalLFSFilters(_ force: Bool) async throws {
    var args = ["lfs", "install", "--skip-repo"]
    if force {
        args.append("--force")
    }

    try await git(args, installLocation(), "installGlobalLFSFilter")
}

/// Install LFS hooks in the repository.
public func installLFSHooks(_ repository: Repository, _ force: Bool) async throws {
    var args = ["lfs", "install"]
    if force {
        args.append("--force")
    }

    try await git(args, repository.path, "installLFSHooks")
}

/// Is the repository configured to track any paths with LFS?
public func isUsingLFS(_ repository: Repository) async throws -> Bool {
    let env: [String: String?] = [
        "GIT_LFS_TRACK_NO_INSTALL_HOOKS": "1",
    ]
    let result = try await git(
        ["lfs", "track", "--json"],
        repository.path,
        "isUsingLFS",
        options: GitExecutionOptions(env: env)
    )

    // True when a pattern in the JSON output is tracked; output of any other
    // shape means false.
    guard let output = try? JSONSerialization.jsonObject(with: result.stdoutData, options: [.fragmentsAllowed]) else {
        return false
    }

    guard let patterns = (output as? [String: Any])?["patterns"] as? [Any] else {
        return false
    }

    for pattern in patterns {
        if pattern is NSNull {
            // A null pattern before a tracked one means false.
            return false
        }
        if let tracked = (pattern as? [String: Any])?["tracked"], isTruthy(tracked) {
            return true
        }
    }
    return false
}

/// JavaScript truthiness of a parsed JSON value.
private func isTruthy(_ value: Any) -> Bool {
    switch value {
    case is NSNull:
        return false
    case let number as NSNumber:
        if CFGetTypeID(number) == CFBooleanGetTypeID() {
            return number.boolValue
        }
        let double = number.doubleValue
        return double != 0 && !double.isNaN
    case let string as String:
        return !string.isEmpty
    default:
        // Arrays and objects are truthy.
        return true
    }
}

/// Check if a provided file path is being tracked by Git LFS
///
/// This uses the Git plumbing to read the .gitattributes file
/// for any LFS-related rules that are set for the file
///
/// - Parameters:
///   - repository: repository with
///   - path: relative file path in the repository
public func isTrackedByLFS(_ repository: Repository, _ path: String) async throws -> Bool {
    // `--`, so git doesn't read a path that starts with a dash as an option.
    let result = try await git(
        ["check-attr", "filter", "--", path],
        repository.path,
        "checkAttrForLFS"
    )

    // "git check-attr -a" will output every filter it can find in .gitattributes
    // and it looks like this:
    //
    // README.md: diff: lfs
    // README.md: merge: lfs
    // README.md: text: unset
    // README.md: filter: lfs
    //
    // To verify git-lfs this test will just focus on that last row, "filter",
    // and the value associated with it. If nothing is found in .gitattributes
    // the output will look like this
    //
    // README.md: filter: unspecified
    //
    // Searching the output for ": filter: lfs" would also match a path
    // containing it. With one path and one attribute the output is one line
    // ending in the value.
    let stdout = result.stdout
    return JSCompat.endsWith(stdout, ": filter: lfs\n") || JSCompat.endsWith(stdout, ": filter: lfs")
}

/// Query a Git repository and filter the set of provided relative paths to see
/// which are not covered by the current Git LFS configuration.
///
/// - Parameters:
///   - repository: The repository
///   - filePaths: List of relative paths in the repository
public func filesNotTrackedByLFS(_ repository: Repository, _ filePaths: [String]) async throws -> [String] {
    var filesNotTrackedByGitLFS: [String] = []

    for file in filePaths {
        let isTracked = try await isTrackedByLFS(repository, file)

        if !isTracked {
            filesNotTrackedByGitLFS.append(file)
        }
    }

    return filesNotTrackedByGitLFS
}
