// Ported from desktop/app/src/lib/stores/app-store.ts
//
// - The diff is made with a temporary index (GitKit's `getFilesDiffText`),
//   so the repository's own index is never reset and restaged around it.
// - Amending the first commit diffs against the empty tree: `<sha>^`
//   doesn't exist there.
// - The repository's instructions (`.github/copilot-instructions.md`) are
//   read only from inside the repository, so a symbolic link can't send
//   another file to the provider.
// - A result for an amend that ended (or a different commit amended) while
//   it was generated is dropped: its diff was of other changes.

import AIKit
import EspalierSupport
import Foundation
import GitHubKit
import GitKit

/// The commit message generation's git and file work, off the main actor.
enum CommitMessageGenerator {
    /// The most of an instructions file that is read. AIKit keeps the first
    /// `MaxRepositoryInstructionsLength` characters of it.
    static let maxInstructionsReadBytes = 256 * 1024

    /// The diff of the changes the commit would include: the files whose
    /// selection isn't none, against HEAD, or against the parent of the commit
    /// being amended (the empty tree for a first commit).
    ///
    /// - Throws: Git's error; `GitLibError("Diff is too large to render")`
    ///   over 10 MB.
    static func diff(_ repository: Repository, files: [WorkingDirectoryFileChange], amending: Commit?) async throws -> String {
        var commitish: String?
        if let amending {
            commitish = amending.parentSHAs.isEmpty ? try await emptyTree(repository) : "\(amending.sha)^"
        }
        return try await getFilesDiffText(repository, files, commitish)
    }

    /// The empty tree's ID in the repository's object format.
    private static func emptyTree(_ repository: Repository) async throws -> String {
        let result = try await git(
            ["hash-object", "-t", "tree", "--stdin"],
            repository.path,
            "emptyTree",
            options: GitExecutionOptions(stdin: Data())
        )
        return result.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// The repository's instructions for AI tools (`RepositoryInstructionsPaths`),
    /// from its working directory. A file that isn't there, resolves outside
    /// the repository, or can't be read is left out.
    @concurrent
    static func readRepositoryInstructions(repositoryPath: String) async -> [RepositoryInstructions] {
        RepositoryInstructionsPaths.compactMap { path in
            guard let resolved = try? ConflictContextGatherer.resolveWithin(repositoryPath, path),
                  let handle = FileHandle(forReadingAtPath: resolved)
            else {
                return nil
            }
            defer { try? handle.close() }
            guard let data = try? handle.read(upToCount: maxInstructionsReadBytes), !data.isEmpty else {
                return nil
            }
            return RepositoryInstructions(path: path, content: String(decoding: data, as: UTF8.self))
        }
    }

    /// The repository's commit message rules, as AIKit takes them
    /// (`commitMessagePatterns.getRules()`).
    static func commitMessageRules(_ rules: RepoRulesInfo?) -> [CommitMessageRule] {
        (rules?.commitMessagePatterns.getRules() ?? []).map { rule in
            let enforced: AIKit.RepoRuleEnforced = switch rule.enforced {
            case .enforced: .enforced
            case .bypass: .bypass
            case .notEnforced: .notEnforced
            }
            return CommitMessageRule(enforced: enforced, humanDescription: rule.humanDescription)
        }
    }

    /// The request for `selection`, with its credential read from the
    /// keychain now. Resolved within `selection`'s provider alone, so the
    /// request goes to the provider the user agreed to.
    ///
    /// - Throws: `AIModelRequestError` when the credential is missing or
    ///   unreadable.
    static func modelRequest(_ selection: ResolvedModelSelection, secrets: any SecretStore) async throws -> AIModelRequest {
        let key = encodeModelKey(AIModelKey(providerId: selection.provider.id, modelId: selection.model.id))
        guard let request = try await resolveAIModelRequest(selection: key, providers: [selection.provider], secretStore: secrets) else {
            throw AIModelNotConfiguredError(
                message: "The model \"\(selection.model.name)\" is no longer available from \"\(selection.provider.name)\"."
            )
        }
        return request
    }
}

/// The selected model is no longer configured. The message is shown to the
/// user.
struct AIModelNotConfiguredError: Error, LocalizedError, Sendable {
    let message: String

    var errorDescription: String? {
        message
    }
}
