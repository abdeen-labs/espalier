// Ported from desktop/app/src/ui/clone-repository/clone-repository.tsx
//
// The default folder is `~/Developer`, then the last folder used.

import Darwin
import EspalierSupport
import Foundation
import GitHubKit
import GitKit
import os

private let logger = Log.logger(category: "clone")

/// Why a folder can't be cloned into.
public enum CloneDestinationProblem: Sendable, Equatable {
    /// The folder's name ends in `.app`, which would make an application
    /// bundle.
    case applicationBundle
    /// The folder has something in it.
    case notEmpty
    /// There's a file, not a folder, at the path.
    case notAFolder
    /// The path couldn't be read.
    case unreadable

    /// The message shown to the user.
    public var message: String {
        switch self {
        case .applicationBundle:
            "The folder's name can't end in .app, because macOS would treat it as an app. Choose a different name."
        case .notEmpty:
            "This folder contains files. Git can only clone to empty folders."
        case .notAFolder:
            "There is already a file with this name. Git can only clone to a folder."
        case .unreadable:
            "Couldn't read this location. Check the path and try again."
        }
    }
}

/// Validates the destination before cloning can create files in it: a
/// folder that doesn't exist yet, or an empty one, and not one whose name
/// ends in `.app`. Nil when it can be cloned into.
@concurrent
public func validateClonePath(_ path: String) async -> CloneDestinationProblem? {
    if JSCompat.endsWith(JSCompat.toLowerCase(POSIXPath.basename(POSIXPath.resolve(path))), ".app") {
        return .applicationBundle
    }

    guard let directory = opendir(path) else {
        switch errno {
        case ENOENT:
            // Folder does not exist.
            return nil
        case ENOTDIR:
            // Path refers to a file or other file system entry.
            return .notAFolder
        default:
            logger.error("CloneRepository: Path validation failed. Error: \(String(cString: strerror(errno)), privacy: .public)")
            return .unreadable
        }
    }
    defer { closedir(directory) }
    // The first entry other than "." and "..", without listing the rest.
    while let entry = readdir(directory) {
        let name = withUnsafeBytes(of: entry.pointee.d_name) { bytes in
            String(decoding: bytes.prefix(Int(entry.pointee.d_namlen)), as: UTF8.self)
        }
        if name != ".", name != ".." {
            return .notEmpty
        }
    }
    return nil
}

/// The folder name a clone of `urlOrAlias` gets: the repository's name, made
/// a single safe path component. Nil when the input names no repository.
public func cloneFolderName(_ urlOrAlias: String) -> String? {
    parseRepositoryIdentifier(urlOrAlias).flatMap { sanitizeCloneName($0.name) }
}

/// The clone's local path after its URL changed from `previousURL` to
/// `url`: a path that ended in the previous repository's name ends in the
/// new one's instead (or in its folder, when the new URL names none);
/// otherwise the new name is appended.
///
/// The Clone sheet starts from `lastCloneLocation` with an empty previous
/// URL, so the path is that folder plus the repository's name.
public func clonePath(_ path: String, afterURLChangeFrom previousURL: String, to url: String) -> String {
    let safeName = cloneFolderName(url)
    if parseRepositoryIdentifier(previousURL) != nil {
        if let safeName {
            return POSIXPath.join(POSIXPath.dirname(path), safeName)
        }
        return POSIXPath.dirname(path)
    }
    if let safeName {
        return POSIXPath.join(path, safeName)
    }
    return path
}

extension CloneCoordinator {
    /// Where a clone of `urlOrAlias` goes unless the user picks another
    /// folder: the last folder cloned into (`~/Developer` at first), plus the
    /// repository's name.
    public func defaultClonePath(for urlOrAlias: String) -> String {
        let directory = app?.preferences.lastCloneLocation ?? POSIXPath.join(NSHomeDirectory(), "Developer")
        return clonePath(directory, afterURLChangeFrom: "", to: urlOrAlias)
    }

    /// Resolves what the user typed, a URL or GitHub's `owner/name`, into
    /// what to clone.
    ///
    /// The account comes from `findAccountForRemoteURL`: the one signed in to
    /// the URL's host, or for `owner/name` the first that can see the
    /// repository (GitHub.com, then Enterprise, then GitHub.com without
    /// signing in). Its API gives the canonical clone URL (the SSH one for an
    /// SSH URL) and the default branch, for cloning an empty repository.
    /// Without an account, and for wikis, the input is cloned as typed.
    ///
    /// - Throws: A precondition error when the account's API doesn't find
    ///   the repository, and when no account can see an `owner/name` (cloning
    ///   it as typed could only fail). Other API failures fall back to cloning
    ///   the input as typed.
    public func resolveCloneInfo(_ urlOrAlias: String) async throws(OperationError) -> APIRepositoryCloneInfo {
        let url = JSCompat.trim(urlOrAlias)
        if JSCompat.endsWith(url, ".wiki.git") {
            return APIRepositoryCloneInfo(url: url)
        }
        guard let app else {
            return APIRepositoryCloneInfo(url: url)
        }

        let environment = app.environment
        let gitHub = environment.gitHub
        let accounts = app.accounts.accounts
        let account = await environment.withRuntimes {
            await findAccountForRemoteURL(url, accounts, runtime: gitHub)
        }
        let identifier = parseRepositoryIdentifier(url)
        let remote = parseRemote(url)

        guard let identifier, let account else {
            if identifier != nil, remote == nil {
                throw repositoryNotFound
            }
            return APIRepositoryCloneInfo(url: url)
        }

        do {
            // Respect the user's preference if they provided an SSH URL.
            let info = try await environment.withRuntimes {
                try await API.fromAccount(account, runtime: gitHub)
                    .fetchRepositoryCloneInfo(owner: identifier.owner, name: identifier.name, protocol: remote?.protocol)
            }
            guard let info else {
                throw repositoryNotFound
            }
            return info
        } catch let error as OperationError {
            throw error
        } catch {
            logger.error("Failed to look up repository clone info for '\(url, privacy: .private)': \(error.localizedDescription, privacy: .public)")
            return APIRepositoryCloneInfo(url: url)
        }
    }

    private var repositoryNotFound: OperationError {
        OperationError(
            .precondition(
                "Espalier couldn't find that repository. Check that you're signed in, that the network is available, and that the URL or owner/name is spelled correctly."
            ),
            operation: .clone
        )
    }
}
