// Ported from desktop/app/src/lib/git/submodule.ts

import EspalierSupport
import Foundation
import os

private let logger = Log.logger(category: "submodule")

/// A progress event that `updateSubmodulesAfterOperation` can report.
/// `targetOrRemote` is the `target` of checkout progress and the `remote` of
/// the others.
public protocol SubmoduleUpdateProgress: ProgressEvent {
    init(submoduleUpdateTitle title: String, description: String, value: Double, targetOrRemote: String)
}

extension CheckoutProgress: SubmoduleUpdateProgress {
    public init(submoduleUpdateTitle title: String, description: String, value: Double, targetOrRemote: String) {
        self.init(value: value, title: title, description: description, target: targetOrRemote)
    }
}

extension FetchProgress: SubmoduleUpdateProgress {
    public init(submoduleUpdateTitle title: String, description: String, value: Double, targetOrRemote: String) {
        self.init(value: value, title: title, description: description, remote: targetOrRemote)
    }
}

extension PullProgress: SubmoduleUpdateProgress {
    public init(submoduleUpdateTitle title: String, description: String, value: Double, targetOrRemote: String) {
        self.init(value: value, title: title, description: description, remote: targetOrRemote)
    }
}

/// `/^Submodule path (.)+?: checked out /`
private let submoduleCheckedOutPattern = JSCompat.regex("^Submodule path (\(JSCompat.dot))+?: checked out ")

/// Fakes the progress of `git submodule update`, which reports none.
private struct SubmoduleUpdateProgressParser: GitProgressParsing {
    private var submoduleEventCount = 0

    mutating func parse(_ line: String) -> GitProgressResult {
        if JSCompat.match(line, submoduleCheckedOutPattern) != nil || JSCompat.startsWith(line, "Cloning into ") {
            submoduleEventCount += 1
        }

        return .context(GitOutput(
            // Math taken from https://math.stackexchange.com/a/2323106
            // We do this to fake a progress that slows down as we process more
            // events, as we don't know how many submodules there are upfront, or
            // what does git have to do with them (cloning, just checking them
            // out...)
            percent: 1 - exp(-Double(submoduleEventCount) * 0.25),
            text: "Updating submodules: \(line)"
        ))
    }
}

/// Update submodules after a git operation.
///
/// - Parameters:
///   - repository: The repository in which to update submodules
///   - remote: The remote for environment setup (can be nil)
///   - progressCallback: An optional function which will be invoked
///     with information about the current progress
///     of the submodule update operation.
///   - progressKind: The kind of progress event (checkout, pull, etc.)
///   - title: The title to use for progress reporting
///   - targetOrRemote: The target (for checkout) or remote name (for pull)
///   - allowFileProtocol: Whether to allow file:// protocol for submodules
///   - gitHubHTMLURL: The web URL of the repository's GitHub endpoint, if
///     any; see `getFallbackUrlForProxyResolve`.
public func updateSubmodulesAfterOperation<T: SubmoduleUpdateProgress>(
    _ repository: Repository,
    _ remote: Remote?,
    _ progressCallback: (@Sendable (T) -> Void)?,
    _ progressKind: T.Type,
    _ title: String,
    _ targetOrRemote: String,
    _ allowFileProtocol: Bool,
    gitHubHTMLURL: String? = nil
) async throws {
    let opts = GitExecutionOptions(
        env: await envForRemoteOperation(
            getFallbackUrlForProxyResolve(repository, remote, gitHubHTMLURL: gitHubHTMLURL)
        ),
        expectedErrors: AuthenticationErrors
    )

    let args = (allowFileProtocol ? ["-c", "protocol.file.allow=always"] : [])
        + ["submodule", "update", "--init", "--recursive"]

    guard let progressCallback else {
        try await git(args, repository.path, "updateSubmodules", options: opts)
        return
    }

    // Initial progress
    progressCallback(T(
        submoduleUpdateTitle: title,
        description: "Updating submodules",
        value: 0,
        targetOrRemote: targetOrRemote
    ))

    var trackingOpts = opts
    trackingOpts.trackLFSProgress = true
    let progressOpts = await executionOptionsWithProgress(trackingOpts, SubmoduleUpdateProgressParser()) { progress in
        progressCallback(T(
            submoduleUpdateTitle: title,
            description: progress.text,
            value: progress.percent,
            targetOrRemote: targetOrRemote
        ))
    }

    try await git(args, repository.path, "updateSubmodules", options: progressOpts)

    // Final progress
    progressCallback(T(
        submoduleUpdateTitle: title,
        description: "Submodules updated",
        value: 1,
        targetOrRemote: targetOrRemote
    ))
}

// entries are of the format:
//  1eaabe34fc6f486367a176207420378f587d3b48 git (v2.16.0-rc0)
//
// first character:
//   - " " if no change
//   - "-" if the submodule is not initialized
//   - "+" if the currently checked out submodule commit does not match the SHA-1 found in the index of the containing repository
//   - "U" if the submodule has merge conflicts
//
// then the 40-character SHA represents the current commit
//
// then the path to the submodule
//
// then the output of `git describe` for the submodule in braces
// we're not leveraging this in the app, so go and read the docs
// about it if you want to learn more:
//
// https://git-scm.com/docs/git-describe
//
// `/^.([^ ]+) (?:(.+) \((.+?)\)|(.+))$/gm`, with JavaScript's line
// terminators for `^` and `$`.
//
// Git prints no describe for a submodule that isn't checked out (`-<sha>
// <path>`: not initialized, or its folder is gone). Such lines are listed
// with an empty describe, so discarding a submodule whose folder was
// deleted updates the submodule rather than checking the gitlink out as an
// empty folder.
private let submoduleStatusPattern: NSRegularExpression = {
    let dot = JSCompat.dot
    let lineStart = #"(?:(?<![\s\S])|(?<=[\n\r\u2028\u2029]))"#
    let lineEnd = #"(?=[\n\r\u2028\u2029]|(?![\s\S]))"#
    return JSCompat.regex("\(lineStart)\(dot)([^ ]+) (?:(\(dot)+) \\((\(dot)+?)\\)|(\(dot)+))\(lineEnd)")
}()

/// Lists the repository's top-level submodules with `git submodule status`.
public func listSubmodules(_ repository: Repository) async throws -> [SubmoduleEntry] {
    async let submodulesFile = pathExists(POSIXPath.join(repository.path, ".gitmodules"))
    async let submodulesDir = pathExists(POSIXPath.join(repository.path, ".git", "modules"))

    if !(await submodulesFile), !(await submodulesDir) {
        // repo path + .gitmodules and + .git/modules covers the vast majority of
        // "normal" repositories but if we're in a linked worktree the modules
        // directory is actually in the git common dir so we'll also check for the
        // existence of the modules directory there as well before giving up on the
        // existence of submodules in this repo. We're reading the commondir file
        // ourselves here instead of calling out to git to avoid the cost of
        // spawning a process
        let commonDir = readCommonDir(repository.resolvedGitDir)

        let hasModules: Bool
        if let commonDir {
            hasModules = await pathExists(POSIXPath.join(commonDir, "modules"))
        } else {
            hasModules = false
        }

        if !hasModules {
            logger.info("No submodules found. Skipping \"git submodule status\"")
            return []
        }
    }

    // We don't recurse when listing submodules here because we don't have a good
    // story about managing these currently. So for now we're only listing
    // changes to the top-level submodules to be consistent with `git status`
    let result = try await git(
        ["submodule", "status", "--"],
        repository.path,
        "listSubmodules",
        options: GitExecutionOptions(successExitCodes: [0, 128])
    )

    if result.exitCode == 128 {
        // unable to parse submodules in repository, giving up
        return []
    }

    let stdout = result.stdout
    let range = NSRange(stdout.startIndex..<stdout.endIndex, in: stdout)
    return submoduleStatusPattern.matches(in: stdout, range: range).compactMap { match in
        guard let sha = Range(match.range(at: 1), in: stdout) else {
            return nil
        }
        if let path = Range(match.range(at: 2), in: stdout), let describe = Range(match.range(at: 3), in: stdout) {
            return SubmoduleEntry(sha: String(stdout[sha]), path: String(stdout[path]), describe: String(stdout[describe]))
        }
        guard let path = Range(match.range(at: 4), in: stdout) else {
            return nil
        }
        return SubmoduleEntry(sha: String(stdout[sha]), path: String(stdout[path]), describe: "")
    }
}

/// The git common directory named by `<gitDir>/commondir`, resolved against
/// the git directory, or nil.
private func readCommonDir(_ gitDir: String) -> String? {
    guard let data = FileManager.default.contents(atPath: POSIXPath.join(gitDir, "commondir")) else {
        return nil
    }

    // Without a final `\n` or `\r\n`.
    var content = String(decoding: data, as: UTF8.self)
    if JSCompat.endsWith(content, "\r\n") {
        content = String(decoding: content.utf8.dropLast(2), as: UTF8.self)
    } else if JSCompat.endsWith(content, "\n") {
        content = String(decoding: content.utf8.dropLast(), as: UTF8.self)
    }

    return content.isEmpty ? nil : POSIXPath.resolve(gitDir, content)
}

/// Updates the given submodules to the commits the repository records for
/// them, discarding their local changes.
///
/// The paths are literal pathspecs.
public func resetSubmodulePaths(_ repository: Repository, _ paths: [String]) async throws {
    if paths.isEmpty {
        return
    }

    try await git(
        ["submodule", "update", "--recursive", "--force", "--"] + literalPathspecs(paths),
        repository.path,
        "updateSubmodule"
    )
}
