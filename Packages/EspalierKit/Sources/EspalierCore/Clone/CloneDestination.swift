// Ported from desktop/app/src/ui/clone-repository/clone-repository.tsx
//
// The default folder is `~/Developer`, then the last folder used.

import Darwin
import EspalierSupport
import Foundation
import GitHubKit
import GitKit
import os
import Synchronization

private let logger = Log.logger(category: "clone")

/// Why a folder can't be cloned into.
public enum CloneDestinationProblem: Sendable, Equatable {
    /// The folder has something in it.
    case notEmpty
    /// There's a file, not a folder, at the path.
    case notAFolder
    /// The path couldn't be read.
    case unreadable

    /// The message shown to the user.
    public var message: String {
        switch self {
        case .notEmpty:
            "This folder contains files. Git can only clone to empty folders."
        case .notAFolder:
            "There is already a file with this name. Git can only clone to a folder."
        case .unreadable:
            "Couldn't read this location. Check the path and try again."
        }
    }
}

/// Something to know about a folder that doesn't stop cloning into it.
public enum CloneDestinationWarning: Sendable, Equatable {
    /// The folder's name ends in `.app`, so macOS treats it as an
    /// application bundle.
    case applicationBundle

    /// The message shown to the user.
    public var message: String {
        switch self {
        case .applicationBundle:
            "The folder's name ends in .app, so macOS will treat it as an app."
        }
    }
}

/// What to know about cloning into `path` that doesn't stop the clone: a
/// folder whose name ends in `.app`, whatever its case. Nil when there's
/// nothing.
public func clonePathWarning(_ path: String) -> CloneDestinationWarning? {
    JSCompat.endsWith(JSCompat.toLowerCase(POSIXPath.basename(POSIXPath.resolve(path))), ".app") ? .applicationBundle : nil
}

/// Validates the destination before cloning can create files in it: a
/// folder that doesn't exist yet, or an empty one. Nil when it can be
/// cloned into.
@concurrent
public func validateClonePath(_ path: String) async -> CloneDestinationProblem? {
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
/// a single safe path component, with a trailing `.app` (whatever its case)
/// as `-app`, so macOS doesn't treat the folder as an app. Nil when the
/// input names no repository.
public func cloneFolderName(_ urlOrAlias: String) -> String? {
    guard let name = parseRepositoryIdentifier(urlOrAlias).flatMap({ sanitizeCloneName($0.name) }) else {
        return nil
    }
    guard JSCompat.endsWith(JSCompat.toLowerCase(name), ".app") else {
        return name
    }
    return String(name.dropLast(4)) + "-" + String(name.suffix(3))
}

/// The clone's local path after its URL changed from `previousURL` to
/// `url`. When the previous URL named a repository, the path is the clone's
/// own folder: one named for that repository is renamed for the new one
/// (or dropped, when the new URL names none), and one the user named stays.
/// Otherwise the path is the folder the clone goes in, and the new name is
/// appended.
///
/// The Clone sheet starts from `lastCloneLocation` with an empty previous
/// URL, so the path is that folder plus the repository's name.
public func clonePath(_ path: String, afterURLChangeFrom previousURL: String, to url: String) -> String {
    let safeName = cloneFolderName(url)
    if parseRepositoryIdentifier(previousURL) != nil {
        guard let previousName = cloneFolderName(previousURL), JSCompat.strictEquals(POSIXPath.basename(path), previousName) else {
            return path
        }
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
    ///   the repository, and when no account can see an `owner/name`; an API
    ///   error when GitHub couldn't be asked about an `owner/name` (cloning it
    ///   as typed could only fail). Other API failures fall back to cloning
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
        struct Lookups {
            /// The last lookup that failed for a reason other than not
            /// finding the repository. An anonymous lookup's failure doesn't
            /// count on a server where a signed-in account didn't find it.
            var failure: (any Error)?
            /// The servers (API endpoints) where a signed-in account didn't
            /// find the repository.
            var notFoundSignedIn: Set<String> = []
        }
        let lookups = Mutex(Lookups())
        let account = await environment.withRuntimes {
            await findAccountForRemoteURL(url, accounts, canAccessRepository: { account, owner, name in
                do {
                    let found = try await API.fromAccount(account, runtime: gitHub)
                        .fetchRepositoryCloneInfo(owner: owner, name: name, protocol: nil) != nil
                    if !found, !account.token.isEmpty {
                        lookups.withLock { _ = $0.notFoundSignedIn.insert(account.endpoint) }
                    }
                    return found
                } catch {
                    lookups.withLock { lookups in
                        if !account.token.isEmpty || !lookups.notFoundSignedIn.contains(account.endpoint) {
                            lookups.failure = error
                        }
                    }
                    return false
                }
            }, runtime: gitHub)
        }
        let identifier = parseRepositoryIdentifier(url)
        let remote = parseRemote(url)

        guard let identifier, let account else {
            if let identifier, remote == nil {
                if let error = lookups.withLock({ $0.failure }) {
                    throw lookupFailed(identifier, error)
                }
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
            if remote == nil {
                throw lookupFailed(identifier, error)
            }
            return APIRepositoryCloneInfo(url: url)
        }
    }

    /// GitHub couldn't be asked about `identifier`: offline, rate limited,
    /// or another error, in GitHub's or the connection's words.
    private func lookupFailed(_ identifier: RepositoryIdentifier, _ error: any Error) -> OperationError {
        let failure = apiFailure(from: error)
        return OperationError(
            .api(APIFailure(
                message: "Couldn't look up \(identifier.owner)/\(identifier.name) on GitHub. \(failure.message)",
                status: failure.status
            )),
            operation: .clone,
            underlying: error
        )
    }

    private var repositoryNotFound: OperationError {
        OperationError(
            .precondition(
                "Couldn't find that repository. Check that you're signed in and that the URL or owner/name is spelled correctly."
            ),
            operation: .clone
        )
    }
}
