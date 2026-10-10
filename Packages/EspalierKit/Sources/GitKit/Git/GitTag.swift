// Ported from desktop/app/src/lib/git/tag.ts

import EspalierSupport
import Foundation

/// Create a new tag on the given target commit.
///
/// - Parameters:
///   - repository: The repository in which to create the new tag.
///   - name: The name of the new tag.
///   - targetCommitSha: The SHA of the commit where the new tag will live on.
public func createTag(_ repository: Repository, _ name: String, _ targetCommitSha: String) async throws {
    let args = ["tag", "-a", "-m", "", name, targetCommitSha]

    try await git(args, repository.path, "createTag")
}

/// Delete a tag.
///
/// - Parameters:
///   - repository: The repository in which to create the new tag.
///   - name: The name of the tag to delete.
public func deleteTag(_ repository: Repository, _ name: String) async throws {
    let args = ["tag", "-d", name]

    try await git(args, repository.path, "deleteTag")
}

/// `name` without a leading `refs/tags/`.
private func removingTagRefPrefix(_ name: String) -> String {
    JSCompat.startsWith(name, "refs/tags/") ? JSCompat.dropFirst(name, "refs/tags/".unicodeScalars.count) : name
}

/// `name` without a trailing `^{}`.
private func removingPeeledSuffix(_ name: String) -> String {
    guard JSCompat.endsWith(name, "^{}") else {
        return name
    }
    return String(name.unicodeScalars.dropLast(3))
}

/// Gets all the local tags. Returns a Map with the tag name and the commit it points to.
///
/// - Parameter repository: The repository in which to get all the tags from.
public func getAllTags(_ repository: Repository) async throws -> [String: String] {
    let args = ["show-ref", "--tags", "-d"]

    let tags = try await git(args, repository.path, "getAllTags", options: GitExecutionOptions(
        successExitCodes: [0, 1] // when there are no tags, git exits with 1.
    ))

    var result: [String: String] = [:]
    for line in JSCompat.split(tags.stdout, "\n") where !line.isEmpty {
        let parts = JSCompat.split(line, " ")
        let commitSha = parts[0]
        let rawTagName = parts.count > 1 ? parts[1] : ""

        // Normalize tag names by removing the leading ref/tags/ and the trailing ^{}.
        //
        // git show-ref returns two entries for annotated tags:
        // deadbeef refs/tags/annotated-tag
        // de510b99 refs/tags/annotated-tag^{}
        //
        // The first entry sha correspond to the blob object of the annotation, while the second
        // entry corresponds to the actual commit where the tag was created.
        // By normalizing the tag name we can make sure that the commit sha gets stored in the returned
        // Map of commits (since git will always print the entry with the commit sha at the end).
        let tagName = removingPeeledSuffix(removingTagRefPrefix(rawTagName))

        result[tagName] = commitSha
    }

    return result
}

/// Fetches the tags that will get pushed to the remote repository (it does a network request).
///
/// - Parameters:
///   - repository: The repository in which to check for unpushed tags
///   - remote: The remote to check for unpushed tags
///   - branchName: The branch that will be used on the push command
///
/// - Throws: `GitError` when git exits with a code other than 0 or 1, the
///   only codes for which its output can be parsed. The `GitError` carries
///   the parsed git error as `result.gitError`.
public func fetchTagsToPush(_ repository: Repository, _ remote: Remote, _ branchName: String) async throws -> [String] {
    let args = [
        "push",
        "--follow-tags",
        "--dry-run",
        "--no-verify",
        "--porcelain",
        "--",
        remote.name,
        branchName,
    ]

    let env = await envForRemoteOperation(remote.url)
    let result = try await git(args, repository.path, "fetchTagsToPush", options: GitExecutionOptions(
        env: env,
        successExitCodes: [0, 1, 128]
    ))

    if result.exitCode != 0 && result.exitCode != 1 {
        // Only when the exit code of git is 0 or 1, its stdout is parseable.
        // In other cases, we just rethrow the error.
        throw GitError(result: result, args: args, terminalOutput: "")
    }

    let lines = JSCompat.split(result.stdout, "\n")
    var currentLine = 1
    var unpushedTags: [String] = []

    // the last line of this porcelain command is always 'Done'
    while currentLine < lines.count && lines[currentLine] != "Done" {
        let line = lines[currentLine]
        let parts = JSCompat.split(line, "\t")

        if parts[0] == "*" && parts.count > 2 && parts[2] == "[new tag]" {
            let tagName = JSCompat.split(parts[1], ":")[0]
            unpushedTags.append(removingTagRefPrefix(tagName))
        }

        currentLine += 1
    }

    return unpushedTags
}
