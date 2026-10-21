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
///
/// `git lfs install` also installs the global LFS filters. Without `force`
/// it refuses to replace hooks that aren't its own
/// (`getHooksInTheWayOfLFS`) and global filters set to other values; with
/// `force` it overwrites both.
public func installLFSHooks(_ repository: Repository, _ force: Bool) async throws {
    var args = ["lfs", "install"]
    if force {
        args.append("--force")
    }

    try await git(args, repository.path, "installLFSHooks")
}

/// The hooks Git LFS installs in a repository, in the order it installs
/// them.
public let lfsHookNames = ["pre-push", "post-checkout", "post-commit", "post-merge"]

/// A repository's hooks folder, and the hooks in it that are in the way of
/// Git LFS's.
public struct LFSHooksInTheWay: Sendable, Equatable {
    /// The folder git runs the repository's hooks from, where Git LFS
    /// installs its own (`getRepoHooksPath`: `core.hooksPath`, or the git
    /// directory's `hooks` folder).
    public let hooksPath: String
    /// The hooks in the way, in `lfsHookNames`' order.
    public let names: [String]

    public init(hooksPath: String, names: [String]) {
        self.hooksPath = hooksPath
        self.names = names
    }

    /// The paths of the hooks in the way.
    public var paths: [String] {
        names.map { POSIXPath.join(hooksPath, $0) }
    }
}

/// The repository's hooks that Git LFS's would replace: anything at one of
/// `lfsHookNames` in the hooks folder other than Git LFS's own hook. Git
/// LFS's own is the hook as this version or an earlier one wrote it, or an
/// empty file, which `git lfs install` replaces without `--force`; it
/// refuses to replace anything else unless forced.
///
/// A link counts as what it points to, as it does for Git LFS, which writes
/// through it. A link that points nowhere, a folder, or a file that can't be
/// read is in the way. Where this differs from Git LFS it's stricter: Git
/// LFS reads a hook's first kilobyte, and this reads the whole file (a file
/// over 4 KB is in the way), so Git LFS never refuses a hook left out here.
public func getHooksInTheWayOfLFS(_ repository: Repository) async throws -> LFSHooksInTheWay {
    let hooksPath = try await getRepoHooksPath(repository.path)
    let names = lfsHookNames.filter { name in
        isInTheWayOfLFS(POSIXPath.join(hooksPath, name), hook: name)
    }
    return LFSHooksInTheWay(hooksPath: hooksPath, names: names)
}

/// The most bytes of a hook that are read: Git LFS's own hooks are a few
/// hundred.
private let maximumLFSHookSize = 4096

/// Whether the item at `path` is in the way of Git LFS's `hook`.
private func isInTheWayOfLFS(_ path: String, hook: String) -> Bool {
    var info = stat()
    guard lstat(path, &info) == 0 else {
        // Nothing there, or nothing that can be looked at, which Git LFS
        // then reports itself.
        return false
    }
    guard let contents = readHook(path) else {
        return true
    }
    let normalized = normalizedHookContents(contents)
    if normalized.isEmpty {
        return false
    }
    return !lfsHookContents(hook).contains { $0.utf8.elementsEqual(normalized.utf8) }
}

/// The text of the hook at `path`, following links: nil for anything but a
/// regular file of UTF-8 text of at most `maximumLFSHookSize` bytes.
private func readHook(_ path: String) -> String? {
    var info = stat()
    guard stat(path, &info) == 0, (info.st_mode & S_IFMT) == S_IFREG, Int(info.st_size) <= maximumLFSHookSize,
          let data = FileManager.default.contents(atPath: path) else {
        return nil
    }
    return String(data: data, encoding: .utf8)
}

/// A hook's text as Git LFS compares it: each line without its leading
/// spaces and tabs, and the whole without the white space around it.
private func normalizedHookContents(_ contents: String) -> String {
    var scalars = String.UnicodeScalarView()
    var isAtLineStart = true
    for scalar in contents.unicodeScalars {
        if isAtLineStart, scalar == " " || scalar == "\t" {
            continue
        }
        isAtLineStart = scalar == "\n"
        scalars.append(scalar)
    }
    return String(scalars).trimmingCharacters(in: .whitespacesAndNewlines)
}

/// Git LFS's `hook` as each version wrote it, the bundled version's last:
/// what `git lfs install` replaces without `--force` (Git LFS's
/// `lfs/hook.go`). The `\n` inside the messages are a backslash and an `n`,
/// as in the hooks.
private func lfsHookContents(_ hook: String) -> [String] {
    func script(_ lines: String...) -> String {
        (["#!/bin/sh"] + lines).joined(separator: "\n")
    }
    let run = #"git lfs \#(hook) "$@""#
    var versions: [String] = []
    if hook == "pre-push" {
        versions += [
            script("git lfs push --stdin $*"),
            script(#"git lfs push --stdin "$@""#),
            script(#"git lfs pre-push "$@""#),
            script(
                #"command -v git-lfs >/dev/null 2>&1 || { echo >&2 "\nThis repository has been set up with Git LFS but Git LFS is not installed.\n"; exit 0; }"#,
                run
            ),
            script(
                #"command -v git-lfs >/dev/null 2>&1 || { echo >&2 "\nThis repository has been set up with Git LFS but Git LFS is not installed.\n"; exit 2; }"#,
                run
            ),
        ]
    }
    versions += [
        script(
            #"command -v git-lfs >/dev/null 2>&1 || { echo >&2 "\nThis repository is configured for Git LFS but 'git-lfs' was not found on your path. If you no longer wish to use Git LFS, remove this hook by deleting .git/hooks/\#(hook).\n"; exit 2; }"#,
            run
        ),
        script(
            #"command -v git-lfs >/dev/null 2>&1 || { echo >&2 "\nThis repository is configured for Git LFS but 'git-lfs' was not found on your path. If you no longer wish to use Git LFS, remove this hook by deleting '.git/hooks/\#(hook)'.\n"; exit 2; }"#,
            run
        ),
        script(
            #"command -v git-lfs >/dev/null 2>&1 || { echo >&2 "\nThis repository is configured for Git LFS but 'git-lfs' was not found on your path. If you no longer wish to use Git LFS, remove this hook by deleting the '\#(hook)' file in the hooks directory (set by 'core.hookspath'; usually '.git/hooks').\n"; exit 2; }"#,
            run
        ),
        script(
            #"command -v git-lfs >/dev/null 2>&1 || { printf >&2 "\n%s\n\n" "This repository is configured for Git LFS but 'git-lfs' was not found on your path. If you no longer wish to use Git LFS, remove this hook by deleting the '\#(hook)' file in the hooks directory (set by 'core.hookspath'; usually '.git/hooks')."; exit 2; }"#,
            run
        ),
    ]
    return versions
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
