// Ported from desktop/app/src/lib/stores/updates/update-remote-url.ts

import EspalierSupport
import Foundation
import GitHubKit
import GitKit
import os

private let logger = Log.logger(category: "github-association")

extension AppModel {
    /// After the API refreshed a repository's GitHub repository, points the
    /// default remote at the API's clone URL when the repository was renamed
    /// or transferred on GitHub.
    ///
    /// The remote changes only when (`updatedRemoteURL`) both URLs have the
    /// same protocol, so a user relying on one keeps it (scp-style SSH
    /// remotes, which have none, are never touched); the remote still
    /// matches the clone URL stored before, so a remote the user pointed
    /// elsewhere stays; and the new clone URL doesn't already match it.
    ///
    /// The write is background work in the repository's network lane (remote
    /// configuration is shared by its worktrees): it doesn't run while
    /// another operation holds the lane, and the next refresh of the
    /// association tries again. The remote is read again under the lane, so
    /// a change made meanwhile is never overwritten.
    ///
    /// - Parameters:
    ///   - gitHubRepository: The repository's GitHub repository before the
    ///     refresh.
    ///   - apiRepository: The repository as the API returned it.
    func updateRemoteUrl(_ id: RepositoryID, _ gitHubRepository: GitHubRepository, _ apiRepository: APIRepository) async {
        // I'm not sure when these early exit conditions would be met. But
        // when they are we don't have enough information to continue so exit
        // early!
        guard let record = record(id), let defaultRemote = await defaultRemote(of: record),
              let updatedURL = updatedRemoteURL(defaultRemote, gitHubRepository, apiRepository),
              let model = repository(id)
        else {
            return
        }

        let descriptor = OperationDescriptor(kind: .setRemoteURL, lanes: [.network], policy: .background)
        do {
            let updated = try await model.performIfIdle(descriptor) { context in
                let remotes = try await getRemotes(context.repository)
                guard let current = findDefaultRemote(remotes), remoteEquals(current, defaultRemote) else {
                    return false
                }
                try await setRemoteURL(context.repository, current.name, updatedURL)
                return true
            }
            switch updated {
            case true?:
                logger.info("Pointed \(defaultRemote.name, privacy: .public) at the renamed GitHub repository \(apiRepository.owner.login, privacy: .public)/\(apiRepository.name, privacy: .public)")
            case false?:
                logger.info("Left \(defaultRemote.name, privacy: .public) alone: it changed while the GitHub repository was being looked up")
            case nil:
                logger.info("Didn't update \(defaultRemote.name, privacy: .public) for the renamed GitHub repository: another operation is running")
            }
        } catch {
            logger.error("Could not update \(defaultRemote.name, privacy: .public) for the renamed GitHub repository: \(error.message, privacy: .private)")
        }
    }
}

/// The URL to point the default remote at after the API refreshed the
/// repository's GitHub repository, or nil to leave the remote alone.
///
/// - Parameters:
///   - defaultRemote: The repository's default remote.
///   - gitHubRepository: The GitHub repository before the refresh.
///   - apiRepository: The repository as the API returned it.
func updatedRemoteURL(_ defaultRemote: Remote, _ gitHubRepository: GitHubRepository, _ apiRepository: APIRepository) -> String? {
    let remoteUrl = defaultRemote.url
    let updatedRemoteUrl = apiRepository.cloneURL
    let urlsMatch = urlMatchesRemote(updatedRemoteUrl, remoteURL: remoteUrl)

    // Verify that protocol hasn't changed. If it has we don't want to alter
    // the protocol in case they are relying on a specific one. If protocol
    // is null that implies the url is a ssh url of the format
    // git@github.com:octocat/Hello-World.git, which can't be parsed by
    // URL.parse. In this case we assume the user manually configured their
    // remote to use this format and we don't want to change what they've done
    // just to be safe
    let remoteProtocol = nodeURLProtocol(remoteUrl)
    let updatedProtocol = nodeURLProtocol(updatedRemoteUrl)
    let protocolsMatch = remoteProtocol != nil && updatedProtocol != nil && remoteProtocol == updatedProtocol

    // Check if the default remote url has been manually changed from the
    // clone url retrieved from the GitHub API previously
    let remoteUrlUnchanged = urlMatchesRemote(gitHubRepository.cloneURL, remoteURL: remoteUrl)

    return protocolsMatch && remoteUrlUnchanged && !urlsMatch ? updatedRemoteUrl : nil
}

/// The protocol Node's legacy `url.parse(url).protocol` reports, lowercased
/// with its colon (`https:`), or nil when there is none: the leading run of
/// letters, digits, `+`, `-`, and `.` before a colon, after Node trims
/// whitespace (code units up to a space, U+00A0, and U+FEFF).
func nodeURLProtocol(_ url: String) -> String? {
    let isWhitespace: (UTF16.CodeUnit) -> Bool = { $0 < 33 || $0 == 0xA0 || $0 == 0xFEFF }
    let codeUnits = Array(url.utf16)
    guard let first = codeUnits.firstIndex(where: { !isWhitespace($0) }) else {
        return nil
    }

    var index = first
    while index < codeUnits.count, isProtocolCharacter(codeUnits[index]) {
        index += 1
    }
    guard index > first, index < codeUnits.count, codeUnits[index] == UInt16(UInt8(ascii: ":")) else {
        return nil
    }
    return String(decoding: codeUnits[first...index], as: UTF16.self).lowercased()
}

private func isProtocolCharacter(_ unit: UTF16.CodeUnit) -> Bool {
    switch unit {
    case 0x30...0x39, 0x41...0x5A, 0x61...0x7A: true    // 0-9 A-Z a-z
    case 0x2B, 0x2D, 0x2E: true                          // + - .
    default: false
    }
}
