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
    /// The path isn't a full path: git and this process would resolve it
    /// against different folders.
    case notFullPath

    /// The message shown to the user.
    public var message: String {
        switch self {
        case .notEmpty:
            "This folder contains files. Git can only clone to empty folders."
        case .notAFolder:
            "There is already a file with this name. Git can only clone to a folder."
        case .unreadable:
            "Couldn't read this location. Check the path and try again."
        case .notFullPath:
            "Choose the folder to clone into by its full path."
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
/// full path to a folder that doesn't exist yet, or an empty one. Nil when
/// it can be cloned into.
@concurrent
public func validateClonePath(_ path: String) async -> CloneDestinationProblem? {
    guard POSIXPath.isAbsolute(path) else {
        return .notFullPath
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
    /// what to clone: the canonical clone URL (the SSH one for an SSH URL)
    /// and the default branch, for cloning an empty repository.
    ///
    /// A URL is looked up with every account signed in to its server in
    /// turn, then GitHub.com without signing in (`resolveURLCloneInfo`); one
    /// account that can't see it never stops the others. Nothing can see it:
    /// an SSH URL is cloned as typed (the user's SSH keys may have access),
    /// an HTTPS one isn't found. With `account` (the Clone sheet's GitHub
    /// list), only it is asked, and the URL is cloned as typed when it
    /// can't be. For `owner/name`, the account is the first that can see
    /// the repository (GitHub.com, then Enterprise, then GitHub.com without
    /// signing in, `findAccountForRemoteURL`). Wikis, and URLs on a server
    /// without an account, are cloned as typed. Which account the clone uses
    /// is chosen when it starts.
    ///
    /// - Throws: A precondition error when no account can see an HTTPS URL
    ///   or an `owner/name`; an API error when GitHub couldn't be asked about
    ///   an `owner/name` (cloning it as typed could only fail).
    public func resolveCloneInfo(_ urlOrAlias: String, account: AccountIdentity? = nil) async throws(OperationError) -> APIRepositoryCloneInfo {
        let url = JSCompat.trim(urlOrAlias)
        if JSCompat.endsWith(url, ".wiki.git") {
            return APIRepositoryCloneInfo(url: url)
        }
        guard let app else {
            return APIRepositoryCloneInfo(url: url)
        }

        let environment = app.environment
        let gitHub = environment.gitHub
        let lookup = lookupCloneInfo(runtime: gitHub)

        if let remote = parseRemote(url) {
            var accounts = app.accounts.accounts
            if let account {
                accounts = accounts.filter { $0.identity == account }
                guard let picked = accounts.first, remoteMatchesEndpoint(remote, picked.endpoint) else {
                    return APIRepositoryCloneInfo(url: url)
                }
                do {
                    let info = try await environment.withRuntimes {
                        try await lookup(picked, remote.owner, remote.name, remote.protocol)
                    }
                    return info ?? APIRepositoryCloneInfo(url: url)
                } catch {
                    logger.error("Failed to look up repository clone info for '\(url, privacy: .private)': \(error.localizedDescription, privacy: .public)")
                    return APIRepositoryCloneInfo(url: url)
                }
            }
            let resolution = await environment.withRuntimes {
                await resolveURLCloneInfo(remote, url: url, accounts: accounts, lookup: lookup)
            }
            switch resolution {
            case .clone(let info):
                return info
            case .notFound:
                throw repositoryNotFound
            }
        }

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
                    let found = try await lookup(account, owner, name, nil) != nil
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

        guard let identifier = parseRepositoryIdentifier(url) else {
            return APIRepositoryCloneInfo(url: url)
        }
        guard let account else {
            if let error = lookups.withLock({ $0.failure }) {
                throw lookupFailed(identifier, error)
            }
            throw repositoryNotFound
        }

        do {
            let info = try await environment.withRuntimes {
                try await lookup(account, identifier.owner, identifier.name, nil)
            }
            guard let info else {
                throw repositoryNotFound
            }
            return info
        } catch let error as OperationError {
            throw error
        } catch {
            logger.error("Failed to look up repository clone info for '\(url, privacy: .private)': \(error.localizedDescription, privacy: .public)")
            throw lookupFailed(identifier, error)
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
